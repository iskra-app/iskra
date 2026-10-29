# Аудит дизайн-системы Iskra (Sources/IskraDesign)

Только чтение, файлы репозитория не менялись. Пути относительны к `Sources/IskraDesign/`.
Контраст посчитан по формуле WCAG 2.x из значений системных цветов iOS (light / dark). Для `.red/.orange/.yellow/.green/.blue/.purple/.cyan` взяты опубликованные sRGB-значения.

## Сводка

| ID | Серьёзность | Суть |
|---|---|---|
| DS-01 | Critical | Белый текст на `.orange/.green/.cyan` (и в слабой степени `.red/.blue/.purple`) — 1.7–4.1:1 |
| DS-02 | High | Акцент как цвет текста/ссылок на светлом фоне: жёлтый 1.5:1, оранжевый/зелёный 2.2:1 |
| DS-03 | High | `AccentTheme.solid(in:)` мёртв, glass-кнопки на моно получают серый вибрантный tint |
| DS-04 | Medium | На iOS 18 вторичная кнопка и поле ввода — один и тот же `.quaternary`, границ нет |
| DS-05 | Medium | `.glassAction` / `.glassSecondary` на iOS 18 без отклика на нажатие |
| DS-06 | Medium | Reduce Motion: корневой `transaction`, скорее всего, не гасит `.animation(value:)` внутри |
| DS-07 | Medium | Increase Contrast нигде не обработан, а комментарии утверждают обратное |
| DS-08 | Medium | Метка поля ввода живёт только в placeholder, граница 1.1:1 |
| DS-10 | Medium | Три копии логики заливки пузыря; `PictureBorder` дублирует её же |
| DS-11 | Medium | ShareSheet обходит Theme: фикс. шрифт 22, 2.5, 0.86, spring, колонки = 4 |
| DS-12 | Low | Мёртвые токены в `Theme` (7 штук) |
| DS-13 | Low | Заявление «только два значения не кратны 4» неверно (17 констант) |
| DS-14 | Low | Дубли токенов и размытая шкала радиусов/длительностей |
| DS-15 | Low | Таблицы цветов обоев продублированы (`luminance` и `colors`) |
| DS-16 | Low | Сырые opacity вне `Theme.Opacity`; тень у текста на обоях |
| DS-17 | Low | `InitialsFace` и `.secondary` на `.quaternary`: контраст около 3:1 |
| DS-18 | Low | Цвет — единственный носитель смысла в `Theme.Storage.bands` (жёлтый на белом 1.5:1) |

---

## DS-01 — Critical — белый текст на акцентах оранжевый, зелёный, голубой (и ещё три)

**Где:** `AccentTheme.swift:69-75` (`foreground`), `:164-182` (`onBubble`, `onBubbleColor`), `PrimaryAction.swift:47,51` и `:73,80`, `ShareSheet.swift:133`.

**Что не так.** Подпись на заливке акцентом белая у шести из семи цветов, чёрная только у жёлтого. Комментарий («White, for six of the seven») считает остальных читаемыми. Расчёт для текста 17pt semibold (в основном тексте пузыря он regular, обычный текст требует 4.5:1):

| Акцент | белый на нём, light | белый на нём, dark |
|---|---|---|
| orange | 2.20 | 2.06 |
| green | 2.22 | 2.02 |
| cyan | 2.54 | **1.72** |
| red | 3.55 | 3.41 |
| purple | 4.13 | 3.52 |
| blue | 4.02 | 3.65 |

Не проходит ни один из шести цветов по 4.5:1; оранжевый, зелёный и голубой не проходят даже 3:1 для крупного текста. `AnswerStyle` (`PrimaryAction.swift:143-153`) уже решил ту же задачу для зелёного и красного: там прямо написано «white on system green is about 2.2:1», и взяты тёмные оттенки (5.2 и 5.8). На главную кнопку, исходящий пузырь и кнопку отправки это решение не распространили.

**Почему важно.** Самая заметная кнопка («Продолжить») и каждое собственное сообщение нечитаемы на солнце и у людей с пониженным зрением, если выбран оранжевый, зелёный или голубой акцент. Тёмная тема хуже светлой, потому что системные цвета там светлее.

