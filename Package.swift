// swift-tools-version: 6.0
import PackageDescription

// Iskra — a native Matrix client for iOS, iPadOS and macOS.
//
// The whole app is assembled from these library targets so that the iOS and macOS
// app shells stay thin: they own entitlements, extensions and the app lifecycle,
// while every line of behaviour lives here and is testable with `swift test`.
//
// Matrix support comes from the upstream `matrix-org/matrix-rust-components-swift`
// package rather than the `element-hq` fork. The fork ships an iOS-only
// XCFramework; the upstream one publishes a `macos-arm64_x86_64` slice, which is
// what makes a native Mac build possible at all.
let package = Package(
    name: "Iskra",
    // Every user-facing string lives in a String Catalog, never in a view. English is
    // the source language; Russian is a full translation, not a fallback.
    defaultLocalization: "en",
    // OS 26 across the board. This buys Liquid Glass without a single availability
    // check, and it also matches reality: the Rust SDK's prebuilt macOS objects are
    // compiled against the 26.x SDK, so linking them into an older deployment target
    // is something the linker rightly complains about.
    // Spelled as strings because `.v26` does not exist in this tools version's
    // PackageDescription yet.
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(name: "IskraCore", targets: ["IskraCore"]),
        .library(name: "IskraDesign", targets: ["IskraDesign"]),
        .library(name: "IskraFeatures", targets: ["IskraFeatures"])
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift.git", exact: "26.06.06")
    ],
    targets: [
        // Matrix, sessions, secrets, media. No SwiftUI here.
        .target(
            name: "IskraCore",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift")
            ],
            resources: [.process("Resources")]
        ),
        // Colours, type, bubbles, glass. No Matrix here.
        .target(name: "IskraDesign"),
        // The screens, which are the only place the two meet.
        .target(
            name: "IskraFeatures",
            dependencies: ["IskraCore", "IskraDesign"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "IskraCoreTests", dependencies: ["IskraCore"]),
        .testTarget(name: "IskraFeaturesTests", dependencies: ["IskraFeatures", "IskraCore"])
    ]
)
