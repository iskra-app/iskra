# Аудит: первый запуск и навигационная оболочка (Iskra)

Метод: чтение кода по зоне. Оболочка в целом дисциплинированная: размеры из Theme, строки через Strings, кнопки .glassAction, есть ReduceMotion.swift (глобально), Escape-стек, скелетон вместо спиннера. Реальных критичных дефектов не найдено. Ниже только то, что проверено по коду.

## SH-02 (Medium) Кнопка очистки поиска в Mac-листе несёт подпись «Отмена»
Rooms/NewChatView.swift:376 (`SheetSearchField`): `.accessibilityLabel(Text(Strings.Room.Manage.cancel))` на кнопке `xmark.circle.fill`, которая очищает текст. VoiceOver/Voice Control говорит «Отмена», пользователь ждёт закрытия листа. Есть готовая `Strings.RoomList.clearSearch` (Support/Strings.swift:428). Фикс: заменить ключ. Заодно зона нажатия — иконка без frame (меньше 44 pt, на Mac допустимо, но стоит `.frame(minWidth/minHeight)` + `.contentShape`).

## SH-03 (Medium) Красный текст ошибки входа на красной подложке: контраст ниже 4.5:1
SignIn/SignInView.swift:306-317. `.foregroundStyle(.red)` `.callout.weight(.medium)` на `red.opacity(Backdrop.wash=0.12)`. Системный красный на светлом фоне ~3.9:1, на подложке ещё ниже. В проекте уже решали ровно это: Recovery/RecoveryBanner.swift:30-36 красит только символ, а слова оставляет `.primary` (комментарий про 2:1). Единственное место, где причина сбоя при входе объясняется словами, самое трудное для чтения. Фикс: как в RecoveryBanner — иконка красная, текст `.primary`.

## SH-04 (Low) Захардкоженные значения в строке чата
Rooms/RoomListView.swift:935 `.padding(.horizontal, 7)` — не кратно 4 и не из Theme (нарушает правило «размеры из Theme»); вариант 8 = `Spacing.close` или 4 = `tight`, иначе бейдж «99+» рассчитан на 7. :898 `.font(.system(size: Theme.Size.unreadBadge * 0.5, …))` — производная размера, но фиксированный кегль без масштабирования; на крупных Dynamic Type сердце останется мелким рядом с растущим счётчиком. Фикс: `Spacing.close` + `@ScaledMetric` для бейджа/сердца либо `.font(.caption2.bold())`.

## SH-05 (Low) VoiceOver произносит «личный чат» для каждой зашифрованной комнаты
Rooms/RoomListView.swift:1050-1054 (+ значок :831 и :1151). Подпись строки добавляет `privateChat` по `privacy == .protected`; при шифровании по умолчанию это почти каждая строка списка: имя, «личный чат», … 100 раз подряд. Данные для слуха не различают строки. Фикс: произносить только отличие (незашифрованная/публичная комната) либо вынести в `accessibilityHint`/`.accessibilityValue`.

## SH-06 (Low) Строка приглашения участников: «уже здесь» гасится opacity 0.5
Rooms/InviteView.swift:187. `.opacity(isMember ? 0.5 : 1)` вместе с `.disabled` понижает и подпись «Уже здесь» (она же единственное объяснение, почему строку нельзя выбрать), и имя ниже 4.5:1; `0.5` — литерал вне Theme.Opacity. Серая иконка `.tertiary` рядом читается как «выбрано»: у участников она `checkmark.circle.fill`, как у выбранных (:176), отличие только цветом. Фикс: не опускать opacity у подписи, оставить `.secondary`; у участника другой символ (`person.fill.checkmark`) или без кружка, значение через `accessibilityValue`.

## SH-07 (Low) Клавиатурная цепочка на экране входа
SignIn/SignInView.swift:419-430. У поля логина нет `.submitLabel(.next)` и `.onSubmit { focus = .password }`, у пароля нет `.submitLabel(.go)`. Return в логине на iPhone и Mac ничего не делает, тогда как поле адреса (:142-143) цепочку имеет. Непоследовательно в одном экране. Фикс: добавить обе строки.

## SH-08 (Low) «Что такое Matrix» — ссылка 13 pt без зоны нажатия
SignIn/SignInView.swift:176-183. `.font(.footnote)`, `.buttonStyle(.plain)`, высота = текст + `padding(.top, close)` ~ 25 pt. Это тот самый вход для человека, который впервые слышит про Matrix. Фикс: `.frame(minHeight: Theme.Size.minimumTapTarget)` и `.contentShape(.rect)`.

## Проверено и дефектов нет
- Пустые состояния списка (RoomListView.swift:690-706): ContentUnavailableView с обычными словами, скелетон на первой загрузке, поиск через системный `.search`. Иллюстраций с «пока ничего» нет. (Иконка bubble.left.and.bubble.right на пустом списке стандартная для системы.)
- Reduce Motion: анимации в оболочке идут через глобальный ReduceMotion.swift, отдельные `withAnimation` покрыты им (если он действительно подставляет `transaction.disablesAnimations`; ручную проверку на устройстве не делал).
- RecoveryBanner: зона 44 pt, подсказка, контраст продуман.
- AccountSwitcher: строка `combine`, подсказка, счётчик непрочитанных с подписью, длинные ID переносятся.
- Бейджи непрочитанных: цвет несут данные (акцент/серый для muted), красный только у реакций.