**Исправление.**
1. Ввести в `AccentTheme` второй список: `fill(in scheme)` с затемнёнными оттенками через `Color.adaptive`, каждый ≥4.5:1 с белым. Ориентир: зелёный `#1C7D38` (5.2:1), оранжевый около `#B25A00`, голубой около `#0B6F9E`, красный `#D70015`, синий `#0062CC`, фиолетовый `#8944AB`.
2. Либо, для светлых акцентов, давать чёрный текст через `foreground`: чёрный на orange 10.2:1, green 10.4:1, cyan 12.2:1, yellow 13.9:1.
3. Покрыть тестом: для каждого `AccentTheme` и обеих схем `contrast(fill, foreground) >= 4.5`. Сейчас гарантий нет вообще.

## DS-02 — High — акцент как цвет текста на светлой странице

**Где:** `ShareSheet.swift:68` (`.caption`, `accent.color` для выбранного чата), `Sources/IskraFeatures/Rooms/MessageContent.swift:327` (`linkColor` в чужом пузыре — `accent.color`), плюс 24 места в `IskraFeatures` с `foregroundStyle(accent.color)`.

**Что не так.** Акцент как цвет текста на белом: yellow 1.51:1, orange 2.20, green 2.22, cyan 2.54, red 3.55, blue 4.02. Для мелкого `.caption` и для ссылки в тексте это провал. Жёлтая ссылка в чужом пузыре (фон 5% чёрного на белом) практически невидима, подчёркивания нет.

**Почему важно.** Ссылка — это единственный способ понять, что слово нажимаемо. У жёлтого и оранжевого акцента ссылки исчезают.

**Исправление.** Добавить `AccentTheme.textColor(in:)` (тёмный оттенок на светлой схеме, светлый на тёмной, ≥4.5:1) и использовать его для любого текста и значков, не лежащих на заливке; ссылкам добавить подчёркивание.

## DS-03 — High — `solid(in:)` не вызывается, на моно glass-кнопки получаются серыми

**Где:** `AccentTheme.swift:85-93` (комментарий и функция), `PrimaryAction.swift:80`, `ShareSheet.swift:138`, `Sources/IskraFeatures/Rooms/MessageComposer.swift:1269`.

**Что не так.** Комментарий к `solid(in:)` прямо говорит: «`.primary` drawn inside glass is vibrant — grey, whatever the appearance — so a fill on the navigation layer that has to be the accent takes this». Поиск `\.solid(in` по `Sources` и `Apps` — ноль вызовов. Все три места, где акцент становится tint для glass (`primaryActionGlass(tint: accent.color)`), передают `accent.color`, то есть `.primary`. Подпись при этом чёрная или белая от `foreground(in:)`. Починка описана, но не подключена.

**Почему важно.** На моно-теме кнопка «Продолжить» и «Отправить» в iOS 26 — серое стекло с подписью другого оттенка вместо контрастной чёрно-белой пары.

**Исправление.** В трёх местах передавать `accent.solid(in: scheme)`. Заодно убрать `foreground` без схемы: он содержит ту же ловушку с `.background` внутри стекла, о которой говорит комментарий выше.

## DS-04 — Medium — на iOS 18 вторичная кнопка и поле ввода выглядят одинаково

**Где:** `Glass.swift:62-68` (`secondaryActionGlass` → `.background(.quaternary, …)`), `EntryField.swift:42` (то же `.quaternary`), `PrimaryAction.swift:92-111`.

**Что не так.** Комментарий в `EntryField` хвалит единую капсулу поля и двух кнопок под ним. На iOS 26 они различаются материалом (поле плоское, кнопки стеклянные). На iOS 18 это один и тот же цвет и одна форма: «Выбрать сервер» нельзя отличить от поля ввода. Граница 4–5% от цвета текста даёт около 1.1:1 против 3:1 для границ интерактивных элементов.

**Исправление.** Для iOS 18 различать: у поля — `strokeBorder(.separator)` или чуть более тёмный fill; у кнопки — `Material`/`.tertiary` плюс тонкая обводка. Или вернуть `.bordered` как в `navigationGlassButton`.

