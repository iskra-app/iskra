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

`Iskra --probe-bridge [npub] [homeserver]` sends one real request through the nostr tunnel and says
which failure it was. Five things make a bridge look broken in exactly the same way — a mistyped
key, a bridge that is not running, one whose `ALLOWED_UPSTREAMS` does not cover this homeserver, a
closed one that has never been told about this device, relays that are all refusing connections —
and from inside the app all five are a sign-in that spins. Given no arguments it uses what is in
Settings → Connection, which is the case worth having.

```sh
xcrun simctl launch --console booted moscow.swag.iskra --probe-bridge
./device.sh -- --probe-bridge npub1… matrix.org
```

### The demo server

Settings → Beta features → **Demo server** (`BetaFeatures.mockBackendKey`) swaps the real account
for a made-up one on a homeserver that lives inside the app (`IskraCore/MockBackend/`). It is there
for looking at every screen with something on it: DMs and groups, a photo, a voice message, a file,
a location, a poll, edits, reactions, a deleted message, a pinned one, a mention, a space, an
invitation, a room long enough to paginate, and people who answer (with "typing…") when you write.

It is **not** a fake of the stores. `MockHomeserver` is an `HTTPUpstream` behind the same
`LocalHTTPProxy` the bridge uses, so the real SDK, sliding sync, send queue and every store run
unchanged against it — which is why it can show a screen's real behaviour and why nothing above
`IskraCore` had to learn about it. `DemoBackendTests` drives it through the real SDK end to end and
pins that nothing the SDK asks for falls through as "unrecognized"; when a screen misbehaves only in
the demo, that list (`MockHomeserver.unrecognized`, also logged under `session`) is the first place
to look.

What it must never do is touch the real account, and three things hold that line: no tokens go
into the Keychain (the store's passphrase is random and the store is wiped every time the demo
starts); `UserSession.isDemo` turns sign-out and "ended elsewhere" into *leaving the demo*, never
`SessionStore.clear`; and the root view skips pushers, the Siri directory and the Shortcuts outbox
for it. The server's memory lasts one launch.

The switch is behind sign-in, so `Iskra --mock-backend` turns it on from the command line for a
device with nobody signed in — `./device.sh -- --mock-backend`. It stays on until turned off.

### The sign-in server

The demo server skips the sign-in screen; this one is for it. `Iskra --mock-signin` opens the
sign-in screen against a second homeserver inside the app (`SignInMockServer`,
`IskraCore/Transport/`), with its address already typed in. There is always
`alice` / `password`; registration makes more accounts for as long as the app runs. Words after the
flag pick the server: `password` (no browser, no "create account"), `sso` (legacy `m.login.sso`
only), `closed` (OIDC without registration), `slow` (two seconds a request).

```sh
xcrun simctl launch --console booted moscow.swag.iskra --mock-signin
./device.sh -- --mock-signin password slow
```

Only the *server* is fake. It is an `HTTPUpstream` behind the same `LocalHTTPProxy` the bridge
uses, and the real SDK talks to it over real HTTP, so `SignInModel`, `AuthenticationService`, the
OIDC dance and the browser page all run as they do against matrix.org, and the flow ends in a real
`UserSession`. That is also why it cannot be a fake `AuthenticationService`: a session is built
around a live `Client`. Past sign-in it answers what an empty account needs to get through the
first-run screen to its recovery code: account data, keys, backup versions, an empty sliding sync.
Anything else gets `M_UNRECOGNIZED` and goes on `unanswered`, which `MockSignInTests` holds to
empty. When an SDK update starts asking for something new, that test names the endpoint.

**It never touches the real account on the device.** The session goes in `StorageMode.scratch` with
`InMemorySecrets`. The next launch without the flag restores whoever was signed in, untouched, and
`AppSettings.forget` does nothing under the flag, so signing out of `alice` leaves the real
accent and wallpaper where they were.

### The bridge, from this side

`Bridge/` is a Rust service that carries Matrix over nostr; `IskraCore/Transport/Nostr/` is the
other half of it. Both link the same wire format on purpose — an envelope one side chunks one way
and the other reassembles another way fails only under load and only in production — so
`TunnelEnvelope` mirrors `iskra-tunnel-proto`'s `Envelope` field for field, `body_chunk` included,
and `NostrTunnelTests` pins that JSON as text.

