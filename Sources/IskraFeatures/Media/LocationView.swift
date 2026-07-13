import CoreLocation
import MapKit
import SwiftUI
import IskraCore
import IskraDesign

/// A place, in a bubble: a small map with a pin on it.
///
/// A live `Map` rather than a snapshot image. `MKMapSnapshotter` would produce a picture, which
/// sounds lighter — but it is an asynchronous render per bubble, cached nowhere, redone every
/// time the row scrolls back into view, and it comes back as a bitmap that is wrong the moment
/// the user switches to dark mode. A `Map` with interaction turned off is a map that draws itself,
/// follows the appearance, and costs nothing until it is on screen.
///
/// Pressing it opens Maps, because that is the only thing anybody wants to do with a place
/// somebody sent them: put it next to where they are and see how far it is.
struct LocationBubble: View {
    let location: Location
    let isOwn: Bool

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                            latitudinalMeters: Self.span,
                                                            longitudinalMeters: Self.span)),
                interactionModes: []) {
                Marker("", coordinate: coordinate)
                    .tint(.red)
            }
            .frame(width: Theme.Size.picture, height: Theme.Size.map)
            .clipShape(BubbleShape())
            .pictureBorder(isOwn: isOwn)
            .contentShape(BubbleShape())
            .onTapGesture { openInMaps() }
            .accessibilityLabel(Text(Strings.Location.title))
            .accessibilityAddTraits(.isButton)

            if let name = location.name {
                Text(name)
                    .font(.body)
                    .padding(.top, Theme.Spacing.close)
                    .padding(.horizontal, Theme.Spacing.tight)
            }
        }
    }

    /// How much of the world the bubble shows. Half a kilometre across: enough to see which
    /// street, not so much that the pin is a dot in a city.
    private static let span: CLLocationDistance = 500

    private func openInMaps() {
        let item = MKMapItem(location: CLLocation(latitude: location.latitude,
                                                  longitude: location.longitude),
                             address: nil)
        item.name = location.name ?? String(app: Strings.Location.title)
        item.openInMaps()
    }
}

/// Choosing a place to send.
///
/// The pin does not move — the map does. A crosshair is fixed in the middle of the screen and the
/// user drags the world under it, which is how every map picker on this platform works and why it
/// needs no instructions: what you are sending is whatever is under the mark.
///
/// The alternative — tap to drop a pin — reads well and works badly on a phone: the point you want
/// is under your thumb at the moment you commit to it, and you cannot see what you have chosen.
struct LocationPicker: View {
    let onPick: (Location) async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var camera: MapCameraPosition = .automatic
    @State private var centre: CLLocationCoordinate2D?
    @State private var isSending = false

    /// Asking the system where the user is. Held so the permission prompt is asked for once, when
    /// the button is pressed — never on opening the screen: somebody sending a pin from a map of
    /// a city they are not in should not be asked for their own position to do it.
    @State private var locations = LocationAuthority()

    var body: some View {
        NavigationStack {
            Map(position: $camera) {
                UserAnnotation()
            }
            .mapControls {
                MapCompass()
            }
            .onMapCameraChange(frequency: .continuous) { context in
                centre = context.camera.centerCoordinate
            }
            // The crosshair. Drawn over the map and deliberately not hit-testable — it is a
            // sight, not a control, and a finger landing on it must reach the map underneath.
            .overlay {
                Image(systemName: "mappin")
                    .font(.system(size: Theme.Size.crosshair))
                    .foregroundStyle(.red)
                    .shadow(radius: 4)
                    // The point of a pin is its point, and a glyph is centred on its middle. Half
                    // its height up puts the tip where the crosshair actually is — otherwise the
                    // user sends a place half a pin south of the one they were looking at.
                    .offset(y: -Theme.Size.crosshair / 2)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    Task { await goToMe() }
                } label: {
                    Image(systemName: "location.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: Theme.Size.minimumTapTarget, height: Theme.Size.minimumTapTarget)
                        .navigationGlass(in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .padding(Theme.Spacing.roomy)
                .accessibilityLabel(Text(Strings.Location.myLocation))
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(String(app: Strings.Location.title))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(app: Strings.Location.cancel)) { dismiss() }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(String(app: Strings.Location.send)) {
                        Task { await send() }
                    }
                    .disabled(centre == nil || isSending)
                }
            }
        }
    }

    private func goToMe() async {
        guard let coordinate = await locations.current() else { return }

        withAnimation(.smooth) {
            camera = .region(MKCoordinateRegion(center: coordinate,
                                                latitudinalMeters: 800,
                                                longitudinalMeters: 800))
        }
    }

    private func send() async {
        guard let centre, !isSending else { return }
        isSending = true

        await onPick(Location(latitude: centre.latitude, longitude: centre.longitude))
        dismiss()
    }
}

/// Where the user is, asked for once and only when they press the button.
///
/// `CLLocationManager` predates async by a decade and answers through a delegate, so this is the
/// bridge: one question, one answer, and nothing kept afterwards. Nothing here *tracks* anybody —
/// there is no continuous updating, no background mode, and the manager is thrown away with the
/// screen. The app wants a single coordinate to point a map at.
@MainActor
@Observable
final class LocationAuthority: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    /// The permission prompt, while the user is looking at it. See `current()`.
    private var deciding: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func current() async -> CLLocationCoordinate2D? {
        // A second press while the first is still being answered must not strand the first
        // continuation — resuming one twice is a crash, and never resuming it is a hang.
        guard waiting == nil, deciding == nil else { return nil }

        // Asking for permission is *asynchronous*, and this is the whole bug it used to hide.
        // `requestWhenInUseAuthorization()` returns at once, the status is still `.notDetermined`,
        // and the `requestLocation()` that came immediately after it was answered by CoreLocation
        // with `kCLErrorDenied` — straight into `didFailWithError`, straight to nil, and the map
        // did not move. So the very first time anybody pressed "my location", they granted
        // permission and nothing happened; pressing it a second time worked, which made it look
        // like a flaky button rather than a missing await.
        //
        // The answer arrives at `locationManagerDidChangeAuthorization`. We wait for it.
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                deciding = continuation
                manager.requestWhenInUseAuthorization()
            }
        }

        switch manager.authorizationStatus {
        case .restricted, .denied, .notDetermined:
            // Nothing to do about it here. The user said no — or said nothing — and the map still
            // works: they can drag it to wherever they meant.
            return nil
        default:
            break
        }

        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in answer(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in answer(nil) }
    }

    /// The user has answered the permission prompt — whichever way. Also fires once, unprompted,
    /// the moment the delegate is set: harmless, because nobody is waiting yet.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            deciding?.resume()
            deciding = nil
        }
    }

    private func answer(_ coordinate: CLLocationCoordinate2D?) {
        waiting?.resume(returning: coordinate)
        waiting = nil
    }
}
