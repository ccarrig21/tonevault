#pragma once
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef void *NAMEngineRef;

enum {
    /* Legacy core params (addresses 0..5 preserved for session compatibility) */
    TVParamInput = 0,
    TVParamGateThr = 1,
    TVParamBass = 2,
    TVParamMid = 3,
    TVParamTreble = 4,
    TVParamOutput = 5,

    /* Block enable flags (0 = bypassed, 1 = active) */
    TVParamGateOn = 6,
    TVParamCompOn = 7,
    TVParamDriveOn = 8,
    TVParamAmpOn = 9,
    TVParamCabOn = 10,
    TVParamModOn = 11,
    TVParamDelayOn = 12,
    TVParamReverbOn = 13,

    /* Gate extra */
    TVParamGateRel = 14,

    /* Compressor */
    TVParamCompThr = 15,
    TVParamCompRatio = 16,
    TVParamCompAtk = 17,
    TVParamCompRel = 18,
    TVParamCompGain = 19,
    TVParamCompMix = 20,

    /* Overdrive */
    TVParamDrive = 21,
    TVParamDriveTone = 22,
    TVParamDriveLvl = 23,
    TVParamDriveMode = 24,

    /* Cab IR */
    TVParamCabLoCut = 25,
    TVParamCabHiCut = 26,
    TVParamCabLevel = 27,

    /* Modulation */
    TVParamModMode = 28,
    TVParamModRate = 29,
    TVParamModDepth = 30,
    TVParamModMix = 31,

    /* Delay */
    TVParamDelayMode = 32,
    TVParamDelayTime = 33,
    TVParamDelayFdbk = 34,
    TVParamDelayTone = 35,
    TVParamDelayMix = 36,

    /* Reverb */
    TVParamRevMode = 37,
    TVParamRevDecay = 38,
    TVParamRevPreDly = 39,
    TVParamRevDamp = 40,
    TVParamRevMix = 41,

    TVParamCount = 42
};

/* Block IDs for chain ordering */
enum {
    TVBlockGate = 0,
    TVBlockComp = 1,
    TVBlockDrive = 2,
    TVBlockAmp = 3,
    TVBlockCab = 4,
    TVBlockMod = 5,
    TVBlockDelay = 6,
    TVBlockReverb = 7,
    TVBlockCount = 8
};

NAMEngineRef NAMEngineCreate(void);
void NAMEngineDestroy(NAMEngineRef);
void NAMEnginePrepare(NAMEngineRef, double sampleRate, int maxFrames);
bool NAMEngineLoadModel(NAMEngineRef, const char *path); /* pass NULL/"" to unload */
bool NAMEngineLoadIR(NAMEngineRef, const float *samples, int count); /* pass NULL/0 to unload */
void NAMEngineSetParam(NAMEngineRef, int id, float value);
void NAMEngineSetChainOrder(NAMEngineRef, const int *order, int count);
void NAMEngineProcess(NAMEngineRef, const float *in, float *outL, float *outR, int frames);

#ifdef __cplusplus
}
#endif