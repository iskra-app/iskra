# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Iskra is a native Matrix client for iPhone, iPad and Mac: one Swift/SwiftUI codebase, with all
Matrix protocol and cryptography work done by `matrix-rust-sdk` over FFI.

`README.md` carries the *rationale* behind the decisions below and is worth reading before
changing any of them. This file is the operational summary.

`ROADMAP.md` is the plan of work to MVP: what is done, what is half-done, what is next, and which
SDK call each remaining piece hangs off. It is kept current — a finished item is ticked there in
the same commit that finishes it.

## Commands

```sh
swift build                      # macOS
swift test                       # all tests
swift test --filter LocalizationTests        # one suite
swift test --filter russianPluralsDecline    # one test (Swift Testing; --filter is a name regex)

xcodebuild -scheme IskraFeatures -destination 'generic/platform=iOS' build

cd Apps && xcodegen              # regenerate Iskra.xcodeproj after editing project.yml
```

Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest.

### Running the app

The `.xcodeproj` is generated and gitignored, so a run always starts with `cd Apps && xcodegen`.

```sh
# Mac
xcodebuild -project Apps/Iskra.xcodeproj -scheme 'Iskra (macOS)' \
  -destination 'platform=macOS' -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Iskra.app

# iPhone simulator — `generic/platform=iOS Simulator`, because two simulators can share
# a name and xcodebuild refuses an ambiguous destination
xcodebuild -project Apps/Iskra.xcodeproj -scheme 'Iskra (iOS)' \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build
# Xcode 27 has no Simulator.app — DeviceHub.app took its place, and it shows devices
# without booting one, so the boot is now an explicit step
xcrun simctl bootstatus 'iPhone 18 Pro' -b
open -b com.apple.dt.Devices
xcrun simctl install booted .build/xcode/Build/Products/Debug-iphonesimulator/Iskra.app
xcrun simctl launch booted moscow.swag.iskra
```

`./run.sh` wraps the two above (`mac`, `ios`, or both). **A real iPhone is `./device.sh`**, which
builds the tip of `dev` — from its own detached worktree in `.build/dev-src`, so whatever is
uncommitted in the working tree neither affects the build nor gets touched by it — signs it,
installs it with `devicectl` and launches it with `--console`. `--here` builds the working tree
instead, `--fetch` pulls `origin/dev` first, and everything after `--` is passed to the app, which
is how the probes are run on a device.

**Never pass `CODE_SIGNING_ALLOWED=NO`.** The build succeeds, the app installs, and then it dies
with `SIGTRAP` the moment the user signs in: an unsigned app is granted none of its entitlements,
so the App Group container cannot be resolved and `AppEnvironment.containerURL` — correctly —
refuses to invent one. The crash lands in `AuthenticationService.startSignIn`, a long way from the
build flag that caused it, so it is worth recognising on sight.

`Iskra --verify-storage` runs `StorageCheck` inside the signed, installed app: it resolves the App
Group container and does a real Keychain round-trip in the shared access group. This is the only
way to check provisioning — `swift test` builds an *unsigned* binary, which the data-protection
Keychain refuses outright (`errSecMissingEntitlement`, -34018) no matter what the entitlements say.

```sh
xcrun simctl launch --console booted moscow.swag.iskra --verify-storage
```

`Iskra --probe-signin <address>` drives the same lookup the "Continue" button does, with the SDK's
logs on, and prints where it stopped. It exists because the sign-in failures that matter only happen
in a signed build on a real device, where the only symptom is a spinner. On a device, run it with
`devicectl`:

```sh
xcrun devicectl device process launch --console --device <id> moscow.swag.iskra --probe-signin matrix.org
```

`Iskra --probe-notification` decrypts a push the way the notification extension will, and prints
what would land on the lock screen. Given no arguments it goes and *finds* a recent message to
try — a push carries only a room ID and an event ID, and nobody has an event ID to hand, so a
probe that demanded one would be a probe nobody ran.

