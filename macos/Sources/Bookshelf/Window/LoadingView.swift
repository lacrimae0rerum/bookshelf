import AppKit

/// The native view shown while the services start (§3): the mark, then one line per step
/// with a spinner, a check or a cross. It keeps the window from flashing white.
@MainActor
final class LoadingView: PaperView {
    private struct Row {
        let spinner: NSProgressIndicator
        let mark: NSImageView
        let detail: NSTextField
    }

    private var rows: [Supervisor.Step: Row] = [:]

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "Bookshelf") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 56, weight: .regular)
        icon.contentTintColor = Paper.accent
        let title = NSTextField.label("Bookshelf", size: 22, weight: .semibold)

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        for step in Supervisor.Step.allCases {
            list.addArrangedSubview(makeRow(step))
        }

        let stack = NSStackView(views: [icon, title, list])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.setCustomSpacing(28, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
        ])
        reset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func reset() {
        for step in Supervisor.Step.allCases { update(step, .waiting) }
    }

    func update(_ step: Supervisor.Step, _ state: Supervisor.StepState) {
        guard let row = rows[step] else { return }
        let symbol: (name: String, color: NSColor)?
        switch state {
        case .waiting: symbol = ("circle", .tertiaryLabelColor)
        case .working: symbol = nil
        case .done: symbol = ("checkmark.circle.fill", .systemGreen)
        case .failed: symbol = ("xmark.octagon.fill", .systemRed)
        }
        if let symbol {
            row.spinner.stopAnimation(nil)
            row.spinner.isHidden = true
            row.mark.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)
            row.mark.contentTintColor = symbol.color
            row.mark.isHidden = false
        } else {
            row.mark.isHidden = true
            row.spinner.isHidden = false
            row.spinner.startAnimation(nil)
        }
        row.detail.stringValue = switch state {
        case .waiting: ""
        case .working(let what): "\(what)…"
        case .done: "Ready"
        case .failed: "Failed"
        }
    }

    private func makeRow(_ step: Supervisor.Step) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        let mark = NSImageView()
        mark.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        let status = NSView()
        for view in [spinner, mark] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            status.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: status.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            ])
        }
        status.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 18),
            status.heightAnchor.constraint(equalToConstant: 18),
        ])
        let name = NSTextField.label(step.rawValue, size: 13, weight: .medium)
        name.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let detail = NSTextField.label("", size: 13, color: .secondaryLabelColor)
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        rows[step] = Row(spinner: spinner, mark: mark, detail: detail)
        let row = NSStackView(views: [status, name, detail])
        row.spacing = 8
        return row
    }
}
