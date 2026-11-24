#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace tv {

constexpr float kPi = 3.14159265358979323846f;

inline float dbToLin(float d) { return std::pow(10.0f, d / 20.0f); }
inline float linToDb(float x) { return 20.0f * std::log10(std::max(x, 1e-6f)); }
inline float fastTanh(float x) {
    if (x < -3.0f) return -1.0f;
    if (x > 3.0f) return 1.0f;
    float x2 = x * x;
    return x * (27.0f + x2) / (27.0f + 9.0f * x2);
}

// RBJ Cookbook Biquad
// type: 0 low shelf, 1 peaking, 2 high shelf, 3 low-pass, 4 high-pass
struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;

    inline float run(float x) {
        float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }

    void reset() { z1 = z2 = 0; }

    void set(int type, double fs, double f0, double dB, double Q) {
        f0 = std::clamp(f0, 10.0, fs * 0.48);
        Q = std::max(0.1, Q);
        double A = std::pow(10.0, dB / 40.0);
        double w = 2.0 * M_PI * f0 / fs;
        double c = std::cos(w), s = std::sin(w);
        double al = (type == 0 || type == 2) ? (s * 0.5 * std::sqrt(2.0)) : (s / (2.0 * Q));
        double sA = 2.0 * std::sqrt(A) * al;
        double B0 = 1, B1 = 0, B2 = 0, A0 = 1, A1 = 0, A2 = 0;

        if (type == 0) { // Low shelf
            B0 = A * ((A + 1) - (A - 1) * c + sA);
            B1 = 2 * A * ((A - 1) - (A + 1) * c);
            B2 = A * ((A + 1) - (A - 1) * c - sA);
            A0 = (A + 1) + (A - 1) * c + sA;
            A1 = -2 * ((A - 1) + (A + 1) * c);
            A2 = (A + 1) + (A - 1) * c - sA;
        } else if (type == 2) { // High shelf
            B0 = A * ((A + 1) + (A - 1) * c + sA);
            B1 = -2 * A * ((A - 1) + (A + 1) * c);
            B2 = A * ((A + 1) + (A - 1) * c - sA);
            A0 = (A + 1) - (A - 1) * c + sA;
            A1 = 2 * ((A - 1) - (A + 1) * c);
            A2 = (A + 1) - (A - 1) * c - sA;
        } else if (type == 1) { // Peaking
            B0 = 1 + al * A; B1 = -2 * c; B2 = 1 - al * A;
            A0 = 1 + al / A; A1 = -2 * c; A2 = 1 - al / A;
        } else if (type == 3) { // Low-pass
            B0 = (1 - c) * 0.5; B1 = 1 - c; B2 = (1 - c) * 0.5;
            A0 = 1 + al; A1 = -2 * c; A2 = 1 - al;
        } else if (type == 4) { // High-pass
            B0 = (1 + c) * 0.5; B1 = -(1 + c); B2 = (1 + c) * 0.5;
            A0 = 1 + al; A1 = -2 * c; A2 = 1 - al;
        }
        b0 = (float)(B0 / A0); b1 = (float)(B1 / A0); b2 = (float)(B2 / A0);
        a1 = (float)(A1 / A0); a2 = (float)(A2 / A0);
    }
};

// ============================================================================
// Zero-Latency Hybrid Partitioned FFT IR Convolver
// 128-tap direct FIR head + 256-point Overlap-Save FFT tail (up to 8320 samples)
// ============================================================================
class IRConvolver {
public:
    static constexpr int B = 128;
    static constexpr int N = 256;
    static constexpr int MAX_PARTS = 64; // 64 * 128 + 128 = 8320 samples (~173ms @ 48kHz)

    IRConvolver() { initFFT(); }

