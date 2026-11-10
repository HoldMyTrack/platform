import HoldMyTrackCore
import UIKit

/// The Dates filter (root docs/SPEC.md FR-5.20): From and To, each set from a calendar, which
/// applies as soon as a day is picked, as the web's does, or cleared; both clear is all time.
/// What a change does is DateFilter.setting's; this only shows it and reports it.
final class DatesViewController: UIViewController {
    private var filter: DateFilter
    private let bounds: (min: String, max: String)
    private let earliest: String?
    private let today: String
    private let onChange: (DateFilter.End, String?) -> Void
    private var open: DateFilter.End?

    private let fromRow = DateEndRow(title: String(localized: "From"), id: "datesAfter")
    private let toRow = DateEndRow(title: String(localized: "To"), id: "datesBefore")
    private let calendar = UIDatePicker()
    private let clear = Controls.textButton(String(localized: "Clear dates"), id: "datesClear")

    init(filter: DateFilter, bounds: (min: String, max: String), earliest: String?, today: String, onChange: @escaping (DateFilter.End, String?) -> Void) {
        self.filter = filter
        self.bounds = bounds
        self.earliest = earliest
        self.today = today
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Filter by dates")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(resource: .bg)
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        calendar.datePickerMode = .date
        calendar.preferredDatePickerStyle = .inline
        calendar.timeZone = TimeZone(identifier: "UTC")
        calendar.tintColor = UIColor(resource: .accent)
        calendar.minimumDate = Self.date(bounds.min)
        calendar.maximumDate = Self.date(bounds.max)
        calendar.isHidden = true
        calendar.accessibilityIdentifier = "datesCalendar"
        calendar.addAction(UIAction { [weak self] _ in self?.picked() }, for: .valueChanged)
        fromRow.onTap = { [weak self] in self?.toggle(.after) }
        toRow.onTap = { [weak self] in self?.toggle(.before) }
        fromRow.onClear = { [weak self] in self?.commit(.after, nil) }
        toRow.onClear = { [weak self] in self?.commit(.before, nil) }
        clear.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.commit(.after, nil)
            self.commit(.before, nil)
        }, for: .primaryActionTriggered)
        let column = Controls.column([fromRow, toRow, calendar, clear], spacing: DesignTokens.Space.s12)
        column.setCustomSpacing(DesignTokens.Space.s4, after: fromRow)
        Controls.host(column, in: self)
        render()
    }

    /// The filter as the map now has it.
    func update(_ next: DateFilter) {
        filter = next
        if isViewLoaded { render() }
    }

    private func toggle(_ end: DateFilter.End) {
        open = open == end ? nil : end
        if let open { calendar.date = Self.date((open == .after ? filter.after : filter.before) ?? (open == .after ? bounds.min : bounds.max)) ?? Date() }
        render()
    }

    private func picked() {
        guard let open else { return }
        commit(open, Self.day(calendar.date))
    }

    private func commit(_ end: DateFilter.End, _ value: String?) {
        onChange(end, value)
    }

    private func render() {
        let format = { (day: String) in DateFilter.short(day, today: self.today, locale: .current) }
        fromRow.show(value: filter.after.map(format), hint: earliest.map { String(localized: "First activity: \(format($0))") }, open: open == .after)
        toRow.show(value: filter.before.map(format), hint: String(localized: "Today"), open: open == .before)
        calendar.isHidden = open == nil
        clear.isEnabled = filter != .allTime
    }

    private static func date(_ day: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    private static func day(_ date: Date) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let d = c.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", d.year!, d.month!, d.day!)
    }
}

/// One end of Dates: its name, its day or a hint, and a clear button while it's set.
private final class DateEndRow: UIView {
    var onTap: (() -> Void)?
    var onClear: (() -> Void)?
    private let button: UIButton
    private let clearButton: UIButton

    init(title: String, id: String) {
        var config = UIButton.Configuration.bordered()
        config.baseBackgroundColor = UIColor(resource: .surface)
        config.baseForegroundColor = UIColor(resource: .ink)
        config.background.strokeColor = UIColor(resource: .border)
        config.cornerStyle = .medium
        config.titleAlignment = .leading
        config.title = title
        config.contentInsets = .init(top: DesignTokens.Space.s12, leading: DesignTokens.Space.s12, bottom: DesignTokens.Space.s12, trailing: DesignTokens.Space.s12)
        button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.accessibilityIdentifier = id
        clearButton = Controls.iconButton(Controls.icon(UIImage(resource: .x), size: 16), label: String(localized: "Clear \(title)"), id: id + "Clear")
        self.title = title
        super.init(frame: .zero)
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .primaryActionTriggered)
        clearButton.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .primaryActionTriggered)
        let row = UIStackView(arrangedSubviews: [button, clearButton])
        row.spacing = DesignTokens.Space.s8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private let title: String

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(value: String?, hint: String?, open: Bool) {
        button.configuration?.title = title
        button.configuration?.subtitle = value ?? hint
        button.configuration?.baseForegroundColor = UIColor(resource: .ink)
        button.configuration?.background.strokeColor = UIColor(resource: open ? .accent : .border)
        button.accessibilityValue = value ?? hint
        clearButton.isHidden = value == nil
    }
}