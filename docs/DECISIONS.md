# Decisions worth knowing

The reasoning behind choices that look arbitrary from the outside. The operational rules
that follow from them are in [`CLAUDE.md`](../CLAUDE.md); this file is the *why*.

## `matrix-org/matrix-rust-components-swift`, not the `element-hq` fork

Element's fork is what Element X iOS uses, but it ships an iOS-only XCFramework. The
upstream package publishes a `macos-arm64_x86_64` slice, and that single fact is what
makes a native Mac build possible rather than a Catalyst compromise.

## Deployment target: iOS 18 / macOS 15

Both numbers are set by `Mutex` (Synchronization), which the code leans on in eleven
places; that is the lowest floor reached without rewriting its locks, and iOS 18 runs on
every iPhone iOS 17 does (XS and XR onwards), so going lower would buy no phones. Below
that the cost climbs fast: `@Observable` is iOS 17, and the SDK itself stops at iOS 16 /
macOS 12.

Liquid Glass is OS 26, and it is still used directly — but only inside
`IskraDesign/Glass.swift`, which is the one place that checks availability. On the older
systems it draws the navigation layer the way it was drawn before glass: a system
material where glass floats, the accent as a solid fill where it is tinted, and nothing at
all for the effects that only exist between sheets of glass. No view checks for OS 26
because of glass.

The Mac build links ~200 warnings that SDK objects were "built for newer macOS version
(26.5)". They are the C libraries inside the Rust SDK (zstd, the TLS stack), compiled
without a deployment target of their own, and they call nothing but libc and pthreads —
checked symbol by symbol. The warning is about the label, not the contents.

## Liquid Glass is confined to the navigation layer

Apple's guidance is explicit that glass belongs on toolbars, controls and floating
panels — not on content, and never on top of other glass. So the composer, the toolbar
buttons and the sign-in actions are glass; message bubbles are opaque fills.
`IskraDesign/Glass.swift` encodes this: there is no general `.glass()` modifier to reach
for, only `.navigationGlass()`.

## Round video messages are recognised by shape, not by a flag

Matrix has no round-video event type. Tagging one with a custom field would mean building
the event by hand — `Client.uploadMedia` plus `Room.sendRaw` — and `uploadMedia` does
*not* encrypt attachments. In an encrypted room that would upload the user's face to the
homeserver in the clear. So we send an ordinary `m.video` through `Timeline.sendVideo`,
which encrypts it properly, and make it recognisable instead: exactly square, at most 60
seconds. The cost is cosmetic and symmetric — our circles appear as square videos in
other clients, and a square clip from another client appears as a circle here. Nothing
leaks. See `IskraCore/Media/VideoNote.swift`.

## `.lproj/.strings`, not a String Catalog

Catalogs are the nicer format, but they are compiled by Xcode's `XCStringsTool` and
SwiftPM's command-line build does not run it — it copies the `.xcstrings` into the bundle
untouched, so every string resolves to its own key and `swift test` sees an unlocalized
app while Xcode sees a localized one. One consistent format beats a prettier one that
only works half the time.

The app bundle must also declare `CFBundleLocalizations`. Without it the system treats
the app as English-only, `Locale.current` can never become Russian, and the translations
sitting in the package bundle are never reached — while every localization unit test
still passes, because tests set the locale by hand. The declaration is in
`Apps/project.yml`.

## Element X was read, not copied

[element-x-ios](https://github.com/element-hq/element-x-ios) was read as a reference for
how a SwiftUI client sits on top of this SDK. **No code was copied from it.** Every file
here was written against the SDK's own generated bindings and its official example. This
matters because element-x-ios is AGPL-3.0 and its copyright is Element's: copying from it
would carry that licence into this project, and with it a store distribution Element has
not agreed to. If any code is ever lifted from it directly, it must be flagged in the
commit that does so.

## GPL-3.0 with an app-store permission

The GPL forbids "further restrictions" on the people who receive a program (section 10)
and requires that a user of a consumer device can install a modified version (section 6).
App Store terms do both of the things it forbids. The author of a work is not bound by
their own licence, so a single-author GPL app can ship there — but the first contribution
under the plain GPL makes that author's code a reason the app may not, which is how VLC
left the App Store in 2011.

The section 7 permission in [`LICENSE-EXCEPTION.md`](../LICENSE-EXCEPTION.md) is the
answer that needs no CLA: contributors sign off under the GPL *with* the permission, so
everyone's code may go to the store on the same terms as the maintainer's, and nobody is
granted more than anyone else. The bridge is MIT on purpose — it exists so that the
protocol can be implemented and run anywhere.
