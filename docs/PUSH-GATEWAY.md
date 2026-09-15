# Пуши: что осталось

Код пушей написан целиком и проверен на живом сообщении. Осталось поднять шлюз, вписать его
адрес и проверить всё это на устройстве. Этот файл — чтобы вернуться к делу, не восстанавливая
контекст заново.

Здесь раньше было написано «осталось три вещи, и ни одна из них не пишется в Xcode». Про Sygnal
это правда, про остальное было неправдой — и грубой: во всём проекте не существовало ни
`requestAuthorization`, ни `registerForRemoteNotifications`, ни `setPusher`, то есть «дальше один
вызов» описывало вызов, которому неоткуда взять аргумент. Написано это теперь всё. Оговорка
осталась здесь нарочно: ошибка была в том, что «ждёт инфраструктуры» прочиталось как «и больше
ничего не нужно».

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

Конфиг (`sygnal.yaml`) — **два приложения, а не одно**:

```yaml
apps:
  moscow.swag.iskra.dev:
    type: apns
    keyfile: /keys/AuthKey_XXXXXXXXXX.p8
    key_id: XXXXXXXXXX
    team_id: 936RH3UPR3
    topic: moscow.swag.iskra          # = bundle id приложения
    platform: sandbox                 # под aps-environment: development
    push_type: alert
  moscow.swag.iskra:
    type: apns
    keyfile: /keys/AuthKey_XXXXXXXXXX.p8
    key_id: XXXXXXXXXX
    team_id: 936RH3UPR3
    topic: moscow.swag.iskra
    platform: production              # под TestFlight и App Store
    push_type: alert
```

Ключевое: `topic` — это **bundle id**, а не app group и не keychain group. Их в проекте три
разных, и путать их — самый лёгкий способ получить пуш, который APNs молча выбрасывает. `topic`
одинаковый у обоих входов: bundle id один.

А вот имя входа — разное, и приложение уже это знает: `PushRegistration.appID` — это
`moscow.swag.iskra.dev` в `#if DEBUG` и `moscow.swag.iskra` иначе. Токен dev-сборки живёт в
**sandbox**-APNs, токен из TestFlight — в **production**, и это два непересекающихся мира. Шлюз
держит один ключ и по имени входа понимает, в какую дверь стучать. Один вход на оба случая — это
пуши, которые работают всю разработку и умирают на первой выкладке, не сказав ни слова: токен
верный, `setPusher` проходит, Apple выбрасывает.

Наружу шлюз смотрит через nginx, отдельным `location` на уже существующем домене — поддомен
заводить незачем:

```nginx
location /_matrix/push/ {
    proxy_pass http://127.0.0.1:5000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

Сертификат — настоящий (Let's Encrypt). Самоподписанный не подойдёт: в шлюз ходит homeserver, а не
браузер, и цепочку он проверяет. Принимающим может быть любой сервер, включая matrix.org: он сам
сходит по URL из `setPusher` — поэтому шлюз обязан быть доступен публично.

### По шагам, на сервере

Ниже — всё подряд, от ключа Apple до живого шлюза. Домен пусть будет `push.example.ru`; подставьте
свой. Если Sygnal вешается на тот же домен, где уже что-то есть, — это просто ещё один `location`,
и отдельный сертификат не нужен.

**1. APNs Auth Key.** [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list)
→ Keys → `+` → имя любое → галочка **Apple Push Notifications service (APNs)** → Continue →
Register → Download.

Скачивается `AuthKey_XXXXXXXXXX.p8`, и **скачивается один раз** — второй попытки Apple не даёт,
потерянный ключ только отзывать и делать новый. `XXXXXXXXXX` в имени файла — это Key ID, он же
написан на странице ключа. Team ID — `936RH3UPR3`.

Ключ подходит ко **всем** приложениям аккаунта и к обоим APNs — sandbox и production. Это и есть
причина, по которой в конфиге ниже один `keyfile` на два входа.

**2. Положить ключ на сервер.**

```sh
ssh you@push.example.ru
sudo mkdir -p /opt/sygnal/keys
# с ноутбука, в другом окне:
scp ~/Downloads/AuthKey_XXXXXXXXXX.p8 you@push.example.ru:/tmp/
# обратно на сервере:
sudo mv /tmp/AuthKey_XXXXXXXXXX.p8 /opt/sygnal/keys/
sudo chmod 600 /opt/sygnal/keys/AuthKey_XXXXXXXXXX.p8
```

В репозиторий `.p8` не кладётся никогда: он уже в `.gitignore`, и это не перестраховка — этим
файлом кто угодно шлёт пуши от имени приложения.

**3. `sygnal.yaml`** — в `/opt/sygnal/sygnal.yaml`, содержимое из раздела выше. Проверьте три
строки глазами: `keyfile` совпадает с реальным именем файла, `key_id` — с тем, что в имени, а
`topic` — это `moscow.swag.iskra` и в dev-входе тоже.

**4. `docker-compose.yml`** — в `/opt/sygnal/docker-compose.yml`:

```yaml
services:
  sygnal:
    image: matrixdotorg/sygnal:latest
    restart: unless-stopped
    ports: ["127.0.0.1:5000:5000"]
    volumes:
      - ./sygnal.yaml:/sygnal.yaml:ro
      - ./keys:/keys:ro
