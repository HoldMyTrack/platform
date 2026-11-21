import HoldMyTrackCore
import MapLibre
import OSLog
import Photos
import UIKit

/// The map image export (apps/ios/docs/SPEC.md FR-2.11, apps/ios/docs/IMPLEMENTATION.md §3.5): the
/// camera button opens the viewfinder over the map, whose chrome steps aside while it shows, since
/// it would sit inside the picture. Capture draws the window with ExportRenderer, adds the photo
/// markers, the stats card and the marks (ExportImage), saves it to Photos and opens the share
/// sheet. The geometry is Viewfinder's, the stats card's request ExportStats'.
extension MapViewController {
    func setUpExport() {
        export.button.addAction(UIAction { [weak self] _ in self?.openExport() }, for: .primaryActionTriggered)
    }

    var exportOpen: Bool { export.view != nil }

    func openExport() {
        guard export.view == nil, pair != nil, !tourBlocked else { return }
        closeFogPlace()
        spotViews.popup.close()
        photoViews.popup.close()
        dismissMenus()
        let finder = ExportViewfinderView(frame: view.bounds)
        finder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        export.view = finder
        renderTopRow()
        // The chrome would sit inside the picture. Faded out and left alone rather than hidden: the
        // map's renders set isHidden as they go (the top row's controls, the sheet on a panel
        // change) and would bring it back over the viewfinder.
        let covers: [UIView] = [chromeColumn, sheet, mapView.logoView, mapView.attributionButton]
        export.covered = covers
        for cover in covers {
            cover.alpha = 0
            cover.isUserInteractionEnabled = false
            cover.accessibilityElementsHidden = true
        }
        view.addSubview(finder)
        finder.closeButton.addAction(UIAction { [weak self] _ in self?.closeExport() }, for: .primaryActionTriggered)
        finder.captureButton.addAction(UIAction { [weak self] _ in self?.captureExport() }, for: .primaryActionTriggered)
        finder.statsButton.addAction(UIAction { [weak self] _ in self?.toggleExportStats() }, for: .primaryActionTriggered)
        finder.onCrop = { [weak self] start, corner, dx, dy in
            guard let self else { return }
            self.setExportWindow(Viewfinder.resize(start, corner: corner, dx: dx, dy: dy, aspect: self.export.choice.aspect, area: self.exportArea, minWindow: ExportState.minWindow))
        }
        finder.onCropEnd = { [weak self] start in
            guard let self, let box = self.export.view?.box, Viewfinder.moved(start, box) else { return }
            self.settleExport(box)
        }
        renderExportChoice(keepWindow: false)
        renderExportStatsButton()
        UIAccessibility.post(notification: .screenChanged, argument: finder.captureButton)
    }

    func closeExport() {
        guard let finder = export.view else { return }
        export.renderer.cancel()
        export.clearCard()
        // A capture still under way finishes into nothing.
        export.capture += 1
        export.busy = false
        export.failed = false
        export.hint = nil
        finder.removeFromSuperview()
        export.view = nil
        for cover in export.covered {
            cover.alpha = 1
            cover.isUserInteractionEnabled = true
            cover.accessibilityElementsHidden = false
        }
        export.covered = []
        renderTopRow()
    }

    /// A turned phone refits the window in its shape; called on every layout.
    func layoutExport() {
        guard let finder = export.view, finder.bounds.size != export.laidOut else { return }
        export.laidOut = finder.bounds.size
        setExportWindow(Viewfinder.fit(exportAspect, area: exportArea))
    }

    /// The part of the map the window may take: clear of the toolbar above and the size line
    /// below, inside the safe area and the tab bar.
    private var exportArea: ViewfinderBox {
        let insets = view.safeAreaInsets
        let margins = ViewfinderMargins(top: insets.top + ExportState.toolbarRoom, bottom: insets.bottom + ExportState.sizeRoom,
                                        side: ExportState.side, minWindow: ExportState.minWindow)
        return Viewfinder.area(width: view.bounds.width, height: view.bounds.height, margins: margins)
    }