    void load(const float *ir, int count) {
        std::fill(head.begin(), head.end(), 0.0f);
        numParts = 0;
        if (!ir || count <= 0) return;

        const int maxLen = B + MAX_PARTS * B;
        const int len = std::min(count, maxLen);

        // Energy normalization so swapping IR packs stays near unity gain
        double energy = 0.0;
        for (int i = 0; i < len; ++i) energy += (double)ir[i] * (double)ir[i];
        float scale = (energy > 1e-8) ? (float)(1.0 / std::sqrt(energy)) : 1.0f;
        scale = std::clamp(scale, 0.05f, 10.0f);

        std::vector<float> buf(len, 0.0f);
        for (int i = 0; i < len; ++i) buf[i] = ir[i] * scale;
        // Short fade-out if truncated
        if (count > maxLen) {
            for (int i = 0; i < 64; ++i) {
                buf[len - 64 + i] *= (1.0f - (float)i / 64.0f);
            }
        }

        const int headLen = std::min(len, B);
        for (int i = 0; i < headLen; ++i) head[i] = buf[i];

        const int tailLen = std::max(0, len - B);
        numParts = (tailLen + B - 1) / B;
        partRe.assign(numParts, std::array<float, N>{});
        partIm.assign(numParts, std::array<float, N>{});
        fdlRe.assign(std::max(1, numParts), std::array<float, N>{});
        fdlIm.assign(std::max(1, numParts), std::array<float, N>{});

        for (int p = 0; p < numParts; ++p) {
            auto &re = partRe[p];
            auto &im = partIm[p];
            re.fill(0.0f);
            im.fill(0.0f);
            const int offset = B + p * B;
            const int copyN = std::min(B, len - offset);
            for (int i = 0; i < copyN; ++i) re[i] = buf[offset + i];
            fft(re.data(), im.data(), false);
        }
        reset();
    }

    void reset() {
        headRing.fill(0.0f);
        blockPrev.fill(0.0f);
        blockCurr.fill(0.0f);
        tailOut.fill(0.0f);
        for (auto &a : fdlRe) a.fill(0.0f);
        for (auto &a : fdlIm) a.fill(0.0f);
        headPos = 0;
        blockPos = 0;
        fdlHead = 0;
    }

    inline float processSample(float x) {
        if (numParts > 0 && blockPos == 0) computeTailBlock();

        // Direct head FIR (0-sample latency)
        headRing[headPos] = x;
        float yHead = 0.0f;
        for (int j = 0; j < B; ++j) {
            yHead += head[j] * headRing[(headPos - j) & (B - 1)];
        }
        headPos = (headPos + 1) & (B - 1);

        float y = yHead;
        if (numParts > 0) {
            blockCurr[blockPos] = x;
            y += tailOut[blockPos];
            if (++blockPos == B) blockPos = 0;
        }
        return y;
    }

private:
    std::array<float, B> head{};
    std::array<float, B> headRing{};
    std::array<float, B> blockPrev{};
    std::array<float, B> blockCurr{};
    std::array<float, B> tailOut{};
    std::vector<std::array<float, N>> partRe, partIm;
    std::vector<std::array<float, N>> fdlRe, fdlIm;
    std::array<float, N> sumRe{}, sumIm{};
    std::array<int, N> bitRev{};
    std::array<float, N / 2> twCos{}, twSin{};
    int numParts = 0;
    int headPos = 0, blockPos = 0, fdlHead = 0;

    void initFFT() {
        for (int i = 0; i < N; ++i) {
            int r = 0, v = i;
            for (int b = 0; b < 8; ++b) { r = (r << 1) | (v & 1); v >>= 1; }
            bitRev[i] = r;
        }
        for (int i = 0; i < N / 2; ++i) {
            float ang = -2.0f * kPi * (float)i / (float)N;
            twCos[i] = std::cos(ang);
            twSin[i] = std::sin(ang);
        }
    }

