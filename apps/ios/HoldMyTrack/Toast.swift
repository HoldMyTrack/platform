import HoldMyTrackCore
import UIKit

/// A short message for something that just happened, over the screen above the record button, or
/// above the safe area while the tab bar is away, and gone after a few seconds, longer for longer
/// words, as Android's Toast and Snackbar. With no action it takes no touch, so a tap reaches what
/// is under it; with one, such as Undo, it holds a button and stays longer.
@MainActor
enum Toast {
    private static weak var shown: UIView?

    static func show(_ text: String, action: (title: String, run: () -> Void)? = nil, over view: UIView, above bottom: UIView?) {
        shown?.removeFromSuperview()
        let label = Controls.body(text, color: UIColor(resource: .ink))
        label.textAlignment = action == nil ? .center : .natural
        label.accessibilityIdentifier = "toast"
        let row = UIStackView(arrangedSubviews: [label])
        row.alignment = .center
        row.spacing = DesignTokens.Space.s12
        let box = UIView()
        box.isUserInteractionEnabled = action != nil
        box.backgroundColor = UIColor(resource: .noticeBg)
        box.layer.cornerRadius = DesignTokens.Radius.md
        if let action {
            let button = Controls.textButton(action.title, id: "toastAction")
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.addAction(UIAction { [weak box] _ in
                box?.removeFromSuperview()
                action.run()
            }, for: .primaryActionTriggered)
            row.addArrangedSubview(button)
        }
        for v in [box, row] { v.translatesAutoresizingMaskIntoConstraints = false }
        box.addSubview(row)
        view.addSubview(box)
        let pad = DesignTokens.Space.s12
        // Above the record button, which stands proud of the tab bar, or the safe area without it.
        let lift = if let bottom, !bottom.isHidden {
            view.bounds.maxY - bottom.convert(bottom.bounds, to: view).minY + RecordButton.side / 2 + pad
        } else {
            view.safeAreaInsets.bottom + pad
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: pad), row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad), row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.widthAnchor),
            box.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -lift),
        ])
        shown = box
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { [weak box] in
            try? await Task.sleep(for: .seconds(ToastDuration.seconds(text, action: action != nil)))
            box?.removeFromSuperview()
        }
    }
}