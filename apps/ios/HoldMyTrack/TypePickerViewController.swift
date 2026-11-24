import HoldMyTrackCore
import UIKit

/// The Type picker of Edit and a recording's Edit, as Android's: the types in use with how many
/// tracks use each, filtered as the user types (TypeSearch), and what was typed offered as a last
/// "Add “…”" row, saved exactly as typed. Return picks the top row.
final class TypePickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private var options: [TypeSearch.Option]
    private let current: String
    private let format: (Int) -> String
    private let onPick: (String) -> Void
    private var result: TypeSearch.Result
    private let search = UISearchBar()
    private let table = UITableView(frame: .zero, style: .plain)
    private let empty = Controls.body()

    /// format writes a count; onPick hears a type other than current.
    init(options: [TypeSearch.Option], current: String, format: @escaping (Int) -> String, onPick: @escaping (String) -> Void) {
        self.options = options
        self.current = current
        self.format = format
        self.onPick = onPick
        result = TypeSearch.search(options, query: "", maxLength: EditPlan.maxType)
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "typePicker.title", defaultValue: "Track type", comment: "The Type picker's title.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// In a sheet of its own over presenter; the picker, for options that arrive after it opens.
    @discardableResult
    static func present(over presenter: UIViewController, options: [TypeSearch.Option], current: String, format: @escaping (Int) -> String,
                        onPick: @escaping (String) -> Void) -> TypePickerViewController {
        let picker = TypePickerViewController(options: options, current: current, format: format, onPick: onPick)
        let nav = UINavigationController(rootViewController: picker)
        nav.sheetPresentationController?.detents = [.large()]
        presenter.present(nav, animated: true)
        return picker
    }

    /// options in place of the ones it opened with, for what's typed now.
    func replace(options: [TypeSearch.Option]) {
        self.options = options
        guard isViewLoaded else {
            result = TypeSearch.search(options, query: "", maxLength: EditPlan.maxType)
            return
        }
        searchBar(search, textDidChange: search.text ?? "")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        search.placeholder = String(localized: "typePicker.search", defaultValue: "Search or add a type", comment: "The Type picker's search field.")
        search.searchBarStyle = .minimal
        search.autocapitalizationType = .sentences
        search.returnKeyType = .done
        search.enablesReturnKeyAutomatically = false
        search.delegate = self
        search.searchTextField.accessibilityIdentifier = "typeSearch"
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.backgroundColor = .clear
        table.accessibilityIdentifier = "typeList"
        empty.numberOfLines = 0
        empty.textAlignment = .center
        empty.isHidden = true
        let stack = UIStackView(arrangedSubviews: [search, table])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        empty.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.addSubview(empty)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s8),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s8),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            empty.topAnchor.constraint(equalTo: search.bottomAnchor, constant: DesignTokens.Space.s16),
            empty.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: DesignTokens.Space.s16),
            empty.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -DesignTokens.Space.s16),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let row = result.shown.firstIndex(where: { $0.value == current }) {
            table.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: false)
        }
    }

    private var rowCount: Int { result.shown.count + (result.add == nil ? 0 : 1) }

    func searchBar(_ searchBar: UISearchBar, textDidChange text: String) {
        result = TypeSearch.search(options, query: text, maxLength: EditPlan.maxType)
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        empty.text = String(localized: "typePicker.noMatch", defaultValue: "No type matches “\(typed)”", comment: "The Type picker: nothing matches the search, too long to add.")
        empty.isHidden = rowCount > 0
        table.reloadData()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        if rowCount > 0 { pick(row: 0) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rowCount }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "type") ?? UITableViewCell(style: .default, reuseIdentifier: "type")
        var content = UIListContentConfiguration.valueCell()
        if indexPath.row < result.shown.count {
            let option = result.shown[indexPath.row]
            content.text = option.label
            content.secondaryText = option.count > 0 ? format(option.count) : nil
            let weight = option.value == current ? DesignTokens.Weight.bold : DesignTokens.Weight.regular
            content.textProperties.font = Typeface.sans(DesignTokens.Text.xl, weight: weight)
            cell.accessibilityTraits = option.value == current ? [.button, .selected] : .button
        } else if let add = result.add {
            content.text = String(localized: "typePicker.add", defaultValue: "Add “\(add)”", comment: "The Type picker: the last row, saving what was typed as a new type.")
            content.secondaryText = String(localized: "typePicker.new", defaultValue: "new", comment: "The Type picker: the detail of the row adding a new type.")
            content.textProperties.font = Typeface.sans(DesignTokens.Text.xl)
            cell.accessibilityTraits = .button
        }
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = UIColor(resource: .inkSecondary)
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        pick(row: indexPath.row)
    }

    private func pick(row: Int) {
        let value = row < result.shown.count ? result.shown[row].value : result.add
        dismiss(animated: true)
        if let value, value != current { onPick(value) }
    }
}