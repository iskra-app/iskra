import Testing
import Foundation
import MatrixRustSDK
@testable import IskraCore
@testable import IskraFeatures
import IskraDesign

/// Guards the two ways localization fails silently.
///
/// The first is a missing `bundle:` — inside a Swift package, `LocalizedStringResource`
/// looks in `Bundle.main` by default, finds nothing, and cheerfully returns the key
/// itself. The screen then reads "signIn.title" and everything still compiles.
///
/// The second is a translation that was never written: the catalog falls back to
/// English, and a Russian user sees an English sentence.
@MainActor
struct LocalizationTests {
    /// Every string the app can put on screen. Adding one to `Strings` without adding
    /// it here is fine; adding one without a translation is not, and that is what
    /// these catch.
    private static let englishAndRussian: [(LocalizedStringResource, en: String, ru: String)] = [
        (Strings.SignIn.title, en: "Welcome to Iskra", ru: "Добро пожаловать в Iskra"),
        (Strings.SignIn.whereIsAccount, en: "Where’s your account?", ru: "Где ваш аккаунт?"),
        (Strings.SignIn.continue, en: "Continue", ru: "Продолжить"),
        (Strings.RoomList.title, en: "Chats", ru: "Чаты"),
        (Strings.RoomList.searchPrompt, en: "Search messages", ru: "Поиск по сообщениям"),
        (Strings.RoomList.newChat, en: "New chat", ru: "Новый чат"),
        (Strings.RoomList.newRoom, en: "New room", ru: "Новая комната"),
        (Strings.Room.composerPlaceholder, en: "Message", ru: "Сообщение"),
        (Strings.Room.detailsTitle, en: "About this chat", ru: "О чате"),
        (Strings.Room.administrator, en: "Administrator", ru: "Администратор"),
        (Strings.Room.today, en: "Today", ru: "Сегодня"),
        (Strings.Room.yesterday, en: "Yesterday", ru: "Вчера"),
        (Strings.Message.Menu.copy, en: "Copy", ru: "Скопировать"),
        (Strings.Message.Menu.delete, en: "Delete", ru: "Удалить"),
        // The date is already in the reader's language by the time it gets here — `Date` did
        // that — so what these two are checked for is the word in front of it.
        (Strings.Message.Menu.sentAt("12:03"), en: "Sent 12:03", ru: "Отправлено 12:03"),
        (Strings.Message.Menu.deletedAt("12:03"), en: "Deleted 12:03", ru: "Удалено 12:03"),
        (Strings.Settings.reactions, en: "Reactions", ru: "Реакции"),
        (Strings.Reactions.quick, en: "Quick reaction", ru: "Быстрая реакция"),
        (Strings.Reactions.quickHelp,
         en: "Double-tap a message to leave it.",
         ru: "Двойное касание сообщения ставит эту реакцию."),
        (Strings.VideoNote.flipCamera, en: "Flip camera", ru: "Перевернуть камеру"),
        (Strings.Message.Media.close, en: "Close", ru: "Закрыть"),
        (Strings.Message.Media.loadFailed, en: "The video would not load", ru: "Видео не загрузилось"),
        (Strings.Message.Delivery.read, en: "Read", ru: "Прочитано"),
        (Strings.Message.Delivery.sendAgain, en: "Send again", ru: "Отправить заново"),
        (Strings.Message.Delivery.discard, en: "Delete", ru: "Удалить"),
        (Strings.Settings.title, en: "Settings", ru: "Настройки"),
        (Strings.Account.signOut, en: "Sign out", ru: "Выйти"),
        (Strings.Message.Menu.reply, en: "Reply", ru: "Ответить"),
        (Strings.Message.Menu.edit, en: "Edit", ru: "Изменить"),
        (Strings.Message.Menu.pin, en: "Pin", ru: "Закрепить"),
        (Strings.Message.Menu.unpin, en: "Unpin", ru: "Открепить"),
        (Strings.Message.edited, en: "edited", ru: "изменено"),
        (Strings.Room.replyingTo, en: "Reply", ru: "Ответ"),
        (Strings.Room.editingMessage, en: "Editing", ru: "Изменение сообщения"),
        (Strings.Room.pinned, en: "Pinned", ru: "Закреплённое"),
        (Strings.Room.pinnedTitle, en: "Pinned messages", ru: "Закреплённые"),
        (Strings.Room.Manage.invite, en: "Invite", ru: "Пригласить"),
        (Strings.Room.Manage.remove, en: "Remove", ru: "Исключить"),
        (Strings.Room.Manage.block, en: "Block", ru: "Заблокировать"),
        (Strings.Room.Manage.member, en: "Member", ru: "Участник"),
        (Strings.Room.Manage.openToAnyone, en: "Open chat", ru: "Открытый чат"),
        (Strings.Room.Manage.leave, en: "Leave the chat", ru: "Выйти из чата"),
        // The one act on this screen that asks first, and it asks by name — so the name has
        // to survive the trip through the format string in both languages.
        (Strings.Room.Manage.blockQuestion("Аня"), en: "Block Аня?", ru: "Заблокировать Аня?"),
        (Strings.RoomList.New.create, en: "Create", ru: "Создать"),
        (Strings.RoomList.New.start, en: "Start", ru: "Начать"),
        (Strings.Room.Manage.alerts, en: "Notifications", ru: "Уведомления"),
        (Strings.Room.Manage.alerts(.muted), en: "Off", ru: "Выключены"),
        (Strings.Room.Manage.alerts(.mentions), en: "Mentions only", ru: "Только упоминания"),
        (Strings.Account.namePlaceholder, en: "Your name", ru: "Ваше имя"),
        (Strings.Account.changePicture, en: "Change picture", ru: "Изменить фото"),
        (Strings.Settings.encryption, en: "Encryption", ru: "Шифрование"),
        (Strings.Encryption.protect, en: "Protect my messages", ru: "Защитить переписку"),
        (Strings.Encryption.restore, en: "Bring my messages back", ru: "Восстановить переписку"),
        (Strings.Encryption.saveKey, en: "Save your key", ru: "Сохраните ключ"),
        (Strings.Encryption.thisDevice, en: "This device", ru: "Это устройство"),
        (Strings.RoomList.Invite.accept, en: "Join", ru: "Войти"),
        (Strings.RoomList.Invite.decline, en: "Decline", ru: "Отклонить"),
        (Strings.RoomList.Invite.unattributed, en: "You have been invited", ru: "Вас приглашают в чат"),
        // Who asked, and — in Russian — without a guess at their gender. "Приглашает" is the same
        // word whoever is doing the inviting; Matrix does not know, and a coin flip on every name
        // in every room is exactly how an interface starts reading as machine-translated.
        (Strings.RoomList.Invite.from("Аня"), en: "Аня invites you", ru: "Аня приглашает вас"),
        (Strings.Room.jumpToNewest, en: "New messages", ru: "Новые сообщения"),
        // Same rule again, and the reason both of these exist rather than one: in a one-to-one chat
        // the person's name is already the title of the screen, so saying it a second time here
        // would be the app repeating itself.
        (Strings.Room.typing, en: "typing…", ru: "печатает…"),
        (Strings.Room.typingBy("Аня"), en: "Аня is typing…", ru: "Аня печатает…")
    ]

