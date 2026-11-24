import SwiftUI
import AudioToolbox

final class PluginModel: ObservableObject {
    let au: ToneVaultAudioUnit
    @Published var values: [Double]
    @Published var modelName: String?
    @Published var loading = false
    @Published var showPicker = false
    @Published var models: [ModelFile] = []
    var importAction: (() -> Void)?
    private var token: AUParameterObserverToken?
    private var obs: NSObjectProtocol?

    init(au: ToneVaultAudioUnit) {
        self.au = au
        values = au.params.map { Double($0.value) }
        modelName = au.modelName
        token = au.parameterTree?.token(byAddingParameterObserver: { [weak self] addr, val in
            DispatchQueue.main.async { if let self, Int(addr) < self.values.count { self.values[Int(addr)] = Double(val) } }
        })
        obs = NotificationCenter.default.addObserver(forName: .toneVaultModelChanged, object: nil, queue: .main) { [weak self] _ in
            self?.modelName = self?.au.modelName
        }
    }

    func set(_ i: Int, _ v: Double) {
        values[i] = v
        au.params[i].setValue(Float(v), originator: token)
    }
    func openPicker() { models = ModelStore.list(); showPicker = true }
    func choose(_ f: ModelFile) {
        loading = true
        au.loadModel(url: f.url) { [weak self] ok in
            self?.loading = false
            if ok { self?.showPicker = false }
        }
    }
}

struct PluginView: View {
    @ObservedObject var model: PluginModel
    private let cols = [GridItem(.adaptive(minimum: 84), spacing: 10)]

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 14) {
                HStack {
                    Text("TONEVAULT").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(3)
                        .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                    Spacer()
                    Circle().fill(model.modelName == nil ? Color.gray : Color.green).frame(width: 8, height: 8)
                }
                Button { model.openPicker() } label: {
                    HStack {
                        Image(systemName: "waveform")
                        Text(model.loading ? "Loading…" : (model.modelName ?? "Load a model")).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption)
                    }
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).foregroundStyle(.white)
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(0..<ToneVaultAudioUnit.specs.count, id: \.self) { i in
                        let s = ToneVaultAudioUnit.specs[i]
                        Knob(label: s.name,
                             value: Binding(get: { model.values[i] }, set: { model.set(i, $0) }),
                             range: Double(s.min)...Double(s.max), def: Double(s.def))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            if model.showPicker { picker }
        }
        .preferredColorScheme(.dark)
    }

    private var picker: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { model.showPicker = false }
            VStack(spacing: 8) {
                HStack {
                    Text("Models").font(.headline)
                    Spacer()
                    Button("Import…") { model.importAction?() }
                    Button("Done") { model.showPicker = false }
                }
                if model.models.isEmpty {
                    Text("No .nam files yet. Download some in the ToneVault app, or tap Import.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.models) { f in
                            Button { model.choose(f) } label: {
                                HStack {
                                    Text(f.name).lineLimit(1)
                                    Spacer()
                                    if f.name == model.modelName { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                                .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(12)
        }
    }
}