    void fft(float *re, float *im, bool inverse) const {
        for (int i = 0; i < N; ++i) {
            int j = bitRev[i];
            if (i < j) {
                std::swap(re[i], re[j]);
                std::swap(im[i], im[j]);
            }
        }
        const float sign = inverse ? -1.0f : 1.0f;
        for (int len = 2; len <= N; len <<= 1) {
            int half = len >> 1;
            int step = N / len;
            for (int i = 0; i < N; i += len) {
                for (int j = 0; j < half; ++j) {
                    float wr = twCos[j * step];
                    float wi = sign * twSin[j * step];
                    int u = i + j, v = i + j + half;
                    float tr = re[v] * wr - im[v] * wi;
                    float ti = re[v] * wi + im[v] * wr;
                    re[v] = re[u] - tr;
                    im[v] = im[u] - ti;
                    re[u] += tr;
                    im[u] += ti;
                }
            }
        }
        if (inverse) {
            constexpr float invN = 1.0f / (float)N;
            for (int i = 0; i < N; ++i) { re[i] *= invN; im[i] *= invN; }
        }
    }

    void computeTailBlock() {
        auto &inRe = fdlRe[fdlHead];
        auto &inIm = fdlIm[fdlHead];
        std::memcpy(inRe.data(), blockPrev.data(), B * sizeof(float));
        std::memcpy(inRe.data() + B, blockCurr.data(), B * sizeof(float));
        inIm.fill(0.0f);
        fft(inRe.data(), inIm.data(), false);

        sumRe.fill(0.0f);
        sumIm.fill(0.0f);
        for (int p = 0; p < numParts; ++p) {
            int idx = fdlHead - p;
            if (idx < 0) idx += numParts;
            const auto &xr = fdlRe[idx];
            const auto &xi = fdlIm[idx];
            const auto &hr = partRe[p];
            const auto &hi = partIm[p];
            for (int k = 0; k < N; ++k) {
                sumRe[k] += xr[k] * hr[k] - xi[k] * hi[k];
                sumIm[k] += xr[k] * hi[k] + xi[k] * hr[k];
            }
        }
        fft(sumRe.data(), sumIm.data(), true);
        std::memcpy(tailOut.data(), sumRe.data() + B, B * sizeof(float));
        if (++fdlHead >= numParts) fdlHead = 0;
        blockPrev = blockCurr;
    }
};

// ============================================================================
// Stereo-Linked Soft-Knee Compressor with Parallel Mix
// ============================================================================
struct Compressor {
    double sr = 48000.0;
    float envDb = -90.0f;

    void prepare(double s) { sr = s; envDb = -90.0f; }

    void process(float *L, float *R, int n,
                 float thrDb, float ratio, float atkMs, float relMs, float gainDb, float mixPct) {
        const float atk = std::exp(-1.0f / (std::max(0.5f, atkMs) * 0.001f * (float)sr));
        const float rel = std::exp(-1.0f / (std::max(5.0f, relMs) * 0.001f * (float)sr));
        const float makeup = dbToLin(gainDb);
        const float wet = std::clamp(mixPct * 0.01f, 0.0f, 1.0f);
        const float dry = 1.0f - wet;
        const float r = std::max(1.0f, ratio);
        const float knee = 6.0f;

        for (int i = 0; i < n; ++i) {
            float peak = std::max(std::fabs(L[i]), std::fabs(R[i]));
            float inDb = linToDb(peak);
            float coeff = (inDb > envDb) ? atk : rel;
            envDb = coeff * envDb + (1.0f - coeff) * inDb;

            float over = envDb - thrDb;
            float grDb = 0.0f;
            if (over > knee * 0.5f) {
                grDb = over * (1.0f - 1.0f / r);
            } else if (over > -knee * 0.5f) {
                float t = over + knee * 0.5f;
                grDb = (1.0f - 1.0f / r) * (t * t) / (2.0f * knee);
            }
            float g = dbToLin(-grDb) * makeup;
            L[i] = L[i] * dry + (L[i] * g) * wet;
            R[i] = R[i] * dry + (R[i] * g) * wet;
        }
    }
};

// ============================================================================
// 2x-Oversampled Overdrive / Boost (0: Tube, 1: Klone, 2: Fuzz)
// ============================================================================
struct Overdrive {
    double sr = 48000.0;
    Biquad preHP[2], midBump[2], toneLP[2], aaLP[2];
    float prevIn[2] = {0, 0};
    float lastTone = -1.0f;
    int lastMode = -1;

