import Foundation
import Testing
@testable import Bookshelf

/// `POST /api/documents` through the web's proxy, and what its answers mean (§13).
struct IntakeAPITests {
    @Test func aFileIsPostedToTheProxyWithThePagesOriginAndNoKey() throws {
        let request = IntakeAPI.request(.libraryPath("inbox/2026-11/Meadows Systems.pdf"))
        #expect(request.url?.absoluteString == "http://127.0.0.1:4321/api/documents")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Origin") == "http://127.0.0.1:4321")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
        #expect(try body(of: request) == ["path": "inbox/2026-11/Meadows Systems.pdf"])
    }

    @Test func aWebArticleSendsItsURL() throws {
        let request = IntakeAPI.request(.webURL(URL(string: "https://example.com/essay?id=3")!))
        #expect(request.httpMethod == "POST")
        #expect(try body(of: request) == ["url": "https://example.com/essay?id=3"])
    }

    @Test func accepted202IsTheNewDocument() {
        let outcome = IntakeAPI.outcome(of: HTTPReply(status: 202, body: Data(accepted.utf8)))
        let document = ShelfDocument(id: "3f2c3b8e-1d1a-4a59-9a39-6f1f7c2a1b10", slug: "meadows-systems")
        #expect(outcome == .added(document))
        #expect(document.pagePath == "/documents/meadows-systems")
    }

    @Test func aDuplicateIs409WithTheExistingDocumentInDetails() {
        let body = #"{"error":{"code":"conflict","message":"This content is already ingested as 'meadows-systems'.","details":[{"document_id":"3f2c3b8e-1d1a-4a59-9a39-6f1f7c2a1b10","slug":"meadows-systems"}],"request_id":"r1"}}"#
        let outcome = IntakeAPI.outcome(of: HTTPReply(status: 409, body: Data(body.utf8)))
        #expect(outcome == .duplicate(ShelfDocument(id: "3f2c3b8e-1d1a-4a59-9a39-6f1f7c2a1b10", slug: "meadows-systems")))
    }

    /// The other 409 (two ingests raced for a slug) names no document: it is not a duplicate.
    @Test func a409ThatNamesNoDocumentIsAFailure() {
        let body = #"{"error":{"code":"conflict","message":"A document with this slug was just created; retry.","details":[],"request_id":"r2"}}"#
        #expect(IntakeAPI.outcome(of: HTTPReply(status: 409, body: Data(body.utf8))) == .failed("A document with this slug was just created; retry."))
    }

    @Test func anyOtherAnswerFailsWithTheAPIsMessage() {
        let invalid = #"{"error":{"code":"invalid_input","message":"No such file in the library: inbox/2026-11/x.pdf","details":[{"field":"body.path"}],"request_id":"r3"}}"#
        #expect(IntakeAPI.outcome(of: HTTPReply(status: 400, body: Data(invalid.utf8))) == .failed("No such file in the library: inbox/2026-11/x.pdf"))
        let validation = #"{"error":{"code":"validation_error","message":"Request validation failed","details":[{"field":"body.url","message":"String should match pattern","type":"string_pattern_mismatch"}],"request_id":"r4"}}"#
        #expect(IntakeAPI.outcome(of: HTTPReply(status: 422, body: Data(validation.utf8))) == .failed("Request validation failed: body.url: String should match pattern"))
        #expect(IntakeAPI.outcome(of: HTTPReply(status: 502, body: Data("<html>Bad Gateway</html>".utf8))) == .failed("The API answered 502."))
    }

    /// The proxy's own 502 when the API did not answer: a refused connection and one cut
    /// after the API committed look the same, so it is no answer, not a refusal.
    @Test func theProxysUpstreamUnavailableIsNoAnswer() {
        let body = #"{"error":{"code":"upstream_unavailable","message":"The Bookshelf API could not be reached.","details":[],"request_id":"r5"}}"#
        #expect(IntakeAPI.outcome(of: HTTPReply(status: 502, body: Data(body.utf8))) == .unanswered(keptAt: nil))
    }

    @Test func noAnswerIsUnansweredNotAFailure() {
        #expect(IntakeAPI.outcome(of: nil) == .unanswered(keptAt: nil))
    }

    @Test func aWebAddressMustBeHTTPOrHTTPS() {
        #expect(IntakeAPI.webURL(from: "  https://example.com/essay \n")?.absoluteString == "https://example.com/essay")
        #expect(IntakeAPI.webURL(from: "HTTP://Example.com/a")?.absoluteString == "http://Example.com/a")
        for text in ["", "example.com/essay", "ftp://example.com/a", "javascript:alert(1)", "file:///etc/hosts", "https://", "https://exa mple.com"] {
            #expect(IntakeAPI.webURL(from: text) == nil, "\(text)")
        }
    }

    /// Credentials in the address would reach the API's logs and the shelf's source link.
    @Test func aWebAddressWithCredentialsIsRefused() {
        for text in ["https://user:pass@example.com/a", "https://user@example.com/a", "http://:secret@example.com/"] {
            #expect(IntakeAPI.webURL(from: text) == nil, "\(text)")
        }
    }

    /// The words `app.log` gets for each file.
    @Test func outcomesReadWellInTheLog() {
        let document = ShelfDocument(id: "3f2c", slug: "meadows-systems")
        #expect("\(IntakeOutcome.added(document))" == "added as meadows-systems")
        #expect("\(IntakeOutcome.added(nil))" == "added")
        #expect("\(IntakeOutcome.duplicate(document))" == "already on the shelf as meadows-systems")
        #expect("\(IntakeOutcome.failed("No such file"))" == "not added: No such file")
        #expect("\(IntakeOutcome.unsupported)" == "not a type the API takes")
        #expect("\(IntakeOutcome.unanswered(keptAt: nil))" == "no answer")
        #expect("\(IntakeOutcome.unanswered(keptAt: "inbox/2026-11/x.pdf"))" == "no answer; the copy stays at library/inbox/2026-11/x.pdf")
    }

    private func body(of request: URLRequest) throws -> [String: String] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }
}

/// A `202` body as the API sends it (trimmed: the fields intake reads, and a few more).
let accepted = #"""
{"document":{"id":"3f2c3b8e-1d1a-4a59-9a39-6f1f7c2a1b10","kind":"pdf","genre":"book","slug":"meadows-systems","title":"Meadows Systems","status":"pending"},"job":{"id":"j1","kind":"parse"},"deduplicated":false}
"""#