    /// The window's shape: a preset's own, or a Custom window's as it is now.
    private var exportAspect: Double? {
        if let aspect = export.choice.aspect { return aspect }
        guard let box = export.view?.box, box.w > 0, box.h > 0 else { return nil }
        return box.w / box.h
    }

    private func setExportWindow(_ box: ViewfinderBox) {
        guard let finder = export.view else { return }
        finder.set(box)
        placeExport(box)
    }

    /// The image's size under the window, and its stats card.
    private func placeExport(_ box: ViewfinderBox) {
        guard let finder = export.view else { return }
        let size = export.choice.outputSize(windowW: box.w, windowH: box.h)
        finder.sizeLabel.text = "\(size.width) × \(size.height)"
        finder.imageSize = size
        askExportStats()
        finder.setNeedsLayout()
    }

    /// A crop's return to full size, the map easing in by the same zoom alongside.
    private func settleExport(_ crop: ViewfinderBox) {
        guard let finder = export.view else { return }
        let settled = Viewfinder.settle(crop, area: exportArea)
        let centre = Viewfinder.settledCenter(settled, mapW: view.bounds.width, mapH: view.bounds.height)
        let target = mapView.convert(CGPoint(x: centre.x, y: centre.y), toCoordinateFrom: view)
        mapView.setCenter(target, zoomLevel: mapView.zoomLevel + settled.zoomDelta, direction: mapView.direction, animated: true)
        finder.animate(to: settled.window, duration: 0.3)
        placeExport(settled.window)
    }

    // MARK: The menu of shapes and sizes

    private func exportLabel(_ choice: ExportChoice, full: Bool) -> String {
        switch choice {
        case .custom(let size):
            full
                ? String(localized: "export.customFull", defaultValue: "Custom · \(size.rawValue) (\(size.longSide) px long side)", comment: "Map image export's menu: a free shape at a size, and its long side in pixels.")
                : String(localized: "export.custom", defaultValue: "Custom · \(size.rawValue)", comment: "Map image export: a free shape at a size, such as HD.")
        case .preset(let preset):
            "\(preset.platform) · \(Self.rowName(preset.row))"
        }
    }

    private static func rowName(_ row: PresetRow) -> String {
        switch row {
        case .square: String(localized: "export.square", defaultValue: "Square", comment: "Map image export: a platform's square image.")
        case .portrait: String(localized: "export.portrait", defaultValue: "Portrait", comment: "Map image export: a platform's portrait image.")
        case .landscape: String(localized: "export.landscape", defaultValue: "Landscape", comment: "Map image export: a platform's landscape image.")
        case .story: String(localized: "export.story", defaultValue: "Story", comment: "Map image export: a platform's story image, tall.")
        }
    }

    /// Custom at each size, then each platform's presets, a section each.
    private func exportMenu() -> UIMenu {
        let action = { [weak self] (choice: ExportChoice) -> UIAction in
            UIAction(title: self?.exportLabel(choice, full: true) ?? "", state: self?.export.choice == choice ? .on : .off) { _ in self?.pickExport(choice) }
        }
        var sections = [UIMenu(options: .displayInline, children: CustomSize.allCases.map { action(.custom($0)) })]
        for platform in ["Instagram", "Facebook", "X"] {
            sections.append(UIMenu(options: .displayInline, children: ExportPreset.all.filter { $0.platform == platform }.map { action(.preset($0)) }))
        }
        return UIMenu(title: String(localized: "export.shape", defaultValue: "Image shape and size", comment: "Map image export: the menu of the image's shapes and sizes."), children: sections)
    }

    /// Another Custom size keeps the window; any other entry fits a window of its shape.
    private func pickExport(_ next: ExportChoice) {
        guard !export.busy else { return }
        var keep = false
        if case .custom = next, case .custom = export.choice { keep = true }
        export.choice = next
        if case .custom = next { ExportState.lastChoice = next }
        renderExportChoice(keepWindow: keep)
    }

