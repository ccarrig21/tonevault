import SwiftUI
import AudioToolbox

enum ActiveModal { case none, models, irs, presets }

final class PluginModel: ObservableObject {
    let au: ToneVaultAudioUnit
    @Published var values: [Double]
    @Published var chainOrder: [Int]
    @Published var selected: EffectBlock = .amp
    @Published var modelName: String?
    @Published var irName: String?
    @Published var presetName: String
    @Published var loading = false
    @Published var modal: ActiveModal = .none
    @Published var models: [ModelFile] = []
    @Published var irs: [ModelFile] = []
    @Published var userPresets: [RigPreset] = []

    var importAction: (() -> Void)?
    private var token: AUParameterObserverToken?
    private var obs: NSObjectProtocol?

    init(au: ToneVaultAudioUnit) {
        self.au = au
        values = au.params.map { Double($0.value) }
        chainOrder = au.chainOrder
        modelName = au.modelName
        irName = au.irName
        presetName = au.presetName

        token = au.parameterTree?.token(byAddingParameterObserver: { [weak self] addr, val in
            DispatchQueue.main.async {
                if let self, Int(addr) < self.values.count { self.values[Int(addr)] = Double(val) }
            }
        })
        obs = NotificationCenter.default.addObserver(forName: .toneVaultStateChanged, object: au, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.modelName = self.au.modelName
            self.irName = self.au.irName
            self.chainOrder = self.au.chainOrder
            self.presetName = self.au.presetName
        }
    }

    deinit {
        if let obs { NotificationCenter.default.removeObserver(obs) }
    }

    func set(_ i: Int, _ v: Double) {
        guard i < values.count else { return }
        values[i] = v
        au.params[i].setValue(Float(v), originator: token)
    }

    func isEnabled(_ b: EffectBlock) -> Bool {
        values[b.enableParamIndex] >= 0.5
    }

    func toggle(_ b: EffectBlock) {
        set(b.enableParamIndex, isEnabled(b) ? 0 : 1)
    }

    func move(_ b: EffectBlock, by delta: Int) {
        guard let idx = chainOrder.firstIndex(of: b.rawValue) else { return }
        let target = idx + delta
        guard target >= 0 && target < chainOrder.count else { return }
        var next = chainOrder
        next.swapAt(idx, target)
        au.setChainOrder(next)
    }

    func canMove(_ b: EffectBlock, by delta: Int) -> Bool {
        guard let idx = chainOrder.firstIndex(of: b.rawValue) else { return false }
        let target = idx + delta
        return target >= 0 && target < chainOrder.count
    }

    func refreshLists() {
        models = ModelStore.list()
        irs = IRStore.list()
        userPresets = PresetStore.listUser()
    }

    func open(_ m: ActiveModal) {
        refreshLists()
        modal = m
    }

    func chooseModel(_ f: ModelFile?) {
        loading = true
        au.loadModel(url: f?.url) { [weak self] ok in
            self?.loading = false
            if ok { self?.modal = .none }
        }
    }

    func chooseIR(_ f: ModelFile?) {
        loading = true
        au.loadIR(url: f?.url) { [weak self] ok in
            self?.loading = false
            if ok { self?.modal = .none }
        }
    }

    func loadPreset(_ p: RigPreset) {
        au.applyPreset(p)
        values = au.params.map { Double($0.value) }
        modal = .none
    }

    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        PresetStore.save(au.snapshotPreset(named: trimmed))
        refreshLists()
    }
}

