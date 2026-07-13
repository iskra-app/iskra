# ROADMAP

Путь Iskra до MVP. Этот файл — рабочий: закрыли пункт → поставили галочку здесь же, в том же
коммите. `CLAUDE.md` ссылается сюда, поэтому роудмап попадает в контекст каждой новой сессии.

Порядок этапов — «сначала дожать чат»: то, чего касаешься каждый день, и что целиком строится
на уже готовом `TimelineStore`.

Номера строк вида «(17249)» — это `matrix_sdk_ffi.swift` в
`.build/xcode-device/SourcePackages/checkouts/matrix-rust-components-swift/Sources/MatrixRustSDK/`.
Они сдвинутся при обновлении SDK; имя функции важнее номера.

## Где мы сейчас

| Фича | Статус |
|---|---|
| Сообщения: приём, отправка, реакции, удаление, повтор неудачной отправки | готово — `TimelineStore.swift` |
| Список комнат | готово — `RoomListStore`, `RoomListView` |
| Поиск по сообщениям (локальный зашифрованный индекс) | готово — `SearchStore`, `RoomSearchField` |
| SSO: OAuth и legacy | готово — `AuthenticationService` |
| Вложения: отправка фото, видео, файла, голосового | API готово — `TimelineStore+Media.swift` |
| «Кружочки»: запись, кроп в квадрат, отправка, круглый рендер | готово — `VideoNote.swift`, `VideoNoteRecorder` |
| Удалённые сообщения | готово — `MessageKind.deleted` |
| Редактирование | готово — `TimelineStore.edit`, пометка «изменено» в `MessageRow` |
| Голосовые | готово — `VoiceRecorder`, `AudioPlayback` |
| Настройки комнаты | правится: имя, тема, фото, приватность, участники, выход — `RoomDetailsStore` |
| Настройки аккаунта | оболочка: профиль, акцент, быстрая реакция, выход |
| Ответы, закрепление, служебные события | готово — этап 1 |
| Просмотрщик медиа, файлы, шаринг | готово — этап 2 (`MediaViewer`, `FileOpener`) |
| Геопозиция | готово — `Location`, `LocationPicker`, `LocationBubble` |
| Пуши | нет вовсе |

Аватарки теперь грузятся: `Avatar` (`IskraFeatures/Support/Avatar.swift`) тянет картинку через
`MediaLoader.avatar(url:size:)` и кэширует её в памяти на время сессии.

## Этап 1 — Чат целиком

- [x] **Ответы.** `Timeline.sendReply(msg:eventId:)` (17249). В `Message` — поле
      `replyTo: ReplyPreview?` (отправитель + однострочная выжимка из `MsgLikeContent.inReplyTo`).
      В `TimelineStore` — `send(text:replyingTo:)`. В UI: пункт меню в `MessageRow.menu`,
      полоска-цитата над `MessageComposer`, цитата внутри пузыря. Вложения тоже умеют отвечать —
      у `UploadParameters` уже есть `inReplyTo`, сейчас везде `nil`.
- [x] **Редактирование.** `Timeline.edit(eventOrTransactionId:newContent:)` (16858) с
      `EditedContent.roomMessage`. Переиспользовать `eventOrTransactionID(for:)`. Показать
      «изменено» в `MessageRow` — флаг уже есть, просто не рисуется. Только свои сообщения.
- [x] **Закрепление.** `Timeline.pinEvent/unpinEvent(eventId:)` (17083/17344) плюс отдельный
      таймлайн с `TimelineFocus.pinnedEvents` для экрана «Закреплённые». Плашка с закреплённым
      сверху комнаты.
- [x] **Служебные события.** `TimelineMapper.kind(from:)` сейчас возвращает `nil` для всего, что
      не `.msgLike`, — поэтому вступления и смены имени пропадают. Добавить в `TimelineRow` случай
      `.event(TimelineEvent)` и разобрать `TimelineItemContent.roomMembership` (вход, выход, бан,
      приглашение), `.profileChange` (имя и аватар), `.state` (тема, название). Одна серая строка
      по центру; соседние однотипные схлопываются («Аня и ещё двое вошли»).
