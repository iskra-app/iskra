# Пуши: что осталось, и почему это не Swift

Код пушей готов и проверен на живом сообщении. Осталось три вещи, и ни одна из них не
пишется в Xcode. Этот файл — чтобы вернуться к ним, не восстанавливая контекст заново.

Что уже сделано (и почему это не ждало шлюза) — в `ROADMAP.md`, этап 7. Коротко: Matrix-push
несёт `room_id` и `event_id` и больше ничего. Шлюз доставляет эти две строки и ничего не
расшифровывает. Поэтому `PushDecoder`, `PushMapper` и само расширение сделаны и работают —
`Iskra --probe-notification` расшифровывает настоящее сообщение прямо сейчас.

## 1. Свой Sygnal

Homeserver не ходит в APNs напрямую. Он отправляет пуш в **push gateway**, а тот уже — в APNs
сертификатом/ключом *приложения*. Публичный шлюз matrix.org (`matrix.org/_matrix/push/v1/notify`)
принимает только зарегистрированные у них app id — то есть элементовские. Под `moscow.swag.iskra`
он пуш не отправит, и это не настраивается с нашей стороны: это их конфиг.

Значит, нужен свой [Sygnal](https://github.com/matrix-org/sygnal).

Что понадобится:

- **APNs Auth Key** (`.p8`) из Apple Developer → Keys → «Apple Push Notifications service».
  Ключ скачивается **один раз**; вместе с ним нужны Key ID и Team ID (`936RH3UPR3`).
  `.p8` уже в `.gitignore` — пусть там и остаётся.
- Хост с TLS. Homeserver ходит в шлюз по HTTPS, самоподписанный сертификат не подойдёт.
- Python 3 и `pip install matrix-sygnal`, либо готовый Docker-образ.

Конфиг (`sygnal.yaml`), минимально:

```yaml
apps:
  moscow.swag.iskra:
    type: apns
    keyfile: /path/to/AuthKey_XXXXXXXXXX.p8
    key_id: XXXXXXXXXX
    team_id: 936RH3UPR3
    topic: moscow.swag.iskra          # = bundle id приложения
    push_type: alert
```

Ключевое: `topic` — это **bundle id**, а не app group и не keychain group. Их в проекте три
разных, и путать их — самый лёгкий способ получить пуш, который APNs молча выбрасывает.

Проверить, что шлюз жив, **до** того как трогать Swift:

```sh
curl -X POST https://<шлюз>/_matrix/push/v1/notify \
  -H 'Content-Type: application/json' \
  -d '{"notification":{"devices":[{"app_id":"moscow.swag.iskra","pushkey":"<device token>"}]}}'
```

Device token взять неоткуда, пока не сделан пункт 2, — поэтому на первом заходе достаточно,
чтобы шлюз отвечал 200 на пустой список устройств и не падал на старте с ошибкой про `.p8`.

Тонкость про `aps-environment`: в `Apps/project.yml` он сейчас `development`. Токен, полученный
в dev-сборке, живёт в **sandbox**-APNs, и Sygnal должен ходить туда же. У Sygnal это
`push_type`/`platform: sandbox` — если шлюз настроен на production, а приложение собрано dev,
пуш уйдёт в никуда без единой ошибки на стороне приложения.

## 2. `setPusher`

Как только шлюз отвечает:

- В приложении — `registerForRemoteNotifications()`, забрать device token из
  `didRegisterForRemoteNotificationsWithDeviceToken`.
- `Client.setPusher(identifiers:kind:appDisplayName:deviceDisplayName:profileTag:lang:append:)`
  (`matrix_sdk_ffi.swift`, ~1367). `identifiers` — это `(pushkey: <device token hex>, appId:
  "moscow.swag.iskra")`, `kind` — `.http` с URL нашего Sygnal.
- Регистрировать после входа и при смене токена; снимать при выходе, иначе сервер продолжит
  слать пуши на устройство, с которого вышли.

Разрешение на уведомления спрашивать **не на старте**. На пустом экране входа «Iskra хочет
присылать уведомления» — это вопрос ни о чём: человеку ещё нечего получать. Спрашивать после
первого успешного входа, когда у него уже есть чаты.

## 3. Проверить на устройстве

Единственное, чего проба не доказывает, — и в симуляторе не докажет, потому что APNs там нет.

- iOS вообще будит `.appex`.
- У `.appex` разрешаются **его собственные** entitlements. Это другой bundle id, и App Group с
  Keychain выданы ему отдельно от приложения. `Iskra --verify-storage` проверяет сторону
  *приложения*; `--probe-notification` идёт в процессе приложения. Ни то ни другое не отвечает
  за расширение.

Если расширение скажет «nobody is signed in» на устройстве, где вход выполнен, — смотреть
`AppIdentifierPrefix` в его `Info.plist`. Внутри расширения `Bundle.main` — это бандл
*расширения*, и без этого ключа префикс команды теряется, keychain-группа выходит без него, и
Keychain честно ничего не находит. Это описано в `CLAUDE.md`.

## Чего делать не нужно

Не писать «пока что» свой HTTP-клиент поверх access token, чтобы обойти шлюз. Пуш всё равно
приходит от Apple, а не от нас; обойти APNs нечем.
