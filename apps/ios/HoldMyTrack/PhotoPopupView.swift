import HoldMyTrackCore
import UIKit

/// A photo's popup (apps/android/docs/SPEC.md FR-2.10), the web's PhotoPopup.tsx in the spot
/// popup's frame: over the photo's marker, or under it when there's no room above, following it
/// as the camera moves (place). The picture, its caption, when it was taken, and Full size, which
/// opens the viewer; a tap on the picture opens it too. Opened on a group (photos at one spot,
/// which no zoom separates), it steps through it with ‹ › and "2 of 5", anchored at the group's
/// first photo so it doesn't jump between them. Changing a photo is the Edit window's job.
final class PhotoPopupView: UIView {
    private let images: PhotoImages
    private let format: () -> PanelFormat
    /// Which photo shows, its marker drawn larger meanwhile, or nil once closed.
    var onChange: ((String?) -> Void)?
    /// Full size, or a tap on the picture: the group and the index showing.
    var onFullSize: (([Photo], Int) -> Void)?

    private(set) var photos: [Photo] = []
    private(set) var index = 0
    private var loading: Task<Void, Never>?

    private let picture = UIImageView()
    private let previousButton = Controls.iconButton(Controls.icon(UIImage(resource: .chevronLeft), size: 18), label: String(localized: "Previous photo"), id: "photoPrevious")
    private let nextButton = Controls.iconButton(Controls.icon(UIImage(resource: .chevronRight), size: 18), label: String(localized: "Next photo"), id: "photoNext")
    private let position = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private let nav = UIStackView()
    private let caption = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: UIColor(resource: .ink))
    private let taken = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor(resource: .inkSecondary))
    private var pictureHeight: NSLayoutConstraint!

    static let width: CGFloat = 276
    /// Half a full marker and a little air, between the photo's point and the popup's edge.
    private static let offset: CGFloat = 30
    private static let maxPictureHeight: CGFloat = 260
    private static let minPictureHeight: CGFloat = 120

    /// The id showing, or nil.
    var showingID: String? { photos.indices.contains(index) ? photos[index].id : nil }

    init(images: PhotoImages, format: @escaping () -> PanelFormat) {
        self.images = images
        self.format = format
        super.init(frame: .zero)
        backgroundColor = UIColor(resource: .surface)
        layer.cornerRadius = DesignTokens.Radius.lg
        layer.borderColor = UIColor(resource: .borderPanel).cgColor
        layer.borderWidth = 1
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.15
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityIdentifier = "photoPopup"
        isHidden = true

        picture.contentMode = .scaleAspectFit
        picture.backgroundColor = UIColor(resource: .surfaceTint)
        picture.layer.cornerRadius = DesignTokens.Radius.md
        picture.clipsToBounds = true
        picture.isUserInteractionEnabled = true
        picture.isAccessibilityElement = true
        picture.accessibilityTraits = .button
        picture.accessibilityIdentifier = "photoPicture"
        picture.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openFull)))
        pictureHeight = picture.heightAnchor.constraint(equalToConstant: Self.minPictureHeight)
        pictureHeight.isActive = true

        // The close button over the picture's corner, light on a dark disc so it shows on any photo.
        var closeConfig = UIButton.Configuration.filled()
        closeConfig.image = Controls.icon(UIImage(resource: .x), size: 16)
        closeConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeConfig.baseForegroundColor = .white
        closeConfig.cornerStyle = .capsule
        let close = UIButton(configuration: closeConfig)
        close.accessibilityLabel = String(localized: "Close")
        close.accessibilityIdentifier = "photoClose"
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        let frame = UIView()
        for v in [picture, close] {
            v.translatesAutoresizingMaskIntoConstraints = false
            frame.addSubview(v)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: frame.topAnchor),
            picture.bottomAnchor.constraint(equalTo: frame.bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            close.topAnchor.constraint(equalTo: frame.topAnchor),
            close.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
        ])

        previousButton.addAction(UIAction { [weak self] _ in self?.step(-1) }, for: .primaryActionTriggered)
        nextButton.addAction(UIAction { [weak self] _ in self?.step(1) }, for: .primaryActionTriggered)
        position.textAlignment = .center
        for v in [previousButton, position, nextButton] { nav.addArrangedSubview(v) }
        nav.distribution = .equalSpacing
        nav.alignment = .center

        var fullConfig = UIButton.Configuration.plain()
        fullConfig.title = String(localized: "Full size")
        fullConfig.image = Controls.icon(UIImage(resource: .maximize2), size: 14)
        fullConfig.imagePadding = DesignTokens.Space.s4
        fullConfig.contentInsets = .init(top: DesignTokens.Space.s8, leading: DesignTokens.Space.s8, bottom: DesignTokens.Space.s8, trailing: 0)
        fullConfig.baseForegroundColor = UIColor(resource: .accent)
        fullConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
            var a = a
            a.font = Typeface.sans(DesignTokens.Text.sm, weight: DesignTokens.Weight.semibold)
            return a
        }
        let full = UIButton(configuration: fullConfig)
        full.accessibilityIdentifier = "photoFullSize"
        full.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        full.setContentCompressionResistancePriority(.required, for: .horizontal)
        full.setContentHuggingPriority(.required, for: .horizontal)
        full.addAction(UIAction { [weak self] _ in self?.openFull() }, for: .primaryActionTriggered)
        let foot = UIStackView(arrangedSubviews: [taken, full])
        foot.alignment = .center
        foot.spacing = DesignTokens.Space.s8

        let content = Controls.column([frame, nav, caption, foot], spacing: DesignTokens.Space.s6)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let m = DesignTokens.Space.s8
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: m),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -m),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Opens on group (one photo, or several at one spot, in route order) at its first.
    func show(_ group: [Photo]) {
        guard let first = group.first, first.lat != nil, first.lon != nil else { return }
        photos = group
        index = 0
        render()
        isHidden = false
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    /// The photos in view changed: it keeps showing those still there, and closes when its
    /// anchor is gone.
    func retain(_ available: [Photo]) {
        guard !photos.isEmpty else { return }
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = photos.compactMap { byID[$0.id] }
        guard let first = kept.first, first.id == photos[0].id else {
            close()
            return
        }
        let showing = showingID
        photos = kept
        index = kept.firstIndex { $0.id == showing } ?? 0
        render()
    }

    func close() {
        guard !photos.isEmpty else { return }
        loading?.cancel()
        photos = []
        picture.image = nil
        isHidden = true
        onChange?(nil)
    }

    /// The viewer stepped: the popup follows.
    func showAt(_ at: Int) {
        let to = min(max(at, 0), photos.count - 1)
        guard to != index else { return }
        index = to
        render()
    }

    private func step(_ by: Int) { showAt(index + by) }

    @objc private func openFull() {
        guard !photos.isEmpty else { return }
        onFullSize?(photos, index)
    }

    private func render() {
        guard photos.indices.contains(index) else { return }
        let photo = photos[index]
        nav.isHidden = photos.count <= 1
        position.text = String(localized: "\(index + 1) of \(photos.count)", comment: "Which photo of a group shows: 2 of 5.")
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < photos.count - 1
        caption.text = photo.caption
        caption.isHidden = photo.caption == nil
        taken.text = photo.takenAt.map { String(localized: "Taken \(format().moment($0, zone: photo.timezone))", comment: "Photo popup: when the photo was taken.") }
        taken.isHidden = photo.takenAt == nil
        picture.accessibilityLabel = photo.caption ?? String(localized: "Photo")
        // The picture at the popup's width, its height from the photo's own shape.
        let inner = Self.width - 2 * DesignTokens.Space.s8
        let height = photo.width > 0 ? inner * CGFloat(photo.height) / CGFloat(photo.width) : Self.minPictureHeight
        pictureHeight.constant = min(max(height, Self.minPictureHeight), Self.maxPictureHeight)
        // The thumbnail stands in until the copy at the popup's width is here.
        picture.image = images.cached(photo.thumbURL)
        loading?.cancel()
        let pixels = Int(inner * (window?.screen.scale ?? 3))
        loading = Task { [weak self] in
            guard let self, let image = try? await self.images.image(photo.url, maxPixels: pixels), !Task.isCancelled, self.showingID == photo.id else { return }
            self.picture.image = image
        }
        onChange?(photo.id)
    }

    /// Where it sits in its superview, set by place.
    private var left: NSLayoutConstraint?
    private var topEdge: NSLayoutConstraint?

    /// Over point, the group's first photo, or under it when there's no room above top.
    func place(at point: CGPoint, top: CGFloat) {
        guard let parent = superview, !photos.isEmpty else { return }
        if left == nil {
            translatesAutoresizingMaskIntoConstraints = false
            left = leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            topEdge = topAnchor.constraint(equalTo: parent.topAnchor)
            NSLayoutConstraint.activate([left!, topEdge!])
        }
        let height = systemLayoutSizeFitting(CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
                                             withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let gutter = DesignTokens.Space.s12
        left?.constant = min(max(point.x - Self.width / 2, gutter), max(parent.bounds.width - Self.width - gutter, gutter))
        let above = point.y - Self.offset - height
        topEdge?.constant = above >= top ? above : point.y + Self.offset
    }
}
