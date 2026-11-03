// swift-tools-version: 6.2
// Bookshelf.app: a native launcher for the repo's services (docs/MACOS_APP.md, ADR-001).
// One executable, two modes: the app, and `Bookshelf --guard <app-pid> -- <command…>`.
import PackageDescription

let package = Package(
    name: "Bookshelf",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "Bookshelf", path: "Sources/Bookshelf"),
        .testTarget(name: "BookshelfTests", dependencies: ["Bookshelf"], path: "Tests/BookshelfTests"),
    ]
)
