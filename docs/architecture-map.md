# Карта архитектуры Iskra

Составлена в ходе аудита 2026-07-13 (фаза «разведка»). Сравнение с element-x-ios — в конце файла.

## Состояние на 2026-09-29 (третий проход)

Этот раздел заменяет устаревшие части ниже. **Неверно теперь:** «~18.5 тыс. строк, ~100 файлов»
(сейчас ~50.8 тыс. строк в 231 файле Sources+Apps, 9.2 тыс. строк тестов в 64 файлах, ~4.3 тыс.
строк Rust в `Bridge/`); «сеть — целиком Rust SDK, ни одного URLSession» (`DirectUpstream` и
`NostrRelayPool` — URLSession/WebSocket за `LocalHTTPProxy`); «в Swift ноль криптопримитивов»
(NIP-44 для туннеля: блок ChaCha20 свой, HKDF/HMAC — CryptoKit, secp256k1 — libsecp256k1;
**Matrix**-крипта по-прежнему только SDK); однопользовательский раздел Session; «Осталось: Sygnal,
setPusher» (сделано); таблица сравнения с element-x (C1, H3, H4, H5, M7 закрыты, SAS есть); раздел
про незакоммиченную работу.

**Таргеты.**
- SPM: `IskraCore` (MatrixRustSDK 26.06.06 + secp256k1; без SwiftUI) · `IskraDesign` (только
  SwiftUI, без зависимостей) · `IskraFeatures` (оба). Тесты: `IskraCoreTests`, `IskraDesignTests`
  (золотая фикстура blobatar), `IskraFeaturesTests`.
- Xcode (`Apps/project.yml` → xcodegen): Iskra (iOS) встраивает `IskraNotificationService`
  (IskraCore + IskraDesign) и `IskraShareExtension` (IskraCore); Iskra (macOS) — без расширений.
  `Apps/Shared`: `IskraApp`, `PushDelegate`, `IskraAppIntents`, `PushFace` (в обоих бандлах),
  DEBUG-пробы.
- `Bridge/` — Rust workspace (`iskra-bridge`, `iskra-tunnel-proto`, `iskra-tunnel-probe`),
  Docker/GHCR: серверная половина Matrix-over-nostr.

**Точки входа.**
- Приложение: `IskraApp.init` → `SDKLogging.start` (+ DEBUG-пробы `--verify-storage`,
  `--probe-signin/-devices/-bridge/-notification/-icons`) → `IskraRootView` (машина фаз
  starting/signedOut/offline/settingUp/decorating/signedIn; restore, переключение аккаунтов, демо,
  reconnect по `TunnelSettings.changed`).
- Флаги (в релизе тоже): `--mock-backend` (`MockHomeserver`), `--mock-signin [password|sso|closed|slow]`.
- NSE: `NotificationService.didReceive` → `PushDecoder` (restoreClient →
  `notificationClient(.multipleProcesses)` → `getNotification`, бюджет 20 с) → `PushMapper` /
  `MessagePreview` → `CommunicationNotification` + `PushFace`.
- Share extension: `ShareViewController` → outbox `ChatDirectory` (App Group) → приложение
  отправляет при открытии (`UserSession.send(_:toRoomID:)` → `TimelineStore` → `MediaPreparation`).
- App Intents: OpenChat / SendMessage поверх `ChatDirectory` (без клиента в процессе интента).

**Где что живёт.**
- FFI — только `IskraCore`. `UserSession` владеет `Client`; сторы (`RoomListStore`,
  `TimelineStore`, `PinnedStore`, `RoomDetailsStore`, `SpaceStore`, `SearchStore`/`RoomSearchStore`,
  `BlockStore`, `VerificationStore`, `RecoveryStore`, `NotificationRulesStore`, `StorageStore`)
  проецируют диффы SDK в value-типы.
- Сессии и секреты: `AuthenticationService` (actor; единственный `makeClientBuilder`: зашифрованный
  SQLite + поисковый индекс, `SessionDelegate` на клиент, autoEnable backups/cross-signing,
  cross-process lock, sliding sync discoverNative→native), `SessionStore` (Keychain по аккаунтам +
  индекс), `AppEnvironment` (`.shared` / `.standalone` / `.scratch`).
- Приватность медиа: `MetadataStripper` (allow-list с перечитыванием) + `VideoTranscoder`, в
  `TimelineStore.send(photo:/video:)`.
