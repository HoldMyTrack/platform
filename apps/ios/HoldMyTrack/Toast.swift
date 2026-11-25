import UIKit

/// A short message over a screen with no notices of its own, gone after a few seconds and taking
/// no touch, as Android's.
@MainActor
enum Toast {
    private static weak var shown: UIView?

    static func show(_ text: String, over view: UIView, above bottom: UIView) {
        shown?.removeFromSuperview()
        let label = Controls.body(text, color: UIColor(resource: .ink))
        label.textAlignment = .center
        label.accessibilityIdentifier = "toast"
        let box = UIView()
        box.isUserInteractionEnabled = false
        box.backgroundColor = UIColor(resource: .noticeBg)
        box.layer.cornerRadius = DesignTokens.Radius.md
        for v in [box, label] { v.translatesAutoresizingMaskIntoConstraints = false }
        box.addSubview(label)
        view.addSubview(box)
        let pad = DesignTokens.Space.s12
        // Above the record button, which stands proud of the tab bar.
        let lift = view.bounds.maxY - bottom.convert(bottom.bounds, to: view).minY + RecordButton.side / 2 + pad
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: pad), label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.widthAnchor.constraint(lessThanOrEqualTo: view.readableContentGuide.widthAnchor),
            box.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -lift),
        ])
        shown = box
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { [weak box] in
            try? await Task.sleep(for: .seconds(3))
            box?.removeFromSuperview()
        }
    }
}