## DS-05 — Medium — на iOS 18 нет отклика на нажатие у glass-кнопок

**Где:** `PrimaryAction.swift:77-83` (комментарий: «The glass is already interactive … does not take the press scale»), `:109`, `Glass.swift:55,66`.

**Что не так.** `PrimaryActionStyle` вызывает `.pressed(...)`, а `GlassActionStyle` и `GlassSecondaryStyle` — нет, потому что на 26 стекло интерактивное само. Но на iOS 18 фолбэк — обычный `background(tint)` / `.quaternary`, и никакого отклика нет вообще. Это главные кнопки входа и восстановления.

**Исправление.** В фолбэке (ветка `else` в `Glass.swift`) применять то же `pressed`, либо вынести `pressed` в `IskraDesign` и вызывать при `!isAvailable(26)`.

## DS-06 — Medium — Reduce Motion может не работать для локальных `.animation(value:)`

**Где:** `ReduceMotion.swift:19-26`, `TypingBubble.swift:75-89`, `PrimaryAction.swift:195-196`, `ShareSheet.swift:76,143`.

**Что не так.** `respectsReduceMotion()` ставит `transaction.animation = nil` на корне. Комментарий обещает, что это гасит «typing dots and the recording pulse that never stop». Но `.animation(_, value:)` заново выставляет animation в транзакции ниже по дереву, поэтому корневое обнуление ему не мешает (классическая ловушка: `animation(nil)` на родителе не останавливает анимацию ребёнка). Признак: `BlinkingSpark` (`:9,19-21`) сам читает `accessibilityReduceMotion`, значит автор не доверял корню. `TypingDots` этого не делает, а `.repeatForever` крутится бесконечно. Проверено только чтением кода; надо подтвердить на устройстве с включённым «Уменьшить движение».

Дополнительно: `scaleEffect(0.97)` у `pressed` и spring-пружина выбора в `ShareTargetGrid` с `bounce: 0.3` не имеют альтернативы.

**Исправление.** В `TypingDots` читать `@Environment(\.accessibilityReduceMotion)`, при `true` не запускать `pulsing` и показывать статичные точки с opacity 0.6. В `ReduceMotion` дополнительно ставить `transaction.disablesAnimations = true`. Один тест на включённый режим.

## DS-07 — Medium — Increase Contrast не обработан, документация утверждает обратное

**Где:** `Theme.swift:1165-1180` (`incomingBubble`), `Theme.swift:1214-1236` (`Color.adaptive`), `Wallpaper.swift`, весь пакет.

**Что не так.** Поиск `colorSchemeContrast`, `accessibilityDifferentiateWithoutColor` и `accessibilityShowButtonShapes` по `Sources` даёт ноль. Комментарий к `incomingBubble` («follows the system into dark mode and into increased-contrast mode without our help») после перехода на `Color.adaptive(light:dark:)` неверен: два фиксированных значения не знают про Increase Contrast. Чужой пузырь 5% чёрного на белом — около 1.1:1 к странице; на Mac цвета `page`/`groupedCard`/`groupedPage` зашиты как hex и тоже не усиливаются.

Reduce Transparency отдельно кодом не нужен: `glassEffect` и `Material` система упрощает сама. Это не дефект.

**Исправление.** В `adaptive` добавить параметры `highContrast` или читать `UITraitCollection.accessibilityContrast`; для `incomingBubble` и `ownReaction` усилить до 10–12% при Increase Contrast. Поправить комментарий.

## DS-08 — Medium — поле ввода без метки и без видимой границы

**Где:** `EntryField.swift:17-20,42-43`.

**Что не так.** Комментарий: «label is carried by the placeholder or by the heading above it, never by a border». Placeholder исчезает при вводе, и тот, кто вернулся к полю, уже не видит, что в нём (адрес сервера или код восстановления). Заливка `.quaternary` — около 1.1:1, фокус ничем не подсвечен.