```

`127.0.0.1:5000` — не опечатка. Наружу Sygnal не смотрит вообще; снаружи его видно только через
nginx, у которого есть TLS.

```sh
cd /opt/sygnal && sudo docker compose up -d && sudo docker compose logs -f
```

Если `docker compose` отвечает `unknown shorthand flag: 'd' in -d`, то `compose` на этой машине —
не тот плагин, который понимает `-d`: команда до него не доходит, и флаг разбирает кто-то другой.
Разбираться необязательно, compose здесь ничего не даёт — один контейнер запускается и так, и это
ровно тот же контейнер:

```sh
sudo docker run -d --name sygnal --restart unless-stopped \
  -p 127.0.0.1:5000:5000 \
  -v /opt/sygnal/sygnal.yaml:/sygnal.yaml:ro \
  -v /opt/sygnal/keys:/keys:ro \
  matrixdotorg/sygnal:latest
sudo docker logs -f sygnal
```

Тогда `docker-compose.yml` из шага 4 не нужен вовсе. Перезапуск после правки `sygnal.yaml` —
`sudo docker restart sygnal`; замена образа — `sudo docker rm -f sygnal` и та же команда заново.

В логе должно быть, что он слушает порт, и **не** должно быть ничего про `.p8`. Жалоба на ключ на
старте — это либо путь, либо права, и дальше идти незачем.

**5. Сертификат.** Если домен новый:

```sh
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d push.example.ru
```

Certbot сам пропишет TLS в конфиг nginx и заведёт обновление по таймеру. Самоподписанный
сертификат не подойдёт: в шлюз ходит homeserver, а не браузер, и цепочку он проверяет — причём
молча, так что симптомом будет «пуши не приходят», а не ошибка.

**6. nginx.** В `server`-блок с TLS добавить `location` из раздела выше, затем:

```sh
sudo nginx -t && sudo systemctl reload nginx
```

`nginx -t` здесь обязателен: `reload` с битым конфигом оставит работать старый, и вы полчаса будете
править файл, который никто не читает.

**7. Проверить снаружи** — командой из репозитория, не с сервера:

```sh
curl -si -X POST https://push.example.ru/_matrix/push/v1/notify \
  -H 'Content-Type: application/json' \
  -d '{"notification":{"devices":[]}}'
```

Ожидается `200` и `{"rejected": []}`. `502` — не поднялся контейнер; `404` — `location` не там, где
думаете; ошибка сертификата — шаг 5. Пока здесь не `200`, приложение трогать бессмысленно.

**8. И только теперь — одна строка в Swift.** `PushRegistration.gatewayURL` из `nil` в
`"https://push.example.ru/_matrix/push/v1/notify"`. Дальше — проверка на устройстве, пункт 3.

Полная форма того же запроса, с настоящим устройством, — для отладки уже после шага 8: `pushkey`
здесь device token, а взять его можно только с устройства.

```sh
curl -X POST https://push.example.ru/_matrix/push/v1/notify \
  -H 'Content-Type: application/json' \
  -d '{"notification":{"devices":[{"app_id":"moscow.swag.iskra.dev","pushkey":"<device token>"}]}}'
```

Ею отделяется «шлюз не доставляет» от «homeserver не зовёт шлюз»: если этот curl доводит пуш до
экрана, а сообщение в комнате — нет, виноват не шлюз.

Тонкость про `aps-environment`: в `Apps/project.yml` он `development`, и именно поэтому сборка из
Xcode ходит во вход `moscow.swag.iskra.dev` с `platform: sandbox`. Это разведено выше и больше
руками не настраивается.

## 2. `setPusher`

Это уже написано — здесь только чтобы не искать. `PushPermission` спрашивает разрешение после
первого входа, `PushDelegate` ловит device token, `PushRegistration.register` зовёт
`Client.setPusher` с `format: .eventIdOnly` (запрет шлюзу, APNs и Apple нести хоть какой-то текст
сообщения), `append: false` (не удваиваться), и снимает pusher при выходе.

Остаётся ровно одна строка: `PushRegistration.gatewayURL` — сейчас `nil`, станет
`https://<домен>/_matrix/push/v1/notify`. Пока она `nil`, всё остальное работает и на последнем
шаге пишет в лог «no push gateway is configured», а не падает и не молчит.

## 3. Проверить на устройстве

Единственное, чего проба не доказывает, — и в симуляторе не докажет, потому что APNs там нет.

Порядок важен: каждый следующий шаг осмыслен, только если прошёл предыдущий.

1. Войти, согласиться на уведомления. В логе (`Log.push`) не должно быть ни «no push gateway is
   configured», ни «the server would not take our push token».
2. Написать в комнату с другого аккаунта, приложение свернуть. В логах Sygnal — входящий `notify`
   и ответ APNs. Если там пусто, до шлюза не дошёл homeserver, а не шлюз до Apple.
3. На экране — настоящий текст сообщения. «New message» означает, что расширение **не** отработало:
   либо iOS его не разбудила, либо у него не разрешились собственные entitlements.
4. Тап по баннеру открывает ту комнату, о которой он был (`PushRouter`).
5. Выйти из аккаунта и написать снова — пуш прийти не должен: `deletePusher` отработал.

Устройством проверяются ровно две вещи, и ничем другим они не проверяются:

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