    private func renderExportChoice(keepWindow: Bool) {
        guard let finder = export.view else { return }
        finder.choiceButton.configuration?.title = exportLabel(export.choice, full: false)
        finder.choiceButton.menu = exportMenu()
        export.failed = false
        renderExportLines()
        if keepWindow, finder.box.w > 0 {
            placeExport(finder.box)
        } else {
            view.layoutIfNeeded()
            export.laidOut = finder.bounds.size
            setExportWindow(Viewfinder.fit(export.choice.aspect, area: exportArea))
        }
    }

    // MARK: The stats card

    private var exportStatsOffered: Bool { ExportStats.offered(checked: session.panel.checked, tripID: session.tripID) }

    private var exportDark: Bool {
        ExportStats.dark(darkFlavor: traitCollection.userInterfaceStyle == .dark, satellite: state.satellite, satelliteFailed: state.satelliteFailed)
    }

    /// The theme or Satellite changed: the card is asked for in the map's new look.
    func exportLookChanged() {
        guard exportOpen else { return }
        askExportStats()
    }

    /// Show stats ticks only while something is Checked; tapped otherwise it says so.
    private func toggleExportStats() {
        guard !export.busy else { return }
        guard exportStatsOffered else {
            // Under the window: the map's notices are covered while the viewfinder shows.
            let hint = String(localized: "export.showStatsHint", defaultValue: "Check tracks to show their stats.", comment: "Map image export: Show stats tapped with nothing checked.")
            export.hint = hint
            renderExportLines()
            UIAccessibility.post(notification: .announcement, argument: hint)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.export.hint == hint else { return }
                self.export.hint = nil
                self.renderExportLines()
            }
            return
        }
        ExportState.showStats.toggle()
        renderExportStatsButton()
        askExportStats()
    }

    private func renderExportStatsButton() {
        guard let finder = export.view else { return }
        let on = ExportState.showStats && exportStatsOffered
        finder.statsButton.configuration?.image = on ? Controls.icon(UIImage(resource: .check), size: 16) : nil
        finder.statsButton.configuration?.imagePadding = DesignTokens.Space.s4
        finder.statsButton.alpha = exportStatsOffered && !export.busy ? 1 : 0.5
        finder.statsButton.accessibilityTraits = on ? [.button, .selected] : .button
    }

    private func askExportStats() {
        guard let finder = export.view, finder.imageSize.width > 0 else { return }
        let request = ExportStats.request(show: ExportState.showStats, checked: session.panel.checked, tripID: session.tripID,
                                          width: finder.imageSize.width, height: finder.imageSize.height, dark: exportDark)
        export.want(request, api: flow.api) { [weak self] in self?.renderExportStats() }
    }

    /// The held card in the window; Capture waits for the one this frame asked for.
    private func renderExportStats() {
        guard let finder = export.view else { return }
        finder.statsCard = export.card
        finder.captureButton.isEnabled = !export.busy && export.ready
        renderExportLines()
    }

    /// The size line, or in its place what went wrong or Show stats' hint.
    private func renderExportLines() {
        guard let finder = export.view else { return }
        let problem = export.failed
            ? String(localized: "export.failed", defaultValue: "Couldn't create the image. Please try again.", comment: "Map image export: Capture failed.")
            : (export.busy ? nil : export.hint ?? export.cardError)
        finder.errorLabel.text = problem
        finder.errorLabel.isHidden = problem == nil
        finder.sizeLabel.isHidden = problem != nil
        finder.setNeedsLayout()
    }

    // MARK: Capture

    private func setExportBusy(_ on: Bool) {
        guard let finder = export.view else { return }
        export.busy = on
        finder.locked = on
        finder.captureButton.isEnabled = !on && export.ready
        finder.captureButton.configuration?.image = on ? nil : Controls.icon(UIImage(resource: .camera), size: 20)
        if on { finder.spinner.startAnimating() } else { finder.spinner.stopAnimating() }
        finder.choiceButton.isEnabled = !on
        renderExportStatsButton()
    }

    private func captureExport() {
        guard let finder = export.view, let pair, !export.busy, export.ready else { return }
        let card = export.card
        export.capture += 1
        let capture = export.capture
        setExportBusy(true)
        export.failed = false
        renderExportLines()
        let box = finder.box
        let size = export.choice.outputSize(windowW: box.w, windowH: box.h)
        let unit = Double(size.width) / box.w
        let steps = ExportStyle.steps(style: pair.style, document: pair.layers, state: state, apiBase: flow.api.app.apiBaseURL)
        let darkFlavor = traitCollection.userInterfaceStyle == .dark
        let statsRequest = ExportStats.request(show: ExportState.showStats, checked: session.panel.checked, tripID: session.tripID,
                                               width: finder.imageSize.width, height: finder.imageSize.height, dark: exportDark)
        let centre = mapView.convert(CGPoint(x: box.centerX, y: box.centerY), toCoordinateFrom: view)
        // The markers where the screen shows them, from the window's corner; the image draws the
        // same extent at the same zoom, only at unit pixels per point.
        let shown = photoViews.markers.shown
        let points = shown.items.map { item in
            let p = mapView.convert(CLLocationCoordinate2D(latitude: item.lat, longitude: item.lon), toPointTo: view)
            return ScreenPoint(id: item.id, x: p.x - box.x, y: p.y - box.y)
        }
        let placements = PhotoMarkers.layout(points, zoom: mapView.zoomLevel, activeID: shown.activeID, loneID: shown.loneID, width: box.w, height: box.h, scale: unit)
        let styleJSON = pair.style
        // The markers' colors as the screen shows them: the image is drawn off the main thread,
        // where the app's appearance isn't the current one.
        let traits = traitCollection
        let images = photoViews.markers.images
        let byID = Dictionary(shown.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        export.renderer.render(steps: steps, center: centre, zoom: mapView.zoomLevel, heading: mapView.direction, pitch: mapView.camera.pitch,
                               window: CGSize(width: box.w, height: box.h), pixelWidth: size.width, pixelHeight: size.height) { [weak self] result in
            guard let self, self.export.capture == capture else { return }
            switch result {
            case .failure(let error):
                Self.log.error("export: \(String(describing: error), privacy: .public)")
                self.failExport()
            case .success(let drawn):
                let picture = drawn.image
                // The credit names only what the picture drew, and the marks and the card take the
                // look it drew in: a step without Satellite is in the map's own flavor.
                let credit = ImageMarks.creditText(
                    basemap: drawn.step.leftOut.contains(ExportStyle.basemapSource) ? nil : ImageMarks.attribution(styleJSON, source: ExportStyle.basemapSource),
                    satellite: drawn.step.satellite ? ImageMarks.attribution(styleJSON, source: MapStyle.satelliteID) : nil)
                let dark = ExportStats.dark(darkFlavor: darkFlavor, satellite: drawn.step.satellite, satelliteFailed: false)
                Task { @MainActor in
                    var card = card
                    if card != nil, let request = statsRequest, request.dark != dark {
                        let redrawn = ExportStats.Request(trackIDs: request.trackIDs, width: request.width, height: request.height, dark: dark)
                        if let data = (try? await self.flow.api.statsCard(redrawn)) ?? nil, let image = UIImage(data: data) { card = image }
                    }
                    var markers: [ExportImage.Marker] = []
                    for placement in placements {
                        let path = byID[placement.ids[0]]?.thumbPath
                        markers.append(ExportImage.Marker(placement: placement, thumbnail: await Self.thumbnail(path, images: images)))
                    }
                    guard self.export.capture == capture else { return }
                    let png = await Task.detached {
                        ExportImage.compose(picture: picture, width: size.width, height: size.height, markers: markers, card: card, credit: credit,
                                            dark: dark, unit: unit, traits: traits).pngData()
                    }.value
                    guard self.export.capture == capture, self.export.busy else { return }
                    guard let png else {
                        self.failExport()
                        return
                    }
                    await self.finishExport(png)
                }
            }
        }
    }

    private static let log = Logger(subsystem: "dev.holdmytrack.ios", category: "export")

    /// A marker's thumbnail, cached or fetched; nil draws its frame empty.
    private static func thumbnail(_ path: String?, images: PhotoImages) async -> UIImage? {
        guard let path else { return nil }
        if let cached = images.cached(path) { return cached }
        return await withCheckedContinuation { done in images.thumb(path) { done.resume(returning: $0) } }
    }

    /// Saved to Photos when allowed, then the share sheet, the viewfinder closed; Photos refused
    /// still shares, whose sheet can save it too.
    private func finishExport(_ png: Data) async {
        let name = "holdmytrack-\(Self.fileTime.string(from: Date())).png"
        let file = FileManager.default.temporaryDirectory.appending(path: name)
        do {
            try png.write(to: file)
        } catch {
            failExport()
            return
        }
        let capture = export.capture
        let saved = await ExportPhotos.save(png)
        guard export.capture == capture else { return }
        closeExport()
        if saved {
            notice(.exported, String(localized: "export.saved", defaultValue: "Saved to Photos", comment: "Map image export: the image is in the Photos library."))
            hideNoticeSoon(.exported)
        }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = export.button
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file) }
        present(share, animated: true)
    }

    private static let fileTime: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd-HHmmss"
        return format
    }()

    private func failExport() {
        guard export.view != nil else { return }
        setExportBusy(false)
        export.failed = true
        renderExportLines()
    }

    private func hideNoticeSoon(_ kind: Notice) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.hideNotice(kind)
        }
    }
}