**Исправление.** Видимая подпись над полем обязательна (заголовок есть не везде); `accessibilityLabel` ставить на само поле; при фокусе рисовать `strokeBorder(accent.control(in:), 2)` через `@FocusState`.

## DS-10 — Medium — заливка пузыря продублирована трижды

**Где:** `MessageBubble.swift:92-98` (`MessageBubble.fill`), `:137-143` (`BubbleFill.fill`), `:181-187` (`PictureBorder.border`). Тот же `switch` в одном и том же виде.

**Что не так.** Три копии одного `switch`. Любая правка (например, из DS-01) в одной забудется в другой. `.foregroundStyle(style == .own ? accent.onBubble : …)` тоже продублирован (`:107`, `:148`).

**Исправление.** Вынести в `BubbleStyle.fill(accent:onWallpaper:)` и `BubbleStyle.ink(accent:)`; три вида зовут его.

## DS-11 — Medium — `ShareSheet` обходит Theme

**Где:** `ShareSheet.swift:34-35` (4 колонки), `:49` (`0.86`), `:52` (`lineWidth: 2.5`), `:58` (`.font(.system(size: 22, weight: .semibold))`), `:76` (`.spring(duration: 0.3, bounce: 0.3)`), `:61` (`Theme.Spacing.withinRun` как отступ фона, семантика «зазор внутри серии сообщений»).

**Что не так.**
- Размер 22 фиксирован, не масштабируется с Dynamic Type. Подпись `.caption` масштабируется, галочка нет.
- Колонок всегда 4: на AX-размерах подписи в 60pt-ячейке с `lineLimit(2)` обрезаются.
- Белая галочка на фоне `Circle().fill(.background)` с белым акцентом `palette(.white, accent.color)` на жёлтом акценте почти невидима.
- Анимация не из `Theme.Timing`, число 0.3/0.3 нигде больше не встречается.
- Нет Reduce Motion (см. DS-06).

**Исправление.** `@ScaledSize(22)`, `Theme.Border.thick` вместо 2.5, `Theme.Scale.selected`, `Theme.Timing.chosen`; число колонок через `@ScaledMetric` или `GridItem(.adaptive(minimum:))`.

## DS-12 — Low — мёртвые токены в Theme

Поиск по `Sources`, `Core`, `Apps`, `Tests` даёт ноль использований (кроме объявления):

- `Theme.swift:325` `Timing.endIsCheckedEvery`
- `:401` `Timing.welcomeSlide`
- `:409` `Timing.previewReplies`
- `:417` `Timing.stepChanges`
- `:685` `Size.qrCode`
- `:882` `Size.welcomeMark`
- `:886` `Size.pageDot`

Комментарии к ним описывают экран приветствия, которого, судя по отсутствию использований, нет. Мёртвые токены с длинной «обоснованной» документацией вводят в заблуждение. Удалить.

## DS-13 — Low — «только два значения не кратны 4» неверно

**Где:** `Theme.swift:16-22`.

Комментарий называет два исключения (`withinRun`, `recordingDot`). По факту не кратны 4: `formRowInset` 10, `albumGap` 2, `unreadDot` 10, `videoNoteGrowth` 2 (множитель), `waveformBar` 2, `waveformBarMinimum` 3, `menuIcon` **26**, `windowMinimumHeight` 450. Часть описана в своих комментариях, но `menuIcon: 26` и `waveformBarMinimum: 3` — просто сетка нарушена; хотя бы `menuIcon` стоит сделать 24 или 28. Исправить комментарий и список исключений, добавить тест на кратность (с белым списком).

## DS-14 — Low — дубли и размытая шкала

- Радиусы: 8, 12, 16, 20, 24, 28, 28 (`qrCard` и `menu` равны, `Theme.swift:57,66`). Семь значений; `Radius.card` (16) и `Radius.control` (12) используются 15 раз на всех экранах — разницы между «карточкой» и «контролем» глазом не видно. Сократить до 4–5 значений.
- Размеры 44: `minimumTapTarget`, `swatch`, `composerControl`, `searchField`, `reactionCell`, `navigationBar` — шесть токенов с одним числом, десять комментариев, объясняющих «почему именно столько». Свести к одному `minimumTapTarget` и алиасам.
- `avatarCropper` = `viewer` = 480; `sideColumn` = `sidebarIdeal` = 320.
- Длительности: 0.05, 0.15 (×3), 0.2 (×4), 0.25 (×3), 0.3 (×3), 0.35, 0.4 (×3), 0.45, 1.6. Шкала из 12+ значений не читается как система; `Timing.reaction` (0.25) против `chrome` (0.2) — спор о 50 мс.