struct PluginView: View {
    @ObservedObject var model: PluginModel
    @State private var newPresetName = ""
    private let cols = [GridItem(.adaptive(minimum: 74), spacing: 8)]

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 10) {
                header
                chainStrip
                editorCard
            }
            .padding(14)

            if model.modal != .none { modalOverlay }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Top Header
    private var header: some View {
        HStack(spacing: 10) {
            Text("TONEVAULT")
                .font(.system(size: 14, weight: .heavy, design: .rounded)).tracking(2.5)
                .foregroundStyle(Theme.gradient)
            Spacer()
            Button { model.open(.presets) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3").font(.caption2)
                    Text(model.presetName).font(.system(size: 11.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.1)))
                .foregroundStyle(.white)
            }.buttonStyle(.plain)

            HStack(spacing: 4) {
                Circle().fill(model.modelName == nil ? Color.gray.opacity(0.5) : Color.green).frame(width: 7, height: 7)
                Circle().fill(model.irName == nil ? Color.gray.opacity(0.5) : Theme.accent).frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - Horizontal Reorderable Signal Chain Strip
    private var chainStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(model.chainOrder.enumerated()), id: \.element) { idx, raw in
                    if let blk = EffectBlock(rawValue: raw) {
                        chainTile(blk)
                        if idx < model.chainOrder.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.white.opacity(0.22))
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chainTile(_ blk: EffectBlock) -> some View {
        let on = model.isEnabled(blk)
        let isSel = model.selected == blk
        return VStack(spacing: 4) {
            Button { model.toggle(blk) } label: {
                Circle()
                    .fill(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.16)))
                    .frame(width: 7, height: 7)
                    .shadow(color: on ? Theme.accent.opacity(0.8) : .clear, radius: 4)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.plain)

            Image(systemName: blk.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : .secondary)

            Text(blk.shortName)
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(on ? .white : .secondary)
                .padding(.bottom, 5)
        }
        .frame(width: 50)
        .background(isSel ? Color.white.opacity(0.14) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSel ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(on ? 0.14 : 0.06)),
                        lineWidth: isSel ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture { model.selected = blk }
    }

    // MARK: - Focused Active Block Editor Card
    private var editorCard: some View {
        let blk = model.selected
        let on = model.isEnabled(blk)
        return VStack(spacing: 10) {
            // Block header: power, title, mode picker, chain shift arrows
            HStack(spacing: 8) {
                Button { model.toggle(blk) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power").font(.system(size: 10, weight: .bold))
                        Text(on ? "ON" : "OFF").font(.system(size: 10, weight: .heavy, design: .rounded))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                    .foregroundStyle(on ? .white : .secondary)
                }.buttonStyle(.plain)

                Text(blk.title)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer(minLength: 4)

                // Reorder block earlier/later in signal chain
                HStack(spacing: 4) {
                    Button { model.move(blk, by: -1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 22)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.canMove(blk, by: -1) ? .white : .white.opacity(0.25))
                    .disabled(!model.canMove(blk, by: -1))

                    Button { model.move(blk, by: 1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 22)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.canMove(blk, by: 1) ? .white : .white.opacity(0.25))
                    .disabled(!model.canMove(blk, by: 1))
                }
            }

            // Optional Mode selector (Drive / Mod / Delay / Reverb)
            if let modeIdx = blk.modeParamIndex {
                SegmentBar(
                    options: blk.modeOptions,
                    selection: Binding(
                        get: { Int(round(model.values[modeIdx])) },
                        set: { model.set(modeIdx, Double($0)) }
                    )
                )
            }

            // Optional File Picker bar (NAM Amp or Cab IR)
            if blk == .amp {
                fileBar(icon: "waveform",
                        label: model.loading ? "Loading…" : (model.modelName ?? "Load a .nam model"),
                        action: { model.open(.models) })
            } else if blk == .cab {
                fileBar(icon: "hifispeaker.fill",
                        label: model.loading ? "Loading…" : (model.irName ?? "Load a .wav Cab IR"),
                        action: { model.open(.irs) })
            }

            // Parameter Knobs
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(blk.knobIndices, id: \.self) { i in
                        let s = ToneVaultAudioUnit.specs[i]
                        Knob(label: s.name,
                             value: Binding(get: { model.values[i] }, set: { model.set(i, $0) }),
                             range: Double(s.min)...Double(s.max),
                             def: Double(s.def),
                             unit: s.unit)
                    }
                }
                .padding(.top, 2)
            }
            .opacity(on ? 1.0 : 0.45)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.09)))
    }

    private func fileBar(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.accent)
                Text(label).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    // MARK: - Modal Pickers (Models / Cab IRs / Presets)
    private var modalOverlay: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea().onTapGesture { model.modal = .none }
            VStack(spacing: 8) {
                switch model.modal {
                case .models:
                    filePickerContent(title: "NAM Models", files: model.models, current: model.modelName,
                                      emptyText: "No .nam files yet. Download in the ToneVault app or tap Import.",
                                      onPick: { model.chooseModel($0) })
                case .irs:
                    filePickerContent(title: "Cabinet IRs", files: model.irs, current: model.irName,
                                      emptyText: "No .wav IR files yet. Drop .wav IRs in Files › ToneVault › IRs or tap Import.",
                                      onPick: { model.chooseIR($0) })
                case .presets:
                    presetPickerContent
                case .none:
                    EmptyView()
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
        }
    }

    private func filePickerContent(title: String, files: [ModelFile], current: String?,
                                   emptyText: String, onPick: @escaping (ModelFile?) -> Void) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if current != nil { Button("Unload") { onPick(nil) }.foregroundStyle(.secondary) }
                Button("Import…") { model.importAction?() }
                Button("Done") { model.modal = .none }
            }
            if files.isEmpty {
                Text(emptyText).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding()
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(files) { f in
                        Button { onPick(f) } label: {
                            HStack {
                                Text(f.name).lineLimit(1)
                                Spacer()
                                if f.name == current { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var presetPickerContent: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Rig Presets").font(.headline)
                Spacer()
                Button("Done") { model.modal = .none }
            }
            HStack(spacing: 6) {
                TextField("Save current rig as…", text: $newPresetName)
                    .font(.system(size: 13))
                    .padding(8).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                Button("Save") {
                    model.savePreset(named: newPresetName)
                    newPresetName = ""
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !model.userPresets.isEmpty {
                        Text("USER RIGS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.top, 4)
                        ForEach(model.userPresets) { p in
                            HStack {
                                Button { model.loadPreset(p) } label: {
                                    HStack {
                                        Text(p.name).lineLimit(1)
                                        Spacer()
                                        if p.name == model.presetName { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                    }
                                }.buttonStyle(.plain)
                                Button {
                                    PresetStore.delete(named: p.name)
                                    model.refreshLists()
                                } label: {
                                    Image(systemName: "trash").font(.caption).foregroundStyle(.red.opacity(0.8))
                                }.buttonStyle(.plain).padding(.leading, 6)
                            }
                            .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    Text("FACTORY TEMPLATES").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(PresetStore.factory) { p in
                        Button { model.loadPreset(p) } label: {
                            HStack {
                                Text(p.name).lineLimit(1)
                                Spacer()
                                if p.name == model.presetName { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}