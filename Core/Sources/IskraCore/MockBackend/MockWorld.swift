// Debug only: the demo is for looking at screens during development, and a release build carries
// none of it — no server to switch on, no flag to start it by. See CLAUDE.md, "The demo server".
#if DEBUG
import Foundation

/// What the demo server starts out holding: the people, the conversations, the pictures.
///
/// Written to put every kind of thing the app draws on screen at least once — a reply, an edit,
/// reactions, a deleted message, a photo, a voice message, a file, a location, a poll, a mention,
/// formatted text, a pinned message, a space, an invitation, a room with enough history to scroll
/// through, a person with no picture — so that a screen which cannot draw one of them shows it.
///
/// In Russian, because the app is written Russian-first and this is what it looks like to the
/// people it is written for.
struct MockWorld {
    typealias JSON = [String: Any]
    typealias Room = MockHomeserver.Room

    static let server = MockHomeserver.serverName
    static func user(_ name: String) -> String { "@\(name):\(server)" }

    let me = user("sasha")
    var rooms: [String: Room] = [:]
    var profiles: [String: MockHomeserver.Profile] = [:]
    var accountData: [String: JSON] = [:]
    var media: [String: (data: Data, mime: String)] = [:]
    var publicRoomIDs: [String] = []

    /// The demo's stickers, drawn once and pointed at from the packs and the conversations alike —
    /// as image entries in the MSC2545 shape, by name.
    private var stickers: [StickerArt: JSON] = [:]

    private let now = Int(Date().timeIntervalSince1970 * 1000)
    private var counter = 0

    // People. Some have a picture and some do not, because both are drawn differently.
    private var anya: String { Self.user("anya") }
    private var misha: String { Self.user("misha") }
    private var mama: String { Self.user("mama") }
    private var papa: String { Self.user("papa") }
    private var lena: String { Self.user("lena") }
    private var dima: String { Self.user("dima") }
    private var olga: String { Self.user("olga") }
    private var kostya: String { Self.user("kostya") }

    init() {
        person(me, "Саша", hue: 0.58)
        person(anya, "Аня Смирнова", hue: 0.95)
        person(misha, "Миша", hue: nil)
        person(mama, "Мама", hue: 0.08)
        person(papa, "Папа", hue: nil)
        person(lena, "Лена Котова", hue: 0.75)
        person(dima, "Дима", hue: nil)
        person(olga, "Ольга", hue: 0.45)
        person(kostya, "Костя Орлов", hue: 0.3)
        drawStickers()

        let anyaChat = directWithAnya()
        let mishaChat = directWithMisha()
        let lenaChat = directWithLena()
        family()
        development()
        workSpace()
        notes()
        bookClubInvitation()
        swiftCommunity()

        accountData["m.direct"] = [anya: [anyaChat], misha: [mishaChat], lena: [lenaChat]]
        accountData["m.push_rules"] = Self.pushRules(for: me)
        // Four of the eight are the account's own; the other four are the development room's,
        // so that a sticker *not* yet yours turns up in a chat and can be added.
        accountData["im.ponies.user_emotes"] = ["images": pack([.hello, .love, .joy, .sleepy])]
        // Two folders, so the tabs over the list have something to show — see `ChatFolder`.
        accountData[ChatFolders.type] = ["folders": [
            ["id": "demo-personal", "name": "Личные", "kinds": ["direct"], "onlyUnread": false,
             "excludesMuted": false, "includesArchived": false, "included": [], "excluded": []],
            ["id": "demo-unread", "name": "Непрочитанные", "kinds": ["direct", "groups"], "onlyUnread": true,
             "excludesMuted": true, "includesArchived": false, "included": [], "excluded": []],
        ]]
    }

    // MARK: - Conversations

