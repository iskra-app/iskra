import SwiftUI
import IskraCore
import IskraDesign

/// The way into a call, in a room's toolbar.
///
/// Two buttons in a direct chat and one in a group, and that is not a simplification of the group
/// case — it is what the protocol says. The SDK's `Intent` has voice-only variants for direct
/// chats and none for groups, so a voice button in a group would either lie to the other clients
/// or mean nothing to them. One button, and the camera is turned off inside the call by whoever
/// wants it off.
struct CallButtons: View {
    let isOneToOne: Bool
    let onCall: (CallIntent) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.close) {
            if isOneToOne {
                Button {
                    onCall(.start(video: false))
                } label: {
                    Label {
                        Text(Strings.Call.voice)
                    } icon: {
                        Image(systemName: "phone")
                    }
                }
                .labelStyle(.iconOnly)
            }

            Button {
                onCall(.start(video: true))
            } label: {
                Label {
                    Text(Strings.Call.video)
                } icon: {
                    Image(systemName: "video")
                }
            }
            .labelStyle(.iconOnly)
        }
    }
}