    void prepare(double s) {
        sr = s;
        for (int c = 0; c < 2; ++c) {
            preHP[c].reset(); midBump[c].reset(); toneLP[c].reset(); aaLP[c].reset();
            aaLP[c].set(3, sr * 2.0, sr * 0.42, 0.0, 0.707);
            prevIn[c] = 0;
        }
        lastTone = -1.0f;
        lastMode = -1;
    }

    inline float shape(float x, float gain, int mode) const {
        if (mode == 0) { // Tube (asymmetric warm soft clip)
            float v = x * gain;
            return (v >= 0.0f) ? fastTanh(v) : fastTanh(v * 0.85f) * 1.05f;
        } else if (mode == 1) { // Klone (clean blend + germanium hard-soft clip)
            float v = x * gain * 0.9f;
            float clipped = std::clamp(fastTanh(v * 1.4f), -0.65f, 0.65f) * 1.15f;
            float cleanBlend = std::clamp(1.0f - (gain - 1.0f) / 20.0f, 0.15f, 0.65f);
            return x * cleanBlend + clipped * (1.0f - cleanBlend * 0.6f);
        } else { // Fuzz (high gain biased clip)
            float v = x * gain * 2.4f + 0.12f;
            return fastTanh(v * 1.6f) - 0.11f;
        }
    }

    void update(float tonePct, int mode) {
        if (std::fabs(tonePct - lastTone) < 0.2f && mode == lastMode) return;
        lastTone = tonePct;
        lastMode = mode;
        float t = std::clamp(tonePct * 0.01f, 0.0f, 1.0f);
        double hpFreq = (mode == 0) ? 260.0 : (mode == 1 ? 110.0 : 85.0);
        double midDb = (mode == 0) ? 5.5 : (mode == 1 ? 2.5 : -2.0);
        double lpFreq = 900.0 + std::pow(t, 1.7) * 7600.0;
        for (int c = 0; c < 2; ++c) {
            preHP[c].set(4, sr, hpFreq, 0.0, 0.707);
            midBump[c].set(1, sr, 720.0, midDb, 0.8);
            toneLP[c].set(3, sr, lpFreq, 0.0, 0.707);
        }
    }

    void process(float *L, float *R, int n, float drivePct, float tonePct, float levelDb, int mode) {
        update(tonePct, mode);
        float d = std::clamp(drivePct * 0.01f, 0.0f, 1.0f);
        float gain = 1.0f + d * d * 24.0f;
        float lvl = dbToLin(levelDb) * (mode == 2 ? 0.55f : 0.75f);
        float *ch[2] = {L, R};

        for (int c = 0; c < 2; ++c) {
            float *buf = ch[c];
            for (int i = 0; i < n; ++i) {
                float x = midBump[c].run(preHP[c].run(buf[i]));
                // 2x oversampled nonlinearity
                float mid = 0.5f * (prevIn[c] + x);
                prevIn[c] = x;
                (void)aaLP[c].run(shape(mid, gain, mode));
                float y = aaLP[c].run(shape(x, gain, mode));
                buf[i] = toneLP[c].run(y) * lvl;
            }
        }
    }
};

// ============================================================================
// Stereo Modulation (0: Chorus, 1: Flanger, 2: Tremolo)
// ============================================================================
struct Modulation {
    double sr = 48000.0;
    std::vector<float> bufL, bufR;
    int writePos = 0, mask = 0;
    float phase = 0.0f;

    void prepare(double s) {
        sr = s;
        int sz = 1;
        while (sz < (int)(sr * 0.06) + 16) sz <<= 1;
        bufL.assign(sz, 0.0f);
        bufR.assign(sz, 0.0f);
        mask = sz - 1;
        writePos = 0;
        phase = 0.0f;
    }

