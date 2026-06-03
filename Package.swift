// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WinHub",
            path: "Sources/WinHub"
        )
    ],
    // The Accessibility API uses C-convention callbacks and we drive AppKit on the
    // main actor throughout; Swift 5 semantics keep that ergonomic. Strict Swift 6
    // concurrency buys us nothing here and fights the AX/AppKit C interop.
    swiftLanguageModes: [.v5]
)
