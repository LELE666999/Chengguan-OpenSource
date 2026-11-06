#include "MonitorBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stddef.h>
#include <math.h>
#include <string.h>

struct VRGain { _Atomic float target, input_rms, output_rms; float current, step; _Atomic uint64_t callbacks; };
VRGain *vr_gain_create(float gain, double sample_rate) {
    VRGain *state = calloc(1, sizeof(VRGain));
    if (!state) return NULL;
    atomic_init(&state->target, fminf(1, fmaxf(0, gain)));
    atomic_init(&state->callbacks, 0);
    atomic_init(&state->input_rms, 0);
    atomic_init(&state->output_rms, 0);
    state->current = gain;
    state->step = (float)(1.0 / fmax(1, sample_rate * 0.02));
    return state;
}
void vr_gain_destroy(VRGain *state) { free(state); }
void vr_gain_set(VRGain *state, float target) {
    if (state) atomic_store_explicit(&state->target, isfinite(target) ? fminf(1, fmaxf(0, target)) : 1, memory_order_relaxed);
}
uint64_t vr_gain_callbacks(VRGain *state) { return state ? atomic_load_explicit(&state->callbacks, memory_order_relaxed) : 0; }
float vr_gain_input_rms(VRGain *state) { return state ? atomic_load_explicit(&state->input_rms, memory_order_relaxed) : 0; }
float vr_gain_output_rms(VRGain *state) { return state ? atomic_load_explicit(&state->output_rms, memory_order_relaxed) : 0; }
static float input_sample(const AudioBufferList *input, unsigned int first, unsigned int channel, unsigned int frame) {
    for (unsigned int b = first; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (channel >= buffer->mNumberChannels) { channel -= buffer->mNumberChannels; continue; }
        unsigned int index = frame * buffer->mNumberChannels + channel;
        if (!buffer->mData || index >= buffer->mDataByteSize / sizeof(float)) return 0;
        float value = ((const float *)buffer->mData)[index];
        return isfinite(value) ? value : 0;
    }
    return 0;
}
void vr_gain_render(VRGain *state, const AudioBufferList *input, AudioBufferList *output, unsigned int first) {
    if (!state || !input || !output) return;
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
    float target = atomic_load_explicit(&state->target, memory_order_relaxed);
    unsigned int frames = 0;
    for (unsigned int b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (buffer->mData) memset(buffer->mData, 0, buffer->mDataByteSize);
        if (buffer->mData && buffer->mNumberChannels) {
            unsigned int count = buffer->mDataByteSize / (sizeof(float) * buffer->mNumberChannels);
            if (count > frames) frames = count;
        }
    }
    double input_power = 0, output_power = 0;
    unsigned int samples = 0;
    for (unsigned int frame = 0; frame < frames; frame++) {
        float diff = target - state->current;
        state->current += fminf(state->step, fmaxf(-state->step, diff));
        unsigned int channel = 0;
        for (unsigned int b = 0; b < output->mNumberBuffers; b++) {
            AudioBuffer *buffer = &output->mBuffers[b];
            for (unsigned int c = 0; c < buffer->mNumberChannels; c++, channel++) {
                unsigned int index = frame * buffer->mNumberChannels + c;
                if (!buffer->mData || index >= buffer->mDataByteSize / sizeof(float)) continue;
                float source = channel < 2 ? input_sample(input, first, channel, frame) : 0;
                float value = source * state->current;
                ((float *)buffer->mData)[index] = fminf(1, fmaxf(-1, value));
                if (channel < 2) { input_power += (double)source * source; output_power += (double)value * value; samples++; }
            }
        }
    }
    atomic_store_explicit(&state->input_rms, samples ? (float)sqrt(input_power / samples) : 0, memory_order_relaxed);
    atomic_store_explicit(&state->output_rms, samples ? (float)sqrt(output_power / samples) : 0, memory_order_relaxed);
}
int32_t vr_audio_disable_hardware_inputs(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t hardware) {
    AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 bytes = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &bytes);
    if (status) return status;
    UInt32 count = bytes / sizeof(AudioStreamID);
    if (count <= hardware) return kAudioHardwareBadStreamError;
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = count;
    for (UInt32 i = hardware; i < count; i++) usage->mStreamIsOn[i] = 1;
    AudioObjectPropertyAddress property = {kAudioDevicePropertyIOProcStreamUsage, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    status = AudioObjectSetPropertyData(device, &property, 0, NULL, (UInt32)size, usage);
    free(usage);
    return status;
}
