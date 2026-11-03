import Foundation

/// One file or web article and what became of it.
struct IntakeResult: Equatable, Sendable {
    let name: String
    let outcome: IntakeOutcome
}

/// What to say about what was not added; the person may open `existing` (one duplicate).
struct IntakeNotice: Equatable, Sendable {
    let title: String
    let detail: String
    let existing: ShelfDocument?
}

/// What the window does after a batch: the page to show, and one notice for the rest.
struct IntakeReport: Equatable, Sendable {
    let pageToOpen: String?
    let notice: IntakeNotice?

    static let libraryPage = "/library"

    /// One new document opens its page. Several open the library, which shows them all;
    /// opening only the last one would hide the others.
    static func summarizing(_ results: [IntakeResult]) -> IntakeReport {
        let added: [ShelfDocument?] = results.compactMap {
            if case .added(let document) = $0.outcome { document } else { nil }
        }
        let problems = results.filter {
            if case .added = $0.outcome { false } else { true }
        }
        let page: String? = switch added.count {
        case 0: nil
        case 1: added[0]?.pagePath ?? libraryPage
        default: libraryPage
        }
        return IntakeReport(pageToOpen: page, notice: notice(for: problems))
    }

    private static func notice(for problems: [IntakeResult]) -> IntakeNotice? {
        guard let only = problems.first else { return nil }
        guard problems.count == 1 else {
            let lines = problems.map { "\($0.name): \(reason(for: $0.outcome))" }
            return IntakeNotice(title: "\(problems.count) files were not added.", detail: lines.joined(separator: "\n"), existing: nil)
        }
        switch only.outcome {
        case .duplicate(let existing):
            return IntakeNotice(title: "“\(only.name)” is already on the shelf.", detail: "The same content is there; nothing new was added.", existing: existing)
        case .unsupported:
            return IntakeNotice(title: "“\(only.name)” was not added.", detail: "Bookshelf takes PDF, EPUB, HTML and Markdown files (\(extensions)).", existing: nil)
        case .failed(let message):
            return IntakeNotice(title: "“\(only.name)” was not added.", detail: message, existing: nil)
        case .unanswered:
            return IntakeNotice(title: "“\(only.name)” may not have been added.", detail: reason(for: only.outcome), existing: nil)
        case .added:
            return nil
        }
    }

    private static func reason(for outcome: IntakeOutcome) -> String {
        switch outcome {
        case .duplicate: "already on the shelf."
        case .unsupported: "not a PDF, EPUB, HTML or Markdown file."
        case .failed(let message): message
        case .unanswered(let kept):
            "The Bookshelf API did not answer."
                + (kept.map { " The copy stays at library/\($0): if it is not on the shelf, add it from Add a book." } ?? "")
        case .added: "added."
        }
    }

    private static var extensions: String {
        IntakeFiles.acceptedExtensions.sorted().map { ".\($0)" }.joined(separator: ", ")
    }
}
