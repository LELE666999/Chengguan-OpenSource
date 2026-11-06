#include "MonitorBridge.h"
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/host_info.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>
#include <sys/resource.h>
#include <sys/proc_info.h>
#include <libproc.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>

bool vr_read_system(VRSystem *out) {
    memset(out, 0, sizeof(*out));
    mach_port_t host = mach_host_self();
    natural_t cores = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cores, &info, &count);
    if (result == KERN_SUCCESS) {
        out->core_count = cores < VR_MAX_CORES ? (int)cores : VR_MAX_CORES;
        for (int i=0; i<out->core_count; i++) {
            out->cores[i].user = (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_USER];
            out->cores[i].system = (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_SYSTEM];
            out->cores[i].idle = (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_IDLE];
            out->cores[i].nice = (uint32_t)info[i*CPU_STATE_MAX+CPU_STATE_NICE];
        }
        vm_deallocate(mach_task_self(), (vm_address_t)info, count*sizeof(integer_t));
    }
    vm_statistics64_data_t vm = {0};
    mach_msg_type_number_t vmcount = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    host_page_size(host, &page);
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vmcount) == KERN_SUCCESS) {
        out->memory_wired = (uint64_t)vm.wire_count*page;
        out->memory_compressed = (uint64_t)vm.compressor_page_count*page;
        out->memory_app = ((uint64_t)vm.internal_page_count > vm.purgeable_count ? (uint64_t)vm.internal_page_count-vm.purgeable_count : 0)*page;
        out->memory_free = (uint64_t)vm.free_count*page;
        out->memory_cached = ((uint64_t)vm.external_page_count+vm.purgeable_count)*page;
    }
    size_t sz = sizeof(out->memory_total);
    sysctlbyname("hw.memsize", &out->memory_total, &sz, NULL, 0);
    struct xsw_usage swap = {0}; sz = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &sz, NULL, 0)==0) out->swap_used=swap.xsu_used;
    sz=sizeof(out->pressure_level);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure_level, &sz, NULL, 0);
    getloadavg(out->load, 3);
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *p=ifs; p; p=p->ifa_next) {
            // Sum physical interfaces; exclude loopback/VPN bridges to avoid double counting.
            if (!p->ifa_addr || p->ifa_addr->sa_family!=AF_LINK || !p->ifa_data || strncmp(p->ifa_name,"en",2)) continue;
            struct if_data *data=p->ifa_data;
            out->network_in+=data->ifi_ibytes; out->network_out+=data->ifi_obytes;
        }
        freeifaddrs(ifs);
    }
    mach_port_deallocate(mach_task_self(), host);
    return result==KERN_SUCCESS;
}

int vr_process_capacity(void) {
    int bytes=proc_listpids(PROC_ALL_PIDS,0,NULL,0);
    int n=bytes>0 ? bytes/(int)sizeof(pid_t):1024;
    return n+n/4+128;
}
int vr_read_processes(VRProcess *out, int capacity) {
    mach_timebase_info_data_t timebase={0};
    mach_timebase_info(&timebase);
    int needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (needed<=0 || capacity<=0) return 0;
    int bytes=needed+4096;
    pid_t *pids=calloc(1, bytes);
    if (!pids) return 0;
    int n=proc_listpids(PROC_ALL_PIDS, 0, pids, bytes)/(int)sizeof(pid_t), used=0;
    for (int i=0; i<n && used<capacity; i++) {
        if(pids[i]<=0) continue;
        struct proc_bsdinfo bsd={0};
        bool has_metadata=proc_pidinfo(pids[i],PROC_PIDTBSDINFO,0,&bsd,sizeof(bsd))==sizeof(bsd);
        if(!has_metadata && kill(pids[i],0)!=0 && errno==ESRCH) continue;
        VRProcess *p=&out[used++]; memset(p,0,sizeof(*p));
        p->pid=pids[i]; p->ppid=bsd.pbi_ppid; p->uid=has_metadata ? bsd.pbi_uid:UINT32_MAX; p->start_sec=bsd.pbi_start_tvsec;
        if(has_metadata) strlcpy(p->name, bsd.pbi_name[0]?bsd.pbi_name:bsd.pbi_comm, sizeof(p->name));
        else {
            // KERN_PROC_PID exposes basic identity even when resource counters are restricted.
            int mib[]={CTL_KERN,KERN_PROC,KERN_PROC_PID,p->pid};
            struct kinfo_proc basic={0}; size_t basic_size=sizeof(basic);
            if(sysctl(mib,4,&basic,&basic_size,NULL,0)==0 && basic_size==sizeof(basic) && basic.kp_proc.p_pid==p->pid) {
                p->ppid=basic.kp_eproc.e_ppid; p->uid=basic.kp_eproc.e_ucred.cr_uid;
                p->start_sec=basic.kp_proc.p_starttime.tv_sec;
                strlcpy(p->name,basic.kp_proc.p_comm,sizeof(p->name));
            } else if(proc_name(p->pid,p->name,sizeof(p->name))<=0) strlcpy(p->name,"System process",sizeof(p->name));
        }
        proc_pidpath(p->pid,p->path,sizeof(p->path));
        struct rusage_info_v4 usage={0};
        int usage_status = -1;
#ifdef RUSAGE_INFO_V6
        struct rusage_info_v6 extended_usage={0};
        usage_status=proc_pid_rusage(p->pid,RUSAGE_INFO_V6,(rusage_info_t*)&extended_usage);
        if(usage_status==0) {
            memcpy(&usage,&extended_usage,sizeof(usage));
            p->energy_nj=extended_usage.ri_energy_nj;
            p->energy_measured=true;
        }
#endif
        if(usage_status!=0) usage_status=proc_pid_rusage(p->pid,RUSAGE_INFO_V4,(rusage_info_t*)&usage);
        if(usage_status==0) {
            p->measured=true;
            // proc_pid_rusage reports Mach absolute-time ticks, not nanoseconds on Apple Silicon.
            p->cpu_ns=(uint64_t)(((__uint128_t)usage.ri_user_time+usage.ri_system_time)*timebase.numer/timebase.denom);
            p->memory=usage.ri_phys_footprint; p->read_bytes=usage.ri_diskio_bytesread;
            p->write_bytes=usage.ri_diskio_byteswritten; p->wakeups=usage.ri_interrupt_wkups+usage.ri_pkg_idle_wkups;
        } else {
            p->read_error=errno;
            // A process that exited during enumeration is not a permission failure.
            if(p->read_error==ESRCH) { used--; continue; }
        }
    }
    free(pids); return used;
}
bool vr_process_cwd(int pid,char *out,int capacity) {
    struct proc_vnodepathinfo paths={0};
    if(proc_pidinfo(pid,PROC_PIDVNODEPATHINFO,0,&paths,sizeof(paths))!=sizeof(paths)) return false;
    strlcpy(out,paths.pvi_cdir.vip_path,capacity); return out[0]!=0;
}
uint64_t vr_process_start(int pid) {
    struct proc_bsdinfo b={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)) return 0;
    return b.pbi_start_tvsec;
}
int vr_process_signal(int pid,uint64_t expected_start,int sig) {
    if(pid<=1 || pid==getpid() || !expected_start || vr_process_start(pid)!=expected_start) return ESRCH;
    struct proc_bsdinfo b={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b) || b.pbi_uid!=getuid()) return EPERM;
    return kill(pid,sig)==0 ? 0 : errno;
}
