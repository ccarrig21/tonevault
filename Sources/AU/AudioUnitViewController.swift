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
        preferredContentSize = CGSize(width: 440, height: 330)
        connect()
    }

    private func connect() {
        guard isViewLoaded, host == nil, let au = audioUnit else { return }
        let model = PluginModel(au: au)
        model.importAction = { [weak self] in self?.importModels() }
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

    private func importModels() {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = self
        present(p, animated: true)
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "nam" {
            let dest = ModelStore.localDir.appendingPathComponent(u.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: u, to: dest)
        }
        host?.rootView.model.models = ModelStore.list()
    }
}
