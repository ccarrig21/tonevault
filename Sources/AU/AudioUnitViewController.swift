import CoreAudioKit
import SwiftUI
import UniformTypeIdentifiers

public class AudioUnitViewController: AUViewController, AUAudioUnitFactory, UIDocumentPickerDelegate {
    private var audioUnit: ToneVaultAudioUnit?
    private var host: UIHostingController<PluginView>?

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let au = try ToneVaultAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = au
        DispatchQueue.main.async { self.connect() }
        return au
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 520, height: 390)
        connect()
    }

    private func connect() {
        guard isViewLoaded, host == nil, let au = audioUnit else { return }
        let model = PluginModel(au: au)
        model.importAction = { [weak self] in self?.importFiles() }
        let h = UIHostingController(rootView: PluginView(model: model))
        addChild(h)
        h.view.translatesAutoresizingMaskIntoConstraints = false
        h.view.backgroundColor = .clear
        view.addSubview(h.view)
        NSLayoutConstraint.activate([
            h.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            h.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            h.view.topAnchor.constraint(equalTo: view.topAnchor),
            h.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        h.didMove(toParent: self)
        host = h
    }

    private func importFiles() {
        let types: [UTType] = [.data, .audio, .wav, .aiff]
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = self
        present(p, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for u in urls {
            let ext = u.pathExtension.lowercased()
            let destDir: URL
            if ModelStore.exts.contains(ext) {
                destDir = ModelStore.localDir
            } else if IRStore.exts.contains(ext) {
                destDir = IRStore.localDir
            } else {
                continue
            }
            let dest = destDir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        host?.rootView.model.refreshLists()
    }
}