#ifndef CHENGGUAN_DISPLAY_BRIDGE_H
#define CHENGGUAN_DISPLAY_BRIDGE_H
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>
// All unavailable private entry points fail closed. No implicit default display.
CFDictionaryRef _Nullable cd_copy_display_info(uint32_t display) CF_RETURNS_RETAINED;
int cd_native_brightness(uint32_t display, float * _Nonnull value);
int cd_set_native_brightness(uint32_t display, float value);
int cd_ddc_read(uint32_t display, const char * _Nonnull uuid, uint8_t code, uint16_t * _Nonnull current, uint16_t * _Nonnull maximum);
int cd_ddc_write(uint32_t display, const char * _Nonnull uuid, uint8_t code, uint16_t value);
bool cd_ddc_validate(const uint8_t * _Nonnull bytes, int length, uint8_t code, uint16_t * _Nonnull current, uint16_t * _Nonnull maximum);
#endif