/// The image added to Photos with add-only access. Not on the main actor: Photos runs the change
/// block on a queue of its own, where a block isolated to the main actor traps.
enum ExportPhotos {
    nonisolated static func save(_ png: Data) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            }
            return true
        } catch {
            return false
        }
    }
}

/// The export's state while the map lives: the viewfinder while it shows, the choice, the stats
/// card the window previews, and the chrome hidden for it.
@MainActor
final class ExportState {
    let button = UIButton(type: .system)
    var view: ExportViewfinderView?
    var choice = ExportState.lastChoice
    var busy = false
    /// The last capture failed, and the line under the window says so.
    var failed = false
    let renderer = ExportRenderer()
    /// The chrome faded out while the viewfinder shows.
    var covered: [UIView] = []
    /// Show stats' hint, in the size line's place for a moment.
    var hint: String?
    /// Counts captures, and closings, so a capture finishes only if it's still the latest.
    var capture = 0
    /// The size the window was last fitted to, so a turn refits it.
    var laidOut = CGSize.zero

    static let toolbarRoom: Double = 72
    static let sizeRoom: Double = 40
    static let side: Double = 16
    static let minWindow: Double = 64
    /// The Custom size last picked, kept while the app runs, the web's per-visit memory.
    static var lastChoice = ExportChoice.initial

