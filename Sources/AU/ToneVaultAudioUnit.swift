import AudioToolbox
import AVFoundation
import CoreAudioKit

extension Notification.Name {
    static let toneVaultStateChanged = Notification.Name("toneVaultStateChanged")
}

struct ParamSpec {
    let name: String
    let min: Float, max: Float, def: Float
    let unit: String
}

enum EffectBlock: Int, CaseIterable, Identifiable {
    case gate = 0, comp, drive, amp, cab, mod, delay, reverb
    var id: Int { rawValue }

    var shortName: String {
        switch self {
        case .gate: return "GATE"
        case .comp: return "COMP"
        case .drive: return "DRIVE"
        case .amp: return "AMP"
        case .cab: return "CAB"
        case .mod: return "MOD"
        case .delay: return "DLY"
        case .reverb: return "REV"
        }
    }

    var title: String {
        switch self {
        case .gate: return "Noise Gate"
        case .comp: return "Compressor"
        case .drive: return "Overdrive"
        case .amp: return "NAM Amp"
        case .cab: return "Cab IR"
        case .mod: return "Modulation"
        case .delay: return "Stereo Delay"
        case .reverb: return "Stereo Reverb"
        }
    }

    var icon: String {
        switch self {
        case .gate: return "door.left.hand.closed"
        case .comp: return "arrow.down.right.and.arrow.up.left"
        case .drive: return "flame.fill"
        case .amp: return "waveform"
        case .cab: return "hifispeaker.fill"
        case .mod: return "wind"
        case .delay: return "repeat"
        case .reverb: return "sparkles"
        }
    }

    var enableParamIndex: Int { Int(TVParamGateOn.rawValue) + rawValue }

    var knobIndices: [Int] {
        switch self {
        case .gate:   return [1, 14]
        case .comp:   return [15, 16, 17, 18, 19, 20]
        case .drive:  return [21, 22, 23]
        case .amp:    return [0, 2, 3, 4, 5]
        case .cab:    return [25, 26, 27]
        case .mod:    return [29, 30, 31]
        case .delay:  return [33, 34, 35, 36]
        case .reverb: return [38, 39, 40, 41]
        }
    }

    var modeParamIndex: Int? {
        switch self {
        case .drive:  return 24
        case .mod:    return 28
        case .delay:  return 32
        case .reverb: return 37
        default:      return nil
        }
    }

    var modeOptions: [String] {
        switch self {
        case .drive:  return ["Tube", "Klone", "Fuzz"]
        case .mod:    return ["Chorus", "Flanger", "Tremolo"]
        case .delay:  return ["Digital", "Tape", "Ping-Pong"]
        case .reverb: return ["Room", "Plate", "Hall"]
        default:      return []
        }
    }
}

public final class ToneVaultAudioUnit: AUAudioUnit {
    static let specs: [ParamSpec] = [
        // 0..5 Legacy core
        .init(name: "Input", min: -20, max: 20, def: 0, unit: "dB"),
        .init(name: "Threshold", min: -90, max: -30, def: -70, unit: "dB"),
        .init(name: "Bass", min: -12, max: 12, def: 0, unit: "dB"),
        .init(name: "Mid", min: -12, max: 12, def: 0, unit: "dB"),
        .init(name: "Treble", min: -12, max: 12, def: 0, unit: "dB"),
        .init(name: "Output", min: -24, max: 12, def: 0, unit: "dB"),
        // 6..13 Block enables
        .init(name: "Gate On", min: 0, max: 1, def: 1, unit: ""),
        .init(name: "Comp On", min: 0, max: 1, def: 0, unit: ""),
        .init(name: "Drive On", min: 0, max: 1, def: 0, unit: ""),
        .init(name: "Amp On", min: 0, max: 1, def: 1, unit: ""),
        .init(name: "Cab On", min: 0, max: 1, def: 1, unit: ""),
        .init(name: "Mod On", min: 0, max: 1, def: 0, unit: ""),
        .init(name: "Delay On", min: 0, max: 1, def: 0, unit: ""),
        .init(name: "Reverb On", min: 0, max: 1, def: 0, unit: ""),
        // 14 Gate extra
        .init(name: "Release", min: 10, max: 300, def: 60, unit: "ms"),
        // 15..20 Compressor
        .init(name: "Threshold", min: -48, max: 0, def: -22, unit: "dB"),
        .init(name: "Ratio", min: 1, max: 12, def: 4, unit: ":1"),
        .init(name: "Attack", min: 1, max: 80, def: 10, unit: "ms"),
        .init(name: "Release", min: 30, max: 400, def: 120, unit: "ms"),
        .init(name: "Makeup", min: -12, max: 18, def: 3, unit: "dB"),
        .init(name: "Mix", min: 0, max: 100, def: 100, unit: "%"),
        // 21..24 Overdrive
        .init(name: "Drive", min: 0, max: 100, def: 45, unit: "%"),
        .init(name: "Tone", min: 0, max: 100, def: 55, unit: "%"),
        .init(name: "Level", min: -12, max: 18, def: 0, unit: "dB"),
        .init(name: "Drive Mode", min: 0, max: 2, def: 0, unit: ""),
        // 25..27 Cab IR
        .init(name: "Lo-Cut", min: 20, max: 400, def: 80, unit: "Hz"),
        .init(name: "Hi-Cut", min: 2000, max: 18000, def: 9500, unit: "Hz"),
        .init(name: "Level", min: -18, max: 12, def: 0, unit: "dB"),
        // 28..31 Modulation
        .init(name: "Mod Mode", min: 0, max: 2, def: 0, unit: ""),
        .init(name: "Rate", min: 0.1, max: 8.0, def: 1.2, unit: "Hz"),
        .init(name: "Depth", min: 0, max: 100, def: 50, unit: "%"),
        .init(name: "Mix", min: 0, max: 100, def: 45, unit: "%"),
        // 32..36 Delay
        .init(name: "Delay Mode", min: 0, max: 2, def: 1, unit: ""),
        .init(name: "Time", min: 20, max: 1200, def: 360, unit: "ms"),
        .init(name: "Feedback", min: 0, max: 92, def: 38, unit: "%"),
        .init(name: "Tone", min: 500, max: 12000, def: 4200, unit: "Hz"),
        .init(name: "Mix", min: 0, max: 100, def: 28, unit: "%"),
        // 37..41 Reverb
        .init(name: "Rev Mode", min: 0, max: 2, def: 1, unit: ""),
        .init(name: "Decay", min: 0.2, max: 8.0, def: 2.2, unit: "s"),
        .init(name: "Pre-Delay", min: 0, max: 120, def: 20, unit: "ms"),
        .init(name: "Damping", min: 1000, max: 14000, def: 6500, unit: "Hz"),
        .init(name: "Mix", min: 0, max: 100, def: 25, unit: "%"),
    ]