`NostrTunnelUpstream` is an `HTTPUpstream`, which is the whole trick: it stands exactly where
`DirectUpstream` stands, behind the same `LocalHTTPProxy` that puts the SDK's requests in front of
us in the clear, and nothing above the transport learns anything. The bridge's address is
`TunnelSettings.addressKey` in the **App Group's** defaults (`TunnelSettings.store`, Settings →
Connection) — the notification extension routes by it too, and with it in `.standard` every push
went straight to the homeserver with the bridge switched on; this device's own nostr key
is in the Keychain, under a **service of its own** — the session's service is emptied on the way
out (`SessionStore.remove(sessionID:)` per account, `SessionStore.clear` for all), and a key
regenerated there would have to be re-added to every closed bridge
before the user could sign in again, through the bridge they can no longer reach.

A message longer than 24 KiB travels in several events (`TunnelChunker`, `TunnelReassembler`), and
the arithmetic is the Rust side's, case for case — `TunnelChunkingTests` asks this implementation
the same questions `chunk.rs` and `reassemble.rs` are asked. Three of those cases are worth knowing
by heart, because each is a bug that only shows up under load: the head fields ride on chunk 0 and
an envelope carrying them elsewhere is refused by both ends; chunks arrive out of order and more
than once, so the head may be last and a duplicate must count once; and everything half-arrived is
capped — 512 chunks, 8 MB, 64 messages at a time, 60 seconds each — because on a phone the memory
being held is somebody's.

Four rules about it fail far from their cause:

- **With an address filled in, a tunnel that will not come up is a refusal**
  (`AuthenticationError.bridgeUnavailable`), never a quiet direct connection. While there was
  nothing on the far side of the switch, falling back cost nothing; now the switch is a decision
  about who may see the traffic, and going direct without saying so answers that question behind
  the user's back. With **no** address, there is nothing to fall back *from*: the listener comes up,
  requests go straight out, and the status says `routingLocally` in those words.
- **A relay list of one is a mistake, not a simplification.** An event is published to all relays
  at once and the answer comes from whichever is quickest; `relay.damus.io` answers `503` to the
  connection itself often enough to be the standing example. Duplicates are the price, and
  `NostrRelayPool` drops them by event id.
- **Nothing in the tunnel waits for a relay to say `OK`.** `NostrRelayPool.publish` hands the event
  to every open socket and returns; what is waited for is the *answer*. The bridge learnt this the
  expensive way: nostr-sdk's `send_event` returns only once every relay has acknowledged or timed
  out — ten seconds for a relay that is down — and chunks sent one after another each waited out the
  dead relay, so a three-chunk sync answer took twenty seconds and the chat list with it. Waiting
  for acknowledgements "to be sure" here would bring exactly that back, on the phone.
  `LiveBridgeSessionTests` is what found it: a whole SDK session through a real bridge, timed
  request by request against the same session run direct.
- **The loopback listener does not survive a suspension by itself.** iOS reclaims a suspended
  app's listening sockets (TN2277), and the SDK knows the homeserver only as
  `http://127.0.0.1:<that port>` — so after a while in a pocket every request was refused and the
  app said "no network" while the bridge answered perfectly well. `LocalHTTPProxy` watches its
  listener for the whole of its life and rebinds on the **same** port when it is lost, and
  `UserSession.enteredForeground` wakes the tunnels (listener checked, relays pinged, backoff cut
  short) *before* sync resumes. The same goes for the demo and sign-in servers, which stand behind
  the same listener. A change of bridge settings is applied the same way a change of account is —
  the session closed and restored (`TunnelSettings.changed`, answered by the root) — because a
  client cannot be re-pointed live, and "on the next launch" was an app that stopped loading
  messages the moment somebody switched the bridge on.

`Iskra --probe-bridge [npub] [homeserver]` and the "Check the bridge" button both drive
`BridgeCheck`, so the terminal and the screen cannot disagree. `LiveBridgeTests` is the end-to-end
check against a real bridge and is **off** unless `ISKRA_BRIDGE_PUBKEY` is set — `swift test` stays
offline. See `Bridge/README.md` for the bridge itself and for what it can see.