- [x] **Аватарки.** Научить `Avatar` грузить картинку через `MediaLoader`
      (`EnvironmentValues.mediaLoader` уже проброшен), с инициалами как заглушкой.

Файлы: `IskraCore/Timeline/{Message,TimelineMapper,TimelineStore}.swift`,
`IskraFeatures/Rooms/{MessageRow,MessageComposer,RoomView}.swift`, `IskraDesign/Avatar`.

## Этап 2 — Просмотрщик медиа

Сделано. Всё держится на `MediaLoader.file(for:)` → `MediaFile`: один расшифрованный файл на
диске отдаёт и `AVPlayer`, и `ShareLink`, и запись в галерею, и живёт ровно столько, сколько
открыт экран. Закрыли — плейнтекст с диска исчез.

- [x] `MediaViewer` в `IskraFeatures`: полноэкранный, зум и панорама для фото, `VideoPlayer` для
      видео, свайп вниз чтобы закрыть, `ShareLink`, сохранение в галерею.
- [x] Воспроизведение «кружочков» — по месту, в круге, по тапу (как в Telegram), не полноэкранно.
- [x] Голосовые: `AVAudioPlayer` и бегунок по уже нарисованной волне в `VoiceMessageView`.
- [x] Файлы: QuickLook (`QLPreviewController`) на iOS, `NSWorkspace` на Mac.

## Этап 3 — «Кружочки»: камера и жест

- [x] **Фронтальная камера по умолчанию.** `VideoNoteRecorder.prepare()` берёт
      `AVCaptureDevice.default(for: .video)` — это основная камера. Должно быть
      `AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)` с откатом
      на заднюю, если фронтальной нет (Mac без камеры — редкая, но реальная конфигурация).
- [x] **Переворот камеры.** Кнопка в углу превью: `session.beginConfiguration()`, снять старый
      `AVCaptureDeviceInput`, добавить новый, `commitConfiguration()`. Разрешён и во время записи —
      `AVCaptureMovieFileOutput` это переживает. Хранить `position` в рекордере, чтобы превью и
      экспорт знали, что зеркалить: **фронтальное превью зеркалится, записанный файл — нет.**
      Иначе собеседник увидит вас в зеркале, а текст на футболке — задом наперёд.
- [x] **Hold-to-talk из композера.** Внутри листа записи жест уже есть
      (`VideoNoteComposer.swift`: `LongPressGesture` запускает запись, отпускание отправляет).
      Чего нет — того же жеста на кнопке в самом `MessageComposer`: сейчас тап открывает лист, и
      зажимать надо уже там, то есть движений два вместо одного. Свести к одному: зажал кнопку →
      лист открылся и запись сразу пошла → отпустил → отправилось. Свайп в сторону — отмена,
      свайп вверх — фиксация записи «без рук».

Тот же словарь жестов, что у голосовых в этапе 4, и это не совпадение: их стоит делать рядом.

## Этап 4 — Недостающие способы отправки

- [x] **Запись голосового.** `AVAudioRecorder` (m4a/AAC), съём уровня → волна из 128 точек,
      hold-to-talk на кнопке в `MessageComposer`, отмена свайпом. Отправка уже написана:
      `TimelineStore.send(voice:duration:waveform:)`.
- [x] **Геопозиция.**
      `Timeline.sendLocation(body:geoUri:description:zoomLevel:assetType:repliedToEventId:)` (17191).
      Выбор точки на `Map` (MapKit) плюс «моё местоположение» (CoreLocation — нужен ключ в
      `Info.plist`, то есть в `Apps/project.yml`). Новый `MessageKind.location(...)`, пузырь —
      статичная карта. `MessagePreview` уже умеет `.location`.

## Этап 5 — Настройки комнаты и права

Всё есть в SDK на `Room`: `setName` (8971), `setTopic` (8993), `uploadAvatar` (9125),
`inviteUserById` (8691), `kickUser` (8734), `banUser` (8561), `leave` (8745),
`updatePowerLevelsForUsers` (9103).

- [x] `RoomDetailsStore` из read-only становится редактируемым: имя, тема, аватар, приватность.
      Поля правятся на месте, без режима «Редактировать»: что видно — то и меняется. Права
      берутся у самой комнаты (`Room.getPowerLevels`), а не выводятся из своего бейджа.
