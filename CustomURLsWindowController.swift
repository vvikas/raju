import Cocoa

// ── Custom URLs settings window ────────────────────────────────────────────────
// Manages a list of text-trigger → URL pairs.
// Accessible via menu bar → Custom URLs…

final class CustomURLsWindowController: NSObject, NSWindowDelegate,
                                         NSTableViewDataSource, NSTableViewDelegate {

    static let shared = CustomURLsWindowController()
    private override init() {}

    private var window: NSWindow?
    private var tableView: NSTableView!

    // MARK: – Public

    func showWindow(_ sender: Any?) {
        if window == nil { buildWindow() }
        tableView.reloadData()
        window!.makeKeyAndOrderFront(nil)
    }

    // MARK: – Window construction

    private func buildWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Custom URLs"
        w.center()
        w.delegate = self
        w.isReleasedWhenClosed = false

        let container = NSView(frame: w.contentRect(forFrameRect: w.frame))
        container.translatesAutoresizingMaskIntoConstraints = false
        w.contentView = container

        // ── Table ────────────────────────────────────────────────────────────
        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 22
        tableView.dataSource = self
        tableView.delegate   = self

        let triggerCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("trigger"))
        triggerCol.title = "Trigger Phrase"
        triggerCol.width = 160
        tableView.addTableColumn(triggerCol)

        let urlCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlCol.title = "URL"
        urlCol.width = 260
        tableView.addTableColumn(urlCol)

        let labelCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        labelCol.title = "Spoken Label"
        labelCol.width = 120
        tableView.addTableColumn(labelCol)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        // ── Buttons ──────────────────────────────────────────────────────────
        let addBtn    = makeButton("+",      action: #selector(addEntry))
        let editBtn   = makeButton("Edit",   action: #selector(editEntry))
        let deleteBtn = makeButton("Delete", action: #selector(deleteEntry))
        let btnStack  = NSStackView(views: [addBtn, editBtn, deleteBtn])
        btnStack.spacing = 8
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(btnStack)

        // ── Layout ───────────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: btnStack.topAnchor, constant: -10),

            btnStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            btnStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        window = w
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.bezelStyle = .rounded
        return btn
    }

    // MARK: – Actions

    @objc private func addEntry() {
        showEditSheet(existing: nil, at: nil)
    }

    @objc private func editEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < CustomURLStore.shared.entries.count else { return }
        showEditSheet(existing: CustomURLStore.shared.entries[row], at: row)
    }

    @objc private func deleteEntry() {
        let row = tableView.selectedRow
        guard row >= 0, row < CustomURLStore.shared.entries.count else { return }
        CustomURLStore.shared.entries.remove(at: row)
        CustomURLStore.shared.save()
        tableView.reloadData()
    }

    private func showEditSheet(existing: CustomURLEntry?, at index: Int?) {
        let alert = NSAlert()
        alert.messageText    = existing == nil ? "Add Custom URL" : "Edit Custom URL"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment   = .leading
        stack.spacing     = 6
        stack.frame       = NSRect(x: 0, y: 0, width: 380, height: 90)

        let triggerField = labeled("Trigger phrase (what you say)", in: stack)
        let urlField     = labeled("URL (https://…)",               in: stack)
        let labelField   = labeled("Spoken label (optional)",       in: stack)

        triggerField.stringValue = existing?.trigger ?? ""
        urlField.stringValue     = existing?.url     ?? ""
        labelField.stringValue   = existing?.label   ?? ""

        alert.accessoryView = stack

        guard let w = window else { return }
        alert.beginSheetModal(for: w) { response in
            guard response == .alertFirstButtonReturn else { return }
            let trigger = triggerField.stringValue.trimmingCharacters(in: .whitespaces)
            let url     = urlField.stringValue.trimmingCharacters(in: .whitespaces)
            let label   = labelField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !trigger.isEmpty, !url.isEmpty else { return }
            let entry = CustomURLEntry(
                trigger: trigger,
                url: url,
                label: label.isEmpty ? trigger : label
            )
            if let idx = index {
                CustomURLStore.shared.entries[idx] = entry
            } else {
                CustomURLStore.shared.entries.append(entry)
            }
            CustomURLStore.shared.save()
            self.tableView.reloadData()
        }
    }

    // Creates a label + text field row inside a stack view
    private func labeled(_ placeholder: String, in stack: NSStackView) -> NSTextField {
        let row   = NSStackView()
        row.orientation = .horizontal
        row.spacing     = 6

        let lbl = NSTextField(labelWithString: placeholder + ":")
        lbl.font = .systemFont(ofSize: 11)
        lbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true

        row.addArrangedSubview(lbl)
        row.addArrangedSubview(field)
        stack.addArrangedSubview(row)
        return field
    }

    // MARK: – NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        CustomURLStore.shared.entries.count
    }

    func tableView(_ tableView: NSTableView,
                   objectValueFor tableColumn: NSTableColumn?,
                   row: Int) -> Any? {
        let entry = CustomURLStore.shared.entries[row]
        switch tableColumn?.identifier.rawValue {
        case "trigger": return entry.trigger
        case "url":     return entry.url
        case "label":   return entry.label
        default:        return nil
        }
    }

    // MARK: – NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // window hidden, not destroyed (isReleasedWhenClosed = false)
    }
}
