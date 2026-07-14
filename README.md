# Iskra

A native Matrix client for iPhone, iPad and Mac. One Swift codebase, SwiftUI
throughout, with all Matrix and cryptography work done by
[matrix-rust-sdk](https://github.com/matrix-org/matrix-rust-sdk).

## Layout

| Target | Holds | Knows about |
|---|---|---|
| `IskraCore` | Sessions, secrets, rooms, timeline, search, media | Matrix. No SwiftUI. |
| `IskraDesign` | Bubbles, glass, spacing, colour | SwiftUI. No Matrix. |
| `IskraFeatures` | The screens | Both — the only place they meet. |

Keeping Matrix out of the views and views out of Matrix is what allows one set of
screens to serve three platforms.

## Decisions worth knowing

**We depend on `matrix-org/matrix-rust-components-swift`, not the `element-hq`
fork.** Element's fork is what Element X iOS uses, but it ships an iOS-only
XCFramework. The upstream package publishes a `macos-arm64_x86_64` slice, and that
single fact is what makes a native Mac build possible rather than a Catalyst
compromise.

**Deployment target is iOS 26 / macOS 26.** This lets Liquid Glass be used directly,
with no availability checks scattered through the views. It also matches reality:
the SDK's prebuilt macOS objects are compiled against the 26.x SDK, and linking them
into an older deployment target makes the linker complain, correctly.

**Liquid Glass is confined to the navigation layer.** Apple's guidance is explicit
that glass belongs on toolbars, controls and floating panels — not on content, and
never on top of other glass. So the composer, the toolbar buttons and the sign-in
actions are glass; message bubbles are opaque fills. `IskraDesign/Glass.swift`
encodes this: there is no general `.glass()` modifier to reach for, only
`.navigationGlass()`.

**Round video messages are recognised by shape, not by a flag.** Matrix has no
round-video event type. Tagging one with a custom field would mean building the
event by hand — `Client.uploadMedia` plus `Room.sendRaw` — and `uploadMedia` does
*not* encrypt attachments. In an encrypted room that would upload the user's face to
the homeserver in the clear. So we send an ordinary `m.video` through
`Timeline.sendVideo`, which encrypts it properly, and make it recognisable instead:
exactly square, at most 60 seconds. The cost is cosmetic and symmetric — our circles
appear as square videos in other clients, and a square clip from another client
appears as a circle here. Nothing leaks. See `IskraCore/Media/VideoNote.swift`.

## Text and translations

No user-facing string appears in a view. Every one is named in a `Strings.swift`
(`Sources/IskraFeatures/Support/Strings.swift` for the screens,
`Sources/IskraCore/Support/Strings.swift` for what the model layer produces), and the
words themselves live in `Resources/<lang>.lproj/Localizable.strings`. **Those `.strings`
files are the ones to edit.** English and Russian are both complete; neither is a
fallback for the other.

Two things here are easy to get wrong and are worth stating:

- **We use `.lproj/.strings`, not a `.xcstrings` String Catalog.** Catalogs are the
  nicer format, but they are compiled by Xcode's `XCStringsTool` and SwiftPM's
  command-line build does not run it — it copies the `.xcstrings` into the bundle
  untouched, so every string resolves to its own key and `swift test` sees an
  unlocalized app while Xcode sees a localized one. One consistent format beats a
  prettier one that only works half the time.

- **The app bundle must declare `CFBundleLocalizations`.** Without it the system
  treats the app as English-only, `Locale.current` can never become Russian, and the
  translations sitting in the package bundle are never reached — while every
  localization unit test still passes, because tests set the locale by hand. The
  declaration is in `Apps/project.yml`.

Russian plurals (one/few/many) live in `Localizable.stringsdict`; `.strings` cannot
express them.

## Security

- Access token, refresh token, the SQLite store passphrase and the search-index key
  live **only** in the Keychain, in a shared access group so the notification
  extension can decrypt messages on device.
- Keychain items are `AfterFirstUnlockThisDeviceOnly`: readable while the phone is
  locked (notifications need that), never synced to iCloud or a backup.
- The Matrix store and the local search index are both encrypted at rest.
- Message search runs against the local index. The query never reaches the server.
- All cryptography — Olm, Megolm, attachment encryption — is the Rust SDK's. None of
  it is reimplemented here, and none of it should be.
- Nothing logs message content, tokens, passwords, or OAuth callback URLs. The
  callback URL carries an authorization code and is as sensitive as the token it
  buys.

## On Element X and AGPL

[element-x-ios](https://github.com/element-hq/element-x-ios) was read as a reference
for how a SwiftUI client sits on top of this SDK. **No code was copied from it.**
Every file here was written against the SDK's own generated bindings and its
official example. This matters because element-x-ios is AGPL-3.0, and copying from
it would carry that licence into this project. If any code is ever lifted from it
directly, it must be flagged in the commit that does so.

## Building

The libraries, which is where all the behaviour lives:

```sh
swift build            # macOS
swift test             # includes a test that the Rust SDK links and is callable
xcodebuild -scheme IskraFeatures -destination 'generic/platform=iOS' build
```

## Running the app

The `.xcodeproj` is generated and not committed, so every run starts here:

```sh
cd Apps && xcodegen && cd ..
```

**On the Mac:**

```sh
xcodebuild -project Apps/Iskra.xcodeproj -scheme 'Iskra (macOS)' \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Iskra.app
```

**On the iPhone simulator:**

```sh
# `generic/platform=iOS Simulator` rather than a device name: several simulators can
# share a name, and xcodebuild refuses an ambiguous one.
xcodebuild -project Apps/Iskra.xcodeproj -scheme 'Iskra (iOS)' \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode build

open -a Simulator     # boot a simulator, any iPhone will do
xcrun simctl install booted .build/xcode/Build/Products/Debug-iphonesimulator/Iskra.app
xcrun simctl launch booted moscow.swag.iskra
```

**Never add `CODE_SIGNING_ALLOWED=NO` to those commands.** It builds and installs
perfectly, and then the app dies with `SIGTRAP` the moment you sign in — because
without a signature the system grants the app none of its entitlements, the App Group
container cannot be resolved, and `AppEnvironment.containerURL` refuses to invent one.
The trap is doing its job; the build was the lie. The symptom appears at sign-in
rather than at launch only because that is the first moment anything opens the store.

To ask a build whether it really has the storage it claims — which the test suite
cannot answer, since `swift test` produces an unsigned binary the Keychain rejects
outright:

```sh
xcrun simctl launch --console booted moscow.swag.iskra --verify-storage
```

## Not built yet

Almost everything this section used to list has been built, and it went on listing it —
which is the failure mode a "not built yet" section has. It said creating a room was "the
shape of it and nothing more", that there were no voice messages, no notification
extension, and no device verification. All four exist. `ROADMAP.md` is the file that is
kept honest, in the commit that finishes each thing; this one had simply fallen out of the
ritual.

What is actually left:

- **A push gateway.** The homeserver does not talk to APNs — it talks to a gateway, which
  holds the app's APNs key and does. The public one at matrix.org only accepts app ids
  registered with them, so `moscow.swag.iskra` needs a [Sygnal](https://github.com/matrix-org/sygnal)
  of its own. Everything on this side of it is written: the permission is asked for, the
  device token is caught, and `Client.setPusher` is called the moment there is a URL to
  give it. See `docs/PUSH-GATEWAY.md`.

- **Answering a verification request.** Iskra can ask to be verified — seven emoji, compared
  against a device that is already trusted — and cannot yet answer somebody else who asks. So
  a new Iskra device is verified from Element, or from the web client, or with the recovery
  key; two Iskra devices cannot yet verify each other.

- **A list of your other sessions.** Not an omission: `Client.devices()` does not exist in the
  FFI, and the internal HTTP client that could reach the endpoint carries no access token.
  `Iskra --probe-devices` demonstrates it against a real homeserver, and `ROADMAP.md` stage 6
  records the answer.
