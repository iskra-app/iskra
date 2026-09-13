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
                if isOffline {
                    Text(Strings.Account.editOffline)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(Text(Strings.Account.editTitle))
        .toolbarTitleDisplayMode(.inline)
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
            Task { await setPicture(item) }
        }
        .failureAlert($failure)
    }

    /// The face, large, with the two things that can be done to it written under it in words.
    ///
    /// Buttons rather than a menu on the picture. On the profile screen the picture is something
    /// to look at and the menu was a trap; here the whole screen is the edit, so the choices can
    /// simply be visible instead of hidden behind a press nobody is told about.
    private var picture: some View {
        VStack(spacing: Theme.Spacing.normal) {
            Avatar(name: session.displayName,
                   url: session.avatarURL,
                   size: Theme.Size.avatarProfile)

            VStack(spacing: Theme.Spacing.close) {
                Button {
                    isChoosingPicture = true
                } label: {
                    Text(Strings.Account.changePicture)
                }
                .disabled(isOffline)

                if session.avatarURL != nil {
                    Button(role: .destructive) {
                        Task { await removePicture() }
                    } label: {
                        Text(Strings.Account.removePicture)
                    }
                    .disabled(isOffline)
                }
            }
            .font(.callout)
        }
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

    private func setPicture(_ item: PhotosPickerItem) async {
        pickedPicture = nil

        guard let data = await imageData(from: item) else {
            failure = .picture
            return
        }

        do {
            try await session.setPicture(data, filename: "avatar.jpg")
        } catch {
            failure = error
        }
    }
}
