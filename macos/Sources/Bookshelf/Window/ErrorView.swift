import AppKit

/// What failed, in one sentence, the end of the log that says why, and the ways out (§17).
@MainActor
final class ErrorView: PaperView {
    struct Action {
        let title: String
        let isDefault: Bool
        let perform: @MainActor () -> Void

        init(_ title: String, isDefault: Bool = false, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.isDefault = isDefault
            self.perform = perform
        }
    }

    private let headline = NSTextField.label("", size: 17, weight: .semibold)
    private let logText = NSTextView()
    private let logScroll = NSScrollView()
    private let buttons = NSStackView()
    private var actions: [Action] = []

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Error") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 40, weight: .regular)
        icon.contentTintColor = .systemOrange
        headline.lineBreakMode = .byWordWrapping
        headline.maximumNumberOfLines = 0
        headline.alignment = .center
        headline.preferredMaxLayoutWidth = 640

        logText.isEditable = false
        logText.isRichText = false
        logText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logText.textColor = .secondaryLabelColor
        logText.drawsBackground = false
        logText.textContainerInset = NSSize(width: 8, height: 8)
        logScroll.documentView = logText
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .lineBorder
        logScroll.drawsBackground = false
        logText.autoresizingMask = [.width]

        buttons.orientation = .horizontal
        buttons.spacing = 12

        let stack = NSStackView(views: [icon, headline, logScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 680),
            logScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            logScroll.heightAnchor.constraint(equalToConstant: 260),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(headline text: String, log: String, actions: [Action]) {
        headline.stringValue = text
        logText.string = log.isEmpty ? "(the log is empty)" : log
        logText.scrollToEndOfDocument(nil)
        self.actions = actions
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(pressed(_:)))
            button.tag = index
            if action.isDefault { button.keyEquivalent = "\r" }
            buttons.addArrangedSubview(button)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform()
    }
}
