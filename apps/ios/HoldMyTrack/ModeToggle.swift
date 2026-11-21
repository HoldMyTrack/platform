import HoldMyTrackCore
import UIKit

/// Normal and Fog of War at the map's top start, Android's mode bar: a panel of two buttons, each
/// an icon and its label, the active one filled. Fog's names the level in view while it's on
/// (fogTitle).
final class ModeToggle: UIView {
    var onPick: ((MapMode) -> Void)?
    private var buttons: [MapMode: UIButton] = [:]
    private(set) var mode = MapMode.normal

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.md
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)
        accessibilityIdentifier = "modes"
        let row = UIStackView()
        row.spacing = DesignTokens.Space.s2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for (mode, icon, id) in [(MapMode.normal, UIImage(resource: .route), "modeNormal"), (.fog, UIImage(resource: .cloudFog), "modeFog")] {
            var config = UIButton.Configuration.filled()
            config.image = Controls.icon(icon, size: 18)
            config.imagePadding = DesignTokens.Space.s6
            config.background.cornerRadius = DesignTokens.Radius.sm
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: DesignTokens.Space.s12, bottom: 0, trailing: DesignTokens.Space.s12)
            let button = UIButton(configuration: config)
            button.accessibilityIdentifier = id
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.onPick?(mode) }, for: .primaryActionTriggered)
            buttons[mode] = button
            row.addArrangedSubview(button)
        }
        setTitle(.normal, plain: String(localized: "Normal"))
        setTitle(.fog, plain: String(localized: "Fog"))
        let inset = DesignTokens.Space.s4
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        select(.normal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The button the level menu hangs from.
    var fogButton: UIButton { buttons[.fog]! }

    /// Fills mode's button, as one choice of two.
    func select(_ mode: MapMode) {
        self.mode = mode
        for (value, button) in buttons {
            let active = value == mode
            button.configuration?.baseBackgroundColor = active ? UIColor(resource: .ink) : .clear
            button.configuration?.baseForegroundColor = UIColor(resource: active ? .surface : .ink)
            button.accessibilityTraits = active ? [.button, .selected] : .button
        }
    }

    /// Fog's label: "Fog" while it's off, else "Fog · City" with a lock while one holds and the
    /// chevron saying it opens a menu; spoken as said.
    func setFogTitle(_ text: String, locked: Bool, menu: Bool, spoken: String) {
        guard menu else { return setTitle(.fog, plain: text) }
        let font = Self.font
        let line = NSMutableAttributedString(string: text, attributes: [.font: font])
        let symbol = UIImage.SymbolConfiguration(pointSize: font.pointSize * 0.75, weight: .semibold)
        for name in (locked ? ["lock.fill"] : []) + ["chevron.down"] {
            guard let image = UIImage(systemName: name, withConfiguration: symbol)?.withRenderingMode(.alwaysTemplate) else { continue }
            line.append(NSAttributedString(string: " "))
            line.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
        }
        fogButton.configuration?.attributedTitle = AttributedString(line)
        fogButton.accessibilityLabel = spoken
    }

    private func setTitle(_ mode: MapMode, plain: String) {
        buttons[mode]?.configuration?.attributedTitle = AttributedString(plain, attributes: AttributeContainer([.font: Self.font]))
        buttons[mode]?.accessibilityLabel = plain
    }

    /// The labels' face at the reader's text size.
    static var font: UIFont { Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold, relativeTo: .footnote) }
}