```sh
xcrun simctl launch --console booted moscow.swag.iskra --probe-notification
xcrun simctl launch --console booted moscow.swag.iskra --probe-notification '!room:matrix.org' '$event'
```

Be exact about what it proves. It proves `PushDecoder` end to end: the session restores, the
notification client comes up in `.multipleProcesses`, the event is found and decrypted, and the
words that come out are the words that would be shown. It does **not** prove the extension's own
entitlements — it runs in the *app's* process, and the `.appex` is a different bundle ID granted
the App Group and the Keychain separately — and nothing but a real push proves that iOS wakes the
extension at all.

## Architecture

Three SwiftPM library targets, and the dependency rule between them is the whole design:

| Target | Holds | May import |
|---|---|---|
| `IskraCore` | Sessions, secrets, rooms, timeline, search, media | `MatrixRustSDK`. **Never SwiftUI.** |
| `IskraDesign` | Bubbles, glass, spacing, colour | SwiftUI. **Never Matrix.** |
| `IskraFeatures` | The screens | Both — the only place they meet. |

Keeping Matrix out of the views and views out of Matrix is what lets one set of screens serve three
platforms. `IskraCore` never leaks an SDK type upward: `UserSession` owns the `Client`, and nothing
above it touches the SDK directly.

The app shells in `Apps/` are deliberately thin — they own the bundle, entitlements and (soon) the
notification extension, nothing else. **Logic accumulating in `Apps/Shared/` belongs in
`IskraFeatures` instead.**

### The SDK streams diffs, not snapshots

`RoomListStore` and `TimelineStore` are both `@MainActor @Observable` classes fed by an SDK listener
that delivers *diffs* (`.insert(3, room)`, `.pushFront`, `.truncate`…). Each applies diffs to an
ordered array of SDK handles, then projects that into value-type summaries SwiftUI can diff cheaply.
Two consequences worth knowing:

- Diffs arrive on a Rust callback thread. `UnsafeTransfer` (`RoomListStore.swift`) is the box that
  carries the non-`Sendable` generated enums across the hop to `@MainActor`. The SDK's *handle*
  types are already `@unchecked Sendable`; only the enums wrapping them are not.
- `RoomListStore` coalesces bursts of diffs with a 50 ms debounce before rebuilding summaries,
  because initial sync would otherwise stampede `roomInfo()`.

### A live timeline starts empty, and history is *fetched*, not streamed

`Timeline.addListener` does **not** hand over the conversation. It subscribes to new events,
and the first diff a freshly opened room emits is `reset` with **zero items**. Everything already
in the room arrives only via `paginateBackwards` — so `TimelineStore.open()` has to ask for the
first page, and it does, in a loop until there is enough on screen to scroll.