    inline float readFrac(const std::vector<float> &b, float delaySamples) const {
        float rp = (float)writePos - delaySamples;
        int i0 = (int)std::floor(rp);
        float frac = rp - (float)i0;
        float y0 = b[i0 & mask];
        float y1 = b[(i0 + 1) & mask];
        return y0 + frac * (y1 - y0);
    }

    void process(float *L, float *R, int n, int mode, float rateHz, float depthPct, float mixPct) {
        if (bufL.empty()) return;
        const float inc = 2.0f * kPi * std::clamp(rateHz, 0.05f, 12.0f) / (float)sr;
        const float depth = std::clamp(depthPct * 0.01f, 0.0f, 1.0f);
        const float wet = std::clamp(mixPct * 0.01f, 0.0f, 1.0f);
        const float dry = 1.0f - wet;

        for (int i = 0; i < n; ++i) {
            float lfoL = 0.5f + 0.5f * std::sin(phase);
            float lfoR = 0.5f + 0.5f * std::sin(phase + kPi * 0.5f); // quadrature stereo
            phase += inc;
            if (phase >= 2.0f * kPi) phase -= 2.0f * kPi;

            float inL = L[i], inR = R[i];

            if (mode == 2) { // Tremolo
                float gL = 1.0f - depth * (1.0f - lfoL);
                float gR = 1.0f - depth * (1.0f - (0.5f * lfoL + 0.5f * lfoR));
                L[i] = inL * dry + (inL * gL) * wet;
                R[i] = inR * dry + (inR * gR) * wet;
            } else {
                float dMsL, dMsR, fb;
                if (mode == 0) { // Chorus
                    dMsL = 6.5f + lfoL * (6.5f * depth);
                    dMsR = 6.5f + lfoR * (6.5f * depth);
                    fb = 0.12f;
                } else { // Flanger
                    dMsL = 0.6f + lfoL * (4.5f * depth);
                    dMsR = 0.6f + lfoR * (4.5f * depth);
                    fb = 0.48f;
                }
                float wL = readFrac(bufL, dMsL * 0.001f * (float)sr);
                float wR = readFrac(bufR, dMsR * 0.001f * (float)sr);
                bufL[writePos] = inL + wL * fb;
                bufR[writePos] = inR + wR * fb;
                writePos = (writePos + 1) & mask;
                L[i] = inL * dry + wL * wet;
                R[i] = inR * dry + wR * wet;
            }
        }
    }
};

// ============================================================================
// Stereo Delay (0: Digital, 1: Tape, 2: Ping-Pong)
// ============================================================================
struct StereoDelay {
    double sr = 48000.0;
    std::vector<float> bufL, bufR;
    int writePos = 0, size = 0;
    float smoothSamples = 17280.0f;
    float wowPhase = 0.0f;
    Biquad lpL, lpR, hpL, hpR;
    float lastTone = -1.0f;

    void prepare(double s) {
        sr = s;
        size = (int)(sr * 1.5) + 16;
        bufL.assign(size, 0.0f);
        bufR.assign(size, 0.0f);
        writePos = 0;
        smoothSamples = (float)(0.36 * sr);
        lpL.reset(); lpR.reset(); hpL.reset(); hpR.reset();
        hpL.set(4, sr, 95.0, 0.0, 0.707);
        hpR.set(4, sr, 95.0, 0.0, 0.707);
        lastTone = -1.0f;
    }

    inline float read(const std::vector<float> &b, float delay) const {
        float rp = (float)writePos - delay;
        while (rp < 0.0f) rp += (float)size;
        while (rp >= (float)size) rp -= (float)size;
        int i0 = (int)rp;
        int i1 = (i0 + 1 < size) ? (i0 + 1) : 0;
        float f = rp - (float)i0;
        return b[i0] + f * (b[i1] - b[i0]);
    }