- UI: экраны `IskraFeatures`; `IskraDesign` — `Theme`, `Glass`, `PrimaryAction`, Blobatar.

**Цепочка транспорта.**

```
SDK (reqwest) → адрес homeserver'а
  ├─ мост выключен → https://homeserver напрямую
  └─ включён → http://127.0.0.1:<port> = LocalHTTPProxy (переподнимается на том же порту после suspend)
       └─ HTTPUpstream:
            DirectUpstream      (URLSession → homeserver; статус «routingLocally»)
            NostrTunnelUpstream (конверты NIP-44, TunnelChunker/Reassembler,
                                 NostrRelayPool → ≥2 relay) → Bridge → homeserver
            MockHomeserver (демо) / SignInMockServer (вход)
TunnelSettings.persistableHomeserver не пускает loopback в Keychain.
```

**Оговорка:** `TunnelSettings` читает `UserDefaults.standard`, поэтому расширение уведомлений
сейчас ходит напрямую (находка T1).

**Сравнение с element-x-ios (кратко).** Совпадает: один билдер, `setSessionDelegate`,
`.multiProcess` lock, `enableAllSendQueues`, явный первый fetch таймлайна, NSE с
`NotificationClient`. Осознанные упрощения: нет threads, `dmRoomDefinition`,
`enableShareHistoryOnInvite`, MVVM-C. **Пробелы, которые выйдут боком:** нет обработки смены
ключей собеседника (X1); NSE на полном билдере (X2); нет `requestConfig(retryLimit:)` и
`.withSharePos`. Скопированного кода (AGPL) не найдено.

Iskra — нативный Matrix-клиент для iPhone, iPad и Mac: один Swift/SwiftUI-код, вся работа с
протоколом и криптографией — в `matrix-rust-sdk` через UniFFI-биндинги
(`matrix-org/matrix-rust-components-swift`, upstream, **не** форк `element-hq`, потому что
только upstream публикует macOS-слайс XCFramework).

~18.5 тыс. строк Swift, ~100 файлов. Swift 6, strict concurrency = complete,
deployment target iOS 26 / macOS 26.

## Слои и правило зависимостей

```
┌─────────────────────────────────────────────────────────┐
│  Apps/ (шеллы: iOS, macOS, NotificationService)          │
│  bundle, entitlements, probe-диагностика — логики нет    │
└──────────────┬────────────────────────┬─────────────────┘
               │                        │
      IskraFeatures (экраны)      NotificationService.swift
       │                │               │
  IskraDesign      IskraCore ◄──────────┘   (расширение линкует
  (SwiftUI,         (Matrix,                 только IskraCore)
   без Matrix)       без SwiftUI)
                        │
                  MatrixRustSDK (FFI, Rust)
```

| Таргет | Держит | Может импортировать |
|---|---|---|
| `IskraCore` | сессии, секреты, комнаты, таймлайн, поиск, медиа, пуши | `MatrixRustSDK`. **Никогда SwiftUI** |
| `IskraDesign` | пузыри, стекло, отступы, цвет | SwiftUI. **Никогда Matrix** |
| `IskraFeatures` | экраны | оба — единственное место встречи |

SDK-типы не выходят за пределы `IskraCore`: наружу отдаются value-типы
(`Message`, `RoomSummary`, `PushNotification`, …). `Client` держит `UserSession`, и ничего
выше него SDK напрямую не трогает. Одно намеренное исключение:
`Attachment.source: MediaSource` и `MediaFile` (обёртка над `MediaFileHandle`) — SDK-хэндлы,
завёрнутые так, что Features видит только `url`/значения.

## Точки входа

| Вход | Файл | Что происходит |
|---|---|---|
| Приложение | `Apps/Shared/IskraApp.swift` | `SDKLogging.start()` (уровень `.info`, выше нельзя — тела сообщений), затем `IskraRootView` |
| Пуш | `Apps/NotificationService/NotificationService.swift` | `didReceive` → `PushDecoder` → `PushMapper`; content handler вызывается ровно один раз через `Mutex` |
| Диагностика | `Apps/Shared/{StorageCheck,SignInProbe,DeviceProbe,NotificationProbe}.swift` | `--verify-storage`, `--probe-signin`, `--probe-devices`, `--probe-notification` — работают только в подписанной сборке |

