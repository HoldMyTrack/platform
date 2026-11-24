import HoldMyTrackCore
import UIKit

/// Create trip, Edit trip and Send a copy as sheets (root docs/SPEC.md FR-13.2, FR-13.7): a
/// navigation bar with Cancel and the form's action over the form, in a `UISheetPresentationController`.
/// The sheet stays up while its request runs, and a failure keeps it open with the server's reason
/// and what was typed. Only Cancel or a swipe closes it, and neither while a request runs.
@MainActor
enum TripSheets {
    /// A Trip's name and description; run answers nil once saved, else why it failed.
    static func trip(over view: UIView, title: String, name: String, description: String, action: String, busy: String,
                     run: @escaping (String, String) async -> TripDialogs.Outcome) {
        present(TripFormController(title: title, name: name, description: description, action: action, busy: busy, run: run), over: view)
    }

    /// FR-13.7: a copy to an email address. It stays open after sending, for another address.
    static func sendCopy(over view: UIView, trip: Trip, run: @escaping (String) async -> TripDialogs.Outcome) {
        present(SendCopyController(trip: trip, run: run), over: view)
    }

    private static func present(_ form: UIViewController, over view: UIView) {
        let nav = UINavigationController(rootViewController: form)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        TripDialogs.top(view)?.present(nav, animated: true)
    }

    /// An edit that would take text past limit (TripForms.length), cut to what fits, with where the
    /// caret goes after it; nil when the whole edit fits.
    static func clip(_ current: String, _ range: NSRange, _ inserted: String, limit: Int) -> (text: String, caret: Int)? {
        let text = current as NSString
        if TripForms.length(text.replacingCharacters(in: range, with: inserted)) <= limit { return nil }
        let rest = TripForms.length(text.replacingCharacters(in: range, with: ""))
        let part = TripForms.fitting(inserted, room: max(0, limit - rest))
        return (text.replacingCharacters(in: range, with: part), range.location + (part as NSString).length)
    }

    static func stack(_ views: [UIView], in controller: UIViewController) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = DesignTokens.Space.s12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let inset = DesignTokens.Space.s16
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -inset),
        ])
        controller.view.backgroundColor = UIColor(resource: .surface)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: controller.view.keyboardLayoutGuide.topAnchor),
        ])
        return scroll
    }
}

/// Name (required, up to 200 characters) and a multi-line Description (up to 2000).
private final class TripFormController: UIViewController, UITextFieldDelegate, UITextViewDelegate {
    private let action: String
    private let busy: String
    private let run: (String, String) async -> TripDialogs.Outcome
    private let name = Controls.field(String(localized: "Name"), id: "tripName")
    private let about = UITextView()
    private let nameHint = Controls.body(String(localized: "Name"))
    private let aboutHint = Controls.body(String(localized: "Description (optional)"))
    private let error = Controls.error(id: "tripError")
    private var saving = false

    init(title: String, name: String, description: String, action: String, busy: String,
         run: @escaping (String, String) async -> TripDialogs.Outcome) {
        self.action = action
        self.busy = busy
        self.run = run
        super.init(nibName: nil, bundle: nil)
        self.title = title
        self.name.text = name
        about.text = description
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: action, primaryAction: UIAction { [weak self] _ in self?.save() })
        navigationItem.rightBarButtonItem?.style = .done
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "tripSave"

        name.autocapitalizationType = .sentences
        name.autocorrectionType = .default
        name.returnKeyType = .done
        name.delegate = self
        name.accessibilityLabel = String(localized: "Name")
        name.addAction(UIAction { [weak self] _ in self?.render() }, for: .editingChanged)