## Architecture

Three SwiftPM library targets, and the dependency rule between them is the whole design:

| Target | Holds | May import |
|---|---|---|
| `IskraCore` | Sessions, secrets, rooms, timeline, search, media | `MatrixRustSDK`. **Never SwiftUI.** |
| `IskraDesign` | Bubbles, glass, spacing, colour | SwiftUI. **Never Matrix.** |
| `IskraFeatures` | The screens | Both — the only place they meet. |

Keeping Matrix out of the views and views out of Matrix is what lets one set of screens serve three
platforms.

**`IskraCore` is a package of its own (`Core/`) and a *dynamic* framework**, and the first is what
makes the second possible. It carries the Rust SDK, ~100 MB of machine code, and the app and both
extensions link it. Linked statically, each of the three carried its own copy, and the app weighed
half a gigabyte on a phone. Inside the root package it could not be shared: `IskraFeatures` depends
on the `IskraCore` *target* there, which is always linked statically, and Xcode refuses outright to
have one target linked both ways into one app. Across a package boundary `IskraFeatures` depends
on the *product*, and so the SDK ships once, in `Frameworks/IskraCore.framework`, and the extensions
load the app's copy (`@executable_path/../../Frameworks`). Putting `IskraCore` back next to
`IskraFeatures` brings the three copies back; the build will not mention it. `IskraCore` never leaks an SDK type upward: `UserSession` owns the `Client`, and nothing
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

### The widgets and the Live Activities are a third extension

`IskraWidgets` (`Apps/Widgets/`) draws the favourites widget and both Live Activities; the app
starts and moves the activities (`LiveLocationActivity`, `MediaSendBackground` in
`IskraFeatures/Support/`) and writes everything the widget reads. Linked like the share
extension — `IskraCore` and `IskraDesign`, never `IskraFeatures`, the App Group and **not** the
Keychain group. Four things about it fail far from their cause:

- **`ChatEntity.swift` and `WidgetIntents.swift` are compiled into both bundles**, and their words
  (`Apps/Shared/<lang>.lproj/Localizable.strings`) are copied into the widget too. A widget's
  configuration and its buttons are intents matched across bundles by type; a look-alike copy is a
  different type, and a chat somebody picked fails to resolve in the app, where `perform` runs.
- **Pictures come from the app.** Neither the widget nor the share sheet holds a token, so the app
  downloads chats' avatars into the App Group (`DirectoryFaces`, `ChatFaces`) and the directory
  entry names the file only once it is there. Written `.completeUntilFirstUserAuthentication`:
  a widget is drawn on a locked phone, and `.complete` would draw it with empty circles.
- **The widget is reloaded only when what it draws changes** (`WidgetChats.fingerprint`,
  `WidgetRefresh`). The directory is rewritten on every sync tick; WidgetKit's daily budget is not.
- **The activities' types are in `IskraCore`** (`LiveActivityAttributes.swift`) because the app and
  the extension must agree on their JSON. Nothing updates them by push — that would tell our
  Sygnal who is sharing a location right now.

### More than one account

Several accounts can be signed in on one device; one is on screen and syncing, the others are
*closed* (not signed out) and a tap away — `AccountSwitcher`, in settings and on a long press of the
avatar. Switching is `UserSession.close()` + `setActiveAccount` + the root's ordinary `restore()`.

- **The Keychain is per account.** `accounts` is the index (who, in what order, who is on screen);
  every account has `session.<id>`, `store-passphrase.<id>` and `search-index-key.<id>`, where `<id>`
  is the random session ID that also names its directories. **Never `removeAll()` for one account**
  — that is the first account's sign-out taking the second one's store key with it. A device from
  before this layout is moved across once by `SessionStore.migrateLegacyIfNeeded`, *keeping* its
  session ID, so nothing is re-downloaded.
- **One `SessionDelegate` per client**, fixed to its session ID at build time. A shared one,
  retargeted before each build, writes one account's refreshed tokens into another's record.
