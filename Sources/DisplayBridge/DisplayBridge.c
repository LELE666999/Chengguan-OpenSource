// DDC transport derived from waydabber/m1ddc (MIT), see Vendor/m1ddc-LICENSE.
// Adaptations: bounded lifetime, dynamic symbol checks, UUID targeting and reply validation.
#include "DisplayBridge.h"
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSync.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>

static void *core, *displayServices;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void load(void) {
  core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
  displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
}
CFDictionaryRef cd_copy_display_info(uint32_t display) {
  pthread_once(&once, load);
  CFDictionaryRef (*copy)(uint32_t) = core ? dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary") : NULL;
  return copy ? copy(display) : NULL;
}
int cd_native_brightness(uint32_t display, float *value) {
  pthread_once(&once, load);
  int (*get)(uint32_t, float *) = displayServices ? dlsym(displayServices, "DisplayServicesGetBrightness") : NULL;
  return get ? get(display, value) : -1;
}
int cd_set_native_brightness(uint32_t display, float value) {
  pthread_once(&once, load);
  if (!(value >= 0 && value <= 1)) return -1;
  int (*set)(uint32_t, float) = displayServices ? dlsym(displayServices, "DisplayServicesSetBrightness") : NULL;
  return set ? set(display, value) : -1;
}
static bool matches(uint32_t display, const char *expected) {
  if (!CGDisplayIsOnline(display)) return false;
  CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(display);
  if (!uuid) return false;
  CFStringRef text = CFUUIDCreateString(NULL, uuid);
  char buffer[128] = {0};
  bool ok = text && CFStringGetCString(text, buffer, sizeof buffer, kCFStringEncodingUTF8) && strcmp(buffer, expected) == 0;
  if (text) CFRelease(text);
  CFRelease(uuid);
  return ok;
}
typedef CFTypeRef AVRef;
typedef struct { AVRef service; uint32_t chip; } Transport;
static Transport transport(uint32_t display, const char *uuid) {
  Transport result = {0, 0x37};
  if (!matches(display, uuid) || CGDisplayIsBuiltin(display)) return result;
  CFDictionaryRef info = cd_copy_display_info(display);
  if (!info) return result;
  CFStringRef path = CFDictionaryGetValue(info, CFSTR("IODisplayLocation"));
  io_registry_entry_t adapter = path && CFGetTypeID(path) == CFStringGetTypeID() ? IORegistryEntryCopyFromPath(kIOMainPortDefault, path) : 0;
  CFRelease(info);
  if (!adapter) return result;
  uint64_t targetID = 0;
  IORegistryEntryGetRegistryEntryID(adapter, &targetID);
  IOObjectRelease(adapter);
  AVRef (*create)(CFAllocatorRef, io_service_t) = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
  if (!create) return result;
  io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
  io_iterator_t iterator = 0;
  kern_return_t status = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
  IOObjectRelease(root);
  if (status != KERN_SUCCESS) return result;
  bool selected = false;
  io_service_t entry;
  while ((entry = IOIteratorNext(iterator))) {
    if (IOObjectConformsTo(entry, "IOMobileFramebuffer")) {
      uint64_t entryID = 0;
      IORegistryEntryGetRegistryEntryID(entry, &entryID);
      selected = entryID == targetID;
    } else if (selected && IOObjectConformsTo(entry, "DCPAVServiceProxy")) {
      CFTypeRef location = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, CFSTR("Location"), NULL, kIORegistryIterateRecursively);
      bool external = location && CFGetTypeID(location) == CFStringGetTypeID() && CFEqual(location, CFSTR("External"));
      if (location) CFRelease(location);
      if (external) {
        result.service = create(NULL, entry);
        io_registry_entry_t parent = 0;
        if (IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS) {
          CFTypeRef provider = IORegistryEntryCreateCFProperty(parent, CFSTR("EPICProviderClass"), NULL, 0);
          if (provider && CFEqual(provider, CFSTR("AppleDCPMCDP29XX"))) result.chip = 0xB7;
          if (provider) CFRelease(provider);
          IOObjectRelease(parent);
        }
      }
    }
    IOObjectRelease(entry);
    if (result.service) break;
  }
  IOObjectRelease(iterator);
  return result;
}
bool cd_ddc_validate(const uint8_t *b, int length, uint8_t code, uint16_t *current, uint16_t *maximum) {
  if (length < 11 || b[0] != 0x6e || (b[1] & 0x7f) != 8 || b[2] != 2 || b[3] != 0 || b[4] != code) return false;
  uint8_t checksum = 0x50;
  for (int i = 0; i < 11; i++) checksum ^= b[i];
  if (checksum != 0) return false;
  *maximum = ((uint16_t)b[6] << 8) | b[7];
  *current = ((uint16_t)b[8] << 8) | b[9];
  return true;
}
int cd_ddc_read(uint32_t display, const char *uuid, uint8_t code, uint16_t *current, uint16_t *maximum) {
  Transport t = transport(display, uuid);
  if (!t.service) return -1;
  int (*write)(AVRef, uint32_t, uint32_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
  int (*read)(AVRef, uint32_t, uint32_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
  if (!read || !write) { CFRelease(t.service); return -1; }
  int status = -1;
  for (int attempt = 0; attempt < 2; attempt++) {
    uint8_t request[] = {0x82, 0x01, code, (uint8_t)(0x6e ^ 0x82 ^ 0x01 ^ code)};
    // Some monitors need the request repeated; shorter waits can return a valid
    // I2C transfer containing a DDC null reply instead of the requested feature.
    for (int n = 0; n < 2; n++) {
      usleep(50000);
      status = write(t.service, t.chip, 0x51, request, sizeof request);
      if (status) break;
    }
    if (status) continue;
    usleep(200000);
    uint8_t reply[12] = {0};
    status = read(t.service, t.chip, 0x51, reply, sizeof reply);
    if (!status && cd_ddc_validate(reply, sizeof reply, code, current, maximum)) break;
    status = -2;
  }
  CFRelease(t.service);
  return status;
}
int cd_ddc_write(uint32_t display, const char *uuid, uint8_t code, uint16_t value) {
  Transport t = transport(display, uuid);
  if (!t.service) return -1;
  int (*write)(AVRef, uint32_t, uint32_t, void *, uint32_t) = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
  uint8_t packet[] = {0x84, 0x03, code, (uint8_t)(value >> 8), (uint8_t)value, 0};
  packet[5] = 0x6e ^ 0x51 ^ packet[0] ^ packet[1] ^ packet[2] ^ packet[3] ^ packet[4];
  int status = -1;
  if (write) {
    for (int n = 0; n < 2; n++) {
      usleep(50000); status = write(t.service, t.chip, 0x51, packet, sizeof packet);
      if (status) break;
    }
  }
  CFRelease(t.service);
  return status;
}