    /// Show stats, kept on the phone; off until ticked.
    static var showStats: Bool {
        get { UserDefaults.standard.bool(forKey: "export.showStats") }
        set { UserDefaults.standard.set(newValue, forKey: "export.showStats") }
    }

    // The stats card the server draws for the current request: asked for again after a pause in
    // changing it, and held until the next one arrives, so Capture draws the card the window
    // previews and never asks a second time. The web's useStatsCard.
    private var hold = ExportStats.Hold()
    private var asking: Task<Void, Never>?
    private(set) var card: UIImage?
    private(set) var cardError: String?

    /// Whether card answers the current request, so Capture would draw what's previewed.
    var ready: Bool { hold.ready }

    func want(_ request: ExportStats.Request?, api: APIClient, changed: @escaping () -> Void) {
        guard hold.want(request) || request == nil else { return }
        asking?.cancel()
        guard let request else {
            card = nil
            cardError = nil
            changed()
            return
        }
        changed()
        asking = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let result: Result<Data?, Error>
            do { result = .success(try await api.statsCard(request)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.hold.answer(request) else { return }
            switch result {
            case .success(let data):
                self.card = data.flatMap { UIImage(data: $0, scale: 1) }
                self.cardError = nil
            case .failure(let error):
                self.card = nil
                self.cardError = (error as? APIError)?.serverMessage ?? String(localized: "export.failed", defaultValue: "Couldn't create the image. Please try again.", comment: "Map image export: Capture failed.")
            }
            changed()
        }
    }

    func clearCard() {
        asking?.cancel()
        asking = nil
        hold = ExportStats.Hold()
        card = nil
        cardError = nil
    }
}