- **A push says whose it is** — `iskra_account` in `default_payload`, the session ID, never the
  Matrix ID — and pushers are registered with **`append: true`**, because `false` deletes other
  users' pushers with the same pushkey. See `docs/PUSH-GATEWAY.md`.
- **Per-account state in the App Group is keyed by account**: `LocalNames` (`use(account:)`), the
  chat directory and outbox (`accountID` on every entry), the badge (`UnreadCounts`, the icon is the
  sum). Appearance is the *device's*: `AppSettings.forget()` runs only when the last account leaves.
- Adding the account that is open is refused (`alreadySignedIn`); signing in again to one that is
  not open replaces its record — that is how a broken account is mended.

## Invariants that are easy to break by accident

**Localization.** No user-facing string appears in a view. Every one is named in a `Strings.swift`
(`IskraFeatures/Support/` for screens, `IskraCore/Support/` for what the model layer produces); the
words live in `Resources/<lang>.lproj/Localizable.strings`, **which is the file to edit**. English
and Russian are both complete; neither is a fallback.

German, Spanish, French, Japanese and Chinese (`de`, `es`, `fr`, `ja`, `zh-Hans`) are complete too —
every string, every plural, and Siri's phrases in `Apps/Shared/<lang>.lproj`. They are translated
from the Russian as much as from the English, so they keep its plain voice — and its «вы»: `Sie`,
`usted`, `vous`, `您`, and Japanese in です/ます. Two exceptions, both on purpose: the chat in the
Appearance preview, which is two friends talking (`du`/`tú`/`tu`/`你`, as «выбрал?» is in Russian),
and Siri's phrases, which are said *to Siri* and are as informal as «Открой…». A key *missing* from a `.lproj` does not
fall back to English, it is shown as the key, so a string added to `en` has to be added to all
seven — in English as a placeholder if there is no translation yet, which
`otherLanguagesAreComplete` will not notice and a reader will.

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
(sign-in, recovery) and `.primaryAction` in content. The second button beside a `.glassAction` is
`.glassSecondary` — same capsule, same height — not the system's `.glass`, which is a few points
shorter and made the two stacked buttons look like two different kinds of thing.

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

**Deployment target is iOS 18 / macOS 15**, set by `Mutex`. Liquid Glass and everything else that
is OS 26 (`.buttonStyle(.glass)`, `GlassEffectContainer`, `glassEffectID`,
`sharedBackgroundVisibility`, the scroll edge effect, `role: .close`) is reached **only** through
`IskraDesign/Glass.swift` — `.navigationGlass()`, `.navigationGlassButton()`, `NavigationGlassGroup`,
`.navigationGlassID`, `.outsideToolbarGlass()`, `.softScrollEdge`, `.scrollEdgeHidden`,
`ButtonRole.leaving` — which is the one file that says `#available(iOS 26, macOS 26, *)` and decides
what the older systems draw instead. Calling the system's glass API from a view compiles only
inside an availability check, so the build itself refuses the shortcut. Any other OS 26 API
takes an `#available` where it is used, with the iOS 18 path next to it (`LocationView.openInMaps`).
The ~200 linker warnings about SDK objects "built for newer macOS version (26.5)" on the Mac are
expected: vendored C code with no deployment target of its own, calling only libc and pthreads.

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
- **All *Matrix* cryptography is the Rust SDK's. None of it is reimplemented here, and none of it
  should be.** Olm, Megolm, cross-signing, the encrypted store: the SDK's, untouched.

  The bridge's transport is the one thing outside that sentence, and it is worth knowing why it is
  not an exception to it. NIP-44 is nostr's, not Matrix's, and it needs three primitives: a
  secp256k1 ECDH, HKDF-SHA256, and *unauthenticated* ChaCha20 under its own HMAC. The curve is
  libsecp256k1 (`21-DOT-DEV/swift-secp256k1` — the C library, not a Swift rewrite of it) and the
  HKDF and HMAC are CryptoKit's. Only the ChaCha20 block function is written out, in
  `IskraCore/Transport/Nostr/ChaCha20.swift`, because CryptoKit exposes `ChaChaPoly` and nothing
  underneath it: the AEAD appends its own Poly1305 tag and will not hand back a keystream, and
  using it instead would produce a payload no other nostr implementation could read. `NIP44Tests`
  runs the vector file published with the NIP — every case, including the 65535-byte message —
  which is what makes "the same encryption the bridge speaks" a fact rather than an intention.
