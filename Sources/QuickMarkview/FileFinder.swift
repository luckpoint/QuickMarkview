import AppKit

@MainActor
final class FileFinderView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onChoose: ((URL) -> Void)?
    var onCancel: (() -> Void)?
    var currentFileURL: URL?

    private let rootLabel = NSTextField(labelWithString: "")
    private let searchField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var rootURL: URL?
    private var paths: [String] = []
    private var results: [(path: String, positions: [Int], score: Int)] = []
    private var query = ""
    private var indexing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(root: URL, paths: [String]) {
        rootURL = root.standardizedFileURL
        self.paths = paths
        indexing = false
        searchField.stringValue = ""
        query = ""
        isHidden = false
        filterResults()
        window?.makeFirstResponder(searchField)
    }

    func focusSearchField() { window?.makeFirstResponder(searchField) }

    func showIndexing(root: URL) {
        rootURL = root.standardizedFileURL
        paths = []
        results = []
        indexing = true
        query = ""
        searchField.stringValue = ""
        isHidden = false
        countLabel.stringValue = "Indexing…"
        tableView.reloadData()
        rootLabel.stringValue = rootURL?.path ?? ""
        window?.makeFirstResponder(searchField)
    }

    func update(paths: [String]) {
        self.paths = paths
        indexing = false
        filterResults()
    }

    private func configure() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10

        rootLabel.font = .systemFont(ofSize: 11)
        rootLabel.textColor = .secondaryLabelColor
        rootLabel.lineBreakMode = .byTruncatingMiddle

        searchField.font = .systemFont(ofSize: 16)
        searchField.placeholderString = "Search Markdown files"
        searchField.delegate = self
        searchField.focusRingType = .default

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 25
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(chooseSelected(_:))
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let searchRow = NSStackView(views: [searchField, countLabel])
        searchRow.orientation = .horizontal
        searchRow.alignment = .centerY
        searchRow.spacing = 12
        countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true

        let stack = NSStackView(views: [rootLabel, searchRow, scrollView])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func filterResults() {
        guard let rootURL else { return }
        rootLabel.stringValue = rootURL.path
        let excludedPath = currentFileURL.map { String($0.standardizedFileURL.path.dropFirst(rootURL.path.count + 1)) }
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = paths.filter { $0 != excludedPath }.map { ($0, [], 0) }
        } else {
            results = paths.compactMap { path in
                guard let match = FuzzyMatcher.match(query: query, candidate: path) else { return nil }
                return (path, match.positions, match.score)
            }.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
                return lhs.path < rhs.path
            }
        }
        let matchingCount = results.count
        countLabel.stringValue = "\(matchingCount) / \(paths.count)"
        results = Array(results.prefix(200))
        tableView.reloadData()
        if !results.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { indexing || results.isEmpty ? 1 : results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FileFinderPathCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            view.textField = label
            view.identifier = identifier
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6), label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
            return view
        }()
        guard results.indices.contains(row) else {
            cell.textField?.stringValue = indexing ? "Indexing…" : "No Markdown files under \(rootURL?.path ?? "")"
            cell.textField?.textColor = .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 12)
            return cell
        }
        let result = results[row]
        cell.textField?.attributedStringValue = attributedPath(result.path, positions: result.positions)
        return cell
    }

    private func attributedPath(_ path: String, positions: [Int]) -> NSAttributedString {
        let value = NSMutableAttributedString(string: path, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
        let filenameStart = (path.lastIndex(of: "/").map { path.distance(from: path.startIndex, to: $0) + 1 }) ?? 0
        if filenameStart > 0 {
            let directoryLength = (Array(path).prefix(filenameStart).map(String.init).joined() as NSString).length
            value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: directoryLength))
        }
        let chars = Array(path)
        var offset = 0
        for (index, character) in chars.enumerated() {
            let length = String(character).utf16.count
            if positions.contains(index) {
                value.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .bold), range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return value
    }

    func controlTextDidChange(_ obj: Notification) {
        query = searchField.stringValue
        guard !indexing else { return }
        filterResults()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { chooseSelected(nil); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelection(by: 1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(by: -1); return true }
        return false
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(results.count - 1, max(0, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    @objc private func chooseSelected(_ sender: Any?) {
        guard results.indices.contains(tableView.selectedRow), let rootURL else { return }
        onChoose?(rootURL.appendingPathComponent(results[tableView.selectedRow].path).standardizedFileURL)
    }
}