    private mutating func directWithAnya() -> String {
        let room = makeRoom("anya", members: [me, anya], admins: [me, anya], minutesAgo: 60 * 24 * 3)
        at(room, 60 * 24 * 3 - 1)
        text(room, anya, "Привет! Ты завтра свободна вечером?")
        text(room, me, "Привет) Да, после семи — вполне")
        let plan = text(room, anya, "Отлично. Давай в «Жан-Жак» на Никитском? Там сейчас тихо по будням")
        react(room, plan, me, "👍")

        at(room, 60 * 24 * 2)
        image(room, anya, "набережная.png", hue: 0.55)
        text(room, anya, "Смотри, какой вчера был закат")
        let wow = text(room, me, "Ого, красота какая. Это где?")
        reply(room, anya, to: wow, "На Крымской набережной, у Музеона")
        react(room, wow, anya, "❤️")

        at(room, 60 * 5)
        let typo = text(room, me, "Я буду минут через дядцать")
        edit(room, me, typo, "Я буду минут через двадцать")
        let secret = text(room, anya, "Ок, я уже тут, взяла нам столик у окна")
        redact(room, secret, by: anya)
        location(room, anya, "Я здесь", lat: 55.7575, lon: 37.5979)
        voice(room, anya)
        let file = self.file(room, me, "список-на-выходные.txt",
                             "— купить подарок Мише\n— забрать книги у Лены\n— позвонить маме\n")
        react(room, file, anya, "🙏")
        at(room, 12)
        text(room, anya, "😂")
        sticker(room, anya, .love)
        let long = text(room, anya, """
            Кстати, дочитала ту книгу, что ты советовала. Первая половина прямо тяжело шла, я даже \
            хотела бросить, но потом как разогналось — не могла оторваться до трёх ночи. \
            Особенно глава про маяк. Давай в субботу обсудим?
            """)
        react(room, long, me, "🔥")
        react(room, long, me, "❤️")
        at(room, 3)
        formatted(room, anya, "Не забудь **зонт** — обещали дождь",
                  "Не забудь <b>зонт</b> — обещали <i>дождь</i>")
        text(room, anya, "И захвати, пожалуйста, зарядку 🙌")
        read(room, me, upToIndex: 2)
        return room
    }

    private mutating func directWithMisha() -> String {
        let room = makeRoom("misha", members: [me, misha], admins: [me, misha], minutesAgo: 60 * 24 * 10)
        at(room, 60 * 24 * 10 - 5)
        text(room, me, "Миш, с днём рождения! 🎉")
        text(room, misha, "Спасибо!!")
        at(room, 40)
        text(room, misha, "Слушай")
        text(room, misha, "А ты не помнишь, как называлась та игра, в которую мы играли у Димы?")
        text(room, misha, "Там ещё надо было угадывать слова по картинкам")
        text(room, misha, "Кажется «Имаджинариум», но не уверен")
        at(room, 25)
        text(room, misha, "Ладно, нашёл, это «Диксит» 😅")
        sticker(room, misha, .surprise)
        read(room, me, upToIndex: 3)
        return room
    }

    private mutating func directWithLena() -> String {
        let room = makeRoom("lena", members: [me, lena], admins: [me, lena], minutesAgo: 60 * 24 * 40)
        at(room, 60 * 24 * 40 - 10)
        text(room, lena, "Саш, я верну книги на следующей неделе, ладно?")
        text(room, me, "Конечно, не торопись")
        at(room, 60 * 24 * 21)
        text(room, lena, "Спасибо ещё раз за «Шантарам», это было что-то")
        rooms[room]?.accountData["m.tag"] = ["tags": ["m.lowpriority": ["order": 0.5]]]
        return room
    }

    private mutating func family() {
        let room = makeRoom("family", members: [me, mama, papa], admins: [mama],
                            name: "Семья 🏡", topic: "Дача, дни рождения и кто что купил", avatarHue: 0.1,
                            minutesAgo: 60 * 24 * 60)
        at(room, 60 * 24 * 60 - 1)
        text(room, mama, "Всем привет! Сделала нам общий чат")
        let pinned = text(room, mama, "Код от калитки на даче: 2580. Не теряйте!")
        text(room, papa, "Принято")
        at(room, 60 * 24 * 6)
        // An album — three photos a second apart, the caption on the first, as this app sends one.
        let harvest = image(room, papa, "грядка.png", hue: 0.24, width: 800, height: 1200, caption: "Первые кабачки в этом году")
        image(room, papa, "урожай.png", hue: 0.28)
        image(room, papa, "кабачки.png", hue: 0.32)
        react(room, pinned, papa, "👌")
        // Threads: one under the album, and a fresh one near the bottom — the line "N answers"
        // under a message, and a thread to open. See `TimelineStore.threadRootID`.
        inThread(room, mama, under: harvest, "Какие красивые! Оставь мне пару штук")
        inThread(room, papa, under: harvest, "Конечно, в воскресенье привезу")
        at(room, 60 * 3)
        let trip = text(room, mama, "Что везти на дачу в субботу? Пишите сюда, в тред")
        inThread(room, papa, under: trip, "Удобрения и лейку, старая потекла")
        inThread(room, mama, under: trip, "И семена укропа")
        inThread(room, me, under: trip, "Я возьму мангал")
        at(room, 60 * 2)
        text(room, mama, "Саша, ты в воскресенье приедешь?")
        mention(room, mama, name: "Саша", "Саша, ответь маме 🙂")
        state(room, mama, "m.room.pinned_events", ["pinned": [pinned]])
        read(room, me, upToIndex: 5)
    }