    @Test("app strings resolve in English and in Russian")
    func appStringsAreTranslated() {
        for (resource, english, russian) in Self.englishAndRussian {
            var resource = resource

            resource.locale = Locale(identifier: "en")
            #expect(String(localized: resource) == english)

            resource.locale = Locale(identifier: "ru")
            #expect(String(localized: resource) == russian)
        }
    }

    @Test("core strings resolve in English and in Russian")
    func coreStringsAreTranslated() {
        var protected = CoreStrings.Privacy.protected

        protected.locale = Locale(identifier: "en")
        #expect(String(localized: protected).contains("Only people in this chat"))

        protected.locale = Locale(identifier: "ru")
        #expect(String(localized: protected).contains("только участники чата"))
    }

    /// Every reason a message can be stuck has to be a sentence in both languages. A
    /// missing one would surface as the badge's popover reading "sendFailure.server",
    /// which is exactly the failure `noStringLeaksItsKey` exists to catch — so the
    /// reasons are put through the same test, from the model's own side.
    @Test("every send failure explains itself in both languages")
    func sendFailuresAreTranslated() {
        // `allCases`, so a reason added later without a sentence fails here rather than
        // showing "sendFailure.whatever" to whoever hits it first.
        for failure in SendFailure.allCases {
            for language in ["en", "ru"] {
                var explanation = failure.explanation
                explanation.locale = Locale(identifier: language)
                let sentence = String(localized: explanation)

                #expect(!sentence.hasPrefix("sendFailure."), "\(sentence) is a key, not a sentence")
                #expect(sentence.count > 10, "\(failure) says too little to act on")
            }
        }

        var russian = SendFailure.verificationRequired.explanation
        russian.locale = Locale(identifier: "ru")
        #expect(String(localized: russian).contains("Подтвердите это устройство"))
    }

