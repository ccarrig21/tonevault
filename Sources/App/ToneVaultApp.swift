import SwiftUI
import UniformTypeIdentifiers

@main
struct ToneVaultApp: App {
    @StateObject private var api = TONE3000()
    init() {
        ModelStore.syncLocalToGroup()
        IRStore.syncLocalToGroup()
    }
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(api).preferredColorScheme(.dark).tint(Theme.accent)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            BrowseView().tabItem { Label("Browse", systemImage: "magnifyingglass") }
            LibraryView().tabItem { Label("Library", systemImage: "waveform") }
            SettingsView().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
    }
}

struct BrowseView: View {
    @EnvironmentObject var api: TONE3000
    @State private var q = ""
    @State private var tones: [Tone] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                if !api.signedIn {
                    VStack(spacing: 8) {
                        Image(systemName: "lock.circle").font(.system(size: 44)).foregroundStyle(Theme.accent)
                        Text("Sign in to TONE3000").font(.headline)
                        Text("Open the Account tab to add your key and connect.").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                            ForEach(tones) { t in
                                NavigationLink(value: t) {
                                    Card {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(t.title).font(.system(.body, design: .rounded).weight(.semibold)).foregroundStyle(.white)
                                            if !t.subtitle.isEmpty { Text(t.subtitle).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }.buttonStyle(.plain)
                            }
                            if busy { ProgressView().padding() }
                        }.padding(16)
                    }
                }
            }
            .navigationTitle("Browse")
            .searchable(text: $q, prompt: "Search amps, pedals, rigs")
            .onSubmit(of: .search) { Task { await run() } }
            .navigationDestination(for: Tone.self) { ToneDetailView(tone: $0) }
            .task { if api.signedIn && tones.isEmpty { await run() } }
        }
    }

    private func run() async {
        busy = true; error = nil
        do { tones = try await api.search(q) } catch { self.error = error.localizedDescription }
        busy = false
    }
}

struct ToneDetailView: View {
    @EnvironmentObject var api: TONE3000
    let tone: Tone
    @State private var models: [RemoteModel] = []
    @State private var done: Set<String> = []
    @State private var working: Set<String> = []
    @State private var error: String?

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    ForEach(models) { m in
                        Card {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(m.name).foregroundStyle(.white)
                                    if !m.size.isEmpty { Text(m.size).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if working.contains(m.id) { ProgressView() }
                                else if done.contains(m.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                else { Button { Task { await get(m) } } label: { Image(systemName: "arrow.down.circle.fill").font(.title2) } }
                            }
                        }
                    }
                }.padding(16)
            }
        }
        .navigationTitle(tone.title).navigationBarTitleDisplayMode(.inline)
        .task { do { models = try await api.models(for: tone) } catch { self.error = error.localizedDescription } }
    }

    private func get(_ m: RemoteModel) async {
        working.insert(m.id)
        do { try await api.download(m, tone: tone); done.insert(m.id) } catch { self.error = error.localizedDescription }
        working.remove(m.id)
    }
}

struct LibraryView: View {
    @State private var tab = 0 // 0 = Amps (.nam), 1 = Cab IRs (.wav)
    @State private var models = ModelStore.list()
    @State private var irs = IRStore.list()
    @State private var showImporter = false

    private var activeFiles: [ModelFile] { tab == 0 ? models : irs }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                VStack(spacing: 10) {
                    SegmentBar(options: ["Amps (.nam)", "Cab IRs (.wav)"], selection: $tab)
                        .padding(.top, 6)

                    if activeFiles.isEmpty {
                        Spacer()
                        Text(tab == 0
                             ? "No amp models yet.\nDownload from Browse, tap +, or drop .nam files into\nFiles › On My iPhone › ToneVault › Models."
                             : "No cabinet IRs yet.\nTap + to import .wav files, or drop them into\nFiles › On My iPhone › ToneVault › IRs.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
                        Spacer()
                    } else {
                        List {
                            ForEach(activeFiles) { f in
                                HStack {
                                    Image(systemName: tab == 0 ? "waveform" : "hifispeaker.fill")
                                        .foregroundStyle(Theme.accent)
                                    Text(f.name)
                                }
                                .listRowBackground(Theme.card)
                            }
                            .onDelete { idx in
                                let items = idx.map { activeFiles[$0] }
                                if tab == 0 { items.forEach(ModelStore.delete) }
                                else { items.forEach(IRStore.delete) }
                                reload()
                            }
                        }.scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data, .audio, .wav, .aiff],
                          allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for u in urls {
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    let ext = u.pathExtension.lowercased()
                    let dir: URL? = ModelStore.exts.contains(ext) ? ModelStore.writeDir
                        : (IRStore.exts.contains(ext) ? IRStore.writeDir : nil)
                    guard let dir else { continue }
                    let dest = dir.appendingPathComponent(u.lastPathComponent)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: u, to: dest)
                }
                reload()
            }
            .onAppear { reload() }
            .refreshable { reload() }
        }
    }

    private func reload() {
        ModelStore.syncLocalToGroup()
        IRStore.syncLocalToGroup()
        models = ModelStore.list()
        irs = IRStore.list()
    }
}

struct SettingsView: View {
    @EnvironmentObject var api: TONE3000
    @State private var pasted = ""
    @State private var msg: String?
    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 12) {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Publishable key").font(.headline)
                                TextField("t3k_pub_…", text: $api.clientID).textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .padding(10).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                                Text("Create one in TONE3000 › Settings › API Keys and add this redirect URI:").font(.caption).foregroundStyle(.secondary)
                                Text(Config.redirectURI).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(api.signedIn ? "Connected" : "Not connected").font(.headline)
                                Button(api.signedIn ? "Reconnect" : "Sign in with TONE3000") {
                                    Task { do { try await api.login(); msg = "Signed in." } catch { msg = error.localizedDescription } }
                                }.buttonStyle(.borderedProminent)
                                if api.signedIn { Button("Sign out", role: .destructive) { api.signOut() } }
                                if let msg { Text(msg).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Fallback: paste an access token").font(.headline)
                                SecureField("access token", text: $pasted).padding(10).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                                Button("Use token") { api.access = pasted; pasted = "" }.disabled(pasted.isEmpty)
                            }
                        }
                    }.padding(16)
                }
            }.navigationTitle("Account")
        }
    }
}