- **A photo or video leaves the way Settings → Photos & videos says** — without its metadata (GPS,
  camera, dates, author, every track that is not picture or sound) and compressed, both on by
  default (`MediaSettings`, applied by `MediaPreparation` in `TimelineStore.send(photo:)` and
  `send(video:)`, which every path — composer, Share outbox, forward, video note — goes through).
  A new way to send media goes through those two, not around them. **A WebP is the one photo
  that skips compression** — it is a sticker (`StickerPicture`), always stripped, never squeezed —
  and in an *encrypted* room it goes as an encrypted `m.image`, never as an `m.sticker`, because
  `uploadMedia` would put it on the server in the clear. **A video note ignores the
  settings** (`asVideoNote: true` → `MediaSettings.videoNote`): always stripped, and never
  compressed twice, because `SquareVideoExporter` already did. A stripped result is read back
  against an allow-list, and one that is not clean is **not sent**: ImageIO's "copy without
  metadata" keeps the GPS in a PNG and the capture date in a HEIC, so trusting it is not an option.
  Video is compressed by `VideoTranscoder` (reader → writer, explicit bit rate), not by an export
  preset: a preset whose size a clip already fits passes it through at its own bit rate. Its two
  tracks are read by **two** `AVAssetReader`s — one reader for both deadlocks against the writer's
  interleaving, at 0% CPU. Files sent *as files* go untouched, on purpose.
- Nothing logs message content, tokens, passwords, or OAuth callback URLs — a callback URL carries
  the authorization code and is as sensitive as the token it buys.

## Do not edit (generated)

`Apps/Iskra.xcodeproj/`, `Apps/*/Info.plist`, `Apps/*/Iskra.entitlements` are all generated by
XcodeGen and gitignored. **Edit `Apps/project.yml` and rerun `xcodegen`.**

## The app icon

`icons/iskra-spark.icon` is an Icon Composer document, and one icon serves both platforms — it carries
its own light, dark and tinted appearances, so there is no set of PNGs to keep in step *in the
bundle*. (The picker's previews are a separate thing and are argued for below.) The whole set
lives in `icons/`, alongside `icons/pngs/`, which is where Icon Composer's 1024 exports are kept —
they are the source the previews are made from and are not built into anything. Two things in
`Apps/project.yml` make the icon work, and both are easy to get subtly wrong:

- It is listed in each target's `sources` with **`type: file`**. An `.icon` is a directory on disk,
  and without that XcodeGen walks into it and adds its insides as loose files instead of handing
  the bundle to `actool` whole.
- `ASSETCATALOG_COMPILER_APPICON_NAME: iskra-spark` is set **on each target**, not in the shared
  `settings.base`. XcodeGen gives every app target a default of `AppIcon`, and a target setting
  beats a project-level one — so the tidier-looking placement silently loses, and the build fails
  with *"None of the input catalogs contained … an app icon set … named AppIcon"*.

**Renaming the primary icon is how iOS is made to forget it.** It was `iskra.icon` until
notifications kept showing an older icon long after the home screen had the new one. Nothing old
was in the bundle — Assets.car and the `CFBundleIconFiles` PNGs were both current — so it was
iOS's cache, which is keyed on the icon's name. `HomeIcon.spark` keeps the id `"iskra"`: that is
the app's name for the choice (the preview file, the remembered setting), and UIKit never sees it,
because the primary is `nil` to `setAlternateIconName`.

### The seven others, on iPhone and iPad

`icons/iskra-chrome.icon` and its six siblings ship on **iOS only** — `setAlternateIconName` is
UIKit's and AppKit has no equivalent — and they need one more setting beyond the two above:
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, which is what *registers* a name. An icon merely
listed in `sources` is compiled and then refused at the moment somebody taps it.

**The compiled icons cannot be got back out of the bundle as pictures.** `UIImage(named:)` returns
nothing for the alternates, and asked for the primary by its bare name it does not fail politely —
it throws `Need an imageRef` and takes the app down. (The one name that works, `iskra-spark60x60`, exists
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