    private mutating func development() {
        let room = makeRoom("iskra-dev", members: [me, lena, dima, anya, misha, kostya], admins: [me],
                            name: "Искра — разработка", topic: "Клиент Matrix для iPhone, iPad и Mac",
                            avatarHue: 0.02, minutesAgo: 60 * 24 * 30)

        // Enough history to scroll a long way back and watch it arrive a page at a time.
        let chatter = [
            (dima, "Собрал ветку со звонками, у кого есть минутка проверить?"),
            (lena, "Могу вечером"),
            (kostya, "Я посмотрю утром, сегодня уже не успею"),
            (misha, "А macOS-сборка сейчас зелёная?"),
            (dima, "Да, после вчерашнего фикса всё собирается"),
            (me, "Отлично, спасибо!"),
            (lena, "Кто-нибудь знает, почему симулятор стал так долго загружаться?"),
            (kostya, "Попробуй удалить DerivedData, мне помогло"),
            (anya, "Нарисовала новые иконки, закинула в фигму"),
            (me, "Шикарно получилось 😍"),
        ]
        at(room, 60 * 24 * 30 - 5)
        for day in 0..<14 {
            for (offset, line) in chatter.enumerated() {
                let (who, what) = line
                at(room, 60 * 24 * (29 - day) - offset * 7)
                text(room, who, what)
            }
        }

        at(room, 60 * 26)
        state(room, kostya, "m.room.member", memberContent(kostya, name: "Костя"), key: kostya)
        let code = formatted(room, dima, """
            Вот так теперь выглядит запуск:
            ```
            ./device.sh --here --no-launch
            ```
            """, """
            <p>Вот так теперь выглядит запуск:</p><pre><code>./device.sh --here --no-launch</code></pre>
            """)
        react(room, code, lena, "🚀")
        react(room, code, me, "🚀")
        react(room, code, kostya, "👀")
        // A thread: the question in the room, the answers under it — see `TimelineStore.threadRootID`.
        let release = text(room, misha, "Что делаем с пушами на macOS — откладываем до следующего релиза?")
        inThread(room, dima, under: release, "Я бы отложил, там ещё entitlements разбирать")
        inThread(room, lena, under: release, "Согласна, iOS важнее")
        inThread(room, misha, under: release, "Ок, тогда переношу задачу")
        let call = poll(room, lena, "Когда созвонимся на неделе?", ["Во вторник", "В среду", "В четверг"])
        vote(room, dima, in: call, ["a1"])
        vote(room, kostya, in: call, ["a0"])
        at(room, 60 * 3)
        formatted(room, kostya, "Список на релиз:\n1. Иконки\n2. Демо-режим\n3. Перевод",
                  "<p>Список на релиз:</p><ol><li>Иконки</li><li>Демо-режим</li><li>Перевод</li></ol>")
        formatted(room, lena, "> Сначала сделай, потом сделай красиво\nА чем кончится сериал — спойлер",
                  "<blockquote><p>Сначала сделай, потом сделай <u>красиво</u></p></blockquote>"
                      + "<p>А чем кончится сериал — <span data-mx-spoiler>все выживут</span></p>")
        let question = mention(room, dima, name: "Саша", "Саша, глянешь мой PR? Там немного, честно")
        reply(room, lena, to: question, "Я уже посмотрела, там всё хорошо 👍")
        text(room, anya, "Ссылка на макеты: https://matrix.org")
        state(room, me, "im.ponies.room_emotes", [
            "pack": ["display_name": "Искра", "usage": ["sticker"]],
            "images": pack([.connected, .unlocked, .surprise, .bypass]),
        ])
        sticker(room, kostya, .connected)

        rooms[room]?.accountData["m.tag"] = ["tags": ["m.favourite": ["order": 0.1]]]
        read(room, me, upToIndex: (rooms[room]?.events.count ?? 5) - 5)
    }

