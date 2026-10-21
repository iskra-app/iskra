import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// Your picture and your name, on a screen that exists to change them.
///
/// Pushed from the pencil in the corner of `SettingsView`, and pushed rather than presented:
/// the back chevron and the swipe are then the system's, exactly as everywhere else in this app.
///
/// There is no Save button. The name is sent when the field is *left* — on submit, on leaving the
/// screen — which is the arrangement settings already used when the field lived on the profile
/// row itself. What moved here is not the mechanism, it is the *mode*: a name you can only edit
/// on a screen you chose to open cannot be emptied by a stray tap on the screen you read.
struct ProfileEditView: View {
    let session: UserSession

    /// Offline, every control here is a call straight to the server with nothing queued behind
    /// it — the same reasoning as `RoomInfoView`, and the same answer. A field that never takes
    /// the text cannot lose it.
    @Environment(\.isOffline) private var isOffline

    @State private var draftName = ""
    @FocusState private var isNaming: Bool

    @State private var isChoosingPicture = false
    @State private var pickedPicture: PhotosPickerItem?
    /// The picked picture, being cut into the face — see `AvatarCropper`.
    @State private var cropping: AvatarCropRequest?

    /// A change the server would not make — or a picture the photo library would not hand over,
    /// which never reached the server at all.
    @State private var failure: AccountActionFailure?

    var body: some View {
        Form {
            Section {
                picture
                    .profileHeaderRow()
            }

            Section {
                TextField(String(app: Strings.Account.namePlaceholder), text: $draftName)
                    .focused($isNaming)
                    .onSubmit { isNaming = false }
                    .disabled(isOffline)
            } header: {
                Text(Strings.Account.nameHeader)
            } footer: {
                // A new display name is a member event in every room the account is in, so
                // everybody it shares a chat with sees "X changed their name to Y". Worth saying
                // before the field is left, not after.
                if isOffline {
                    Text(Strings.Account.editOffline)
                } else {
                    Text(Strings.Account.nameChangeNotice)
                }
            }

            // The Matrix ID, shown in a field so it reads as the name's sibling, and disabled
            // because no homeserver can change it: it is the account itself.
            Section {
                TextField(String(app: Strings.Account.usernameHeader), text: .constant(session.userID))
                    .disabled(true)
                    .textSelection(.enabled)
            } header: {
                Text(Strings.Account.usernameHeader)
            } footer: {
                Text(Strings.Account.usernameFixed)
            }
        }
        .formStyle(.groupedRows)
        .profileScreen()
        .onChange(of: session.displayName, initial: true) { _, name in
            guard !isNaming else { return }
            draftName = name
        }
        .onChange(of: isNaming) { wasNaming, _ in
            guard wasNaming else { return }
            Task { await rename() }
        }
        // Leaving the screen is leaving the field: SwiftUI does not promise that focus resigns
        // before a view is torn down, so tapping back with the keyboard still up would otherwise
        // drop the new name. `UserSession.rename` returns early when nothing changed.
        .onDisappear {
            guard isNaming else { return }
            Task { await rename() }
        }
        // At the root of the screen, never inside the menu that asks for it: a `PhotosPicker`
        // declared inside a `Menu` simply never appears.
        .photosPicker(isPresented: $isChoosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            Task { await choosePicture(item) }
        }
        // Cut to a square before it goes anywhere — see `AvatarCropper`.
        .sheet(item: $cropping) { request in
            AvatarCropper(image: request.image,
                          onCancel: { cropping = nil },
                          onDone: { data in
                              cropping = nil
                              Task { await setPicture(data) }
                          })
        }
        .failureAlert($failure)
    }

    /// The face, large, dimmed under a pencil — tapping it offers to change it or remove it.
    private var picture: some View {
        EditableAvatar(name: session.displayName,
                       url: session.avatarURL,
                       seed: session.userID,
                       canRemove: session.avatarURL != nil,
                       onChange: { isChoosingPicture = true },
                       onRemove: { Task { await removePicture() } })
            .disabled(isOffline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.roomy)
    }

    private func rename() async {
        do {
            try await session.rename(to: draftName)
        } catch {
            failure = error
        }
    }

    private func removePicture() async {
        do {
            try await session.removePicture()
        } catch {
            failure = error
        }
    }

    private func choosePicture(_ item: PhotosPickerItem) async {
        pickedPicture = nil

        guard let data = await imageData(from: item), let image = AvatarCrop.image(from: data) else {
            failure = .picture
            return
        }
        cropping = AvatarCropRequest(image: image)
    }

    private func setPicture(_ data: Data) async {
        do {
            try await session.setPicture(data, filename: "avatar.jpg")
        } catch {
            failure = error
        }
    }
}
