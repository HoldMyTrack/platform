import HoldMyTrackCore
import UIKit

/// The photo viewer (apps/android/docs/SPEC.md FR-2.10), the web's PhotoViewer.tsx: a photo over
/// the whole screen, opened from its popup, to pinch, double-tap and drag, or zoom with the
/// bottom bar's buttons, up to PhotoZoom's limits. Steps through a group as the popup does, and
/// with it (onIndex). Close leaves the popup open.
///
/// The popup's copy or the thumbnail shows at once; the stored copy replaces it when it arrives,
/// at the same fit, since the picture is sized by the photo's own width and height.
final class PhotoViewerViewController: UIViewController, UIScrollViewDelegate {
    private let images: PhotoImages
    private let format: PanelFormat
    private var photos: [Photo]
    private var index: Int
    private let preview: (Photo) -> UIImage?
    private let onIndex: (Int) -> Void
    private var loading: Task<Void, Never>?

    private let scroll = UIScrollView()
    private let picture = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let failed = Controls.label(String(localized: "Couldn't load this photo."), font: Typeface.sans(DesignTokens.Text.md), color: .white)
    private let caption = Controls.label("", font: Typeface.sans(DesignTokens.Text.md, weight: DesignTokens.Weight.semibold), color: .white)
    private let taken = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: UIColor.white.withAlphaComponent(0.8))
    private let position = Controls.label("", font: Typeface.sans(DesignTokens.Text.sm, relativeTo: .footnote), color: .white)
    private lazy var previousButton = button(.chevronLeft, String(localized: "Previous photo"), "viewerPrevious") { $0.step(-1) }
    private lazy var nextButton = button(.chevronRight, String(localized: "Next photo"), "viewerNext") { $0.step(1) }
    private lazy var zoomOut = button(.zoomOut, String(localized: "Zoom out"), "viewerZoomOut") { $0.zoom(by: 1 / PhotoZoom.zoomStep) }
    private lazy var zoomIn = button(.zoomIn, String(localized: "Zoom in"), "viewerZoomIn") { $0.zoom(by: PhotoZoom.zoomStep) }
    private lazy var fit = button(.maximize, String(localized: "Fit to screen"), "viewerFit") { $0.scroll.setZoomScale(1, animated: true) }

    init(images: PhotoImages, format: PanelFormat, photos: [Photo], index: Int, preview: @escaping (Photo) -> UIImage?, onIndex: @escaping (Int) -> Void) {
        self.images = images
        self.format = format
        self.photos = photos
        self.index = index
        self.preview = preview
        self.onIndex = onIndex
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "photoViewer"

        scroll.delegate = self
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = PhotoZoom.maxScale
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.addSubview(picture)
        picture.contentMode = .scaleAspectFit
        picture.isAccessibilityElement = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        failed.textAlignment = .center
        spinner.color = .white

        let close = button(.x, String(localized: "Close"), "viewerClose") { $0.dismiss(animated: true) }
        let titles = Controls.column([caption, taken], spacing: DesignTokens.Space.s2)
        let top = UIStackView(arrangedSubviews: [titles, close])
        top.alignment = .center
        top.spacing = DesignTokens.Space.s8
        position.textAlignment = .center
        position.setContentHuggingPriority(.required, for: .horizontal)
        let bottom = UIStackView(arrangedSubviews: [previousButton, position, nextButton, UIView(), zoomOut, zoomIn, fit])
        bottom.alignment = .center
        bottom.spacing = DesignTokens.Space.s4

        let topBar = Self.bar(top), bottomBar = Self.bar(bottom)
        for v in [scroll, spinner, failed, topBar, bottomBar] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failed.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failed.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s16),
            failed.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s16),
            // The bars clear the status bar and the home indicator; the picture runs under them.
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.topAnchor.constraint(equalTo: guide.topAnchor, constant: DesignTokens.Space.s4),
            top.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s16),
            top.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s4),
            top.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -DesignTokens.Space.s4),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: DesignTokens.Space.s4),
            bottom.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s4),
            bottom.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s4),
            bottom.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -DesignTokens.Space.s4),
        ])
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPicture()
    }

    /// The popup's photos changed under it: kept on the same photo if it's still there.
    func update(_ next: [Photo], index nextIndex: Int) {
        let same = next.indices.contains(nextIndex) && next[nextIndex].id == photos[index].id
        photos = next
        index = nextIndex
        if !same, isViewLoaded { render() }
    }

    private func step(_ by: Int) {
        let to = index + by
        guard photos.indices.contains(to) else { return }
        index = to
        onIndex(to)
        render()
    }

    private func render() {
        let photo = photos[index]
        caption.text = photo.caption
        caption.isHidden = photo.caption == nil
        taken.text = photo.takenAt.map { String(localized: "Taken \(format.moment($0, zone: photo.timezone))", comment: "Photo popup: when the photo was taken.") }
        taken.isHidden = photo.takenAt == nil
        let group = photos.count > 1
        position.text = String(localized: "\(index + 1) of \(photos.count)", comment: "Which photo of a group shows: 2 of 5.")
        for v in [previousButton, position, nextButton] as [UIView] { v.isHidden = !group }
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < photos.count - 1
        picture.accessibilityLabel = photo.caption ?? String(localized: "Photo")
        failed.isHidden = true
        picture.image = preview(photo)
        scroll.setZoomScale(1, animated: false)
        layoutPicture()
        renderZoom()
        if picture.image == nil { spinner.startAnimating() }
        loading?.cancel()
        loading = Task { [weak self] in
            let full = try? await self?.images.image(photo.url, maxPixels: nil)
            guard let self, !Task.isCancelled, self.photos[self.index].id == photo.id else { return }
            self.spinner.stopAnimating()
            if let full { self.picture.image = full } else { self.failed.isHidden = self.picture.image != nil }
        }
    }

    /// The picture at its fit for the screen, as the photo's own shape decides, centred.
    private func layoutPicture() {
        let photo = photos[index]
        let stage = PhotoZoom.Size(width: scroll.bounds.width, height: scroll.bounds.height)
        guard stage.width > 0, photo.width > 0, photo.height > 0 else { return }
        let fitted = PhotoZoom.fitSize(image: PhotoZoom.Size(width: Double(photo.width), height: Double(photo.height)), stage: stage)
        let scale = scroll.zoomScale
        picture.frame = CGRect(x: 0, y: 0, width: fitted.width * scale, height: fitted.height * scale)
        scroll.contentSize = picture.frame.size
        centerPicture()
    }

    private func centerPicture() {
        let dx = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
        let dy = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    private func zoom(by factor: Double) {
        let scale = min(max(scroll.zoomScale * factor, 1), PhotoZoom.maxScale)
        let center = CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
        scroll.zoom(to: zoomRect(scale: scale, center: scroll.convert(center, to: picture)), animated: true)
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: true)
        } else {
            scroll.zoom(to: zoomRect(scale: PhotoZoom.doubleTapScale, center: tap.location(in: picture)), animated: true)
        }
    }

    /// The rect in the picture's own points that fills the screen at scale, around center.
    private func zoomRect(scale: Double, center: CGPoint) -> CGRect {
        let width = scroll.bounds.width / scale, height = scroll.bounds.height / scale
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    private func renderZoom() {
        zoomOut.isEnabled = scroll.zoomScale > 1.001
        fit.isEnabled = scroll.zoomScale > 1.001
        zoomIn.isEnabled = scroll.zoomScale < PhotoZoom.maxScale - 0.001
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPicture()
        renderZoom()
    }

    private func button(_ icon: ImageResource, _ label: String, _ id: String, _ action: @escaping (PhotoViewerViewController) -> Void) -> UIButton {
        let button = Controls.iconButton(Controls.icon(UIImage(resource: icon), size: 22), label: label, id: id)
        button.configuration?.baseForegroundColor = .white
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self)
        }, for: .primaryActionTriggered)
        return button
    }

    /// A translucent bar behind row, running to the screen's edge.
    private static func bar(_ row: UIView) -> UIView {
        let bar = UIView()
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        row.backgroundColor = .clear
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        return bar
    }
}
