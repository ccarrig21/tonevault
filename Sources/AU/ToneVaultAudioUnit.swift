import AudioToolbox
import AVFoundation
import CoreAudioKit

extension Notification.Name {
    static let toneVaultModelChanged = Notification.Name("toneVaultModelChanged")
}

struct ParamSpec {
    let name: String
    let min: Float, max: Float, def: Float
}

public final class ToneVaultAudioUnit: AUAudioUnit {
    static let specs: [ParamSpec] = [
        .init(name: "Input", min: -20, max: 20, def: 0),
        .init(name: "Gate", min: -90, max: -30, def: -70),
        .init(name: "Bass", min: -12, max: 12, def: 0),
        .init(name: "Mid", min: -12, max: 12, def: 0),
        .init(name: "Treble", min: -12, max: 12, def: 0),
        .init(name: "Output", min: -24, max: 12, def: 0),
    ]

    private let engine: NAMEngineRef = NAMEngineCreate()
    private var inBuses: AUAudioUnitBusArray!
    private var outBuses: AUAudioUnitBusArray!
    private var tree: AUParameterTree!
    private(set) var params: [AUParameter] = []
    private var inScratch: AVAudioPCMBuffer?
    private var outScratch: AVAudioPCMBuffer?
    private let loadQueue = DispatchQueue(label: "tonevault.load", qos: .userInitiated)
    private(set) var modelName: String?

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
        NAMEnginePrepare(engine, fmt.sampleRate, Int32(maximumFramesToRender))
        inScratch = AVAudioPCMBuffer(pcmFormat: inBuses[0].format, frameCapacity: maximumFramesToRender)
        outScratch = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: maximumFramesToRender)
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

    func loadModel(url: URL, completion: ((Bool) -> Void)? = nil) {
        loadQueue.async {
            let ok = NAMEngineLoadModel(self.engine, url.path)
            DispatchQueue.main.async {
                if ok { self.modelName = url.deletingPathExtension().lastPathComponent }
                NotificationCenter.default.post(name: .toneVaultModelChanged, object: nil)
                completion?(ok)
            }
        }
    }

    // Remember the loaded model in host sessions/presets.
    public override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            if let n = modelName { s["modelName"] = n }
            return s
        }
        set {
            super.fullState = newValue
            if let n = newValue?["modelName"] as? String, let u = ModelStore.url(named: n) { loadModel(url: u) }
        }
    }
}