- [x] Участники: пригласить, исключить, забанить, сменить роль — по своему power level.
      Недоступное скрыто, а не выключено. Правило «кого можно тронуть» — строго ниже себя и
      никогда себя; у создателя комнаты (room v12) power level бесконечный, поэтому `Authority`
      это enum, а не `Int`. Всё это в `RoomManagementTests`.
- [x] Выход из комнаты. Выбор сбрасывается наверху (`IskraRootView`), иначе на iPhone
      остаёшься в комнате, из которой уже вышел.
- [ ] Создание комнаты и диалога — `Client.createRoom` (899). В `RoomListView` под это уже стоят
      две пустые кнопки с `// TODO`.
- [ ] Уведомления комнаты — `Client.getNotificationSettings` (1006): выключить, все, только
      упоминания.

## Этап 6 — Настройки аккаунта и сессии

- [ ] Профиль: имя (`Client.setDisplayName`, 1347) и аватар (`Client.uploadAvatar`, 1477).
- [ ] Шифрование: состояние верификации и ключ восстановления (`Encryption.recoveryState`,
      `resetRecoveryKey`, `recover(recoveryKey:)` — 4440/4450/4423). Без этого история не читается
      на новом устройстве, так что для MVP это не украшение.
- [ ] **Список сессий — сначала проверить, возможен ли он вообще.** В FFI нет `Client.devices()`.
      Есть `Client.getUrl(url:)` (1058) — вопрос, ходит ли он в `GET /_matrix/client/v3/devices`
      под токеном клиента. Это проверка на десять минут: дёрнуть и посмотреть, 200 там или 401.
      Удаление чужой сессии требует User-Interactive Auth и через FFI не выражается вовсе.
      Если авторизации в `getUrl` нет — честно сузить MVP до «эта сессия и выход» и записать
      причину сюда же, а не изобретать свой HTTP-клиент поверх чужого токена.

## Этап 7 — Пуш-уведомления

Самый длинный этап, и единственный, который упирается не в код.

- [ ] **Сначала push gateway, потом всё остальное.** APNs-ключ у Apple-аккаунта есть, но
      homeserver шлёт пуши не в APNs напрямую, а через шлюз (Sygnal). Публичный шлюз matrix.org
      принимает только зарегистрированные app id — элементовские. Под `moscow.swag.iskra` придётся
      поднять свой Sygnal со своим ключом. Это отдельная, не-Swift задача, и весь код этапа от неё
      зависит: **не начинать, пока шлюз не отвечает.**
- [ ] Регистрация: `Client.setPusher(identifiers:kind:...)` (1367) с токеном из
      `registerForRemoteNotifications`.
- [ ] Notification Service Extension: новый таргет в `Apps/project.yml`. App Group и Keychain
      access group у него те же — ровно то, что уже доказано `Iskra --verify-storage`. Внутри:
      `Client.notificationClient(processSetup:)` (1176) → `NotificationItem`, чтобы расшифровать
      событие и показать настоящий текст вместо «новое сообщение».

Тонкое место: расширение пишет в тот же зашифрованный store, что и приложение. Отсюда весь
`AppEnvironment.StorageMode.shared` и запрет тихого отката на собственный контейнер — это
писалось под этот этап.

## Что легко нарушить по дороге

Подробности — в `CLAUDE.md`; здесь только напоминание, потому что каждый этап это задевает.

- Любая новая строка — в `Strings.swift` и во все четыре `.strings`/`.stringsdict`, иначе
  `LocalizationTests` падает. **Русский пишется первым, английский — вторым.**
- Размеры и отступы — только из `Theme`. Стекло — только в навигационном слое.
- `IskraCore` не знает про SwiftUI, `IskraDesign` не знает про Matrix.
- Никогда не `CODE_SIGNING_ALLOWED=NO`.
- В «кружочках» не заводить кастомных полей события: `uploadMedia` + `sendRaw` не шифрует, и в
  зашифрованной комнате это выложит лицо пользователя на сервер открытым текстом.

Каждый этап проверяется в подписанном приложении, а не только тестами — как это делается, описано
в `CLAUDE.md`. Пуши проверяются только на устройстве: в симуляторе APNs нет.
