import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Bookshelf

/// The Dock and *Open With* (§9): the bundle's document types, read from Info.plist.
struct DocumentTypesTests {
    static let infoPlist = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Resources/Info.plist")

    func documentTypes() throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.infoPlist)
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
    }

    func identifiers() throws -> Set<String> {
        Set(try documentTypes().flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
    }

    /// Viewer and Alternate: Bookshelf shows in *Open With* without becoming the default app.
    @Test func opensTheFourTypesAsAnAlternateViewer() throws {
        #expect(try identifiers() == ["com.adobe.pdf", "org.idpf.epub-container", "public.html", "net.daringfireball.markdown"])
        for type in try documentTypes() {
            #expect(type["CFBundleTypeRole"] as? String == "Viewer")
            #expect(type["LSHandlerRank"] as? String == "Alternate")
        }
    }

    @Test func coversEveryExtensionIntakeTakes() throws {
        let declared = try identifiers().compactMap { UTType($0) }
        for suffix in IntakeFiles.acceptedExtensions {
            let type = try #require(UTType(filenameExtension: suffix))
            #expect(declared.contains { type.conforms(to: $0) }, "\(suffix)")
        }
    }
}

/// Drops onto the window (§13): intake takes a drag only when it carries file URLs and
/// comes from outside the app; every other drag stays WebKit's (`super`).
@MainActor
struct FileDropTests {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.lacrimae0rerum.bookshelf.tests.\(UUID().uuidString)"))
    let files = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.epub")]

    @Test func takesFilesDraggedInFromOutsideTheApp() {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        #expect(FileDrop.files(on: pasteboard, startedInApp: false)?.map(\.path) == files.map(\.path))
    }

    /// A drag that starts in the page (an image, a link to a file) is the page's, never intake's.
    @Test func leavesADragThatStartedInTheAppToWebKit() {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects(files.map { $0 as NSURL })
        #expect(FileDrop.files(on: pasteboard, startedInApp: true) == nil)
    }

    @Test func leavesDragsWithoutFileURLsToWebKit() {
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/essay")! as NSURL])
        #expect(FileDrop.files(on: pasteboard, startedInApp: false) == nil)
        pasteboard.clearContents()
        pasteboard.setString("a quote from the page", forType: .string)
        #expect(FileDrop.files(on: pasteboard, startedInApp: false) == nil)
    }
}
