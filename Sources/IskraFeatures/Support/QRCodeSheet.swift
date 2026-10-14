import SwiftUI
import IskraCore
import IskraDesign

/// A face, a name and a code to point a camera at — yours from settings, a person's or a public
/// room's from its info screen. Telegram's QR screen, without the wallpaper.
///
/// What the code holds is a `matrix.to` link, not the bare ID — see `MatrixLink`, which is where
/// that choice is argued. The ID is written under the code as well, for the person standing next
/// to you who would rather type it.
struct QRCodeSheet: View {
    let name: String
    /// The Matrix ID or the room's address, written out under the code.
    let subtitle: String
    let avatarURL: String?
    var seed: String?
    var shape: AvatarShape = .circle
    let link: MatrixLink

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.roomy) {
                    Avatar(name: name, url: avatarURL, size: Theme.Size.avatarLarge, shape: shape, seed: seed)

                    Text(name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    QRCodeImage(text: link.url.absoluteString)
                        .frame(maxWidth: Theme.Size.qrCode)

                    Text(verbatim: subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)

                    ShareLink(item: link.url) {
                        Label(String(app: Strings.Profile.share), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: Theme.Size.qrCode)
                    }
                    .buttonStyle(.primaryAction)
                }
                .padding(Theme.Spacing.generous)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text(Strings.QR.title))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .leaving) { dismiss() } label: {
                        Label(String(app: Strings.Recovery.close), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
        #if os(macOS)
        // A Mac sheet is as small as its content will let it be, and a scroll view will let it be
        // very small indeed.
        .frame(minWidth: Theme.Size.qrCode * 1.5, minHeight: Theme.Size.qrCode * 2.25)
        #endif
    }
}

/// Where a link — scanned, tapped, opened from another app — leads: a person's page, or a room
/// to step into.
///
/// Never straight into a room. A QR code is somebody else's choice of where to send you, and
/// joining is visible to everyone already there; so a room is shown first, with what the server
/// will say about it, and entered with a press. A room this account is already in simply opens.
struct MatrixLinkView: View {
    let session: UserSession
    let link: MatrixLink
    /// The conversation to put on screen — the caller closes whatever this is standing in.
    var onOpen: (String) -> Void

    var body: some View {
        switch link {
        case .user(let userID):
            PersonLinkView(session: session, userID: userID, onOpen: onOpen)
        case .room(let room, let via):
            RoomLinkView(session: session, address: room, via: via, onOpen: onOpen)
        }
    }
}

private struct PersonLinkView: View {
    let session: UserSession
    let userID: String
    var onOpen: (String) -> Void

    @State private var person: PersonProfile?

    var body: some View {
        Group {
            if let person {
                MemberProfileView(member: RoomMemberSummary(person: person),
                                  roles: [], canRemove: false, canBlock: false,
                                  setRole: { _ in }, remove: {}, block: {},
                                  showsRole: false)
                    // "Write" ends here: the conversation is put on screen by whoever opened this.
                    .environment(\.openRoom, onOpen)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // A name and a face to show while it loads would be a guess; the ID is enough to write
            // to, and the profile, when the server gives it, is the real one.
            person = await session.profile(of: userID)
        }
    }
}

private struct RoomLinkView: View {
    let session: UserSession
    let address: String
    let via: [String]
    var onOpen: (String) -> Void

    @State private var isLoading = true
    @State private var joined: String?
    @State private var preview: PublicRoom?
    @State private var isJoining = false
    @State private var failure: RoomJoinFailure?

    var body: some View {
        Form {
            Section {
                ProfileHeader(name: preview?.title ?? address,
                              avatarURL: preview?.avatarURL,
                              subtitle: subtitle,
                              seed: preview?.id ?? address,
                              isSubtitleSelectable: true)
                    .profileHeaderRow()
            }

            if let topic = preview?.topic, !topic.isEmpty {
                Section {
                    Text(topic)
                        .font(.callout)
                        .textSelection(.enabled)
                } header: {
                    Text(Strings.Room.about)
                }
            }

            Section {
                Button {
                    Task { await enter() }
                } label: {
                    HStack {
                        Spacer()
                        if isJoining {
                            ProgressView()
                        } else {
                            Text(joined == nil ? Strings.QR.joinRoom : Strings.QR.openRoom)
                        }
                        Spacer()
                    }
                }
                .disabled(isLoading || isJoining)
            } footer: {
                if !isLoading, joined == nil {
                    if preview == nil {
                        Text(Strings.QR.roomUnknown)
                    } else if preview?.isOpen == false {
                        Text(Strings.QR.inviteOnlyRoom)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .profileScreen()
        .failureAlert($failure)
        .task {
            joined = await session.joinedRoom(address)
            if joined == nil {
                preview = await session.roomPreview(address, via: via)
            }
            isLoading = false
        }
    }

    private var subtitle: String {
        var parts = [preview?.alias ?? address]
        if let preview, preview.memberCount > 0 {
            parts.append(String(app: Strings.Room.participants(preview.memberCount)))
        }
        return parts.joined(separator: " · ")
    }

    private func enter() async {
        if let joined {
            onOpen(joined)
            return
        }
        isJoining = true
        do {
            onOpen(try await session.joinRoom(address, via: via))
        } catch {
            failure = error
        }
        isJoining = false
    }
}
