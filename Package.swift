// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flickdown",
    platforms: [.macOS(.v14)],
    targets: [
        // md4c: the Markdown parser + HTML renderer (C, MIT). Vendored from github.com/mity/md4c v0.6.0.
        .target(
            name: "CMd4c",
            path: "Sources/CMd4c",
            // md4c-html.c is compiled inside flick.c (see the note there).
            exclude: ["LICENSE.md", "md4c-html.c"],
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .executableTarget(
            name: "Flickdown",
            dependencies: ["CMd4c"],
            path: "Sources/Flickdown",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("WebKit")]
        ),
        // Command-line parser benchmark: `swift run -c release md-bench file.md`
        .executableTarget(
            name: "md-bench",
            dependencies: ["CMd4c"],
            path: "Sources/md-bench"
        ),
    ]
)
