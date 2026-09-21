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
http:
  # Внутри контейнера — и только поэтому 0.0.0.0. По умолчанию Sygnal слушает 127.0.0.1, то есть
  # петлю *контейнера*, до которой проброс порта не достаёт: `docker run -p` стучится в контейнер
  # снаружи, и на том конце никого. Симптом — 502 от nginx при живом, ничего не пишущем в лог
  # контейнере. Наружу это ничего не открывает: публикация порта прибита к 127.0.0.1 хоста.
  bind_addresses: ['0.0.0.0']
  port: 5000

log:
  setup:
    version: 1
    handlers:
      stderr:
        class: logging.StreamHandler
    root:
      handlers: [stderr]
      level: INFO

apps:
  moscow.swag.iskra.dev:
    type: apns
    keyfile: /keys/AuthKey_XXXXXXXXXX.p8
    key_id: XXXXXXXXXX
    team_id: 936RH3UPR3
    topic: moscow.swag.iskra          # = bundle id приложения
    platform: sandbox                 # под aps-environment: development
    push_type: alert
    convert_device_token_to_hex: false   # мы уже шлём hex; см. ниже
  moscow.swag.iskra:
    type: apns
    keyfile: /keys/AuthKey_XXXXXXXXXX.p8
    key_id: XXXXXXXXXX
    team_id: 936RH3UPR3
    topic: moscow.swag.iskra
    platform: production              # под TestFlight и App Store
    push_type: alert
    convert_device_token_to_hex: false
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
    proxy_pass http://127.0.0.1:5400;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

