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
    // iOS 18 / macOS 15, and neither number is a preference: `Mutex` (Synchronization) is
    // what sets both, and it is the lowest floor the code reaches without rewriting its
    // locks. iOS 18 runs on everything iOS 17 does, so going lower would buy no phones.
    //
    // Liquid Glass is OS 26 and is reached only through `IskraDesign` (`Glass.swift`),
    // which draws a material in its place on older systems — a view never checks.
    //
    // The linker says ~200 times that SDK objects were "built for newer macOS version
    // (26.5)". They are the C libraries vendored into the Rust SDK (zstd, the TLS stack),
    // compiled without a deployment target of their own, and what they call is libc and
    // pthreads — nothing a macOS 15 lacks. The warning is the label, not the contents.
    //
    // Spelled as strings to match the tools version's PackageDescription.
    platforms: [
        .iOS("18.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "IskraDesign", targets: ["IskraDesign"]),
        .library(name: "IskraFeatures", targets: ["IskraFeatures"])
    ],
    dependencies: [
        // IskraCore lives in a package of its own so that it can be one dynamic framework shared
        // by the app and both extensions, instead of three copies of the Rust SDK — see
        // Core/Package.swift. The SDK and secp256k1 are its dependencies, not this package's.
        .package(path: "Core")
    ],
    targets: [
        // Colours, type, bubbles, glass. No Matrix here.
        .target(name: "IskraDesign"),
        // The screens, which are the only place the two meet.
        .target(
            name: "IskraFeatures",
            dependencies: [.product(name: "IskraCore", package: "Core"), "IskraDesign"],
            resources: [.process("Resources")]
        ),
        // Carries the NIP-44 vector file published with the NIP, so the tunnel's encryption
        // can be held to somebody else's arithmetic rather than to its own.
        .testTarget(
            name: "IskraCoreTests",
            dependencies: [.product(name: "IskraCore", package: "Core")],
            resources: [.process("Resources")]
        ),
        // Carries blobatar's own golden fixture, so the port can be held to it.
        .testTarget(
            name: "IskraDesignTests",
            dependencies: ["IskraDesign"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "IskraFeaturesTests", dependencies: ["IskraFeatures", .product(name: "IskraCore", package: "Core")])
    ]
)