    private mutating func workSpace() {
        let general = makeRoom("work-general", members: [me, kostya, dima, olga], admins: [olga],
                               name: "Общий", topic: "Всё про работу", minutesAgo: 60 * 24 * 90)
        at(general, 60 * 8)
        text(general, olga, "Коллеги, напоминаю: в пятницу выходим на час раньше 🎉")
        text(general, dima, "Ура!")

        let offtop = makeRoom("work-offtop", members: [kostya, dima, olga], admins: [olga],
                              name: "Офтоп", topic: "Котики, мемы и обеды", joinRule: "public",
                              minutesAgo: 60 * 24 * 90)
        at(offtop, 60 * 30)
        text(offtop, kostya, "Кто на обед в 13:00?")
        text(offtop, dima, "Я!")

        let space = makeRoom("work", members: [me, kostya, dima, olga], admins: [olga],
                             name: "Работа", topic: "Пространство команды", avatarHue: 0.62,
                             isSpace: true, minutesAgo: 60 * 24 * 90)
        for child in [general, offtop] {
            state(space, olga, "m.space.child", ["via": [Self.server]], key: child)
            state(child, olga, "m.space.parent", ["via": [Self.server], "canonical": true], key: space)
        }
        publicRoomIDs.append(offtop)
    }

    private mutating func notes() {
        let room = makeRoom("notes", members: [me], admins: [me], name: "Заметки",
                            topic: "Только для себя", minutesAgo: 60 * 24 * 14)
        at(room, 60 * 24 * 14 - 1)
        text(room, me, "Идеи подарков: плед, настолка, термос")
        text(room, me, "Пароль от вайфая на даче — на холодильнике")
        at(room, 60 * 24 * 4)
        image(room, me, "скриншот.png", hue: 0.8)
    }

    private mutating func bookClubInvitation() {
        let room = makeRoom("books", members: [olga, lena], admins: [olga], name: "Книжный клуб 📚",
                            topic: "Читаем по книге в месяц", avatarHue: 0.35, minutesAgo: 60 * 24 * 5)
        at(room, 60 * 24 * 5 - 1)
        text(room, olga, "В этом месяце читаем «Лавра» Водолазкина")
        at(room, 50)
        var content = memberContent(me, name: "Саша")
        content["membership"] = "invite"
        state(room, olga, "m.room.member", content, key: me)
    }

    private mutating func swiftCommunity() {
        let room = makeRoom("swift", members: [kostya, misha, anya], admins: [kostya], name: "Swift по-русски",
                            topic: "Открытое сообщество", avatarHue: 0.05, joinRule: "public",
                            minutesAgo: 60 * 24 * 200)
        at(room, 60 * 24 * 2)
        text(room, kostya, "Кто уже попробовал новые макросы в Swift 7?")
        text(room, misha, "Я, очень удобно для тестов")
        publicRoomIDs.append(room)
    }

    // MARK: - Building blocks

    /// The minute events are being written at, per room, counting back from now.
    private var clock: [String: Int] = [:]

    private mutating func at(_ room: String, _ minutesAgo: Int) {
        clock[room] = now - minutesAgo * 60_000
    }

    private mutating func makeRoom(_ slug: String, members: [String], admins: [String], name: String? = nil,
                                   topic: String? = nil, avatarHue: Double? = nil, isSpace: Bool = false,
                                   joinRule: String = "invite", minutesAgo: Int) -> String {
        let id = "!\(slug):\(Self.server)"
        rooms[id] = Room(id: id)
        at(id, minutesAgo)
        let creator = admins.first ?? members[0]
        var create: JSON = ["room_version": "11", "creator": creator]
        if isSpace { create["type"] = "m.space" }
        state(id, creator, "m.room.create", create)
        for member in members {
            state(id, member, "m.room.member", memberContent(member), key: member)
        }
        state(id, creator, "m.room.power_levels", Self.powerLevels(admins: admins))
        state(id, creator, "m.room.join_rules", ["join_rule": joinRule])
        state(id, creator, "m.room.history_visibility", ["history_visibility": "shared"])
        if let name { state(id, creator, "m.room.name", ["name": name]) }
        if let topic { state(id, creator, "m.room.topic", ["topic": topic]) }
        if let avatarHue {
            state(id, creator, "m.room.avatar", ["url": store(MockMedia.avatar(hue: avatarHue), mime: "image/png")])
        }
        return id
    }

