import HoldMyTrackCore
import UIKit
import UniformTypeIdentifiers

/// Upload (apps/docs/SPEC.md FR-3.6): GPX, FIT and TCX files from the document picker, sent
/// by Uploads, or opened or shared from another app, listed until Upload sends them or Cancel
/// drops them; the files going, what the server said, and the imports still running, read every
/// 2 seconds while the screen shows.
final class UploadViewController: UIViewController, UIDocumentPickerDelegate {
    private let api: APIClient
    private let transfers = Controls.column([], spacing: DesignTokens.Space.s8)
    private let notes = Controls.column([], spacing: DesignTokens.Space.s8)
    private let running = Controls.column([], spacing: DesignTokens.Space.s8)
    private var poll: Task<Void, Never>?
    private var onClose: (() -> Void)?
    private let sharedNames = Controls.body("", color: UIColor(resource: .ink))
    private lazy var sharedSection: UIStackView = {
        let title = Controls.body(String(localized: "Upload these files to your account?", comment: "Upload: over the files another app opened in HoldMyTrack."), color: UIColor(resource: .ink))
        sharedNames.accessibilityIdentifier = "sharedFiles"
        let send = Controls.primaryButton(String(localized: "Upload"), id: "uploadShared")
        send.addAction(UIAction { _ in Uploads.shared.sendShared() }, for: .primaryActionTriggered)
        let cancel = Controls.secondaryButton(String(localized: "Cancel"), id: "cancelShared")
        cancel.addAction(UIAction { _ in Uploads.shared.cancelShared() }, for: .primaryActionTriggered)
        return Controls.column([title, sharedNames, send, cancel], spacing: DesignTokens.Space.s8)
    }()

    /// The document types the app opens, declared in Info.plist.
    static let types: [UTType] = ["com.topografix.gpx", "com.garmin.fit", "com.garmin.tcx"].map { UTType(importedAs: $0) }

    init(api: APIClient) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Upload")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Upload as a sheet over the screen it opens from (apps/docs/SPEC.md FR-3.6), closed
    /// by Close or a swipe; files carry on once it's gone.
    /// onClose: what's under the sheet, which iOS doesn't tell, reads again.
    static func sheet(api: APIClient, onClose: @escaping () -> Void) -> UINavigationController {
        let upload = UploadViewController(api: api)
        upload.onClose = onClose
        let close = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak upload] _ in upload?.dismiss(animated: true) })
        close.accessibilityIdentifier = "uploadClose"
        upload.navigationItem.leftBarButtonItem = close
        let nav = UINavigationController(rootViewController: upload)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        let about = Controls.body(String(localized: ".gpx, .fit or .tcx files, up to \(UploadPlan.maxFiles) at a time."))
        let pick = Controls.primaryButton(String(localized: "Choose files…"), id: "chooseFiles")
        pick.addAction(UIAction { [weak self] _ in self?.choose() }, for: .primaryActionTriggered)
        running.accessibilityIdentifier = "runningImports"
        Controls.host(Controls.column([sharedSection, about, pick, transfers, notes, running]), in: self)
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true { onClose?() }
    }

    /// Files from the picker, sent at once.
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
        sharedSection.isHidden = uploads.shared.urls.isEmpty
        sharedNames.text = uploads.shared.names.joined(separator: "\n")
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