`IskraRootView` — конечный автомат `starting → signedOut → signedIn(UserSession)`;
`NavigationSplitView` обслуживает все три платформы.

## IskraCore по подсистемам

### Session — вход и жизненный цикл
- `AuthenticationService` (actor): discovery homeserver'а, OAuth/legacy SSO/пароль,
  restore, sign-out. Все сетевые вызовы ограничены `withTimeout(30 s)`. Единственное место,
  где конфигурируется `ClientBuilder`: зашифрованный SQLite-store (passphrase из Keychain) +
  зашифрованный поисковый индекс + sliding sync `.discoverNative`.
- `UserSession` (@MainActor @Observable): владеет `Client`, раздаёт
  `RoomListStore` / `SearchStore` / `TimelineStore` / `RoomDetailsStore` / `MediaLoader` /
  `RecoveryStore`. Профиль (имя/аватар) — оптимистичные правки с откатом.
- `Account.swift`: `RecoveryStore` — состояние шифрования аккаунта
  (`HistoryProtection`: on/off/keyNeeded), ключ восстановления
  (`enableRecovery(waitForBackupsToUpload: true)`), восстановление по ключу.
- `DeviceListProbe`: доказательство, что списка устройств в FFI нет (`getUrl` без токена).

### Security — секреты
- `Keychain`: data-protection Keychain, `AfterFirstUnlockThisDeviceOnly` (расширению нужно
  читать при заблокированном телефоне; никогда не синкается), `kSecUseDataProtectionKeychain`
  (без него access groups на macOS молча не работают), опциональный `kSecAttrAccessGroup`.
- `SessionStore`: `StoredSession` (userID, deviceID, accessToken, refreshToken, oauthData) —
  JSON в одном Keychain-item; плюс два случайных секрета (32 байта CSPRNG):
  passphrase SQLite-store и ключ поискового индекса. `clear()` — секреты раньше файлов.
- `SecretStoring` — протокол, чтобы тесты жили без Keychain (unsigned-бинарь его не откроет,
  `errSecMissingEntitlement`).

### Support — фундамент
- `AppEnvironment`: `StorageMode.shared(appGroup, keychainGroup)` / `.standalone`.
  Недоступный App Group — **брошенная ошибка, не fallback** (`StorageError.appGroupUnavailable`
  → `AuthenticationError.storageUnavailable` → текст на экране входа).
  App Group `group.moscow.swag.iskra` ≠ Keychain group
  `$(AppIdentifierPrefix)moscow.swag.iskra.shared` — и это обязано быть двумя идентификаторами
  (Team Provisioning Profile разрешает только `<TeamID>.*`).
- `Timeout.swift`: `withTimeout` — гонка через `CheckedContinuation` + `Mutex`, проигравший
  **не** await'ится (task group ждала бы зависший в Rust вызов — это и есть баг, от которого
  защищаемся). Хэндлит вызов из уже отменённой задачи (`pending`-результат).
- `Log`: категории media/rooms/session/push; правило — никакого контента, токенов, имён
  файлов, callback-URL.
- `SDKLogging`: уровень зашит `.info`, параметра нет намеренно.
- `Strings.swift` (CoreStrings) + `Resources/{en,ru}.lproj` — строки модельного слоя.

### Rooms — список и управление
- `RoomListStore` (@MainActor @Observable): sync service + `RoomList.entriesWithDynamicAdapters`
  (pageSize 100, фильтр `.nonLeft`); диффы с Rust-колбэка через `UnsafeTransfer` →
  `Task { @MainActor }`; трейлинг-дебаунс 50 мс (rebuild всегда добегает до конца);
  подписка на send queue (локальное эхо двигает превью); сортировка `byRecency`
  (приглашения сверху); `stop()` гасит поток entries и терпит дифф-опоздавший
  (`hasStopped`). Принять/отклонить приглашение.
- `RoomSummary` — value-снапшот строки списка; `RoomMembership` joined/invited.
- `RoomDetailsStore`: инфо, участники (кэш `membersNoSync` → свежие `members`), права из
  `getPowerLevels` (спрятать, не задизейблить), `Authority` (`.level(Int)`/`.unlimited` —
  создатель room v12 бесконечен), уведомления комнаты через `NotificationSettings`
  (кэшируется — каждая копия несёт своего листенера), rename/topic/аватар/приватность/
  kick/ban/роли/выход. Оптимистично, с откатом и `failure`.
