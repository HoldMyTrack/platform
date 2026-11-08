import HoldMyTrackCore
import UIKit
import UniformTypeIdentifiers

/// Upload (apps/android/docs/SPEC.md FR-3.6): GPX, FIT and TCX files from the document picker, or
/// opened or shared from another app, sent by Uploads; the files going, what the server said,
/// and the imports still running, read every 2 seconds while the screen shows.
final class UploadViewController: UIViewController, UIDocumentPickerDelegate {
    private let api: APIClient
    private let transfers = Controls.column([], spacing: DesignTokens.Space.s8)
    private let notes = Controls.column([], spacing: DesignTokens.Space.s8)
    private let running = Controls.column([], spacing: DesignTokens.Space.s8)
    private var poll: Task<Void, Never>?

    /// The document types the app opens, declared in Info.plist.
    static let types: [UTType] = ["com.topografix.gpx", "com.garmin.fit", "com.garmin.tcx"].map { UTType(importedAs: $0) }

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Upload")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        let about = Controls.body(String(localized: "GPX, FIT or TCX files, up to \(UploadPlan.maxFiles) at a time and \(UploadPlan.maxFileBytes >> 20) MB each. They keep going if you leave this screen. Finished imports are in Sync history on the web."))
        let pick = Controls.primaryButton(String(localized: "Choose files"), id: "chooseFiles")
        pick.addAction(UIAction { [weak self] _ in self?.choose() }, for: .primaryActionTriggered)
        running.accessibilityIdentifier = "runningImports"
        Controls.host(Controls.column([about, pick, transfers, notes, running]), in: self)
        NotificationCenter.default.addObserver(forName: Uploads.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        poll = Task {
            while !Task.isCancelled {
                if let imports = try? await api.activeImports() { show(imports) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.cancel()
    }

    /// Files from another app, or the picker.
    func send(_ urls: [URL]) {
        loadViewIfNeeded()
        Uploads.shared.enqueue(urls)
    }

    private func choose() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        send(urls)
    }

    private func render() {
        let uploads = Uploads.shared
        transfers.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for transfer in uploads.transfers.values.sorted(by: { $0.name < $1.name }) {
            let label = Controls.body(transfer.name, color: UIColor(resource: .ink))
            let bar = UIProgressView(progressViewStyle: .default)
            bar.progressTintColor = UIColor(resource: .accent)
            bar.progress = transfer.total > 0 ? Float(transfer.sent) / Float(transfer.total) : 0
            bar.accessibilityLabel = String(localized: "Sending \(transfer.name)")
            transfers.addArrangedSubview(Controls.column([label, bar], spacing: DesignTokens.Space.s4))
        }
        notes.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for note in uploads.notes {
            let label = Controls.body(note.text, color: UIColor(resource: note.error ? .danger : .inkSecondary))
            label.accessibilityIdentifier = "uploadNote"
            notes.addArrangedSubview(label)
        }
    }

    private func show(_ imports: [ActiveImport]) {
        running.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in imports {
            let label = Controls.body(String(localized: "\(item.title): processed \(item.done) of \(item.total)"), color: UIColor(resource: .ink))
            running.addArrangedSubview(label)
        }
    }
}