    @discardableResult
    private mutating func event(_ room: String, _ sender: String, _ type: String, _ content: JSON,
                                key: String? = nil, extra: JSON = [:]) -> String {
        counter += 1
        let slug = room.dropFirst().prefix { $0 != ":" }
        let id = "$\(slug)-\(counter)"
        let ts = (clock[room] ?? now) + 1_000
        clock[room] = min(ts, now)
        var event: JSON = ["event_id": id, "type": type, "sender": sender, "room_id": room,
                           "origin_server_ts": ts, "content": content, "unsigned": [:] as JSON]
        if let key { event["state_key"] = key }
        for (name, value) in extra { event[name] = value }
        rooms[room]?.events.append(event)
        if let key { rooms[room]?.state["\(type)\u{0}\(key)"] = event }
        // A person has read what they wrote.
        rooms[room]?.receipts[sender] = (id, ts)
        return id
    }

    @discardableResult
    private mutating func state(_ room: String, _ sender: String, _ type: String, _ content: JSON,
                                key: String = "") -> String {
        event(room, sender, type, content, key: key)
    }

    @discardableResult
    private mutating func text(_ room: String, _ sender: String, _ body: String) -> String {
        event(room, sender, "m.room.message", ["msgtype": "m.text", "body": body])
    }

    @discardableResult
    private mutating func formatted(_ room: String, _ sender: String, _ body: String, _ html: String) -> String {
        event(room, sender, "m.room.message", ["msgtype": "m.text", "body": body,
                                               "format": "org.matrix.custom.html", "formatted_body": html])
    }

    @discardableResult
    private mutating func mention(_ room: String, _ sender: String, name: String, _ body: String) -> String {
        let link = "<a href=\"https://matrix.to/#/\(me)\">\(name)</a>"
        return event(room, sender, "m.room.message", [
            "msgtype": "m.text", "body": body, "format": "org.matrix.custom.html",
            "formatted_body": body.replacingOccurrences(of: name, with: link, options: .anchored),
            "m.mentions": ["user_ids": [me]],
        ])
    }

    @discardableResult
    private mutating func reply(_ room: String, _ sender: String, to target: String, _ body: String) -> String {
        event(room, sender, "m.room.message", ["msgtype": "m.text", "body": body,
                                               "m.relates_to": ["m.in_reply_to": ["event_id": target]]])
    }

    /// An answer in the thread under `root` — with the reply fallback older clients read.
    @discardableResult
    private mutating func inThread(_ room: String, _ sender: String, under root: String, _ body: String) -> String {
        let id = event(room, sender, "m.room.message", ["msgtype": "m.text", "body": body,
                                                        "m.relates_to": ["rel_type": "m.thread", "event_id": root,
                                                                         "is_falling_back": true,
                                                                         "m.in_reply_to": ["event_id": root]]])
        // What a real server bundles onto the root (`unsigned.m.relations.m.thread`): how many answers,
        // the newest, and whether the reader is among those who answered. The room's timeline reads
        // its "3 answers" from this.
        if let events = rooms[room]?.events,
           let rootIndex = events.firstIndex(where: { $0["event_id"] as? String == root }),
           let latest = events.last(where: { $0["event_id"] as? String == id }) {
            var unsigned = events[rootIndex]["unsigned"] as? JSON ?? [:]
            var relations = unsigned["m.relations"] as? JSON ?? [:]
            let previous = relations["m.thread"] as? JSON
            let count = (previous?["count"] as? Int ?? 0) + 1
            let participated = (previous?["current_user_participated"] as? Bool ?? false) || sender == me
            relations["m.thread"] = ["latest_event": latest, "count": count, "current_user_participated": participated]
            unsigned["m.relations"] = relations
            rooms[room]?.events[rootIndex]["unsigned"] = unsigned
        }
        return id
    }

    private mutating func edit(_ room: String, _ sender: String, _ target: String, _ body: String) {
        event(room, sender, "m.room.message", [
            "msgtype": "m.text", "body": "* \(body)",
            "m.new_content": ["msgtype": "m.text", "body": body],
            "m.relates_to": ["rel_type": "m.replace", "event_id": target],
        ])
    }

    private mutating func react(_ room: String, _ target: String, _ sender: String, _ key: String) {
        event(room, sender, "m.reaction", ["m.relates_to": ["rel_type": "m.annotation", "event_id": target, "key": key]])
    }

