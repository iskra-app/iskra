# Аудит экрана беседы Iskra (Rooms/, Media/, VideoNote/)

Метод: чтение кода, без запуска. Все пути относительно `Sources/`. Числа контраста приблизительные (по значениям системных цветов iOS); где вывод требует проверки на устройстве, это помечено.

Общее впечатление: экран дисциплинированный. Размеры в основном из Theme, стекло только в навигационном слое, у голосовой кнопки продуманы действия VoiceOver, у кнопки сбоя отправки зона нажатия расширена до 44pt. Дефекты ниже в основном про контраст акцентных цветов, про VoiceOver в «составных» сообщениях и про зоны нажатия мелких элементов.

---

## High

### CH-01 High. Белый текст на светлых акцентах и акцентный текст на светлых пузырях
- Файлы: `IskraDesign/AccentTheme.swift:62-75` (`foreground`), `:166-179` (`onBubbleColor`), `:40-52` (`color`); потребители: `IskraFeatures/Rooms/MessageContent.swift:327` (ссылки), `Rooms/ThreadLine.swift:31`, `Rooms/MessageRow.swift:412` (счётчик реакции).
- Что не так: исключение сделано только для жёлтого (`.yellow` даёт чёрный). Для оранжевого, зелёного, голубого (cyan) и красного пузырь заливается системным цветом, а текст остаётся белым. Приблизительный контраст белого: orange около 2,2:1, green около 2,2:1 (в тёмной теме цвет светлее, хуже), cyan около 2,6:1, red около 3,6:1. Норма для текста 4,5:1. Обратная сторона: `accent.color` как цвет текста на `incomingBubble` и странице в светлой теме (ссылки, упоминания, «N ответов» в ThreadLine, полоска цитаты). Жёлтый на почти белом около 1,5:1.
- Почему важно: чтение и письмо главная задача экрана. Тело собственных сообщений плохо читается на трёх-четырёх из семи акцентов.
- Исправление: ввести в `AccentTheme` пару «заливка пузыря / чернила» с проверкой контраста. Для orange/green/cyan чернила чёрные (или затемнённая заливка пузыря). Для акцентного текста на нейтральном фоне добавить `AccentTheme.text(in:)` с затемнённым вариантом для yellow/orange/green/cyan и использовать его вместо `accent.color` в ссылках, ThreadLine, упоминаниях. Добавить тест расчёта контраста для всех акцентов в обеих схемах.

### CH-02 High. Упоминания в своём пузыре красятся акцентом поверх акцентной заливки
- Файл: `Rooms/MessageContent.swift:356-364` (`:357`).
- Что не так: `paintedBody` для любого упоминания ставит `foregroundColor = accent.color`, не глядя на `style`. Для ссылок учтено (`linkColor`, строка 327: в своём пузыре `onBubbleColor`). В своём сообщении «@Аня, привет» имя окрашено в цвет самого пузыря и пропадает (на mono читается, на шести цветных нет). Подложка `accent.opacity(0.16)` для упоминания себя на своём пузыре не видна.
- Исправление: `foregroundColor = style == .own ? accent.onBubbleColor : accent.color`, плюс вес `.semibold` и подчёркивание (как у ссылок). Подложка для own: `onBubbleColor.opacity(0.2)`.

### CH-03 High. Опрос и геопозиция недоступны для VoiceOver
- Файлы: `Rooms/MessageSpoken.swift:73-78` (`hasPressableContent`), `Rooms/MessageRow.swift:162-172`, `Rooms/CompactMessageRow.swift:213`; `Rooms/PollBubble.swift:60-85`; `Media/LocationView.swift:36-39`.
- Что не так: `hasPressableContent` перечисляет `.voice, .audio, .image, .video, .videoNote, .file`. `.poll` и `.location` в списке нет, поэтому строка схлопывается в один элемент с `accessibilityLabel(message.spokenLabel)`. Кнопки ответов опроса (`Button` в `PollBubble.row`) проглочены, проголосовать нельзя: слышно «Аня: опрос, вопрос» и всё. У `LocationBubble` нажатие сделано через `.messageTap` (по комментарию в `MessageRow.swift:747` `onTapGesture` для VoiceOver невидим), трейт `.isButton` есть, `accessibilityAction` нет, и всё внутри схлопнутого элемента. Это ровно та ошибка, которую комментарий к `hasPressableContent` описывает для голосовых.
- Исправление: добавить `.poll` и `.location` в `hasPressableContent`; в `LocationBubble` добавить `.accessibilityAction { openInMaps() }`. Тест: перебор `MessageKind`, каждый вид с кнопкой внутри входит в `hasPressableContent`.

---

## Medium