- `RoomCreation` (extension UserSession): DM = `trustedPrivateChat` + шифрование всегда;
  комната: публичная = нешифрованная, приватная = шифрованная (один выбор, не два);
  `awaitRoomRemoteEcho` после создания, всё под таймаутами.
- `MessagePreview` — общий текст превью для списка чатов **и** пушей (одно предложение,
  написанное один раз).

### Timeline — разговор
- `TimelineStore` (@MainActor @Observable, ~1050 строк — сердце приложения):
  - Живой таймлайн начинается **пустым**; история — `paginateBackwards`, не стрим.
    `open()` явно набирает страницы (`fillPages`) до экрана (15 строк, ≤4 страниц).
  - Диффы → `items` → `rebuildRows()` → `rows` (value-типы). Реакции, которые не ушли
    (`UnsentReactions`), вычитаются на каждом ребилде.
  - `refill()`: SDK имеет право выбросить таймлайн (redaction, gappy sync) — старые rows
    держатся на экране, пока новые не догонят (`isRefilling`/`latestRows`).
  - Пагинация: `pageInFlight: Task` — второй вызов ждёт первого, спиннер отдельно.
  - Send/edit/redact/reply/pin через `Timeline`; retry = `enableSendQueue` + `tryResend` +
    возврат unsent-реакций в полёт; discard = `SendHandle.abort()`.
  - Черновики в зашифрованном сторе SDK (`saveComposerDraft`), не в UserDefaults.
  - Typing: первый keystroke шлёт notice, лулл 4 с забирает; `stop()` забирает notice.
  - `stop()` — пауза (переживает push/pop экранов), `start()` поднимает заново.
- `TimelineMapper` — единственное место, знающее `MsgLikeKind`/`EventSendState`:
  сообщения, службные события (пулятся: «Аня и ещё двое вошли»), реплаи, реакции
  (сорт по первому появлению), redaction-дата из raw JSON (`unsigned.redacted_because`),
  delivery (`sending/failed/sent/read`), `QueueWedgeError` → `SendFailure` (человеческий текст).
- `Message.swift` — value-типы + правила `canReact/canDelete/canEdit/canReply`.
- `TimelineStore+Media`: фото — байтами (`UploadSource.data`, плейнтекст не касается диска),
  видео/файл/голос — файлом, `blurhash` обязателен (SDK иначе отказывает), видео-превью
  уезжает парой (байты + `ThumbnailInfo`, иначе SDK молча не шлёт), локация `assetType: .pin`.
- `PinnedStore` — второй таймлайн `TimelineFocus.pinnedEvents`, по требованию.

### Search
- `SearchStore`: локальный зашифрованный индекс (`searchMessages`), запрос не покидает
  устройство; дебаунс 200 мс, отмена в полёте, спиннер гасит только актуальный поиск.

### Media
- `MediaLoader`: `getMediaContent`/`getMediaThumbnail`/`getMediaFile`; в шифрованной комнате
  серверный thumbnail невозможен (сервер держит шифротекст) → превью отправителя, для
  видеонот — первый кадр скачанного файла. `MediaFile` — плейнтекст на диске живёт ровно
  столько, сколько объект (SDK удаляет в deinit). `Equatable` по identity `Client` — иначе
  SwiftUI перерисовывает всё дерево на каждом тике.
- `MediaMetadata` — размеры/длительность/thumbnail/blurhash/наличие звука (AVFoundation).
- `Blurhash` — единственный «свой» алгоритм: DCT→base83 по публичной спецификации woltapp
  (не криптография; SDK требует blurhash, иначе `InvalidAttachmentData`).
- `SquareVideoExporter` — центр-кроп в квадрат 480×480 (видеонота распознаётся формой).
- `VideoNote` — правило распознавания: квадрат + ≤60 с. Кастомного поля нет намеренно:
  `uploadMedia`+`sendRaw` не шифруют вложение.

### Notifications — пуш-пайплайн
- Пуш несёт только `room_id`+`event_id`. `PushDecoder` (actor): restore сессии →
  `notificationClient(processSetup: .multipleProcesses)` (кросс-процессный лок SQLite — app
  может держать тот же файл) → `getNotification` под бюджетом 20 с (из 30, что даёт iOS).
  Никогда не бросает — только `PushOutcome`.