Сертификат — настоящий (Let's Encrypt). Самоподписанный не подойдёт: в шлюз ходит homeserver, а не
браузер, и цепочку он проверяет. Принимающим может быть любой сервер, включая matrix.org: он сам
сходит по URL из `setPusher` — поэтому шлюз обязан быть доступен публично.

### По шагам, на сервере

Ниже — всё подряд, от ключа Apple до живого шлюза, на домене `push.iskra.swag.moscow`. Если Sygnal
вешается на домен, где уже что-то работает, — это просто ещё один `location`, и шаг с сертификатом
пропускается.

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
ssh you@push.iskra.swag.moscow
sudo mkdir -p /opt/sygnal/keys
# с ноутбука, в другом окне:
scp ~/Downloads/AuthKey_XXXXXXXXXX.p8 you@push.iskra.swag.moscow:/tmp/
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
    ports: ["127.0.0.1:5400:5000"]
    volumes:
      - ./sygnal.yaml:/sygnal.yaml:ro
      - ./keys:/keys:ro
```

`127.0.0.1:5400` — не опечатка, и ни одна из двух половин. `127.0.0.1` значит, что наружу Sygnal
не смотрит вообще: снаружи его видно только через nginx, у которого есть TLS. А номера разные
потому, что это две разные стороны: внутри контейнера Sygnal слушает свой обычный 5000, и менять
там нечего, наружу же он опубликован на 5400 — его и ждёт `proxy_pass` в nginx. Порт в
`sygnal.yaml` при этом трогать не нужно; если его всё-таки поменять, поменяется правая половина
`-p`, а не левая.

```sh
cd /opt/sygnal && sudo docker compose up -d && sudo docker compose logs -f
```

Если `docker compose` отвечает `unknown shorthand flag: 'd' in -d`, то `compose` на этой машине —
не тот плагин, который понимает `-d`: команда до него не доходит, и флаг разбирает кто-то другой.
Разбираться необязательно, compose здесь ничего не даёт — один контейнер запускается и так, и это
ровно тот же контейнер:

```sh
sudo docker run -d --name sygnal --restart unless-stopped \
  -p 127.0.0.1:5400:5000 \
  -v /opt/sygnal/sygnal.yaml:/sygnal.yaml:ro \
  -v /opt/sygnal/keys:/keys:ro \
  matrixdotorg/sygnal:latest
sudo docker logs -f sygnal
```

Тогда `docker-compose.yml` из шага 4 не нужен вовсе. Перезапуск после правки `sygnal.yaml` —
`sudo docker restart sygnal`; замена образа — `sudo docker rm -f sygnal` и та же команда заново.

`--restart unless-stopped` — это и есть автозапуск: после перезагрузки сервера контейнер поднимет
сам Docker. Но поднимет он его только если запускается сам, а на этом стоит убедиться один раз, а
не выяснять после первой же перезагрузки:

```sh
systemctl is-enabled docker   # ожидается enabled
sudo systemctl enable docker  # если нет
```

Смысл `unless-stopped` — «поднимать всегда, кроме случая, когда его остановили руками». То есть
после `docker stop sygnal` он не вернётся и после перезагрузки, и это нарочно: остановленный
человеком контейнер остаётся остановленным. Поднять обратно — `sudo docker start sygnal`.

В логе должно быть, что он слушает порт, и **не** должно быть ничего про `.p8`. Жалоба на ключ на
старте — это либо путь, либо права, и дальше идти незачем.

**5. DNS и сертификат.** Сначала `A`-запись `push.iskra.swag.moscow` на IP сервера — certbot
проверяет владение доменом, ходя на него же, так что без записи он не выдаст ничего.

Перед тем как звать certbot, нужен `server`-блок, который отвечает на 80-м: он и пишет туда TLS, а
не создаёт конфиг с нуля. Минимальный — в `/etc/nginx/sites-available/sygnal`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name push.iskra.swag.moscow;
    root /var/www/html;
}
```

```sh
sudo ln -s /etc/nginx/sites-available/sygnal /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d push.iskra.swag.moscow
```

Certbot допишет TLS в этот блок и заведёт обновление по таймеру. Самоподписанный сертификат не
подойдёт: в шлюз ходит homeserver, а не браузер, и цепочку он проверяет — причём молча, так что
симптомом будет «пуши не приходят», а не ошибка.

**6. nginx целиком.** После certbot довести `/etc/nginx/sites-available/sygnal` до этого вида —
здесь весь файл, а не фрагмент:

```nginx
# HTTP: только редирект и место для обновления сертификата.
server {
    listen 80;
    listen [::]:80;
    server_name push.iskra.swag.moscow;

    # Certbot обновляет сертификат по этому пути, и редирект не должен его съесть.
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # `listen ... http2` слитно, а не отдельной директивой `http2 on` — та появилась в nginx 1.25,
    # а в Ubuntu 20.04 nginx 1.18, и конфиг с ней просто не пройдёт `nginx -t`.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name push.iskra.swag.moscow;

    ssl_certificate     /etc/letsencrypt/live/push.iskra.swag.moscow/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/push.iskra.swag.moscow/privkey.pem;
    include             /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

    # Свой лог, потому что первый вопрос при молчащих пушах — приходил ли сюда вообще
    # homeserver. В общем access.log это искать среди всего остального.
    access_log /var/log/nginx/sygnal.access.log;
    error_log  /var/log/nginx/sygnal.error.log;

    location /_matrix/push/ {
        proxy_pass http://127.0.0.1:5400;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Sygnal ждёт ответа от APNs внутри запроса, и на молчащем APNs это дольше обычного.
        proxy_read_timeout 60s;
    }

    # Всё остальное на этом домене не существует. Sygnal — не сайт, и единственный путь,
    # который он обслуживает, назван выше; отдавать наружу что-то ещё незачем.
    location / {
        return 404;
    }
}
```

```sh
sudo nginx -t && sudo systemctl reload nginx
```

`nginx -t` здесь обязателен: `reload` с битым конфигом оставит работать старый, и вы полчаса будете
править файл, который никто не читает.

**7. Проверить снаружи** — командой из репозитория, не с сервера:

```sh
curl -si -X POST https://push.iskra.swag.moscow/_matrix/push/v1/notify \
  -H 'Content-Type: application/json' \
  -d '{"notification":{"devices":[]}}'
```

Ожидается **`400 No devices in notification`**, и это правильный ответ, а не ошибка: список
устройств пуст, Sygnal разобрал запрос и возразил по существу. Тем он и хорош как проверка —
ответить так может только сам Sygnal, то есть цепочка «TLS → nginx → контейнер» прошла целиком.
`200` здесь не бывает, и ждать его не надо.

Остальные ответы — это стоп, и каждый показывает свой участок:

- `404` с html-страницей nginx — запрос не попал в `location /_matrix/push/`. Проверьте, что файл
  из `sites-available` действительно включён симлинком, и что certbot не завёл второй блок с тем
  же `server_name` в `default`: `sites-enabled` читается по алфавиту, и выигрывает первый.
- `502` — nginx на месте, за ним никого. Обычно Sygnal слушает петлю контейнера: см. блок `http:`
  в `sygnal.yaml` выше.
- ошибка сертификата — шаг 5 не доделан.

**8. И только теперь — одна строка в Swift.** `PushRegistration.gatewayURL` из `nil` в
`"https://push.iskra.swag.moscow/_matrix/push/v1/notify"`. Дальше — проверка на устройстве, пункт 3.

Полная форма того же запроса, с настоящим устройством, — для отладки уже после шага 8: `pushkey`
здесь device token, а взять его можно только с устройства.

```sh
curl -X POST https://push.iskra.swag.moscow/_matrix/push/v1/notify \
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

### Что говорит лог Sygnal

Здесь видно всю цепочку разом, и по одной строке понятно, на каком она участке.

`Handled request: … "POST /_matrix/push/v1/notify HTTP/1.0" 200 … "Synapse/…"` — homeserver дошёл
до шлюза. Если таких строк нет вовсе, дело не в шлюзе и не в APNs: pusher не зарегистрирован или
зарегистрирован не с тем URL, смотреть `setPusher` и `Log.push` на устройстве.

`Sending (attempt 0) => … room:!… event:$…` — Sygnal понял, какому приложению и какому устройству
слать, и пошёл в APNs.

`Sending … room:None, event:None` — тоже нормальная строка, и она не про сообщение. Это пуш со
счётчиком: Matrix шлёт такие, когда меняется число непрочитанного, например когда чат прочитали с
другого устройства. События в нём нет, расшифровывать нечего, и расширение по нему ничего не
покажет. Как проверка «дошло ли сообщение» такой пуш не годится, а выглядит убедительно — поэтому
смотреть надо, есть ли в строке `room:!` и `event:$`.

Дальше отвечает Apple, и её ответы стоит читать буквально:

- **`400 BadDeviceToken`** — Apple не узнаёт токен. Причин ровно две, и различаются они по длине
  токена, который Sygnal печатает рядом в логе.

  **Токен в логе длиной 96 символов** — значит, Sygnal его испортил, и виноват
  `convert_device_token_to_hex`, который по умолчанию **включён**. Он base64-декодирует pushkey и
  переводит в hex, потому что так делают клиенты, шлющие base64. `PushRegistration` шлёт **уже
  hex** (64 символа), Sygnal декодирует его как base64, получает 48 байт мусора и предъявляет их
  Apple. Арифметика сходится ровно: 64 символа base64 — это 48 байт, они же 96 hex-символов.
  Лечится `convert_device_token_to_hex: false` у **обоих** входов. Настоящий APNs-токен — 32 байта,
  то есть 64 hex-символа, и столько же должно быть в логе.

  **Токен длиной 64 символа** — токен цел, но предъявлен не в ту APNs. Debug-сборка выдаёт
  **sandbox**-токен, и вход, через который он идёт, обязан быть `platform: sandbox`; по умолчанию
  Sygnal ходит в production. Это и есть причина, по которой входов два.

  На этом здесь потерялось время, потому что второе объяснение выглядит исчерпывающим и проверяется
  первым — а `platform` стоял правильно. Длина токена в логе различает их за секунду, и смотреть
  надо на неё.
- `400 BadTopic` / `DeviceTokenNotForTopic` — не совпал `topic`. Он равен **bundle id**
  (`moscow.swag.iskra`) у обоих входов, а не имени входа.
- `403 InvalidProviderToken` — не тот `.p8`, `key_id` или `team_id`.
- `410 Unregistered` — приложение с телефона удалено; сервер узнает об этом и снимет pusher сам.

`200` в ответе APNs — пуш ушёл, и дальше вопрос уже к устройству: разбудила ли iOS расширение.

И если на этом месте на телефоне **ничего** — смотреть надо не сюда. Лог шлюза при этом выглядит
идеально, потому что со стороны шлюза всё и правда идеально: он отдал пуш, Apple его приняла.
Причина, которая так выглядит, одна — пустой `defaultPayload` у pusher'а. Без `alert` и
`mutable-content` пуш получается data-only, iOS не показывает его и не будит расширение. Это
`PushRegistration.defaultPayload()` в приложении, не настройка сервера; `PushPayloadTests` держит
его форму.

Если расширение скажет «nobody is signed in» на устройстве, где вход выполнен, — смотреть
`AppIdentifierPrefix` в его `Info.plist`. Внутри расширения `Bundle.main` — это бандл
*расширения*, и без этого ключа префикс команды теряется, keychain-группа выходит без него, и
Keychain честно ничего не находит. Это описано в `CLAUDE.md`.

## 4. Звонки: второй pusher и свой pushkin

Звонок на iOS должен прийти **VoIP-пушем** — это единственный вид, ради которого iOS будит
приложение вовремя, чтобы зазвонить. И с iOS 13 каждый доставленный VoIP-пуш обязан закончиться
`CXProvider.reportNewIncomingCall`: промах — и система сначала придерживает пуши, потом перестаёт
их доставлять этому приложению совсем, до переустановки, и нигде об этом не пишет.

Значит, VoIP-пуш должен приходить на звонки и ни на что больше. А правила пушей в Matrix
маршрутизировать по pusher'ам не умеют: **каждый pusher на аккаунте получает каждое уведомление.**

### Почему не «полный payload»

Очевидный выход — зарегистрировать VoIP-pusher без `format: event_id_only`, чтобы шлюз видел `type`
и сам отбрасывал всё, что не звонок. Работает. И стоит того, что шлюз начинает получать `type`,
`sender`, `sender_display_name`, `room_name` и `content` по **каждому** уведомлению в аккаунте,
навсегда, — чтобы отвечать на вопрос «да/нет» про одно событие в день. В незашифрованной комнате
`content` это текст сообщения. Ровно та сделка, от которой отказывается весь остальной этот
документ.

### Как сделано

Клиент ставит своё override-правило (`CallPushRule`, id `moscow.swag.iskra.calls`), которое
матчит `*rtc.notification` и вешает на уведомление метку:

```
set_tweak: sound = "iskra.ring"
```

Метка едет в `devices[].tweaks` — **снаружи** урезанного события, — поэтому `event_id_only` её не
трогает. Оба pusher'а остаются `event_id_only`, шлюз узнаёт ровно один бит.

Глоб, а не точная строка: MSC4075/4143 ещё в полёте, и сервер вправе писать как
`m.rtc.notification`, так и unstable-префикс. Хвост стабилен, начало — нет.

### Почему именно `sound`, а не свой тег

Логично было бы поставить свой тег — `set_tweak: moscow.swag.iskra.ring` — спецификация это
разрешает, Synapse такое пересылает, и в FFI для этого есть `Tweak.custom`. **Не работает**, и
причина не в Matrix, а внутри самого Sygnal. Он разбирает уведомление раньше, чем его увидит любой
pushkin, и разбирает вот так (`sygnal/notifications.py`):

```python
class Tweaks:
    def __init__(self, raw):
        self.sound = get_key(raw, "sound", str)
```

`sound` сохраняется, всё остальное выбрасывается. Сырого payload'а `Notification` тоже не хранит —
каждое устройство превращается в объект `Device` ещё до вызова pushkin'а. То есть свой тег доезжает
до машины и теряется **внутри процесса шлюза**, на слой выше всего, что мы можем написать.

`sound` переживает разбор, это строка, и значение наше. Отсюда звук, которого никто не услышит:
файла `iskra.ring` в бандле нет, а звонит CallKit, а не уведомление. Проверено по исходникам Sygnal,
не выведено из общих соображений.

### Записи в `sygnal.yaml`

Две новых, рядом с теми двумя, что уже есть:

```yaml
  moscow.swag.iskra.voip.dev:
    type: iskra_ring.RingPushkin      # наш подкласс sygnal.apnspushkin.ApnsPushkin
    keyfile: /keys/AuthKey_XXXXXXXXXX.p8
    key_id: XXXXXXXXXX
    team_id: 936RH3UPR3
    topic: moscow.swag.iskra.voip     # bundle id + ".voip" — это и есть весь VoIP-переключатель
    platform: sandbox
    push_type: voip
    convert_device_token_to_hex: false
```

и `moscow.swag.iskra.voip` с `platform: production`. Тот же `.p8`-ключ, что и у обычных записей:
отдельный VoIP-сертификат нужен только при авторизации сертификатом, а не токеном.

`RingPushkin` (`Gateway/iskra_ring.py` в репозитории) — подкласс `ApnsPushkin`, который молча
ничего не отправляет, если `device.tweaks.sound` не наш. Он же вычищает `aps` из payload'а: PushKit
отдаёт приложению словарь целиком, а `mutable-content` и `alert` из обычного `default_payload` там
не нужны.

Своим кодом, а не конфигом: фильтровать надо по метке, чего конфигом не выразить. Переопределяется
`_dispatch_notification_unlimited`, а не `dispatch_notification` — последний принадлежит базовому
классу с ограничением параллелизма, и перекрыв его, это ограничение молча снимаешь.

Все три опоры на внутренности Sygnal (хук диспетчеризации, сборщик payload'а и `Tweaks.sound`)
проверяются на импорте: контейнер, которому они не подошли, не поднимется. Это лучше, чем шлюз,
который поднялся и молча никому не звонит, — со стороны такой неотличим от рабочего.

### Порядок

**Правило первым, VoIP-pusher последним.** В приложении это `enableCallPushes()` перед
`VoIPPermission.signedIn` (`IskraRootView`). Наоборот — это VoIP-пуш на каждое сообщение в окне
между ними, а за это iOS отбирает право на VoIP.

### Ловушки, каждая из которых выглядит как успех

- **Топик без `.voip`.** APNs отвечает `400 BadTopic` в логе Sygnal и ничего не шлёт на устройство.
- **`push_type: alert` с правильным топиком.** Может быть принято, и PushKit этого не увидит.
- **`platform: production` против Debug-сборки.** `400 BadDeviceToken` при **64-символьном** токене
  — та же арифметика длины, что и в разделе 1, только теперь для PushKit-токена.
- **Нет `voip` в `UIBackgroundModes`.** `PKPushRegistry` не выдаёт токен, `didUpdate` не зовётся,
  **ошибки нет нигде**. Весь диагноз — `Iskra --probe-voip-token`, который печатает «нет токена».
- **Правило есть, pushkin'а нет.** Звонок notify'ится, доезжает обычным пушем, расширение его
  глушит — и телефон не звонит, при том что на сервере всё «настроено».

### Чем проверять

```sh
# устройство: есть ли токен и какие pusher'ы висят на аккаунте
xcrun devicectl device process launch --console --device <id> moscow.swag.iskra --probe-voip-token

# устройство: рисует ли CallKit экран вообще
xcrun devicectl device process launch --console --device <id> moscow.swag.iskra --probe-callkit

# где угодно, включая симулятор: расшифровывается ли звонок и что увидел бы CallKit
xcrun simctl launch --console booted moscow.swag.iskra --probe-ring '!room:server' '$event'
```

Первые две — только устройство: в симуляторе APNs нет, а `CXProvider` принимает звонки и не рисует
ничего. Третья доказывает всю «решающую» половину и **ничего** про PushKit.

## Чего делать не нужно

Не писать «пока что» свой HTTP-клиент поверх access token, чтобы обойти шлюз. Пуш всё равно
приходит от Apple, а не от нас; обойти APNs нечем.