    private mutating func redact(_ room: String, _ target: String, by sender: String) {
        if let index = rooms[room]?.events.firstIndex(where: { $0["event_id"] as? String == target }) {
            rooms[room]?.events[index]["content"] = [:] as JSON
            rooms[room]?.events[index]["unsigned"] = ["redacted_because": ["type": "m.room.redaction",
                                                                           "sender": sender,
                                                                           "content": ["redacts": target]]]
        }
        event(room, sender, "m.room.redaction", ["redacts": target], extra: ["redacts": target])
    }

    @discardableResult
    private mutating func image(_ room: String, _ sender: String, _ name: String, hue: Double,
                                width: Int = 1200, height: Int = 800, caption: String? = nil) -> String {
        let data = MockMedia.photo(hue: hue, width: width, height: height)
        // A caption is the body, with the file's name moved to `filename` — the way Matrix tells a
        // caption from a name.
        var content: JSON = [
            "msgtype": "m.image", "body": caption ?? name, "url": store(data, mime: "image/png"),
            "info": ["mimetype": "image/png", "w": width, "h": height, "size": data.count],
        ]
        if caption != nil { content["filename"] = name }
        return event(room, sender, "m.room.message", content)
    }

    private mutating func voice(_ room: String, _ sender: String) {
        let (data, waveform) = MockMedia.voice()
        event(room, sender, "m.room.message", [
            "msgtype": "m.audio", "body": "Голосовое сообщение", "url": store(data, mime: "audio/wav"),
            "info": ["mimetype": "audio/wav", "duration": 4_000, "size": data.count],
            "org.matrix.msc1767.audio": ["duration": 4_000, "waveform": waveform],
            "org.matrix.msc3245.voice": [:] as JSON,
        ])
    }

    @discardableResult
    private mutating func file(_ room: String, _ sender: String, _ name: String, _ contents: String) -> String {
        let data = Data(contents.utf8)
        return event(room, sender, "m.room.message", [
            "msgtype": "m.file", "body": name, "url": store(data, mime: "text/plain"),
            "info": ["mimetype": "text/plain", "size": data.count],
        ])
    }

    private mutating func location(_ room: String, _ sender: String, _ body: String, lat: Double, lon: Double) {
        let uri = "geo:\(lat),\(lon)"
        event(room, sender, "m.room.message", ["msgtype": "m.location", "body": body, "geo_uri": uri,
                                               "org.matrix.msc3488.location": ["uri": uri]])
    }

    @discardableResult
    private mutating func poll(_ room: String, _ sender: String, _ question: String, _ answers: [String]) -> String {
        let options = answers.enumerated().map { ["id": "a\($0.offset)", "org.matrix.msc1767.text": $0.element] }
        return event(room, sender, "org.matrix.msc3381.poll.start", [
            "org.matrix.msc3381.poll.start": [
                "question": ["org.matrix.msc1767.text": question],
                "kind": "org.matrix.msc3381.poll.disclosed",
                "max_selections": 1,
                "answers": options,
            ],
            "org.matrix.msc1767.text": question,
        ])
    }

    private mutating func vote(_ room: String, _ sender: String, in poll: String, _ answers: [String]) {
        event(room, sender, "org.matrix.msc3381.poll.response", [
            "m.relates_to": ["rel_type": "m.reference", "event_id": poll],
            "org.matrix.msc3381.poll.response": ["answers": answers],
        ])
    }

    private mutating func drawStickers() {
        for art in StickerArt.allCases {
            let data = art.png()
            stickers[art] = ["url": store(data, mime: "image/png"), "body": art.emoji,
                             "info": ["w": StickerArt.side, "h": StickerArt.side, "mimetype": "image/png",
                                      "size": data.count]]
        }
    }

    /// Image entries by shortcode, for a pack's `images`.
    private func pack(_ arts: [StickerArt]) -> JSON {
        var images: JSON = [:]
        for art in arts { images[art.rawValue] = stickers[art] }
        return images
    }

    private mutating func sticker(_ room: String, _ sender: String, _ art: StickerArt) {
        guard let image = stickers[art] else { return }
        event(room, sender, "m.sticker", ["body": image["body"] ?? "", "url": image["url"] ?? "",
                                          "info": image["info"] ?? [:]])
    }

    /// Marks the room read up to the `index`-th message event, so that what comes after is unread.
    private mutating func read(_ room: String, _ user: String, upToIndex index: Int) {
        let messages = rooms[room]?.events.filter { $0["type"] as? String == "m.room.message" } ?? []
        guard messages.indices.contains(index), let id = messages[index]["event_id"] as? String else { return }
        rooms[room]?.receipts[user] = (id, messages[index]["origin_server_ts"] as? Int ?? now)
    }

