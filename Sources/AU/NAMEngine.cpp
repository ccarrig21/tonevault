#include "NAMEngine.h"
#include "EffectsDSP.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <mutex>
#include <vector>
#include "NAM/dsp.h"
#if __has_include("NAM/get_dsp.h")
#include "NAM/get_dsp.h"
#endif

namespace {

static constexpr int kEnableParam[TVBlockCount] = {
    TVParamGateOn, TVParamCompOn, TVParamDriveOn, TVParamAmpOn,
    TVParamCabOn, TVParamModOn, TVParamDelayOn, TVParamReverbOn,
    TVParamDenoiseOn
};

inline uint64_t packOrder(const int *order) {
    uint64_t v = 0;
    for (int i = 0; i < TVBlockCount; ++i) {
        v |= (uint64_t)(order[i] & 0xF) << (i * 4);
    }
    return v;
}

struct Engine {
    std::mutex ampMtx;
    std::unique_ptr<nam::DSP> dsp;

    std::mutex irMtx;
    std::unique_ptr<tv::IRConvolver> ir;

    double sr = 48000.0;
    int maxFrames = 1024;

    std::vector<NAM_SAMPLE> namIn, namOut;
    std::vector<float> bufL, bufR, dryL, dryR;

    std::atomic<float> p[TVParamCount];
    std::atomic<bool> eqDirty{true};
    std::atomic<bool> cabDirty{true};
    // Default order: Denoise(8), Gate(0), Comp(1), Drive(2), Amp(3), Cab(4), Mod(5), Delay(6), Reverb(7)
    std::atomic<uint64_t> chainOrder{0x765432108ULL};

    // DSP units
    tv::Biquad eqLo, eqMid, eqHi;
    tv::Biquad cabHP, cabLP;
    float gateEnv = 0.0f, gateGain = 1.0f;
    tv::SpectralDenoiser denoise;
    bool denoiseWasActive = false;
    tv::Compressor comp;
    tv::Overdrive drive;
    tv::Modulation mod;
    tv::StereoDelay delay;
    tv::FDNReverb reverb;

    // Clickless per-block bypass smoothing
    std::array<float, TVBlockCount> blkSmooth{1, 0, 0, 1, 1, 0, 0, 0, 0};

    Engine() {
        const float defs[TVParamCount] = {
            0, -70, 0, 0, 0, 0,                    // 0..5 core
            1, 0, 0, 1, 1, 0, 0, 0,                // 6..13 enables
            60,                                    // 14 gate rel
            -22, 4, 10, 120, 3, 100,               // 15..20 comp
            45, 55, 0, 0,                          // 21..24 drive
            80, 9500, 0,                           // 25..27 cab
            0, 1.2f, 50, 45,                       // 28..31 mod
            1, 360, 38, 4200, 28,                  // 32..36 delay
            1, 2.2f, 20, 6500, 25,                 // 37..41 reverb
            0, 24, 3, 45, 100                      // 42..46 denoise
        };
        for (int i = 0; i < TVParamCount; ++i) p[i].store(defs[i], std::memory_order_relaxed);
    }
};

void updateEQ(Engine *e) {
    e->eqLo.set(0, e->sr, 100.0, e->p[TVParamBass].load(std::memory_order_relaxed), 0.7);
    e->eqMid.set(1, e->sr, 700.0, e->p[TVParamMid].load(std::memory_order_relaxed), 0.7);
    e->eqHi.set(2, e->sr, 3500.0, e->p[TVParamTreble].load(std::memory_order_relaxed), 0.7);
}

void updateCabFilters(Engine *e) {
    e->cabHP.set(4, e->sr, e->p[TVParamCabLoCut].load(std::memory_order_relaxed), 0.0, 0.707);
    e->cabLP.set(3, e->sr, e->p[TVParamCabHiCut].load(std::memory_order_relaxed), 0.0, 0.707);
}

void processGate(Engine *e, float *L, float *R, int n) {
    const float gateDb = e->p[TVParamGateThr].load(std::memory_order_relaxed);
    if (gateDb <= -89.0f) return;
    const float thr = tv::dbToLin(gateDb);
    const float relMs = std::clamp(e->p[TVParamGateRel].load(std::memory_order_relaxed), 10.0f, 300.0f);
    const float rel = std::exp(-1.0f / (relMs * 0.001f * (float)e->sr));
    const float sm = 1.0f - std::exp(-1.0f / (0.004f * (float)e->sr));

    for (int i = 0; i < n; ++i) {
        float a = std::max(std::fabs(L[i]), std::fabs(R[i]));
        e->gateEnv = (a > e->gateEnv) ? a : (e->gateEnv * rel);
        float target = (e->gateEnv > thr) ? 1.0f : 0.0f;
        e->gateGain += (target - e->gateGain) * sm;
        L[i] *= e->gateGain;
        R[i] *= e->gateGain;
    }
}

void processAmp(Engine *e, float *L, float *R, int n) {
    for (int i = 0; i < n; ++i) e->namIn[i] = (NAM_SAMPLE)(0.5f * (L[i] + R[i]));
    {
        std::unique_lock<std::mutex> lk(e->ampMtx, std::try_to_lock);
        NAM_SAMPLE *inCh[1] = {e->namIn.data()};
        NAM_SAMPLE *outCh[1] = {e->namOut.data()};
        if (lk.owns_lock() && e->dsp) {
            e->dsp->process(inCh, outCh, n);
        } else {
            std::copy(e->namIn.begin(), e->namIn.begin() + n, e->namOut.begin());
        }
    }
    for (int i = 0; i < n; ++i) {
        float y = (float)e->namOut[i];
        y = e->eqHi.run(e->eqMid.run(e->eqLo.run(y)));
        L[i] = y;
        R[i] = y;
    }
}

void processCab(Engine *e, float *L, float *R, int n) {
    const float lvl = tv::dbToLin(e->p[TVParamCabLevel].load(std::memory_order_relaxed));
    std::unique_lock<std::mutex> lk(e->irMtx, std::try_to_lock);
    const bool hasIR = lk.owns_lock() && e->ir != nullptr;

    for (int i = 0; i < n; ++i) {
        float x = 0.5f * (L[i] + R[i]);
        if (hasIR) x = e->ir->processSample(x);
        x = e->cabLP.run(e->cabHP.run(x)) * lvl;
        L[i] = x;
        R[i] = x;
    }
}

} // namespace