### CH-04 Medium. Голосовая подпись сообщения теряет время, «изменено», статус доставки, цитату
- Файлы: `Rooms/MessageSpoken.swift:20-52`, `Rooms/MessageRow.swift:162-172`, `Rooms/CompactMessageRow.swift:213-222`.
- Что не так: у схлопнутой строки подпись заменена на `spokenLabel` = «кто: что» (и сбой). Время, «изменено», `DeliveryTick` (у него своя подпись «отправлено/прочитано»), закреплено, цитата, число ответов в ветке в подпись не попадают: `.combine` с явным label подменяет содержимое детей. Реакции остаются отдельными элементами (хорошо), остальное незрячему недоступно.
- Исправление: собирать подпись из частей: отправитель, текст, «в 14:32», «изменено», статус (для своих), «ответ на: …», «закреплено». Порядок: отправитель, текст, время, статус.

### CH-05 Medium. Баннер смены ключей: кнопка проглочена `.combine`
- Файл: `Rooms/IdentityChangeBanner.swift:49`.
- Что не так: `.accessibilityElement(children: .combine)` на контейнере с `Button` («Понятно» / «Отозвать»). Проект сам пишет в `MessageRow.swift:96-99`, что combined-элемент проглатывает кнопки. Для пользователя VoiceOver это предупреждение безопасности, которое нельзя закрыть.
- Исправление: `.accessibilityElement(children: .contain)`, заголовок и тело в отдельный `VStack` с `.combine`, кнопка вне его.

### CH-07 Medium. Текст прямо на обоях без `onWallpaperInk`
- Файлы: `Rooms/MessageRow.swift:204-210` (имя отправителя над пузырём), `Rooms/CompactMessageRow.swift:144-148` (имя в компактной колонке), `Rooms/RoomView.swift:2514-2517` (`earlierUnavailable`), `Rooms/ThreadLine.swift:20-31`.
- Что не так: время, дата и системные строки используют `onWallpaperInk()` (`IskraDesign/Wallpaper.swift:203`), а имя отправителя имеет `.foregroundStyle(.secondary)` на тех же обоях. На фото-обоях серое имя нечитаемо. `ThreadLine` (акцент и `.secondary`) стоит под пузырём прямо на обоях.
- Исправление: заменить на `.onWallpaperInk()`; для ThreadLine при обоях подложка `incomingBubbleOnWallpaper` или то же чернило.

### CH-08 Medium. `onTapGesture` на цитате, имени и аватаре: для VoiceOver перехода нет
- Файлы: `Rooms/ReplyQuote.swift:66-83`, `Rooms/MessageRow.swift:199`, `:210`.
- Что не так: переход к исходному сообщению сделан `onTapGesture` на элементе `.combine` без трейта кнопки и `accessibilityAction`. Имя отправителя нажимается, но не помечено кнопкой. У аватара трейт `.isButton` есть, действия нет.
- Исправление: `.accessibilityAddTraits(.isButton)` + `.accessibilityAction { onOpen?() }` в `ReplyQuote` (когда `onOpen != nil`); для имени и аватара `.accessibilityAction { openProfile?(...) }`.

### CH-10 Medium. Плитки действий в инфо: подписи `lineLimit(1)` и до пяти плиток в ряд
- Файлы: `Rooms/ProfileActionTile.swift:60-63`, `Rooms/RoomInfoView.swift:253-292`.
- Что не так: подпись `.caption`, `lineLimit(1)`, без `minimumScaleFactor`. До пяти плиток в `HStack` на 390pt, около 70pt на плитку. Немецкое «Stummschalten» и любые крупные размеры Dynamic Type обрежут подпись в многоточие. Круг масштабируется, ряд не перестраивается. У занятой плитки (`isBusy`) нет `accessibilityValue`.
- Исправление: `ViewThatFits`/`FlowLayout` вместо `HStack`, при больших размерах два ряда; `lineLimit(2)` + `minimumScaleFactor(0.8)`.

### CH-11 Medium. Нет предела длины строки на широких окнах
- Файлы: `IskraDesign/Theme.swift:798` (`bubbleWidthFraction = 0.9`), `Rooms/MessageRow.swift:338-341`.
- Что не так: пузырь занимает до 90 процентов колонки и ничем больше не ограничен. Во весь экран на Mac или iPad с закрытой инфо-колонкой это 800-1200pt, 120+ знаков в строке. Решение задокументировано, но на широких окнах оно вредит чтению; у цитаты и опроса максимум есть.
- Исправление: `min(timelineWidth * 0.9, Theme.Size.bubbleMaxWidth)` (около 520-600pt для regular), пустая колонка с другой стороны растёт. То же для компактной раскладки.

### CH-12 Medium. Mac: упоминания без клавиатуры, Escape уходит из чата
- Файлы: `Rooms/MentionPicker.swift:24-30`, `Rooms/MessageComposer.swift:505`, `Rooms/RoomView.swift:1736-1749`.
- Что не так: список подсказок выбирается только нажатием: нет ↑/↓/Tab/Return/Esc (единственный `onKeyPress` композера в `ComposerReturnKey`). Return при открытом списке отправит сообщение с недописанным «@ан». `RoomView.escape`: инфо, меню, контекст ответа, иначе `onClose()`; то есть Escape при открытых упоминаниях или меню вложений покидает чат.
- Исправление: при непустом `matches` перехватывать ↑/↓/Return/Tab/Esc (по образцу `UpArrowCatcher`), подсвечивать текущую строку; в `escape()` закрывать список упоминаний и меню вложений до `onClose()`.

