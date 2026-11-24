#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef void *NAMEngineRef;
/* Param ids: 0 input dB, 1 gate dB (-90 = off), 2 bass, 3 mid, 4 treble, 5 output dB */
NAMEngineRef NAMEngineCreate(void);
void NAMEngineDestroy(NAMEngineRef);
void NAMEnginePrepare(NAMEngineRef, double sampleRate, int maxFrames);
bool NAMEngineLoadModel(NAMEngineRef, const char *path); /* blocking: call off the audio thread */
void NAMEngineSetParam(NAMEngineRef, int id, float value);
void NAMEngineProcess(NAMEngineRef, const float *in, float *outL, float *outR, int frames);
#ifdef __cplusplus
}
#endif