    void process(float *L, float *R, int n, int mode, float timeMs, float fdbkPct, float toneHz, float mixPct) {
        if (size <= 0) return;
        if (std::fabs(toneHz - lastTone) > 10.0f) {
            lastTone = toneHz;
            lpL.set(3, sr, toneHz, 0.0, 0.707);
            lpR.set(3, sr, toneHz, 0.0, 0.707);
        }
        const float target = std::clamp(timeMs * 0.001f * (float)sr, 16.0f, (float)(size - 8));
        const float fb = std::clamp(fdbkPct * 0.01f, 0.0f, 0.94f);
        const float wet = std::clamp(mixPct * 0.01f, 0.0f, 1.0f);
        const float dry = 1.0f - wet * 0.5f;
        const float sm = 1.0f - std::exp(-1.0f / (0.04f * (float)sr));
        const float wowInc = 2.0f * kPi * 0.65f / (float)sr;

        for (int i = 0; i < n; ++i) {
            smoothSamples += (target - smoothSamples) * sm;
            float mod = 0.0f;
            if (mode == 1) { // Tape wow/flutter
                mod = std::sin(wowPhase) * (0.0014f * (float)sr);
                wowPhase += wowInc;
                if (wowPhase >= 2.0f * kPi) wowPhase -= 2.0f * kPi;
            }
            float dL = std::clamp(smoothSamples + mod, 8.0f, (float)(size - 4));
            float dR = std::clamp(smoothSamples - mod, 8.0f, (float)(size - 4));

            float tapL = read(bufL, dL);
            float tapR = read(bufR, dR);

            float fL = lpL.run(tapL);
            float fR = lpR.run(tapR);
            if (mode == 1) {
                fL = fastTanh(hpL.run(fL) * 1.15f);
                fR = fastTanh(hpR.run(fR) * 1.15f);
            }

            float inL = L[i], inR = R[i];
            if (mode == 2) { // Ping-Pong
                float mono = 0.5f * (inL + inR);
                bufL[writePos] = mono + fR * fb;
                bufR[writePos] = fL * fb;
            } else {
                bufL[writePos] = inL + fL * fb;
                bufR[writePos] = inR + fR * fb;
            }
            if (++writePos >= size) writePos = 0;

            L[i] = inL * dry + tapL * wet;
            R[i] = inR * dry + tapR * wet;
        }
    }
};

// ============================================================================
// 8-Channel Hadamard FDN Stereo Reverb (0: Room, 1: Plate, 2: Hall)
// ============================================================================
struct FDNReverb {
    static constexpr int M = 8;
    double sr = 48000.0;
    std::array<std::vector<float>, M> lines;
    std::array<int, M> pos{}, len{};
    std::array<float, M> dampState{};
    std::vector<float> preL, preR;
    int prePos = 0, preSize = 0;
    int lastMode = -1;
    // Allpass diffusers for smooth stereo onset
    std::array<std::vector<float>, 4> apBuf;
    std::array<int, 4> apPos{};

    void prepare(double s) {
        sr = s;
        preSize = (int)(sr * 0.15) + 16;
        preL.assign(preSize, 0.0f);
        preR.assign(preSize, 0.0f);
        prePos = 0;

        static constexpr int apBase[4] = {142, 107, 379, 277};
        for (int i = 0; i < 4; ++i) {
            int sz = std::max(16, (int)(apBase[i] * (sr / 48000.0)));
            apBuf[i].assign(sz, 0.0f);
            apPos[i] = 0;
        }

        // Max size for Hall mode
        static constexpr int maxBase[M] = {1699, 1949, 2237, 2551, 2887, 3253, 3637, 4051};
        for (int i = 0; i < M; ++i) {
            int sz = std::max(64, (int)(maxBase[i] * (sr / 48000.0)) + 16);
            lines[i].assign(sz, 0.0f);
            pos[i] = 0;
            dampState[i] = 0.0f;
        }
        lastMode = -1;
        setMode(1);
    }