- `PushMapper` — чистая функция → `PushOutcome`: show/silence(filteredOut|redacted|
  notWorthWaking)/notSignedIn/failed. Правило атрибуции: «не называть одно имя дважды»
  (не `isDm` — welcome-комната matrix.org не DM, а имя совпадает).
- `RecentMessage` — для `--probe-notification` без аргументов.
- Осталось (не код): свой Sygnal-шлюз, `setPusher`, проверка `.appex`-entitlements на
  устройстве. См. `docs/PUSH-GATEWAY.md` и ROADMAP этап 7.

## IskraDesign

- `Theme` — все размеры/радиусы/тайминги, кратные 4, углы `.continuous`.
- `Glass.swift` — **нет** общего `.glass()`: только `.navigationGlass()` и
  `.primaryActionGlass(tint:)`. Стекло — навигационный слой; пузыри — непрозрачные заливки.
- `MessageBubble` (BubbleShape/BubbleBackground), `AccentTheme` (выбор цвета, AppStorage),
  `FlowLayout` (реакции).

## IskraFeatures (экраны)

- `IskraRootView` — фазы запуска, split view, выбор комнаты/события.
- `SignIn/` — `SignInModel` (@MainActor @Observable: адрес → `SignInOptions` → SSO через
  `ASWebAuthenticationSession` (callback-URL никогда не логируется) или пароль),
  `SignInView`.
- `Rooms/` — `RoomListView` (список, поиск, «+»), `RoomView` (~1030 строк: скролл-якорь,
  пагинация по скроллу, jump-to-message с подгрузкой, unseen-pill, маркировка прочитанного,
  черновики, запись голоса/видеонот — жизненный цикл рекордеров явно гасится в
  `onDisappear`), `MessageComposer` (стекло, hold-to-record с drag-жестом,
  attach-меню из GlassEffectContainer), `MessageRow` (~1170 строк: пузыри, вложения,
  реакции, контекстное меню, ретрай), `RoomInfoView`, `PinnedMessagesView`,
  `NewConversationView`, `RoomHeader`, `ReplyQuote`, `RoomEventRow`, `RoomSearchField`,
  `RecordingStrip`.
- `Media/` — `MediaViewer` (зум/пан/шаринг/сохранение), `AudioPlayback`, `VideoPlayback`,
  `FileOpener` (QuickLook / NSWorkspace), `LocationView`+`LocationPicker`, `VoiceRecorder`.
- `VideoNote/` — `VideoNoteRecorder` (AVCaptureSession, фронталка по умолчанию, переворот,
  зеркалится только превью), `VideoNoteComposer` (шторка с камерой, hold/lock/cancel).
- `Settings/` — `SettingsView` (профиль на месте, без «Сохранить»), `EncryptionView`
  (ключ восстановления показывается один раз), `AppearanceView`, `QuickReaction(View)`.
- `Support/` — `Avatar` (через `MediaLoader`, кэш на сессию), `Strings.swift` (все строки
  экранов), `FailureAlert` (общий алерт для `ActionFailure`), `Clipboard`, `PickedImage`,
  `MediaThumbnail`, `PlaybackAudio`.

## Локализация

Никаких строк в вью. `Strings.swift` (Features) + `CoreStrings` (Core) →
`Resources/{en,ru}.lproj/Localizable.strings(+stringsdict)`. `.lproj/.strings`, **не**
`.xcstrings` (SwiftPM CLI-сборка не запускает XCStringsTool). `bundle:` на каждом ресурсе
обязателен. `CFBundleLocalizations` в `project.yml`. Русский пишется первым.
Плюрали — в `.stringsdict`. Всё это охраняет `LocalizationTests`.

## Где что (срезы аудита)

| Срез | Где живёт |
|---|---|
| FFI-граница | только `IskraCore` (import MatrixRustSDK); наружу — value-типы |
| Крипто | целиком Rust SDK (Olm/Megolm/attachment AES-CTR); в Swift — ноль криптопримитивов (Blurhash — не крипто) |
| Сеть | целиком Rust SDK; ни одного `URLSession` в продуктовом коде (только `DeviceListProbe` через `client.getUrl` — диагностика) |
| TLS | SDK/системный стек; никаких обходов сертификатов в кодовой базе |
| Секреты | только Keychain (`SessionStore`); сторы и индекс зашифрованы на диске |
| Логи | `Log` + `SDKLogging(.info)`; правило «без контента» задекларировано в обоих |
| Конкурентность | Swift 6 strict complete; сторы @MainActor; Rust-колбэки → `UnsafeTransfer`/Sendable-значения → MainActor-hop; `Mutex` в Timeout/SDKLogging/NotificationService |
| UI-состояние | @Observable-сторы + value-снапшоты; SwiftUI diff'ит дёшево |

