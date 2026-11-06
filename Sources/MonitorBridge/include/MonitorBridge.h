#ifndef MONITOR_BRIDGE_H
#define MONITOR_BRIDGE_H
#include <stdint.h>
#include <stdbool.h>
#include <CoreAudio/CoreAudio.h>
#define VR_MAX_CORES 128
typedef struct {
    uint64_t user, system, idle, nice;
} VRTicks;
typedef struct {
    int core_count;
    VRTicks cores[VR_MAX_CORES];
    uint64_t memory_total, memory_app, memory_wired, memory_compressed, memory_free, memory_cached, swap_used;
    int pressure_level;
    double load[3];
    uint64_t network_in, network_out;
} VRSystem;
typedef struct {
    int pid, ppid;
    unsigned int uid;
    uint64_t start_sec, cpu_ns, memory, read_bytes, write_bytes, wakeups;
    uint64_t energy_nj;
    bool energy_measured;
    bool measured;
    int read_error;
    char name[256];
    char path[4096];
} VRProcess;
bool vr_read_system(VRSystem *out);
int vr_process_capacity(void);
int vr_read_processes(VRProcess *out, int capacity);
bool vr_process_cwd(int pid, char *out, int capacity);
uint64_t vr_process_start(int pid);
int vr_process_signal(int pid, uint64_t expected_start, int signal);
typedef struct VRGain VRGain;
VRGain *vr_gain_create(float gain, double sample_rate);
void vr_gain_destroy(VRGain *gain);
void vr_gain_set(VRGain *gain, float target);
uint64_t vr_gain_callbacks(VRGain *gain);
float vr_gain_input_rms(VRGain *gain);
float vr_gain_output_rms(VRGain *gain);
void vr_gain_render(VRGain *gain, const AudioBufferList *input, AudioBufferList *output, unsigned int first_input_buffer);
int32_t vr_audio_disable_hardware_inputs(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t hardware_streams);
#endif
