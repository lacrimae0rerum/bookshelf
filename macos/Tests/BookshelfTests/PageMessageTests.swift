import Foundation
import Testing
@testable import Bookshelf

/// What the page may ask of the app: only *Choose files…*, only from our origin's main frame.
struct PageMessageTests {
    private let own = URL(string: "http://127.0.0.1:4321")

    @Test func addFilesWithTheChosenGenre() {
        #expect(PageMessage.parse(["action": "addFiles", "genre": "paper"], origin: own, mainFrame: true) == .addFiles(genre: "paper"))
        #expect(PageMessage.parse(["action": "addFiles"], origin: own, mainFrame: true) == .addFiles(genre: nil))
    }

    @Test func anUnknownGenreIsDropped() {
        #expect(PageMessage.parse(["action": "addFiles", "genre": "x"], origin: own, mainFrame: true) == .addFiles(genre: nil))
    }

    @Test func refusesOtherOriginsFramesAndActions() {
        let body: [String: Any] = ["action": "addFiles"]
        #expect(PageMessage.parse(body, origin: URL(string: "https://example.com"), mainFrame: true) == nil)
        #expect(PageMessage.parse(body, origin: URL(string: "http://127.0.0.1:8000"), mainFrame: true) == nil)
        #expect(PageMessage.parse(body, origin: nil, mainFrame: true) == nil)
        #expect(PageMessage.parse(body, origin: own, mainFrame: false) == nil)
        #expect(PageMessage.parse(["action": "quit"], origin: own, mainFrame: true) == nil)
        #expect(PageMessage.parse("addFiles", origin: own, mainFrame: true) == nil)
    }
}
