import Foundation
import Testing
@testable import Bookshelf

/// One origin in the window (M13).
struct NavigationPolicyTests {
    func decide(_ string: String, mainFrame: Bool = true, user: Bool = true) -> NavigationPolicy.Decision {
        NavigationPolicy.decide(URL(string: string), mainFrame: mainFrame, userInitiated: user)
    }

    @Test func allowsOnlyTheWebOrigin() {
        #expect(decide("http://127.0.0.1:4321/library?x=1") == .allow)
        #expect(decide("http://127.0.0.1:4321/", user: false) == .allow)
    }

    @Test func sendsOtherWebLinksAPersonFollowedToTheBrowser() {
        #expect(decide("https://example.com/paper") == .openInBrowser)
        #expect(decide("http://localhost:4321/") == .openInBrowser)  // another origin (M6)
        #expect(decide("http://127.0.0.1:8000/docs") == .openInBrowser)
        #expect(decide("http://127.0.0.1:4321@evil.example/") == .openInBrowser)
        #expect(decide("mailto:me@example.com") == .openInBrowser)
    }

    @Test func refusesWhatNobodyClicked() {
        #expect(decide("https://example.com/", user: false) == .cancel)
        #expect(decide("https://example.com/", mainFrame: false) == .cancel)
    }

    @Test func neverLoadsFilesOrOtherSchemes() {
        #expect(decide("file:///etc/passwd") == .cancel)
        #expect(decide("bookshelf://restart") == .cancel)
        #expect(decide("javascript:alert(1)") == .cancel)
        #expect(NavigationPolicy.decide(nil, mainFrame: true, userInitiated: true) == .cancel)
    }

    @Test func allowsTheInnerSchemesOfOurOwnPages() {
        #expect(decide("about:blank", user: false) == .allow)
        #expect(decide("blob:http://127.0.0.1:4321/6f1c", user: false) == .allow)
        #expect(decide("blob:https://example.com/6f1c") == .cancel)
        #expect(decide("data:text/html,hi", mainFrame: false, user: false) == .allow)
        #expect(decide("data:text/html,hi") == .cancel)
    }

    @Test func buildsAndRemembersPathsOnTheOriginOnly() {
        #expect(NavigationPolicy.url(forPath: "/review?due=1")?.absoluteString == "http://127.0.0.1:4321/review?due=1")
        #expect(NavigationPolicy.url(forPath: "//evil.example/") == nil)
        #expect(NavigationPolicy.url(forPath: "https://evil.example/") == nil)
        #expect(NavigationPolicy.pathAndQuery(URL(string: "http://127.0.0.1:4321/documents/a%20b?tab=notes")!) == "/documents/a%20b?tab=notes")
        #expect(NavigationPolicy.pathAndQuery(URL(string: "http://127.0.0.1:4321")!) == "/")
        #expect(NavigationPolicy.pathAndQuery(URL(string: "https://example.com/x")!) == nil)
    }
}