    /// The same, from the account's side. Driven from `allCases`, so a failure added to
    /// `AccountActionFailure` without a sentence fails here rather than surfacing as an
    /// alert that says "account.newKeyFailed".
    ///
    /// The recovery-key failure is the one checked by name: it is the only one on that
    /// screen the user can do anything about, and what makes it actionable is that it says
    /// *how* — so a translation that shortened it to "that didn't work" would pass every
    /// other assertion here and take the point out.
    @Test("every account failure explains itself in both languages")
    func accountFailuresAreTranslated() {
        for failure in AccountActionFailure.allCases {
            for language in ["en", "ru"] {
                var explanation = failure.explanation
                explanation.locale = Locale(identifier: language)
                let sentence = String(localized: explanation)

                #expect(!sentence.hasPrefix("account."), "\(sentence) is a key, not a sentence")
                #expect(sentence.count > 10, "\(failure) says too little to act on")
            }
        }

        var russian = AccountActionFailure.restore.explanation
        russian.locale = Locale(identifier: "ru")
        #expect(String(localized: russian).contains("скопировали его целиком"))
    }

    /// Every accent the user can choose has a name in both languages.
    ///
    /// Driven from `allCases`, so a colour added to the palette without a word for it fails
    /// here rather than shipping as a swatch VoiceOver reads out as "appearance.color.teal".
    /// A swatch is the one control with nothing on it to read: the name is all it has.
    @Test("every accent colour is named in both languages")
    func accentColoursAreNamed() {
        for theme in AccentTheme.allCases {
            for language in ["en", "ru"] {
                var name = Strings.Appearance.color(theme)
                name.locale = Locale(identifier: language)
                let word = String(localized: name)

                #expect(!word.hasPrefix("appearance."), "\(word) is a key, not a name")
            }
        }

        var mono = Strings.Appearance.color(.mono)
        mono.locale = Locale(identifier: "ru")
        #expect(String(localized: mono) == "Чёрно-белый")
    }

    /// The button is offered exactly where pressing it can achieve something. A lost file
    /// and a rejected file type never come back, so a retry there would spin and fail on
    /// the same thing — and the SDK's `isRecoverable` cannot be used to decide this: it
    /// reports a homeserver rejection as unrecoverable, which is the one failure most
    /// worth trying again.
    @Test("send again is offered only where it can work")
    func retryIsOfferedHonestly() {
        #expect(SendFailure.server.canRetry)
        #expect(SendFailure.verificationRequired.canRetry)
        #expect(SendFailure.insecureDevices.canRetry)
        #expect(SendFailure.identityChanged.canRetry)

        #expect(!SendFailure.missingMedia.canRetry)
        #expect(!SendFailure.unsupportedFileType.canRetry)
    }

    /// The failure this is really guarding against: a string that resolves to its own
    /// key because the bundle was wrong. That looks fine to the compiler and awful on
    /// screen.
    ///
    /// A leaked key is a dotted identifier — "message.menu.copy" — and what tells it apart
    /// from a sentence is not the dot but the *absence of a space*. The rule used to be the
    /// dot alone, which quietly meant no string in this table could end in a full stop: the
    /// first properly punctuated sentence added to it failed the test and looked, for a
    /// minute, like a bundle that was wrong.
    @Test("no string resolves to its own key")
    func noStringLeaksItsKey() {
        for (resource, _, _) in Self.englishAndRussian {
            let resolved = String(localized: resource)
            let looksLikeAKey = resolved.contains(".") && !resolved.contains(" ")
            #expect(!looksLikeAKey, "\(resolved) looks like a key, not a sentence")
        }
    }