    private let engine: NAMEngineRef = NAMEngineCreate()
    private var inBuses: AUAudioUnitBusArray!
    private var outBuses: AUAudioUnitBusArray!
    private var tree: AUParameterTree!
    private(set) var params: [AUParameter] = []
    private var inScratch: AVAudioPCMBuffer?
    private var outScratch: AVAudioPCMBuffer?
    private let loadQueue = DispatchQueue(label: "tonevault.load", qos: .userInitiated)
    private var activeSampleRate: Double = 48000.0
    private var loadedIRURL: URL?

    private(set) var modelName: String?
    private(set) var irName: String?
    private(set) var presetName: String = "Default"
    private(set) var chainOrder: [Int] = Array(0..<Int(TVBlockCount.rawValue))

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let inBus = try AUAudioUnitBus(format: fmt)
        let outBus = try AUAudioUnitBus(format: fmt)
        inBus.maximumChannelCount = 2
        outBus.maximumChannelCount = 2
        inBuses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outBuses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])

        let eng = engine
        params = Self.specs.enumerated().map { i, s in
            let p = AUParameterTree.createParameter(
                withIdentifier: "p\(i)", name: s.name, address: AUParameterAddress(i),
                min: s.min, max: s.max, unit: .generic, unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
            p.value = s.def
            NAMEngineSetParam(eng, Int32(i), s.def)
            return p
        }
        tree = AUParameterTree.createTree(withChildren: params)
        tree.implementorValueObserver = { p, v in NAMEngineSetParam(eng, Int32(p.address), v) }
        parameterTree = tree
        maximumFramesToRender = 1024
    }

    deinit { NAMEngineDestroy(engine) }

    public override var inputBusses: AUAudioUnitBusArray { inBuses }
    public override var outputBusses: AUAudioUnitBusArray { outBuses }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let fmt = outBuses[0].format
        let srChanged = abs(fmt.sampleRate - activeSampleRate) > 1.0
        activeSampleRate = fmt.sampleRate
        NAMEnginePrepare(engine, fmt.sampleRate, Int32(maximumFramesToRender))
        inScratch = AVAudioPCMBuffer(pcmFormat: inBuses[0].format, frameCapacity: maximumFramesToRender)
        outScratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: maximumFramesToRender)
        if srChanged, let irURL = loadedIRURL {
            loadIR(url: irURL)
        }
    }

    public override func deallocateRenderResources() {
        super.deallocateRenderResources()
        inScratch = nil; outScratch = nil
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let eng = engine
        return { [unowned self] flags, ts, frames, _, outList, _, pull in
            guard let pull, let inBuf = self.inScratch, let outBuf = self.outScratch else {
                return kAudioUnitErr_Uninitialized
            }
            let bytes = frames * 4
            let inABL = inBuf.mutableAudioBufferList
            let inList = UnsafeMutableAudioBufferListPointer(inABL)
            for i in 0..<inList.count { inList[i].mDataByteSize = bytes }
            let st = pull(flags, ts, frames, 0, inABL)
            if st != noErr { return st }

            let out = UnsafeMutableAudioBufferListPointer(outList)
            let spare = UnsafeMutableAudioBufferListPointer(outBuf.mutableAudioBufferList)
            for i in 0..<out.count {
                out[i].mDataByteSize = bytes
                if out[i].mData == nil, i < spare.count { out[i].mData = spare[i].mData }
            }
            guard out.count > 0, inList.count > 0,
                  let inp = inList[0].mData?.assumingMemoryBound(to: Float.self),
                  let l = out[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let r = out.count > 1 ? (out[1].mData?.assumingMemoryBound(to: Float.self) ?? l) : l
            NAMEngineProcess(eng, inp, l, r, Int32(frames))
            return noErr
        }
    }

    // MARK: - NAM Model Loading
    func loadModel(url: URL?, completion: ((Bool) -> Void)? = nil) {
        loadQueue.async {
            let ok = NAMEngineLoadModel(self.engine, url?.path ?? "")
            DispatchQueue.main.async {
                if ok { self.modelName = url?.deletingPathExtension().lastPathComponent }
                NotificationCenter.default.post(name: .toneVaultStateChanged, object: self)
                completion?(ok)
            }
        }
    }

    // MARK: - Cab IR Loading & Resampling
    func loadIR(url: URL?, completion: ((Bool) -> Void)? = nil) {
        let targetSR = activeSampleRate
        loadQueue.async {
            guard let url else {
                _ = NAMEngineLoadIR(self.engine, nil, 0)
                DispatchQueue.main.async {
                    self.loadedIRURL = nil
                    self.irName = nil
                    NotificationCenter.default.post(name: .toneVaultStateChanged, object: self)
                    completion?(true)
                }
                return
            }
            guard let samples = Self.decodeIR(url: url, targetSampleRate: targetSR), !samples.isEmpty else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let ok = samples.withUnsafeBufferPointer { ptr in
                NAMEngineLoadIR(self.engine, ptr.baseAddress, Int32(ptr.count))
            }
            DispatchQueue.main.async {
                if ok {
                    self.loadedIRURL = url
                    self.irName = url.deletingPathExtension().lastPathComponent
                }
                NotificationCenter.default.post(name: .toneVaultStateChanged, object: self)
                completion?(ok)
            }
        }
    }

    private static func decodeIR(url: URL, targetSampleRate: Double) -> [Float]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let srcFmt = file.processingFormat
            let maxRead = AVAudioFrameCount(min(Double(file.length), srcFmt.sampleRate * 1.0))
            guard maxRead > 0, let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: maxRead) else { return nil }
            try file.read(into: srcBuf, frameCount: maxRead)

            guard let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else { return nil }

            let ratio = targetSampleRate / srcFmt.sampleRate
            let outCap = AVAudioFrameCount(ceil(Double(srcBuf.frameLength) * ratio)) + 64
            guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { return nil }

            var provided = false
            var convErr: NSError?
            converter.convert(to: dstBuf, error: &convErr) { _, outStatus in
                if provided {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return srcBuf
            }
            guard convErr == nil, dstBuf.frameLength > 0, let ptr = dstBuf.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: Int(dstBuf.frameLength)))
        } catch {
            return nil
        }
    }

    // MARK: - Chain Order & Presets
    func setChainOrder(_ order: [Int]) {
        guard order.count == Int(TVBlockCount.rawValue), Set(order).count == order.count else { return }
        chainOrder = order
        let cOrder = order.map { Int32($0) }
        cOrder.withUnsafeBufferPointer { ptr in
            NAMEngineSetChainOrder(engine, ptr.baseAddress, Int32(ptr.count))
        }
        NotificationCenter.default.post(name: .toneVaultStateChanged, object: self)
    }

    func applyPreset(_ preset: RigPreset) {
        setChainOrder(preset.chainOrder)
        for (idx, val) in preset.params where idx < params.count {
            params[idx].value = val
        }
        if let m = preset.modelName, let u = ModelStore.url(named: m) { loadModel(url: u) }
        if let i = preset.irName, let u = IRStore.url(named: i) { loadIR(url: u) }
        presetName = preset.name
        NotificationCenter.default.post(name: .toneVaultStateChanged, object: self)
    }

    func snapshotPreset(named name: String) -> RigPreset {
        var map: [Int: Float] = [:]
        for (i, p) in params.enumerated() { map[i] = p.value }
        presetName = name
        NotificationCenter.default.post(name: .toneVaultStateChanged, object: self)
        return RigPreset(name: name, isFactory: false, chainOrder: chainOrder, params: map,
                         modelName: modelName, irName: irName)
    }

    // Remember full rig state in host sessions (Loopy Pro, AUM, GarageBand).
    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            if let n = modelName { s["modelName"] = n }
            if let ir = irName { s["irName"] = ir }
            s["chainOrder"] = chainOrder
            s["presetName"] = presetName
            return s
        }
        set {
            super.fullState = newValue
            if let o = newValue?["chainOrder"] as? [Int] { setChainOrder(o) }
            if let p = newValue?["presetName"] as? String { presetName = p }
            if let n = newValue?["modelName"] as? String, let u = ModelStore.url(named: n) { loadModel(url: u) }
            if let ir = newValue?["irName"] as? String, let u = IRStore.url(named: ir) { loadIR(url: u) }
        }
    }
}