    void setMode(int mode) {
        if (mode == lastMode) return;
        lastMode = mode;
        static constexpr int base[3][M] = {
            { 613,  739,  881, 1031, 1187, 1361, 1543, 1733}, // Room
            {1069, 1249, 1451, 1667, 1901, 2143, 2411, 2689}, // Plate
            {1699, 1949, 2237, 2551, 2887, 3253, 3637, 4051}, // Hall
        };
        int m = std::clamp(mode, 0, 2);
        for (int i = 0; i < M; ++i) {
            int l = std::max(32, (int)(base[m][i] * (sr / 48000.0)));
            len[i] = std::min(l, (int)lines[i].size() - 1);
            if (pos[i] >= len[i]) pos[i] = 0;
        }
    }

    inline float runAP(int idx, float x, float g = 0.55f) {
        auto &b = apBuf[idx];
        int p = apPos[idx];
        float d = b[p];
        float v = x - g * d;
        b[p] = v;
        if (++p >= (int)b.size()) p = 0;
        apPos[idx] = p;
        return d + g * v;
    }

    void process(float *L, float *R, int n, int mode, float decaySec, float preDelayMs, float dampHz, float mixPct) {
        if (preSize <= 0) return;
        setMode(mode);

        const float t60 = std::clamp(decaySec, 0.15f, 10.0f);
        const float dampCoeff = std::exp(-2.0f * kPi * std::clamp(dampHz, 500.0f, 16000.0f) / (float)sr);
        const int preSamps = std::clamp((int)(preDelayMs * 0.001f * (float)sr), 1, preSize - 2);
        const float wet = std::clamp(mixPct * 0.01f, 0.0f, 1.0f);
        const float dry = 1.0f - wet * 0.45f;

        float g[M];
        for (int i = 0; i < M; ++i) {
            g[i] = std::min(0.992f, std::pow(10.0f, -3.0f * (float)len[i] / (t60 * (float)sr)));
        }

        constexpr float invSqrt8 = 0.35355339f;

        for (int i = 0; i < n; ++i) {
            float inL = L[i], inR = R[i];
            int rp = prePos - preSamps;
            if (rp < 0) rp += preSize;
            float pL = preL[rp], pR = preR[rp];
            preL[prePos] = inL;
            preR[prePos] = inR;
            if (++prePos >= preSize) prePos = 0;

            float dL = runAP(1, runAP(0, pL));
            float dR = runAP(3, runAP(2, pR));

            float x[M];
            for (int k = 0; k < M; ++k) {
                float s = lines[k][pos[k]];
                dampState[k] = (1.0f - dampCoeff) * s + dampCoeff * dampState[k];
                x[k] = dampState[k] * g[k];
            }

            // 8x8 Walsh-Hadamard orthogonal feedback matrix
            float a0 = x[0] + x[1], a1 = x[0] - x[1];
            float a2 = x[2] + x[3], a3 = x[2] - x[3];
            float a4 = x[4] + x[5], a5 = x[4] - x[5];
            float a6 = x[6] + x[7], a7 = x[6] - x[7];

            float b0 = a0 + a2, b1 = a1 + a3, b2 = a0 - a2, b3 = a1 - a3;
            float b4 = a4 + a6, b5 = a5 + a7, b6 = a4 - a6, b7 = a5 - a7;

            float h[M] = {
                (b0 + b4) * invSqrt8, (b1 + b5) * invSqrt8, (b2 + b6) * invSqrt8, (b3 + b7) * invSqrt8,
                (b0 - b4) * invSqrt8, (b1 - b5) * invSqrt8, (b2 - b6) * invSqrt8, (b3 - b7) * invSqrt8
            };

            const float injL = dL * 0.35f;
            const float injR = dR * 0.35f;
            for (int k = 0; k < M; ++k) {
                lines[k][pos[k]] = h[k] + ((k & 1) ? injR : injL);
                if (++pos[k] >= len[k]) pos[k] = 0;
            }

            float outL = (x[0] + x[2] - x[4] + x[6]) * 0.55f;
            float outR = (x[1] - x[3] + x[5] + x[7]) * 0.55f;

            L[i] = inL * dry + outL * wet;
            R[i] = inR * dry + outR * wet;
        }
    }
};

} // namespace tv