    /// The bundle must actually ship both languages.
    ///
    /// Note what this cannot catch: the app *bundle* also has to declare
    /// `CFBundleLocalizations` in its Info.plist. Without that the system treats the
    /// app as English-only, `Locale.current` never becomes Russian, and these
    /// translations are never reached — even though every test here passes, because
    /// the tests set the locale by hand. That declaration lives in Apps/project.yml.
    @Test("both languages ship in the bundle")
    func bothLanguagesArePresent() {
        let localizations = Set(Strings.resourceBundle.localizations)
        #expect(localizations.contains("en"))
        #expect(localizations.contains("ru"))
    }

    /// Russian has one/few/many where English has one/other. A count of 2 and a count
    /// of 5 must not read the same.
    @Test("Russian plurals decline")
    func russianPluralsDecline() {
        func unread(_ count: Int) -> String {
            var resource = Strings.RoomList.unread(count)
            resource.locale = Locale(identifier: "ru")
            return String(localized: resource)
        }

        #expect(unread(1) == "1 непрочитанное")
        #expect(unread(2) == "2 непрочитанных")
        #expect(unread(5) == "5 непрочитанных")
    }

    /// The header above a conversation counts people, and Russian declines them: one
    /// участник, two участника, five участников. Getting this wrong is the single most
    /// visible way a Russian interface reads as machine-translated, and it is on the
    /// screen the user looks at most.
    @Test("the participant count declines in Russian")
    func participantCountDeclines() {
        func participants(_ count: Int, _ language: String) -> String {
            var resource = Strings.Room.participants(count)
            resource.locale = Locale(identifier: language)
            return String(localized: resource)
        }

        #expect(participants(1, "ru") == "1 участник")
        #expect(participants(2, "ru") == "2 участника")
        #expect(participants(5, "ru") == "5 участников")
        #expect(participants(12, "ru") == "12 участников")

        #expect(participants(1, "en") == "1 participant")
        #expect(participants(12, "en") == "12 participants")
    }

    /// A reaction is read out as the emoji and the people behind it, and that count
    /// declines too. It also takes *two* arguments through the plural rules — the emoji
    /// and the number — which is the part that silently breaks: get the positional
    /// specifiers wrong in the `.stringsdict` and this comes back as the format string.
    @Test("a reaction reads as its emoji and a declined count of people")
    func reactionCountDeclines() {
        func reaction(_ key: String, _ count: Int, _ language: String) -> String {
            var resource = Strings.Message.Menu.reaction(key, count)
            resource.locale = Locale(identifier: language)
            return String(localized: resource)
        }

        #expect(reaction("👍", 1, "ru") == "👍, 1 человек")
        #expect(reaction("👍", 3, "ru") == "👍, 3 человека")
        #expect(reaction("👍", 7, "ru") == "👍, 7 человек")

        #expect(reaction("👍", 1, "en") == "👍, 1 person")
        #expect(reaction("👍", 7, "en") == "👍, 7 people")
    }

    /// "Delete" is offered only where it can actually take a message back.
    ///
    /// A message still in the send queue has no event on the server to redact, and one
    /// that failed is undone by the red badge beside it — offering a delete for either
    /// would be a menu item that quietly does nothing, which is the failure mode this
    /// whole app is written against.
    @Test("delete is offered only on your own messages that actually landed")
    func deleteIsOfferedHonestly() {
        func message(isOwn: Bool, delivery: DeliveryStatus?, kind: MessageKind = .text("hi")) -> Message {
            Message(id: "1",
                    kind: kind,
                    senderID: "@me:matrix.org",
                    senderName: "Me",
                    senderAvatarURL: nil,
                    isOwn: isOwn,
                    timestamp: .now,
                    delivery: delivery,
                    isEdited: false,
                    reactions: [])
        }

        #expect(message(isOwn: true, delivery: .sent).canDelete)
        #expect(message(isOwn: true, delivery: .read).canDelete)

        // Someone else's message is not ours to take back.
        #expect(!message(isOwn: false, delivery: nil).canDelete)
        // Still in the queue: there is no event to redact yet.
        #expect(!message(isOwn: true, delivery: .sending).canDelete)
        #expect(!message(isOwn: true, delivery: .failed(.server)).canDelete)
        // Already gone.
        #expect(!message(isOwn: true, delivery: .sent, kind: .deleted).canDelete)
    }

