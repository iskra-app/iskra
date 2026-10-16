// swift-tools-version: 6.0
import PackageDescription

// IskraCore is a package of its own for one reason: it is the only way it can be a *dynamic*
// framework. It carries the Rust SDK — some 85 MB of machine code — and three binaries need it:
// the app, the notification extension and the share extension. Linked statically, each of them
// carried its own copy of the SDK and the app weighed half a gigabyte on a phone.
//
// In one package with IskraFeatures it could not be shared: a target that depends on another
// target in the same package links it statically, whatever type the latter's product is, and
// Xcode refuses outright to have the same target linked both ways into one app. Across a package
// boundary IskraFeatures depends on the *product*, and the product is dynamic — so the SDK ships
// once, in `Frameworks/IskraCore.framework`, and the two extensions load the app's copy.
let package = Package(
    name: "IskraCore",
    defaultLocalization: "en",
    platforms: [
        .iOS("18.0"),
        .macOS("15.0")
    ],
    products: [
        .library(name: "IskraCore", type: .dynamic, targets: ["IskraCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift.git", exact: "26.06.06"),
        // secp256k1, for the nostr tunnel and nothing else: NIP-44 needs an ECDH on that curve and
        // a nostr event needs a BIP-340 signature over it, and CryptoKit has neither — it stops at
        // the NIST curves. This is libsecp256k1 itself, the same C library bitcoin runs on, not a
        // reimplementation. Matrix cryptography is untouched by it and stays the Rust SDK's.
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1.git", exact: "0.9.2")
    ],
    targets: [
        // Matrix, sessions, secrets, media. No SwiftUI here.
        .target(
            name: "IskraCore",
            dependencies: [
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
                .product(name: "secp256k1", package: "swift-secp256k1")
            ],
            resources: [.process("Resources")]
        )
    ]
)
