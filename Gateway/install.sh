#!/usr/bin/env bash
#
# Выкатывает поддержку звонков на push-шлюз. Запускать на самом шлюзе:
#
#     cd ~/iskra-calls && sudo bash install.sh
#
# Делает три вещи: кладёт свой pushkin, добавляет две .voip-записи в sygnal.yaml и чинит проброс
# порта. Последнее — не косметика: в старом docker-compose.yml стоит 5400:5400, а Sygnal внутри
# слушает 5000, и контейнер, пересозданный по тому файлу, не отвечал бы вовсе — умерли бы ВСЕ
# пуши, не только звонки.
#
# ## Почему здесь нет docker compose
#
# Первая версия этого скрипта звала `docker compose up -d` и упала: на этой машине плагина
# compose нет, и `docker` разбирает `-d` сам, отвечая `unknown shorthand flag`. Это описано в
# docs/PUSH-GATEWAY.md, раздел 1, и compose здесь всё равно ничего не даёт — контейнер один.
# Так что всё делается голым `docker`, который есть всегда.
#
# ## Если что-то пойдёт не так
#
# Скрипт снимает бэкап до первого изменения и откатывается сам, если после перезапуска шлюз не
# отвечает. Откат возвращает файлы и поднимает контейнер заново — с тем же пробросом 5400:5000,
# который сходится с `port: 5000` в восстановленном sygnal.yaml.

set -euo pipefail

STAGE="${STAGE:-/home/me/iskra-calls}"
LIVE="${LIVE:-/opt/sygnal}"
IMAGE="matrixdotorg/sygnal:latest"
NAME="sygnal"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$LIVE/backup-$STAMP"

if [ "$(id -u)" -ne 0 ]; then
    echo "нужен root: sudo bash install.sh" >&2
    exit 1
fi

for f in "$STAGE/sygnal.yaml" "$STAGE/docker-compose.yml" "$STAGE/pushkins/iskra_ring.py"; do
    [ -f "$f" ] || { echo "нет файла $f — сначала подготовь их в $STAGE" >&2; exit 1; }
done

# Контейнер ищется по образу, а не по имени: его создавал compose, и как он его назвал —
# неизвестно. После этого скрипта он будет называться "sygnal" и управляться обычным docker.
current_container() {
    docker ps -aq --filter "ancestor=$IMAGE" | head -1
}

start_container() {
    docker run -d --name "$NAME" --restart unless-stopped \
        -p 127.0.0.1:5400:5000 \
        -v "$LIVE/sygnal.yaml:/sygnal.yaml:ro" \
        -v "$LIVE/keys:/keys:ro" \
        -v "$LIVE/pushkins:/pushkins:ro" \
        -e PYTHONPATH=/pushkins \
        "$IMAGE" >/dev/null
}

# 400 на пустой POST — это и значит «живой»: Sygnal разобрал запрос и честно его отверг.
healthy() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        -X POST -H 'Content-Type: application/json' -d '{}' \
        http://127.0.0.1:5400/_matrix/push/v1/notify || true)"
    [ "$code" = "400" ]
}

rollback() {
    echo
    echo "!!! откат из $BACKUP"
    cp -a "$BACKUP/sygnal.yaml" "$LIVE/sygnal.yaml"
    cp -a "$BACKUP/docker-compose.yml" "$LIVE/docker-compose.yml"

    docker rm -f "$NAME" >/dev/null 2>&1 || true
    start_container || true

    for _ in $(seq 1 20); do
        sleep 1
        if healthy; then
            echo "!!! вернул как было, шлюз отвечает"
            exit 1
        fi
    done

    echo "!!! ОТКАТ НЕ ПОМОГ. Смотреть: docker logs --tail=100 $NAME" >&2
    exit 2
}

echo "==> бэкап в $BACKUP"
mkdir -p "$BACKUP"
cp -a "$LIVE/sygnal.yaml" "$LIVE/docker-compose.yml" "$BACKUP/"

OLD="$(current_container)"
if [ -n "$OLD" ]; then
    # Слепок старого контейнера — на случай, если понадобится узнать, чем он отличался.
    docker inspect "$OLD" > "$BACKUP/container.json" 2>/dev/null || true
    echo "==> нашёл контейнер $OLD, его конфиг сохранён в $BACKUP/container.json"
else
    echo "==> работающего контейнера из $IMAGE не нашлось — подниму новый"
fi

echo "==> кладу файлы"
install -d -m 755 "$LIVE/pushkins"
install -m 644 "$STAGE/pushkins/iskra_ring.py" "$LIVE/pushkins/iskra_ring.py"
install -m 644 "$STAGE/sygnal.yaml" "$LIVE/sygnal.yaml"
install -m 644 "$STAGE/docker-compose.yml" "$LIVE/docker-compose.yml"

echo "==> пересоздаю контейнер"
[ -n "$OLD" ] && docker rm -f "$OLD" >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
start_container || rollback

echo "==> жду, пока поднимется"
for _ in $(seq 1 20); do
    sleep 1
    if healthy; then
        echo "==> шлюз отвечает"
        echo
        echo "==> что в логах про нас:"
        docker logs --tail=60 "$NAME" 2>&1 | grep -iE "iskra|pushkin|voip|error|Traceback" | tail -20 || true
        echo
        echo "ГОТОВО. Бэкап: $BACKUP"
        echo "Если понадобится вернуть всё руками: файлы оттуда + docker rm -f $NAME + этот скрипт."
        exit 0
    fi
done

echo "!!! шлюз не ответил за 20 секунд"
docker logs --tail=80 "$NAME" 2>&1 | tail -40 || true
rollback
