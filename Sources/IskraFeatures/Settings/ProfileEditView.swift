import SwiftUI
import PhotosUI
import IskraCore
import IskraDesign

/// Your picture and your name, on a screen that exists to change them.
///
/// Pushed from the pencil in the corner of `SettingsView`, and pushed rather than presented:
/// the back chevron and the swipe are then the system's, exactly as everywhere else in this app.
///
/// The name is sent only on purpose: with the Save button, or with Return in the field. Losing
/// focus or leaving the screen sends nothing, because a new name is an event in every shared chat
/// and a stray tap should not be able to announce it. An empty name is never sent; the field goes
/// back to the current one instead of looking saved.
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
                    .submitLabel(.done)
                    .onSubmit { Task { await save() } }
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
                Text(verbatim: session.userID)
                    .foregroundStyle(.secondary)
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    Text(Strings.Account.save)
                }
                .disabled(!canSave)
            }
        }
        // At the root of the screen, never inside the menu that asks for it: a `PhotosPicker`
        // declared inside a `Menu` simply never appears.
        .photosPicker(isPresented: $isChoosingPicture, selection: $pickedPicture, matching: .images)
        .onChange(of: pickedPicture) { _, item in
            guard let item else { return }
            Task { await choosePicture(item) }
        }
        // Cut to a square before it goes anywhere — see `AvatarCropper`.
        .pageSheet(item: $cropping) { request in
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

    private var trimmedName: String { draftName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canSave: Bool {
        !isOffline && !trimmedName.isEmpty && trimmedName != session.displayName
    }

    /// Return in the field and the toolbar button both end here. An empty name cannot be sent, so
    /// the field takes the current name back instead of staying empty and looking saved.
    private func save() async {
        isNaming = false
        guard !trimmedName.isEmpty else {
            draftName = session.displayName
            return
        }
        await rename()
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