## DS-15 — Low — таблицы цветов обоев продублированы

**Где:** `Wallpaper.swift:60-67` (`luminance`) и `:100-110` (`colors`). Одни и те же RGB записаны дважды (`Double` и `Color`). Поменяешь градиент и забудешь таблицу — `isDark` начнёт врать, чернила на обоях станут нечитаемыми. Вывести `luminance` из `colors` через единый массив `[[Double]]`.

## DS-16 — Low — сырые opacity и тень на тексте

- `Theme.Opacity` существует, но `AccentTheme.swift:119` (0.38 / 0.72), `:159` и `Theme.swift:1210` (0.16 дважды: `bubble` на моно и `ownReaction`), `MessageBubble.swift:243` (0.5), `Wallpaper.swift:214,218` (0.92, 0.78, 0.45) в него не вынесены.
- `Wallpaper.swift:218`: `.shadow(color:…, radius: 1.5)` на каждом тексте над обоями — тень в покое, ради читаемости на неизвестной фотографии. Лучше подложка-плашка (как `Backdrop.plate`), а не свечение.

## DS-17 — Low — инициалы: `.secondary` на `.quaternary`

**Где:** `DirectoryFace.swift:102-106`. `secondaryLabel` на белом около 3.45:1, поверх заливки `quaternary` — ещё чуть ниже (≈3.1). Размер `side * 0.4` — для 56pt это 22pt medium, формально ближе к «крупному», но на `avatarSmall` (28pt) получается 11pt при 3:1. Использовать `.primary` с opacity 0.7 или цвет из пары blobatar.

## DS-18 — Low — смысл хранится только в цвете

**Где:** `Theme.swift:1153` (`Storage.bands`: red, yellow, green, blue, purple). Жёлтая полоса на белом 1.51:1, различимость только по оттенку. Нужны подписи или шаблоны (Differentiate Without Color), как минимум легенда с названием категории.

---

## Что проверено и в порядке

- Стекло только в навигационном слое, единственная точка входа с `#available` — `Glass.swift`; заявленное правило выполнено.
- Все четыре ключевые кнопки (`primaryAction`, `glassAction`, `glassSecondary`, `answer`) имеют `minHeight` = 44pt × масштаб (до 1.6), контрольный размер `ScaledSize` корректен.
- `AnswerStyle` — хороший образец: цвета подобраны под 4.5:1, цель касания вынесена за капсулу.
- `AccentTheme.control` для моно решает «белый на белом» у переключателей, контраст трека достаточен (проверено по значениям 0.38 / 0.72).
- Скругления везде `.continuous`; произвольных `cornerRadius(Int)` в `IskraFeatures` и `IskraDesign` не нашлось.
- Ручные отступы в `IskraFeatures` почти не встречаются (6 вызовов `.padding(число)`, 3 фиксированных `.frame`), но `font(.system(size:))` — 16 мест; стоит пройтись отдельным проходом по Dynamic Type.
- `HoloWatermark` (радужный градиент) ограничен карточкой QR, на неё не влияют остальные экраны; в покое слабый (`strength`).

## Приоритет исправлений

1. DS-01 + DS-02 + DS-03 — один заход в `AccentTheme` (пара «заливка/текст» с гарантированным контрастом, `solid`, тест на контраст).
2. DS-06 — проверка на устройстве с «Уменьшить движение», затем правка `TypingDots` и `ReduceMotion`.
3. DS-04 + DS-05 — единые фолбэки iOS 18 (граница, отклик).
4. DS-11, DS-10 — вынос дублей.
5. DS-12–DS-18 — уборка токенов и документации.