        about.font = Typeface.sans(DesignTokens.Text.xl)
        about.adjustsFontForContentSizeCategory = true
        about.backgroundColor = UIColor(resource: .surface)
        about.layer.cornerRadius = DesignTokens.Radius.sm
        about.layer.borderWidth = 1
        about.layer.borderColor = UIColor(resource: .border).cgColor
        about.autocapitalizationType = .sentences
        about.delegate = self
        about.accessibilityIdentifier = "tripDescription"
        about.accessibilityLabel = String(localized: "Description (optional)")
        about.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        nameHint.isAccessibilityElement = false
        aboutHint.isAccessibilityElement = false
        // A layer's color doesn't follow the theme on its own.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.about.layer.borderColor = UIColor(resource: .border).cgColor
        }

        _ = TripSheets.stack([nameHint, name, aboutHint, about, error], in: self)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        name.becomeFirstResponder()
    }

    private func render() {
        let item = navigationItem.rightBarButtonItem
        item?.title = saving ? busy : action
        item?.isEnabled = TripForms.actionEnabled(text: name.text ?? "", busy: saving)
        navigationItem.leftBarButtonItem?.isEnabled = !saving
        isModalInPresentation = saving
        name.isEnabled = !saving
        about.isEditable = !saving
    }

    private func save() {
        guard TripForms.actionEnabled(text: name.text ?? "", busy: saving) else { return }
        let typed = (name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = about.text.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        error.isHidden = true
        render()
        Task {
            let failure = await run(typed, text)
            saving = false
            if let failure {
                error.text = failure
                error.isHidden = false
                render()
                UIAccessibility.post(notification: .announcement, argument: failure)
            } else {
                dismiss(animated: true)
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        save()
        return false
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let clipped = TripSheets.clip(textField.text ?? "", range, string, limit: TripForms.nameLimit) else { return true }
        textField.text = clipped.text
        if let caret = textField.position(from: textField.beginningOfDocument, offset: clipped.caret) {
            textField.selectedTextRange = textField.textRange(from: caret, to: caret)
        }
        render()
        return false
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard let clipped = TripSheets.clip(textView.text, range, text, limit: TripForms.descriptionLimit) else { return true }
        textView.text = clipped.text
        textView.selectedRange = NSRange(location: clipped.caret, length: 0)
        return false
    }
}

/// The address to send a copy to. Once sent it says so, the same whether or not the address has
/// an account, and clears the field for another; Cancel becomes Close.
private final class SendCopyController: UIViewController, UITextFieldDelegate {
    private let run: (String) async -> TripDialogs.Outcome
    private let email = Controls.field(String(localized: "Email"), id: "sendEmail")
    private let status = Controls.body()
    private var sending = false
    private var sent = false

    init(trip: Trip, run: @escaping (String) async -> TripDialogs.Outcome) {
        self.run = run
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Send a copy of “\(trip.name)”")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: String(localized: "Cancel"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: String(localized: "Send"), primaryAction: UIAction { [weak self] _ in self?.send() })
        navigationItem.rightBarButtonItem?.style = .done
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "sendCopy"

        let about = Controls.body(String(localized: "They get their own copy of this trip and its tracks in their HoldMyTrack account, once they accept it. It's theirs from then on: what you change later doesn't reach it. Sending again later adds only the tracks they don't have yet."))
        email.keyboardType = .emailAddress
        email.textContentType = .emailAddress
        email.returnKeyType = .send
        email.delegate = self
        email.accessibilityLabel = String(localized: "Email")
        email.addAction(UIAction { [weak self] _ in self?.render() }, for: .editingChanged)
        status.accessibilityIdentifier = "sendStatus"
        status.isHidden = true

        _ = TripSheets.stack([about, email, status], in: self)
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        email.becomeFirstResponder()
    }

    private func render() {
        let item = navigationItem.rightBarButtonItem
        item?.title = sending ? String(localized: "Sending…") : String(localized: "Send")
        item?.isEnabled = TripForms.actionEnabled(text: email.text ?? "", busy: sending)
        navigationItem.leftBarButtonItem?.title = sent ? String(localized: "Close") : String(localized: "Cancel")
        navigationItem.leftBarButtonItem?.isEnabled = !sending
        isModalInPresentation = sending
        email.isEnabled = !sending
    }

    private func send() {
        let typed = (email.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard TripForms.actionEnabled(text: typed, busy: sending) else { return }
        sending = true
        status.isHidden = true
        render()
        Task {
            let failure = await run(typed)
            sending = false
            if let failure {
                status.text = failure
                status.textColor = UIColor(resource: .danger)
            } else {
                sent = true
                email.text = ""
                status.text = String(localized: "Sent to \(typed). If that address has a HoldMyTrack account, they'll find the copy in their Trips tab.")
                status.textColor = UIColor(resource: .ink)
            }
            status.isHidden = false
            render()
            UIAccessibility.post(notification: .announcement, argument: status.text)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        send()
        return false
    }
}
