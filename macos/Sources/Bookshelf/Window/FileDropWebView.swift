import AppKit
import WebKit

/// Which drags intake takes (§13). Pure, so it is tested without WebKit.
enum FileDrop {
    /// The file URLs on `pasteboard` when the drag came from outside the app, else `nil`:
    /// the drag is WebKit's. A drag that starts in the page (its own, or an image or link
    /// someone pulls out of it) must never add anything to the shelf.
    static func files(on pasteboard: NSPasteboard, startedInApp: Bool) -> [URL]? {
        guard !startedInApp else { return nil }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        let files = (objects as? [URL]) ?? []
        return files.isEmpty ? nil : files
    }
}

/// The page's web view, with one change (§13): a drag from outside the app that carries
/// file URLs (from Finder, say) goes to intake, whole, and WebKit never sees it; WebKit
/// would navigate to `file://`. Every other drag goes to WebKit (`super`). The navigation
/// policy also cancels `file://`, as a second line.
@MainActor
final class FileDropWebView: WKWebView {
    /// The dropped files. While `nil`, file drags go to WebKit too.
    var onFileDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        takenFiles(sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        takenFiles(sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender, takenFiles(sender) != nil { return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        takenFiles(sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let onFileDrop, let files = takenFiles(sender) else {
            return super.performDragOperation(sender)
        }
        onFileDrop(files)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if let sender, takenFiles(sender) != nil { return }
        super.concludeDragOperation(sender)
    }

    /// `draggingSource` is `nil` exactly when the drag comes from another app.
    private func takenFiles(_ drag: any NSDraggingInfo) -> [URL]? {
        guard onFileDrop != nil else { return nil }
        return FileDrop.files(on: drag.draggingPasteboard, startedInApp: drag.draggingSource != nil)
    }
}