This has already been broken once, and it broke in a way nothing caught. `RoomView` used to show a
`ProgressView` at the top of the list whenever `canLoadMore` was true, with a `.task` on it that
called `loadMore()` when it appeared — so rooms filled as a *side effect of drawing a spinner*. The
spinner looked like a pure bug (it span forever, because `canLoadMore` stays true until you have
paginated back to the room's creation) and deleting it emptied every chat in the app. The lesson is
not "keep the spinner": it is that the initial fetch must be an explicit call you can see, and never
a side effect of a view that might reasonably be deleted.

Scroll position asks for *further* pages. It cannot ask for the first one — an empty timeline has
nothing to scroll.

### Storage is explicitly `.shared` or `.standalone`

`AppEnvironment.StorageMode` (`IskraCore/Support/AppEnvironment.swift`) decides where the encrypted
store and the secrets live. `.shared` uses the App Group + shared Keychain access group that the
notification extension needs; `.standalone` keeps everything inside the app and needs no
provisioning. A missing App Group is **refused, never worked around** — a silent fallback to the
app's own container would produce an app that works perfectly until the first push arrives.

It is refused as a *thrown error*, not a trap. It used to be `preconditionFailure`, and the claim
that this "crashes on launch" was simply not true: the container is first resolved inside
`startSignIn`, on an actor, in response to a tap — so a device whose App ID has no App Group enabled
would run, show the sign-in screen, and then die on "Continue", nowhere near the provisioning
mistake that caused it. Now it becomes `AuthenticationError.storageUnavailable` and the screen says
so. The refusal is the same; it is just legible. `Iskra --verify-storage` still answers it directly.

**Every SDK call the user waits on is bounded** (`withTimeout`, `IskraCore/Support/Timeout.swift`).
`startSignIn` reaches the network, and a server that accepts a connection and then says nothing left
"Continue" spinning forever with nothing on screen to explain it. Note that `withTimeout` does not
await the operation it gave up on, and a task group would: a group waits for its children, so a call
stuck in Rust and deaf to cancellation would still hold the caller past the deadline — which is the
hang, not a hypothetical. `TimeoutTests` pins exactly that.

**The SDK logs nothing until asked.** `SDKLogging.start()` (called from `IskraApp.init`) is what makes
a stall on a real device visible at all — there is no debugger attached to a signed build on a phone.
The level stops at `.info` on purpose: `.debug` and `.trace` make the SDK log request and response
bodies, and in this app those bodies are people's messages.

The App Group (`group.moscow.swag.iskra`) and the Keychain access group
(`$(AppIdentifierPrefix)moscow.swag.iskra.shared`) are two different identifiers and have to be: a
Team Provisioning Profile allows `keychain-access-groups = ["<TeamID>.*"]`, which an App Group ID
does not match.

### The notification extension is a second process, and it is granted nothing for free

`IskraNotificationService` (`Apps/NotificationService/`) is where a push becomes a sentence: a
Matrix push carries a room ID and an event ID and nothing else, so in an encrypted room the
homeserver could not write the notification even if it wanted to — it cannot read the message
either. `PushDecoder` opens the app's encrypted store from that second process and decrypts the
event; `PushMapper` turns it into words, sharing `MessagePreview` with the chat list so that a
photo is not "Photo" in one place and "Image" in the other.

Two things about it are easy to get subtly wrong, and both fail far from their cause:

- **`AppIdentifierPrefix` must be in the extension's own Info.plist.**
  `AppEnvironment.keychainAccessGroup` reads that key out of `Bundle.main` — and inside an
  extension `Bundle.main` is the *extension's* bundle, not the app's. Leave it out and the prefix
  is empty, the Keychain group silently becomes `moscow.swag.iskra.shared` with no team ID in
  front of it, the lookup returns nothing, and the extension reports *"nobody is signed in"* on a
  device where somebody plainly is.
- **`processSetup: .multipleProcesses`, never `.singleProcess`.** The app may be open and holding
  the same SQLite file at the moment a push arrives. `.multipleProcesses` is what makes the two
  take a cross-process lock instead of writing over each other.

The extension links `IskraCore` and **not** `IskraFeatures`. It has 24 MB and no screens; dragging
SwiftUI and every view in the app into a process that exists to write two lines of text is how an
extension gets killed before it decrypts anything.

It does link `IskraDesign`, which is not the same concession: that target has no dependencies at
all, and it is linked for one symbol — `BlobatarImage`, which draws the face of a sender who has no
picture. The circle on a notification is filled from the intent and from nowhere else, so the
creature `Avatar` draws in the app's process never reaches it; it is drawn again in this one, from
the same seed, with Core Graphics, never touching SwiftUI at runtime. `PushFace` (`Apps/Shared/`,
compiled into *both* bundles) is the one place that decides whether it is drawn, so that
`--probe-notification` cannot disagree with the extension about the very thing it diagnoses.

Which is also why **the two generated-face flags live in the App Group's defaults**, not in
`.standard` — `BetaFeatures.faceStore`. An extension's own `UserDefaults.standard` is its own and
empty: a switch only the app can see is a switch the lock screen silently disobeys, and the symptom
is an empty circle with nothing in any log. `BetaFeatures` itself moved to `IskraCore` for the same
reason. Everything else in it stays in `.standard`, where a preference of the app's belongs.

## Invariants that are easy to break by accident

**Localization.** No user-facing string appears in a view. Every one is named in a `Strings.swift`
(`IskraFeatures/Support/` for screens, `IskraCore/Support/` for what the model layer produces); the
words live in `Resources/<lang>.lproj/Localizable.strings`, **which is the file to edit**. English
and Russian are both complete; neither is a fallback.

**Write the Russian first, then the English.** Not the other way round, however natural that feels.
A sentence composed in English and then translated arrives in Russian with its tone stripped out:
the result is grammatical, and it reads like a machine talking — stiff, official, nothing like the
plain friendly voice the rest of the app has. Написанное сразу по-русски so it sounds like a person,
then carried into English, keeps that voice in both. English is the *source* language in
`Package.swift` (`defaultLocalization`), which is a fact about resource loading and not an
instruction about which one to think in.

Three ways this fails silently, all guarded by `LocalizationTests`:
- Use `.lproj/.strings`, **not** a `.xcstrings` String Catalog — SwiftPM's command-line build does
  not run `XCStringsTool`, so a catalog makes every string resolve to its own key under `swift test`
  while Xcode looks fine.
- `bundle:` on every `LocalizedStringResource` is load-bearing. Without it the lookup goes to
  `Bundle.main`, misses, and returns the key — the screen reads "signIn.title" and it still compiles.
- The app bundle must declare `CFBundleLocalizations` (in `Apps/project.yml`), or the system treats
  the app as English-only and no translation is ever reached — while every test still passes, because
  tests set the locale by hand.

Russian plurals (one/few/many) need `Localizable.stringsdict`; `.strings` cannot express them.

**Liquid Glass is confined to the navigation layer.** Toolbars, composer, floating controls. Never on
content, never on glass. There is deliberately no general `.glass()` modifier — only
`.navigationGlass()` and `.primaryActionGlass(tint:)` in `IskraDesign/Glass.swift`. Message bubbles
are opaque fills. If `.navigationGlass()` feels like the wrong name where you are about to put it,
that is the guideline talking.

**The main button on a screen is `.primaryAction` or `.glassAction`** (`IskraDesign/PrimaryAction.swift`),
**never `.borderedProminent` or `.glassProminent`.** The system's prominent styles fill themselves with
the *tint*, and the tint at the root of this app is `.primary` — so a prominent button that does not
tint itself is a solid white slab in the dark, with a white label the system draws on top of it: a
button with nothing written on it. Tinting each site by hand is not the fix either, because on the
mono accent the tint *is* `.primary` and the slab comes straight back. The two styles here draw the
fill and the words from `AccentTheme.color` and `AccentTheme.foreground(in:)`, which is the pair
"the accent, and what stays readable on top of it". Use `.glassAction` on the navigation layer
(sign-in, recovery) and `.primaryAction` in content.

**`@Environment(\.dismiss)` is not allowed in a screen pushed onto the sidebar column.** On
macOS 26 a view that sits in the sidebar's stack, reads `dismiss`, *and* pushes a screen of its
own re-enters layout forever: the main thread spins at 100% inside `NSHostingView.layout()` and
the window stops answering. It hung every settings row at once, because every settings row is a
push from `SettingsView` — and it looked like a bug in the rows, which is why it cost an
afternoon and one wrong fix (the sidebar's fixed width, which changes nothing: the hang survives
both an absolute width and no width at all). The way out is handed down instead — `onClose`, set
by whoever owns the flag that opened the screen. A sheet's `dismiss` is fine; a sheet has its own
stack. Narrowed by bisection under `sample`: a single `@Environment(\.dismiss)` added to an
otherwise empty pushed `Form` is enough to reproduce it.

**Sizes come from `Theme`.** Every spacing, radius and size is a named constant in
`IskraDesign/Theme.swift`, all multiples of 4, corners `.continuous`. A view that hard-codes
`.padding(12)` is a bug waiting to drift.

**Deployment target is iOS 26 / macOS 26.** This is what allows Liquid Glass with no availability
checks, and it matches the SDK's prebuilt macOS objects, which are compiled against the 26.x SDK.

**Round video messages are recognised by shape, not by a flag** (`IskraCore/Media/VideoNote.swift`).
Exactly square, ≤60 s. Tagging them with a custom field would mean `Client.uploadMedia` +
`Room.sendRaw` — and `uploadMedia` does **not** encrypt attachments, so in an encrypted room that
uploads the user's face to the homeserver in the clear. Send ordinary `m.video` via
`Timeline.sendVideo`, which encrypts properly.

## Security rules

- Access token, refresh token, store passphrase and search-index key live **only** in the Keychain,
  `AfterFirstUnlockThisDeviceOnly` (readable while locked, for notifications; never synced or backed
  up), in a shared access group. `kSecUseDataProtectionKeychain` is required or access groups quietly
  do nothing on macOS.
- The Matrix store and the local search index are both encrypted at rest. Search runs against the
  local index; the query never reaches the server.
- All cryptography is the Rust SDK's. **None of it is reimplemented here, and none of it should be.**
- Nothing logs message content, tokens, passwords, or OAuth callback URLs — a callback URL carries
  the authorization code and is as sensitive as the token it buys.

## Do not edit (generated)

`Apps/Iskra.xcodeproj/`, `Apps/*/Info.plist`, `Apps/*/Iskra.entitlements` are all generated by
XcodeGen and gitignored. **Edit `Apps/project.yml` and rerun `xcodegen`.**

## The app icon

`icons/iskra.icon` is an Icon Composer document, and one icon serves both platforms — it carries
its own light, dark and tinted appearances, so there is no set of PNGs to keep in step *in the
bundle*. (The picker's previews are a separate thing and are argued for below.) The whole set
lives in `icons/`, alongside `icons/pngs/`, which is where Icon Composer's 1024 exports are kept —
they are the source the previews are made from and are not built into anything. Two things in
`Apps/project.yml` make the icon work, and both are easy to get subtly wrong:

- It is listed in each target's `sources` with **`type: file`**. An `.icon` is a directory on disk,
  and without that XcodeGen walks into it and adds its insides as loose files instead of handing
  the bundle to `actool` whole.
- `ASSETCATALOG_COMPILER_APPICON_NAME: iskra` is set **on each target**, not in the shared
  `settings.base`. XcodeGen gives every app target a default of `AppIcon`, and a target setting
  beats a project-level one — so the tidier-looking placement silently loses, and the build fails
  with *"None of the input catalogs contained … an app icon set … named AppIcon"*.

### The seven others, on iPhone and iPad

`icons/iskra-chrome.icon` and its six siblings ship on **iOS only** — `setAlternateIconName` is
UIKit's and AppKit has no equivalent — and they need one more setting beyond the two above:
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, which is what *registers* a name. An icon merely
listed in `sources` is compiled and then refused at the moment somebody taps it.

**The compiled icons cannot be got back out of the bundle as pictures.** `UIImage(named:)` returns
nothing for the alternates, and asked for the primary by its bare name it does not fail politely —
it throws `Need an imageRef` and takes the app down. (The one name that works, `iskra60x60`, exists
only because the primary is also registered the old way under `CFBundleIconFiles`.) This is normal:
Apple's own guidance is that an icon picker ships its own preview images, and that is what
`Sources/IskraFeatures/Resources/icon-<name>.png` are — each icon exported at 1024 and scaled to
240, carrying its own rounded corner and transparent outside, so the tile neither masks it nor puts
a shape behind it.

**They are loaded from their file URL, never by name.** `Image("icon-x", bundle: .module)` resolves
through an asset catalog, and a SwiftPM resource directory has none: the lookup misses, SwiftUI
draws an empty view, and nothing is written anywhere — eight blank tiles and a clean log. Asking
`UIImage(named:in:)` whether the picture is there does not catch it either, because *that* does
fall back to loose files and answers yes about an image SwiftUI will never find. So
`HomeIcon.previewURL` is the single way in, for the tile and for `--probe-icons` alike, and
`HomeIconPreviewTests` holds every icon to having a file and every file to having an icon.

**`setAlternateIconName` reports a cancellation for changes it makes.** It comes back
`NSCocoaErrorDomain` / `NSUserCancelledError` whenever the app is not fully active at the moment
of the call, having changed the icon anyway — the same call from an active app throws nothing, and
`alternateIconName` names the new icon correctly either way. Nobody can cancel an icon change;
there is no cancel button in it. Taken at face value it put the failure alert up over a home
screen that had just changed correctly, so `HomeIcons.set` swallows that one error and treats the
change as made.

**And the ring is drawn from storage, not from a re-read.** `HomeIcons.set` writes the choice into
`UserDefaults.standard`, and the screen reads that key through `@AppStorage`. It used to be
`@State` filled from UIKit in `onAppear`, which is the shape of the bug it caused: a pushed screen
is built afresh every time it is returned to, so the ring was blank until the fill happened and
stayed blank whenever the fill produced `spark`. There is now nothing to re-fill and nothing to be
late. `onAppear` only reconciles the note with UIKit, for the one case the note cannot cover — a
reinstall, or an icon set by a build that kept no note.

The tiles used to be **drawn** instead, by a `SparkShape` reading a symlink into the icon document,
and that was right while every icon was the same spark on a different ground: nothing could drift.
It stopped being right rather than stopped working — `iskra-retro` knocks the spark out of a disc
and `iskra-letters` has no spark in it at all, so a drawn tile would have shown two icons that do
not exist. Redrawing an icon now means re-exporting its PNG; `HomeIcon.preview` says so, and
`--probe-icons` names the file when one is missing.

`Iskra --probe-icons` checks all of it inside the installed app: that the system knows all eight
names, that it allows the change at all, and that each has a preview to show. It runs from the root
view and not from `IskraApp.init`, because `supportsAlternateIcons` answers `false` if it is asked
before UIKit has finished launching — which is a lie that looks exactly like a locked-down device.

## Dependencies and licence

The package depends on `matrix-org/matrix-rust-components-swift`, **not** the `element-hq` fork.
Element's fork ships an iOS-only XCFramework; upstream publishes a `macos-arm64_x86_64` slice, and
that single fact is what makes a native Mac build possible instead of a Catalyst compromise.

`element-x-ios` was read as a reference but **no code was copied from it** — it is AGPL-3.0, and
copying would carry that licence into this project. If any code is ever lifted from it directly, it
must be flagged in the commit that does so.

**blobatar is the one thing here that was ported rather than written** (`IskraDesign/Blobatar/`).
It is MIT — permissive, not copyleft, so nothing about it obliges this project to publish its own
source — but the notice travels with the binary: `Licenses/blobatar.txt` is kept verbatim, every
ported file carries the attribution header, and a distributed build has to show that notice
somewhere a person can reach.

It is a *port*, not a call to `blobatar.dev/avatar/<seed>`, and the endpoint is not an option: the
seed is a Matrix user ID, so using it would send the list of everyone you talk to a third party,
once per row of the chat list. Being a port also means it has to be the same program — the same
seed must come out as the same creature here as anywhere else blobatar runs. `BlobatarTests` holds
it to blobatar's own golden fixture: a thousand seeds byte for byte, every silhouette's markup, and
the band histogram over twenty thousand. **A change that moves any of those numbers is a change of
identity**, not a bug fix — it gives people a different face — and the fixture is there to make
that impossible to do by accident. The port stops short of blobatar's *expressions*, which this app
does not use; the fixture's expression cases are skipped by name.