## Тесты (Swift Testing)

`IskraCoreTests`: Blurhash, HomeserverDiscovery (in-memory SecretStoring),
Invitation, Location, Push (PushMapper), RoomEvent, RoomManagement (права/Authority),
SDKLinkage, SquareVideoExporter (реальное видео), Timeout (в т.ч. уже-отменённый вызов),
UnsentReactions.
`IskraFeaturesTests`: ComposerLayout и MessageRowLayout (рендер в PNG),
DayDivider, Localization (полнота en/ru, bundle:, плюрали), SignInModel.

Что тестами принципиально не покрывается и проверяется в подписанной сборке:
Keychain/App Group (`--verify-storage`), реальный вход (`--probe-signin`),
расшифровка пуша (`--probe-notification`), пробуждение `.appex` (только реальный пуш).

## Что добавилось последней (незакоммиченной) работой

На момент аудита в дереве лежит незакоммиченная работа, и она уже собирается и проходит тесты:

- `IskraCore/Storage/StorageStore.swift` — сколько места занято и очистка кэша
  (`client.clearCaches(syncService:)`), плюс экран `IskraFeatures/Settings/StorageView.swift`.
- `IskraFeatures/VideoNote/VideoNoteWriter.swift` — запись кружков переехала с
  `AVCaptureMovieFileOutput` на `AVAssetWriter`. Причина записана в ROADMAP: `MovieFileOutput` при
  смене камеры **заканчивает файл**, а не приостанавливает его, и готовый файл приходил в делегат
  неотличимым от того, который пользователь просил отправить, — и отправлялся. Теперь переворот
  камеры — склейка внутри одного кружка.
- `IskraFeatures/Rooms/RecordLock.swift` — «замок» записи без рук.
- `IskraDesign/AppearanceMode.swift` + `IskraFeatures/Support/AppSettings.swift` — тема оформления
  (system/light/dark) и настройки, которые стираются при выходе.
- `Tests/IskraCoreTests/VideoStillTests.swift` — превью видео.

## Сравнение с element-x-ios

Подробности и вердикты по каждой оси — в `docs/audit-report.md`. Коротко:

| Ось | Вердикт |
|---|---|
| Расшифровка пуша (NSE, `NotificationClient`, `.multipleProcesses`, fallback, бюджет) | **соответствует эталону** |
| Очистка при выходе (Keychain → директории), clear cache | **соответствует** |
| Слои, отсутствие своей криптографии, таймауты | **соответствует** |
| `ClientSessionDelegate` (сохранение обновлённого токена) | **отсутствует — critical (C1)** |
| `ClientDelegate.didReceiveAuthError` (аннулированная сессия) | **отсутствует — high (H4)** |
| `autoEnableBackups` / `autoEnableCrossSigning` | **отсутствуют — high (H5)** |
| `crossProcessLockConfig` (ротация токена в двух процессах) | **отсутствует — medium (M7)** |
| SyncService: пауза в фоне, рестарт после ошибки | **отсутствует — medium (M8)** |
| Интерактивная верификация (SAS), шилды, `pinUserIdentity` | отсутствует — осознанное упрощение MVP, **но** интерфейс на неё ссылается (H1, H2) |
| Регистрация пушей (`requestAuthorization`, `setPusher`, badge, тап) | **отсутствует — high (H3)**; ROADMAP ошибочно относит это к инфраструктуре |
| MVVM-C, DI-контейнер, Compound DS | осознанно не нужны — Iskra минималистична |

**Копирования кода нет.** Проверено построчным пересечением нормализованных строк (все совпадения —
общие идиомы SwiftUI/Foundation и сигнатуры, продиктованные FFI) и шинглами из пяти подряд идущих
строк (совпали только цепочки закрывающих скобок). Заявление `CLAUDE.md` подтверждается.
