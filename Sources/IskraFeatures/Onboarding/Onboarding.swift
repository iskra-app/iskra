import Foundation
import IskraCore

/// What the app remembers about having introduced itself.
///
/// One flag, and it is deliberately **not** in `AppSettings.forget()` — unlike the accent or the
/// quick reaction, this is not a preference belonging to whoever is signed in. It records that
/// this device has been shown what the app is. Somebody who signs out to change accounts, or who
/// is signed out by a server that ended their session, has not forgotten what Iskra is, and six
/// slides of pitch on the way back in would be the app talking over them at the worst moment.
enum Onboarding {
    /// Whether the slides have been got through. Written once, by the button under them.
    static let welcomeSeenKey = "onboarding.welcomeSeen"
}

/// The three answers to "who gets a drawn creature instead of their face".
///
/// It is one question with three positions, and underneath it is two independent switches in the
/// App Group's defaults (`BetaFeatures.blobatarKey` and `.forceBlobatarKey`). That pair is right
/// where it lives — the second switch only means anything while the first is on, and Beta features
/// shows it that way — but it is the wrong shape to *ask* somebody on their first run. Three
/// positions on one slider have no impossible combination in them: force-without-creatures cannot
/// be expressed, so it cannot be chosen by accident.
///
/// The mapping is total in one direction only. `force` set while `blobatar` is off is a state the
/// app can hold and this type cannot name; it reads as `.pictures`, which is what the app in that
/// state actually does.
public enum FaceMode: Int, CaseIterable, Identifiable, Sendable {
    /// Pictures where there are pictures, initials everywhere else. What the app ships as.
    case pictures
    /// A creature for the people who never set a picture.
    case mixed
    /// A creature for everybody, over the pictures people did set.
    case faces

    public var id: Int { rawValue }

    /// The key fragment the strings are named after — see `Strings.Onboarding.faceMode(_:)`.
    var key: String {
        switch self {
        case .pictures: "pictures"
        case .mixed: "mixed"
        case .faces: "faces"
        }
    }

    /// The two switches this position stands for.
    var drawsCreatures: Bool { self != .pictures }
    var overridesPictures: Bool { self == .faces }

    init(drawsCreatures: Bool, overridesPictures: Bool) {
        guard drawsCreatures else { self = .pictures; return }
        self = overridesPictures ? .faces : .mixed
    }
}
