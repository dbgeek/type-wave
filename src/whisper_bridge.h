#ifndef TYPE_WAVE_WHISPER_BRIDGE_H
#define TYPE_WAVE_WHISPER_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tw_whisper_runtime tw_whisper_runtime;

tw_whisper_runtime * tw_whisper_create(int model_fd);
void tw_whisper_destroy(tw_whisper_runtime * runtime);
bool tw_whisper_warm(tw_whisper_runtime * runtime);
void tw_whisper_begin_inference(tw_whisper_runtime * runtime);
bool tw_whisper_request_cancel(tw_whisper_runtime * runtime);
int tw_whisper_transcribe(
    tw_whisper_runtime * runtime,
    uint8_t language,
    const float * samples,
    size_t sample_count,
    const char ** text,
    size_t * text_len);

#ifdef __cplusplus
}
#endif

#endif