extern "C" {

NAMEngineRef NAMEngineCreate(void) {
    static std::once_flag once;
    std::call_once(once, [] { nam::activations::Activation::enable_fast_tanh(); });
    return new Engine();
}

void NAMEngineDestroy(NAMEngineRef r) {
    delete static_cast<Engine *>(r);
}

void NAMEnginePrepare(NAMEngineRef r, double sr, int maxFrames) {
    auto *e = static_cast<Engine *>(r);
    e->sr = (sr > 1000.0) ? sr : 48000.0;
    e->maxFrames = std::max(1, maxFrames);

    e->namIn.assign(e->maxFrames, 0);
    e->namOut.assign(e->maxFrames, 0);
    e->bufL.assign(e->maxFrames, 0.0f);
    e->bufR.assign(e->maxFrames, 0.0f);
    e->dryL.assign(e->maxFrames, 0.0f);
    e->dryR.assign(e->maxFrames, 0.0f);

    e->eqLo.reset(); e->eqMid.reset(); e->eqHi.reset();
    e->cabHP.reset(); e->cabLP.reset();
    e->gateEnv = 0.0f; e->gateGain = 1.0f;

    e->denoise.prepare(e->sr);
    e->denoiseWasActive = false;
    e->comp.prepare(e->sr);
    e->drive.prepare(e->sr);
    e->mod.prepare(e->sr);
    e->delay.prepare(e->sr);
    e->reverb.prepare(e->sr);

    e->eqDirty = true;
    e->cabDirty = true;

    {
        std::lock_guard<std::mutex> g(e->ampMtx);
        if (e->dsp) e->dsp->Reset(e->sr, e->maxFrames);
    }
    {
        std::lock_guard<std::mutex> g(e->irMtx);
        if (e->ir) e->ir->reset();
    }
}

bool NAMEngineLoadModel(NAMEngineRef r, const char *path) {
    auto *e = static_cast<Engine *>(r);
    if (!path || path[0] == '\0') {
        std::unique_ptr<nam::DSP> empty;
        std::lock_guard<std::mutex> g(e->ampMtx);
        std::swap(e->dsp, empty);
        return true;
    }
    try {
        std::unique_ptr<nam::DSP> d = nam::get_dsp(std::filesystem::path(path));
        if (!d) return false;
        d->Reset(e->sr, e->maxFrames);
        std::lock_guard<std::mutex> g(e->ampMtx);
        std::swap(e->dsp, d);
        return true;
    } catch (...) {
        return false;
    }
}

bool NAMEngineLoadIR(NAMEngineRef r, const float *samples, int count) {
    auto *e = static_cast<Engine *>(r);
    if (!samples || count <= 0) {
        std::unique_ptr<tv::IRConvolver> empty;
        std::lock_guard<std::mutex> g(e->irMtx);
        std::swap(e->ir, empty);
        return true;
    }
    try {
        auto conv = std::make_unique<tv::IRConvolver>();
        conv->load(samples, count);
        std::lock_guard<std::mutex> g(e->irMtx);
        std::swap(e->ir, conv);
        return true;
    } catch (...) {
        return false;
    }
}

void NAMEngineSetParam(NAMEngineRef r, int id, float v) {
    auto *e = static_cast<Engine *>(r);
    if (id < 0 || id >= TVParamCount) return;
    e->p[id].store(v, std::memory_order_relaxed);
    if (id >= TVParamBass && id <= TVParamTreble) e->eqDirty = true;
    if (id == TVParamCabLoCut || id == TVParamCabHiCut) e->cabDirty = true;
}

void NAMEngineSetChainOrder(NAMEngineRef r, const int *order, int count) {
    auto *e = static_cast<Engine *>(r);
    if (!order || count != TVBlockCount) return;
    bool seen[TVBlockCount] = {};
    for (int i = 0; i < TVBlockCount; ++i) {
        if (order[i] < 0 || order[i] >= TVBlockCount || seen[order[i]]) return;
        seen[order[i]] = true;
    }
    e->chainOrder.store(packOrder(order), std::memory_order_relaxed);
}

void NAMEngineStartNoiseLearn(NAMEngineRef r, float seconds) {
    static_cast<Engine *>(r)->denoise.startLearn(seconds);
}

void NAMEngineClearNoiseProfile(NAMEngineRef r) {
    static_cast<Engine *>(r)->denoise.clearProfile();
}

int NAMEngineGetNoiseLearnState(NAMEngineRef r) {
    return static_cast<Engine *>(r)->denoise.getState();
}

float NAMEngineGetNoiseLearnProgress(NAMEngineRef r) {
    return static_cast<Engine *>(r)->denoise.getProgress();
}

int NAMEngineGetNoiseProfile(NAMEngineRef r, float *outBins, int maxBins) {
    return static_cast<Engine *>(r)->denoise.getProfile(outBins, maxBins);
}

void NAMEngineSetNoiseProfile(NAMEngineRef r, const float *bins, int count) {
    static_cast<Engine *>(r)->denoise.setProfile(bins, count);
}

void NAMEngineProcess(NAMEngineRef r, const float *in, float *oL, float *oR, int n) {
    auto *e = static_cast<Engine *>(r);
    if (n <= 0) return;
    if (n > e->maxFrames) {
        for (int off = 0; off < n; off += e->maxFrames) {
            int c = std::min(n - off, e->maxFrames);
            NAMEngineProcess(r, in + off, oL + off, oR + off, c);
        }
        return;
    }

    if (e->eqDirty.exchange(false)) updateEQ(e);
    if (e->cabDirty.exchange(false)) updateCabFilters(e);

    const float inG = tv::dbToLin(e->p[TVParamInput].load(std::memory_order_relaxed));
    const float outG = tv::dbToLin(e->p[TVParamOutput].load(std::memory_order_relaxed));

    float *L = e->bufL.data();
    float *R = e->bufR.data();
    for (int i = 0; i < n; ++i) {
        float x = in[i] * inG;
        L[i] = x;
        R[i] = x;
    }

    const uint64_t packed = e->chainOrder.load(std::memory_order_relaxed);
    const float rampStep = 1.0f / std::max(1.0f, 0.005f * (float)e->sr);

    for (int slot = 0; slot < TVBlockCount; ++slot) {
        const int blk = (int)((packed >> (slot * 4)) & 0xF);
        if (blk < 0 || blk >= TVBlockCount) continue;

        const bool active = e->p[kEnableParam[blk]].load(std::memory_order_relaxed) >= 0.5f;
        const float curMix = e->blkSmooth[blk];

        if (!active && curMix <= 0.0001f) {
            e->blkSmooth[blk] = 0.0f;
            if (blk == TVBlockDenoise && e->denoiseWasActive) {
                e->denoise.resetBuffers();
                e->denoiseWasActive = false;
            }
            continue;
        }

        const bool ramping = (active && curMix < 0.9999f) || (!active && curMix > 0.0001f);
        if (ramping) {
            std::memcpy(e->dryL.data(), L, n * sizeof(float));
            std::memcpy(e->dryR.data(), R, n * sizeof(float));
        }

        switch (blk) {
            case TVBlockDenoise:
                e->denoiseWasActive = true;
                e->denoise.process(L, R, n,
                    e->p[TVParamDenoiseRed].load(std::memory_order_relaxed),
                    e->p[TVParamDenoiseSens].load(std::memory_order_relaxed),
                    e->p[TVParamDenoiseSmooth].load(std::memory_order_relaxed),
                    e->p[TVParamDenoiseMix].load(std::memory_order_relaxed));
                break;
            case TVBlockGate:
                processGate(e, L, R, n);
                break;
            case TVBlockComp:
                e->comp.process(L, R, n,
                    e->p[TVParamCompThr].load(std::memory_order_relaxed),
                    e->p[TVParamCompRatio].load(std::memory_order_relaxed),
                    e->p[TVParamCompAtk].load(std::memory_order_relaxed),
                    e->p[TVParamCompRel].load(std::memory_order_relaxed),
                    e->p[TVParamCompGain].load(std::memory_order_relaxed),
                    e->p[TVParamCompMix].load(std::memory_order_relaxed));
                break;
            case TVBlockDrive:
                e->drive.process(L, R, n,
                    e->p[TVParamDrive].load(std::memory_order_relaxed),
                    e->p[TVParamDriveTone].load(std::memory_order_relaxed),
                    e->p[TVParamDriveLvl].load(std::memory_order_relaxed),
                    (int)std::lround(e->p[TVParamDriveMode].load(std::memory_order_relaxed)));
                break;
            case TVBlockAmp:
                processAmp(e, L, R, n);
                break;
            case TVBlockCab:
                processCab(e, L, R, n);
                break;
            case TVBlockMod:
                e->mod.process(L, R, n,
                    (int)std::lround(e->p[TVParamModMode].load(std::memory_order_relaxed)),
                    e->p[TVParamModRate].load(std::memory_order_relaxed),
                    e->p[TVParamModDepth].load(std::memory_order_relaxed),
                    e->p[TVParamModMix].load(std::memory_order_relaxed));
                break;
            case TVBlockDelay:
                e->delay.process(L, R, n,
                    (int)std::lround(e->p[TVParamDelayMode].load(std::memory_order_relaxed)),
                    e->p[TVParamDelayTime].load(std::memory_order_relaxed),
                    e->p[TVParamDelayFdbk].load(std::memory_order_relaxed),
                    e->p[TVParamDelayTone].load(std::memory_order_relaxed),
                    e->p[TVParamDelayMix].load(std::memory_order_relaxed));
                break;
            case TVBlockReverb:
                e->reverb.process(L, R, n,
                    (int)std::lround(e->p[TVParamRevMode].load(std::memory_order_relaxed)),
                    e->p[TVParamRevDecay].load(std::memory_order_relaxed),
                    e->p[TVParamRevPreDly].load(std::memory_order_relaxed),
                    e->p[TVParamRevDamp].load(std::memory_order_relaxed),
                    e->p[TVParamRevMix].load(std::memory_order_relaxed));
                break;
        }

        if (ramping) {
            float m = curMix;
            const float target = active ? 1.0f : 0.0f;
            for (int i = 0; i < n; ++i) {
                if (m < target) m = std::min(target, m + rampStep);
                else if (m > target) m = std::max(target, m - rampStep);
                L[i] = e->dryL[i] * (1.0f - m) + L[i] * m;
                R[i] = e->dryR[i] * (1.0f - m) + R[i] * m;
            }
            e->blkSmooth[blk] = m;
        } else {
            e->blkSmooth[blk] = active ? 1.0f : 0.0f;
        }
    }

    for (int i = 0; i < n; ++i) {
        float yL = L[i] * outG;
        float yR = R[i] * outG;
        oL[i] = std::isfinite(yL) ? yL : 0.0f;
        oR[i] = std::isfinite(yR) ? yR : 0.0f;
    }
}

} // extern "C"