    private mutating func person(_ user: String, _ name: String, hue: Double?) {
        profiles[user] = .init(name: name, avatar: hue.map { store(MockMedia.avatar(hue: $0), mime: "image/png") })
    }

    private func memberContent(_ user: String, name: String? = nil) -> JSON {
        var content: JSON = ["membership": "join", "displayname": name ?? profiles[user]?.name ?? user]
        if let avatar = profiles[user]?.avatar { content["avatar_url"] = avatar }
        return content
    }

    private mutating func store(_ data: Data, mime: String) -> String {
        counter += 1
        let id = "seed\(counter)"
        media[id] = (data, mime)
        return "mxc://\(Self.server)/\(id)"
    }

    // MARK: - Shared shapes

    static let replies = [
        "Ага, поняла 👌", "Звучит отлично!", "Ха-ха, точно", "Давай так и сделаем",
        "Секунду, сейчас посмотрю", "Спасибо!", "😄", "Договорились 🤝",
    ]

    static func powerLevels(admins: [String]) -> JSON {
        var users: JSON = [:]
        for admin in admins { users[admin] = 100 }
        return ["users": users, "users_default": 0, "events_default": 0, "state_default": 50,
                "ban": 50, "kick": 50, "redact": 50, "invite": 0,
                "events": ["m.room.name": 50, "m.room.avatar": 50, "m.room.topic": 50,
                           "m.room.pinned_events": 50, "m.room.power_levels": 100]]
    }

    /// The server-default push rules, as the spec lists them — the SDK's notification settings
    /// read and rewrite exactly these.
    static func pushRules(for user: String) -> JSON {
        let notify: [Any] = ["notify"]
        let sound: [Any] = ["notify", ["set_tweak": "sound", "value": "default"]]
        let highlight: [Any] = ["notify", ["set_tweak": "sound", "value": "default"], ["set_tweak": "highlight"]]
        func event(_ key: String, _ pattern: String) -> JSON { ["kind": "event_match", "key": key, "pattern": pattern] }
        func rule(_ id: String, _ actions: [Any], _ conditions: [JSON], enabled: Bool = true) -> JSON {
            ["rule_id": ".m.rule.\(id)", "default": true, "enabled": enabled, "actions": actions, "conditions": conditions]
        }
        let localpart = String(user.dropFirst().prefix { $0 != ":" })
        return ["global": [
            "override": [
                rule("master", [], [], enabled: false),
                rule("suppress_notices", [], [event("content.msgtype", "m.notice")]),
                rule("invite_for_me", sound, [event("type", "m.room.member"), event("content.membership", "invite"),
                                              event("state_key", user)]),
                rule("member_event", [], [event("type", "m.room.member")]),
                rule("is_user_mention", highlight, [["kind": "event_property_contains",
                                                     "key": "content.m\\.mentions.user_ids", "value": user]]),
                rule("is_room_mention", highlight, [["kind": "event_property_is", "key": "content.m\\.mentions.room",
                                                     "value": true],
                                                    ["kind": "sender_notification_permission", "key": "room"]]),
                rule("tombstone", highlight, [event("type", "m.room.tombstone"), event("state_key", "")]),
                rule("reaction", [], [event("type", "m.reaction")]),
                rule("suppress_edits", [], [["kind": "event_property_is", "key": "content.m\\.relates_to.rel_type",
                                             "value": "m.replace"]]),
            ],
            "content": [
                ["rule_id": ".m.rule.contains_user_name", "default": true, "enabled": true,
                 "pattern": localpart, "actions": highlight],
            ],
            "room": [], "sender": [],
            "underride": [
                rule("call", ["notify", ["set_tweak": "sound", "value": "ring"]], [event("type", "m.call.invite")]),
                rule("encrypted_room_one_to_one", sound, [["kind": "room_member_count", "is": "2"],
                                                          event("type", "m.room.encrypted")]),
                rule("room_one_to_one", sound, [["kind": "room_member_count", "is": "2"],
                                                event("type", "m.room.message")]),
                rule("message", notify, [event("type", "m.room.message")]),
                rule("encrypted", notify, [event("type", "m.room.encrypted")]),
            ],
        ]]
    }
}
#endif
