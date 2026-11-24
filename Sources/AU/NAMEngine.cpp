#include "NAMEngine.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <memory>
#include <mutex>
#include <vector>
#include "NAM/dsp.h"
#if __has_include("NAM/get_dsp.h")
#include "NAM/get_dsp.h"
#endif

namespace {
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    float run(float x) { float y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y; }
    void reset() { z1 = z2 = 0; }
    // RBJ cookbook. type: 0 low shelf, 1 peaking, 2 high shelf
    void set(int type, double fs, double f0, double dB, double Q) {
        double A = std::pow(10.0, dB / 40.0), w = 2 * M_PI * f0 / fs, c = std::cos(w), s = std::sin(w);
        double al = (type == 1) ? s / (2 * Q) : s / 2 * std::sqrt(2.0), sA = 2 * std::sqrt(A) * al;
        double B0, B1, B2, A0, A1, A2;
        if (type == 0) {
            B0 = A * ((A + 1) - (A - 1) * c + sA); B1 = 2 * A * ((A - 1) - (A + 1) * c); B2 = A * ((A + 1) - (A - 1) * c - sA);
            A0 = (A + 1) + (A - 1) * c + sA; A1 = -2 * ((A - 1) + (A + 1) * c); A2 = (A + 1) + (A - 1) * c - sA;
        } else if (type == 2) {
            B0 = A * ((A + 1) + (A - 1) * c + sA); B1 = -2 * A * ((A - 1) + (A + 1) * c); B2 = A * ((A + 1) + (A - 1) * c - sA);
            A0 = (A + 1) - (A - 1) * c + sA; A1 = 2 * ((A - 1) - (A + 1) * c); A2 = (A + 1) - (A - 1) * c - sA;
        } else {
            B0 = 1 + al * A; B1 = -2 * c; B2 = 1 - al * A; A0 = 1 + al / A; A1 = -2 * c; A2 = 1 - al / A;
        }
        b0 = B0 / A0; b1 = B1 / A0; b2 = B2 / A0; a1 = A1 / A0; a2 = A2 / A0;
    }
};

struct Engine {
    std::mutex m;
    std::unique_ptr<nam::DSP> dsp;
    double sr = 48000;
    int maxFrames = 1024;
    std::vector<NAM_SAMPLE> inBuf, outBuf;
    std::atomic<float> p[6];
    std::atomic<bool> dirty{true};
    Biquad lo, mid, hi;
    float env = 0, gate = 1;
    Engine() { const float d[6] = {0, -70, 0, 0, 0, 0}; for (int i = 0; i < 6; i++) p[i] = d[i]; }
};

inline float dbToLin(float d) { return std::pow(10.0f, d / 20.0f); }

void updateFilters(Engine *e) {
    e->lo.set(0, e->sr, 100, e->p[2], 0.7);
    e->mid.set(1, e->sr, 700, e->p[3], 0.7);
    e->hi.set(2, e->sr, 3500, e->p[4], 0.7);
}
} // namespace

extern "C" {
NAMEngineRef NAMEngineCreate(void) {
    static std::once_flag once;
    std::call_once(once, [] { nam::activations::Activation::enable_fast_tanh(); });
    return new Engine();
}
void NAMEngineDestroy(NAMEngineRef r) { delete static_cast<Engine *>(r); }

void NAMEnginePrepare(NAMEngineRef r, double sr, int maxFrames) {
    auto *e = static_cast<Engine *>(r);
    e->sr = sr; e->maxFrames = std::max(1, maxFrames);
    e->inBuf.assign(e->maxFrames, 0); e->outBuf.assign(e->maxFrames, 0);
    e->lo.reset(); e->mid.reset(); e->hi.reset(); e->env = 0; e->gate = 1;
    e->dirty = true;
    std::lock_guard<std::mutex> g(e->m);
    if (e->dsp) e->dsp->Reset(sr, e->maxFrames);
}

bool NAMEngineLoadModel(NAMEngineRef r, const char *path) {
    auto *e = static_cast<Engine *>(r);
    try {
        std::unique_ptr<nam::DSP> d = nam::get_dsp(std::filesystem::path(path));
        if (!d) return false;
        d->Reset(e->sr, e->maxFrames);
        std::lock_guard<std::mutex> g(e->m); // old model is destroyed after the lock is released
        std::swap(e->dsp, d);
        return true;
    } catch (...) { return false; }
}

void NAMEngineSetParam(NAMEngineRef r, int id, float v) {
    auto *e = static_cast<Engine *>(r);
    if (id < 0 || id > 5) return;
    e->p[id] = v;
    if (id >= 2 && id <= 4) e->dirty = true;
}

void NAMEngineProcess(NAMEngineRef r, const float *in, float *oL, float *oR, int n) {
    auto *e = static_cast<Engine *>(r);
    if (n > e->maxFrames) { // host exceeded the promised max: process in chunks
        for (int off = 0; off < n; off += e->maxFrames) {
            int c = std::min(n - off, e->maxFrames);
            NAMEngineProcess(r, in + off, oL + off, oR + off, c);
        }
        return;
    }
    if (e->dirty.exchange(false)) updateFilters(e);
    const float inG = dbToLin(e->p[0]), outG = dbToLin(e->p[5]);
    const float gateDb = e->p[1];
    const bool gateOn = gateDb > -89.f;
    const float thr = dbToLin(gateDb);
    const float rel = std::exp(-1.f / (0.06f * (float)e->sr));
    const float sm = 1.f - std::exp(-1.f / (0.004f * (float)e->sr));

    for (int i = 0; i < n; i++) {
        float x = in[i] * inG, a = std::fabs(x);
        e->env = a > e->env ? a : e->env * rel;
        float target = (!gateOn || e->env > thr) ? 1.f : 0.f;
        e->gate += (target - e->gate) * sm;
        e->inBuf[i] = (NAM_SAMPLE)(x * e->gate);
    }
    {
        std::unique_lock<std::mutex> lk(e->m, std::try_to_lock);
        if (lk.owns_lock() && e->dsp) e->dsp->process(e->inBuf.data(), e->outBuf.data(), n);
        else std::copy(e->inBuf.begin(), e->inBuf.begin() + n, e->outBuf.begin()); // no model: pass dry
    }
    for (int i = 0; i < n; i++) {
        float y = (float)e->outBuf[i];
        y = e->hi.run(e->mid.run(e->lo.run(y))) * outG;
        if (!std::isfinite(y)) y = 0.f;
        oL[i] = y; oR[i] = y;
    }
}
}
