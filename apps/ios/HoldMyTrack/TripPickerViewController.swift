import HoldMyTrackCore
import UIKit

/// Add to trip (root docs/SPEC.md FR-13) as a sheet, as Android's AddToTripSheet: New trip…, then
/// the account's Trips newest first, read as it opens, with their track counts, and a search field
/// once there are many (TripPicker). A Trip that already holds every target track can't be picked.
/// Picking a Trip adds the targets in one request; the sheet closes once it lands, and a failure
/// stays in it.
final class TripPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let api: APIClient
    private let targets: [String]
    private let format: PanelFormat
    private let onNewTrip: () -> Void
    private let added: (Trip) -> Void
    private var trips: [Trip] = []
    private var shown: TripPicker.Shown?
    /// The Trip being added to, while its request runs.
    private var sending: String?
    private let search = UISearchBar()
    private let table = UITableView(frame: .zero, style: .plain)
    private let note = Controls.body()

    /// onNewTrip runs once the sheet has closed; added hears the Trip the targets went into.
    init(api: APIClient, targets: [String], format: PanelFormat, onNewTrip: @escaping () -> Void, added: @escaping (Trip) -> Void) {
        self.api = api
        self.targets = targets
        self.format = format
        self.onNewTrip = onNewTrip
        self.added = added
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Add to trip")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func present(over presenter: UIViewController, api: APIClient, targets: [String], format: PanelFormat,
                        onNewTrip: @escaping () -> Void, added: @escaping (Trip) -> Void) {
        let picker = TripPickerViewController(api: api, targets: targets, format: format, onNewTrip: onNewTrip, added: added)
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(nav, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        view.accessibilityIdentifier = "tripPicker"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        search.placeholder = String(localized: "tripPicker.search", defaultValue: "Search trips", comment: "Add to trip's search field, once there are many Trips.")
        search.searchBarStyle = .minimal
        search.returnKeyType = .done
        search.delegate = self
        search.isHidden = true
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.backgroundColor = .clear
        table.accessibilityIdentifier = "tripPickerList"
        note.numberOfLines = 0
        note.textAlignment = .center
        note.accessibilityIdentifier = "tripPickerNote"
        let stack = UIStackView(arrangedSubviews: [search, note, table])
        stack.axis = .vertical
        stack.spacing = DesignTokens.Space.s8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s8),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s8),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        show(note: String(localized: "Loading…"), failed: false)
        Task { await load() }
    }

    private func load() async {
        do {
            trips = try await api.trips().map { $0.trip }
            show(note: nil, failed: false)
            render()
        } catch {
            show(note: TripsPanel.message(error, String(localized: "Could not load your trips")), failed: true)
        }
    }

    private func render() {
        let entries = trips.map { TripPicker.Entry(id: $0.id, name: $0.name, trackIDs: $0.trackIDs) }
        let next = TripPicker.shown(entries, target: targets, query: search.text ?? "")
        search.isHidden = !next.search
        shown = next
        table.reloadData()
    }

    private func show(note text: String?, failed: Bool) {
        note.text = text
        note.textColor = UIColor(resource: failed ? .danger : .inkSecondary)
        note.isHidden = text == nil
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        render()
        let typed = text.trimmingCharacters(in: .whitespaces)
        if shown?.rows.isEmpty == true, !typed.isEmpty {
            show(note: String(localized: "tripPicker.noMatch", defaultValue: "No trip matches “\(typed)”", comment: "Add to trip: no Trip's name holds what was typed."), failed: false)
        } else if sending == nil {
            show(note: nil, failed: false)
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : shown?.rows.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "trip") ?? UITableViewCell(style: .default, reuseIdentifier: "trip")
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = UIColor(resource: .inkSecondary)
        cell.accessoryType = .none
        if indexPath.section == 0 {
            content.text = String(localized: "New trip…")
            content.image = UIImage(resource: .plus)
            content.imageProperties.tintColor = UIColor(resource: .accent)
            cell.accessibilityIdentifier = "tripPickerNew"
            cell.accessibilityTraits = .button
            cell.contentView.alpha = sending == nil ? 1 : 0.5
        } else if let row = shown?.rows[indexPath.row], let trip = trips.first(where: { $0.id == row.id }) {
            content.text = trip.name
            content.secondaryText = sending == row.id
                ? String(localized: "tripPicker.adding", defaultValue: "Adding…", comment: "Add to trip: the picked Trip while the tracks are added.")
                : row.holdsAll
                ? String(localized: "tripPicker.holdsAll", defaultValue: "Already in this trip", comment: "Add to trip: a Trip that has every target track, which can't be picked.")
                : format.trackCount(trip.trackIDs.count)
            cell.accessoryType = row.holdsAll ? .checkmark : .none
            cell.contentView.alpha = row.holdsAll ? 0.5 : 1
            cell.accessibilityIdentifier = "tripPickerRow"
            cell.accessibilityTraits = row.holdsAll ? [.button, .notEnabled] : .button
        }
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard sending == nil else { return false }
        return indexPath.section == 0 || shown?.rows[indexPath.row].holdsAll == false
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sending == nil else { return }
        if indexPath.section == 0 {
            dismiss(animated: true) { [onNewTrip] in onNewTrip() }
            return
        }
        guard let row = shown?.rows[indexPath.row], !row.holdsAll else { return }
        sending = row.id
        // Not swiped away mid-request: added runs once the sheet closes on success.
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        show(note: nil, failed: false)
        table.reloadData()
        Task {
            do {
                let changed = try await api.changeTripTracks(row.id, trackIDs: targets, add: true)
                dismiss(animated: true) { [added] in added(changed.trip) }
            } catch {
                sending = nil
                isModalInPresentation = false
                navigationController?.isModalInPresentation = false
                show(note: TripsPanel.message(error, String(localized: "Could not save the trip")), failed: true)
                table.reloadData()
            }
        }
    }
}