    /// Editing is offered on your own *words* and nothing else.
    ///
    /// The case worth pinning is the photograph. Matrix can edit a picture's caption, and this
    /// app puts no captions on pictures — so an "Edit" on a photo would open the composer on an
    /// empty string and, on being sent, replace a caption that was never there. The rule that
    /// prevents it is `editableText`, and it is the same property that fills the box, which is
    /// what keeps the two from drifting apart.
    @Test("editing is offered only on your own text, and only once it has landed")
    func editingIsOfferedHonestly() {
        func message(isOwn: Bool, delivery: DeliveryStatus?, kind: MessageKind = .text("hi")) -> Message {
            Message(id: "1",
                    kind: kind,
                    senderID: "@me:matrix.org",
                    senderName: "Me",
                    senderAvatarURL: nil,
                    isOwn: isOwn,
                    timestamp: .now,
                    delivery: delivery,
                    isEdited: false,
                    reactions: [])
        }

        #expect(message(isOwn: true, delivery: .sent).canEdit)
        #expect(message(isOwn: true, delivery: .read).canEdit)

        // Not somebody else's words.
        #expect(!message(isOwn: false, delivery: nil).canEdit)
        // Not one still in the queue: an edit points at an event, and there is none yet.
        #expect(!message(isOwn: true, delivery: .sending).canEdit)
        // Not a photograph, which has no text to change.
        let photo = try? MessageKind.image(Attachment(source: MediaSource.fromUrl(url: "mxc://x/y"),
                                                      thumbnailSource: nil,
                                                      filename: "cat.jpg",
                                                      caption: nil,
                                                      width: 100,
                                                      height: 100,
                                                      duration: nil,
                                                      mimeType: "image/jpeg",
                                                      blurhash: nil))
        #expect(photo != nil)
        if let photo {
            #expect(!message(isOwn: true, delivery: .sent, kind: photo).canEdit)
        }
        // Not one that is gone.
        #expect(!message(isOwn: true, delivery: .sent, kind: .deleted).canEdit)
    }

    /// A reaction on a message that has been taken back is the one this app must refuse.
    ///
    /// Matrix would take it: a reaction is an event pointing at an event, and the server does
    /// not mind that the target is a tombstone. The result is an emoji hanging under the words
    /// "message deleted", visible to the whole room, and nothing but this rule prevents it —
    /// which is why the rule lives on `Message`, is asked by the menu, by the double tap, and
    /// again by `TimelineStore.toggleReaction` on the way out.
    @Test("a deleted message cannot be reacted to, and neither can one still in the queue")
    func reactionsAreOfferedHonestly() {
        func message(isOwn: Bool, delivery: DeliveryStatus?, kind: MessageKind = .text("hi")) -> Message {
            Message(id: "1",
                    kind: kind,
                    senderID: "@me:matrix.org",
                    senderName: "Me",
                    senderAvatarURL: nil,
                    isOwn: isOwn,
                    timestamp: .now,
                    delivery: delivery,
                    isEdited: false,
                    reactions: [])
        }

        // Someone else's: it is on the server by definition, so it can be reacted to.
        #expect(message(isOwn: false, delivery: nil).canReact)
        #expect(message(isOwn: true, delivery: .sent).canReact)
        #expect(message(isOwn: true, delivery: .read).canReact)

        // Gone. This is the one that matters.
        #expect(!message(isOwn: false, delivery: nil, kind: .deleted).canReact)
        #expect(!message(isOwn: true, delivery: .sent, kind: .deleted).canReact)

        // Not sent yet: a reaction names an event ID, and this message has none.
        #expect(!message(isOwn: true, delivery: .sending).canReact)
        #expect(!message(isOwn: true, delivery: .failed(.server)).canReact)
    }
}