### CH-13 Medium (проверить на устройстве). Reduce Motion может не гасить анимации, заданные ближе к виду
- Файлы: `IskraDesign/ReduceMotion.swift`, `Rooms/RecordingStrip.swift:84-90`, `Rooms/MessageRow.swift:134-156`, `Rooms/PollBubble.swift:39`.
- Что не так: `respectsReduceMotion()` ставит `.transaction { animation = nil }` один раз у корня. Транзакция идёт сверху вниз, и `.animation(_:value:)` ближе к виду переопределяет корень. `withAnimation` гасится, а модификаторы `.animation(..., value:)` и бесконечный пульс записи (`RecordingStrip.swift:90`, `repeatForever`) работают как раньше. Комментарий `QRCodeSheet.swift:249` признаёт предел. Явно читают `accessibilityReduceMotion` только `ReactionBar` и `RoomListStatus`.
- Исправление: проверить с включённым Reduce Motion пульс точки записи и появление реакций; общий хелпер для `.animation` и пройти все `.animation(` в Rooms/ (около 108 мест с `withAnimation` / `.animation`).

---

## Low

### CH-14 Low. Серый `Color.secondary` внутри своего пузыря (цитата-блок, спойлер)
- `Rooms/MessageContent.swift:387`, `:401`. В `AttributedString` `.secondary` это конкретный серый, а не иерархический стиль; в цветном своём пузыре контраст низкий. Исправление: для `style == .own` использовать `onBubbleColor.opacity(0.7)`.

### CH-15 Low. Подтверждение правки подписано «Отправить»
- `Rooms/MessageComposer.swift:405-412`. Иконка `checkmark`, но `label: Strings.Room.send`; VoiceOver говорит «Отправить» вместо «Сохранить». Исправление: отдельная строка `Strings.Room.saveEdit` во всех семи локалях.

### CH-16 Low. Жёсткие значения вне Theme
- `Rooms/MessageRow.swift:701`, `:1264`: `.font(.system(size: 44))` / `40` для кнопки воспроизведения: не масштабируется с Dynamic Type, число не из Theme. Заменить на токен + `@ScaledSize`.
- `Rooms/IdentityChangeBanner.swift:22,36,47`, `Rooms/NewRoomView.swift:57`: `.orange` напрямую. Завести токен предупреждения и проверить контраст оранжевого текста.
- `Rooms/AlbumBubble.swift:116`, `Rooms/MessageRow.swift:718,735,1275`: `.padding(.vertical, 2)` вместо токена (`Spacing.withinRun`).

### CH-17 Low. Набор текста и полноэкранное фото для VoiceOver
- `Rooms/CompactMessageRow.swift:307`: `CompactTypingRow` скрыт `accessibilityHidden(true)`, то же у пузыря набора; слепой не узнает, что собеседник пишет (возможно, осознанная тишина, но без опции).
- `Media/MediaGallery.swift` (страница с `ZoomableImage`): у самой картинки нет `accessibilityLabel` (отправитель, время, подпись); панель управления переключается только одиночным тапом, действия для VoiceOver нет.

### CH-18 Low. Стекло на контентных плитках профиля
- `Rooms/ProfileActionTile.swift:61-62`: `navigationGlass(in: .circle)` на плитках внутри страницы, что противоречит правилу «стекло только в навигационном слое». Комментарий в файле признаёт исключение по воле автора. Если правило в силе, стоит записать исключение в `docs/DECISIONS.md` или заменить на непрозрачную заливку.

### CH-19 Low. Повтор «значок в круге» в инфо и профиле
- `Rooms/RoomInfoView.swift:253-292`, `Rooms/MemberProfileView.swift:201-225`: до пяти одинаковых стеклянных кругов подряд одинакового веса; QR и «Поделиться» для публичной комнаты близки по смыслу. Выделить главное действие (Сообщение / Поиск), вторичные убрать в меню.

---

## Проверено, дефектов нет
- `SendFailureBadge`: зона 44pt через отрицательный padding, подпись, подсказка, popover. Образец для CH-06.
- Запись голоса: default action, действия «отмена» и «переключить режим», запрет переключения во время записи.
- Строки: хардкода в `Text/Label/Button` в Rooms/Media/VideoNote нет (кроме техн. пунктуации в `ReplyQuote.swift:81` с отключённым линтером и «−» в таймере галереи).
- `@Environment(\.dismiss)` в `MediaPager` допустим: это окно/обложка просмотра, не экран в боковой колонке.
- Заголовок беседы: одна фраза для VoiceOver с замком и подзаголовком, обрезка в конец, максимум ширины из Theme.
