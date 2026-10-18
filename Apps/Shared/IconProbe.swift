#if os(iOS)
import Foundation
import UIKit
import IskraFeatures

/// `Iskra --probe-icons` says whether the six app icons are really in this build.
///
/// It exists for the same reason the other probes do: the thing most likely to be wrong is the
/// thing the test suite cannot see. Alternate icons are not code — they are two build settings and
/// six directories handed to `actool`, and `swift test` never runs `actool` at all. An icon left
/// out of `ALTERNATE_APPICON_NAMES` compiles and ships and is refused at the moment somebody taps
/// it; a spark vector left out of the package's resources leaves six blank tiles on the screen
/// where the choosing happens. Neither writes anything to any log.
///
/// Unlike every other probe here it runs *after* launch rather than from `IskraApp.init`, and that
/// is not tidiness — it is the whole reason the first version of it reported a lie.
/// `supportsAlternateIcons` answers `false` when it is asked before UIKit has finished launching,
/// so the probe said "this device forbids them" about a simulator that allows them perfectly well.
/// It is attached to the root view instead, which cannot appear until the application is up.
///
/// Be exact about what it proves. It proves that the system knows all six names, that it will
/// allow the icon to be changed at all, and that the tiles on the settings screen have a spark to
/// draw. It does **not** change the icon: a probe that did would leave the home screen altered,
/// and it would put iOS's own "you have changed the icon" alert up with nobody there to dismiss
/// it. That last step is a person tapping a tile.
///
/// ```sh
/// xcrun simctl launch --console booted wtf.iskra --probe-icons
/// ```
enum IconProbe {
    static var wasRequested: Bool {
        CommandLine.arguments.contains("--probe-icons")
    }

    /// Prints what it found and exits. Never returns.
    @MainActor
    static func runAndExit() async -> Never {
        let lines = HomeIcons.report()
        for line in lines {
            print(line)
        }

        // A name the system does not know is a failed check and not a note, so the exit code says
        // so: this is the kind of thing a script runs after a build.
        exit(lines.contains { $0.hasPrefix("  ❌") } ? 1 : 0)
    }
}
#endif
