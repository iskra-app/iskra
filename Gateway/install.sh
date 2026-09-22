#!/usr/bin/env bash
#
# Выкатывает поддержку звонков на push-шлюз. Запускать на самом шлюзе:
#
#     cd ~/iskra-calls && sudo bash install.sh
#
# Кладёт свой pushkin, добавляет две .voip-записи в sygnal.yaml, чинит проброс порта и
# пересоздаёт контейнер. Если после этого шлюз не отвечает — откатывается сам.
#
# ## Почему здесь нет docker compose
#
# На этой машине плагина compose нет, и `docker` разбирает `-d` сам, отвечая
# `unknown shorthand flag`. Это описано в docs/PUSH-GATEWAY.md, раздел 1. Контейнер один, compose
# ничего не даёт, и ищется контейнер по образу, а не по имени: имя ему давал compose.
#
# ## Откат, и почему он двухступенчатый
#
# Первая версия восстанавливала два yaml-файла и считала это откатом. Этого не хватило, и шлюз
# полежал: `pushkins/iskra_ring.py` к тому моменту уже был перезаписан новым, а восстановленный
# sygnal.yaml на него ссылался — Sygnal падал на старте, и «откат» возвращал ровно ту же поломку.
#
# Поэтому теперь, по порядку:
#
#   1. восстановить ВСЁ, что трогали, включая pushkins/, и поднять;
#   2. если и это не встало — поднять шлюз **без звонков вообще**: конфиг из самого раннего
#      бэкапа, где нет ни строчки про voip, и контейнер без тома с pushkin'ом.
#
# Второй шаг важнее первого. Шлюз без звонков — это работающие уведомления; шлюз, который не
# поднялся, — это тишина на всех устройствах сразу.

set -euo pipefail

STAGE="${STAGE:-/home/me/iskra-calls}"
LIVE="${LIVE:-/opt/sygnal}"
IMAGE="matrixdotorg/sygnal:latest"
NAME="sygnal"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$LIVE/backup-$STAMP"

[ "$(id -u)" -eq 0 ] || { echo "нужен root: sudo bash install.sh" >&2; exit 1; }

for f in "$STAGE/sygnal.yaml" "$STAGE/docker-compose.yml" "$STAGE/pushkins/iskra_ring.py"; do
    [ -f "$f" ] || { echo "нет файла $f — сначала подготовь их в $STAGE" >&2; exit 1; }
done

healthy() {
    # 400 на пустой POST — это и значит «живой»: Sygnal разобрал запрос и честно его отверг.
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
        -X POST -H 'Content-Type: application/json' -d '{}' \
        http://127.0.0.1:5400/_matrix/push/v1/notify || true)" = "400" ]
}

wait_healthy() {
    for _ in $(seq 1 20); do
        sleep 1
        healthy && return 0
    done
    return 1
}

start_container() {
    # $1 — "with-calls" или "no-calls"
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    if [ "$1" = "with-calls" ]; then
        docker run -d --name "$NAME" --restart unless-stopped \
            -p 127.0.0.1:5400:5000 \
            -v "$LIVE/sygnal.yaml:/sygnal.yaml:ro" \
            -v "$LIVE/keys:/keys:ro" \
            -v "$LIVE/pushkins:/pushkins:ro" \
            -e PYTHONPATH=/pushkins \
            "$IMAGE" >/dev/null
    else
        docker run -d --name "$NAME" --restart unless-stopped \
            -p 127.0.0.1:5400:5000 \
            -v "$LIVE/sygnal.yaml:/sygnal.yaml:ro" \
            -v "$LIVE/keys:/keys:ro" \
            "$IMAGE" >/dev/null
    fi
}

# Самый ранний конфиг, в котором нет ни слова про звонки. Последняя опора отката.
precalls_config() {
    local candidate
    for candidate in "$LIVE"/backup-*/sygnal.yaml; do
        [ -f "$candidate" ] || continue
        grep -q voip "$candidate" || { echo "$candidate"; return 0; }
    done
    return 1
}

rollback() {
    echo
    echo "!!! ступень 1: возвращаю всё из $BACKUP"
    cp -a "$BACKUP/sygnal.yaml" "$LIVE/sygnal.yaml"
    cp -a "$BACKUP/docker-compose.yml" "$LIVE/docker-compose.yml"
    if [ -d "$BACKUP/pushkins" ]; then
        rm -rf "$LIVE/pushkins"
        cp -a "$BACKUP/pushkins" "$LIVE/pushkins"
    else
        # Бэкап снят до того, как звонки вообще появились — значит и каталога быть не должно.
        rm -rf "$LIVE/pushkins"
    fi

    start_container with-calls || true
    if wait_healthy; then
        echo "!!! вернул как было, шлюз отвечает"
        exit 1
    fi

    echo
    echo "!!! ступень 2: поднимаю шлюз БЕЗ звонков — лишь бы ходили обычные пуши"
    local clean
    if clean="$(precalls_config)"; then
        cp -a "$clean" "$LIVE/sygnal.yaml"
        echo "!!! взял конфиг из $clean"
    else
        echo "!!! чистого конфига не нашлось, пробую как есть" >&2
    fi

    start_container no-calls || true
    if wait_healthy; then
        echo
        echo "!!! ШЛЮЗ ПОДНЯТ БЕЗ ЗВОНКОВ. Обычные пуши ходят, звонки выключены."
        echo "!!! Что сломалось: docker logs --tail=100 $NAME"
        exit 1
    fi

    echo "!!! ШЛЮЗ НЕ ПОДНЯЛСЯ ВООБЩЕ. docker logs --tail=100 $NAME" >&2
    docker logs --tail=60 "$NAME" 2>&1 | tail -30 >&2
    exit 2
}

if healthy; then
    echo "==> шлюз сейчас живой, это и будем защищать"
else
    echo "==> шлюз сейчас НЕ отвечает — значит терять нечего, поднимаю со звонками"
fi

echo "==> бэкап в $BACKUP"
mkdir -p "$BACKUP"
cp -a "$LIVE/sygnal.yaml" "$LIVE/docker-compose.yml" "$BACKUP/"
# Вместе с pushkin'ом: без него откат возвращает конфиг, ссылающийся на файл, которого больше
# нет в том виде. Именно на этом шлюз один раз и слёг.
[ -d "$LIVE/pushkins" ] && cp -a "$LIVE/pushkins" "$BACKUP/pushkins"

OLD="$(docker ps -aq --filter "ancestor=$IMAGE" | head -1)"
if [ -n "$OLD" ]; then
    docker inspect "$OLD" > "$BACKUP/container.json" 2>/dev/null || true
    echo "==> нашёл контейнер $OLD, его конфиг сохранён в $BACKUP/container.json"
fi

echo "==> кладу файлы"
install -d -m 755 "$LIVE/pushkins"
install -m 644 "$STAGE/pushkins/iskra_ring.py" "$LIVE/pushkins/iskra_ring.py"
install -m 644 "$STAGE/sygnal.yaml" "$LIVE/sygnal.yaml"
install -m 644 "$STAGE/docker-compose.yml" "$LIVE/docker-compose.yml"

echo "==> пересоздаю контейнер"
[ -n "$OLD" ] && docker rm -f "$OLD" >/dev/null 2>&1 || true
start_container with-calls || rollback

echo "==> жду, пока поднимется"
if wait_healthy; then
    echo "==> шлюз отвечает"
    echo
    echo "==> что в логах про нас:"
    docker logs --tail=80 "$NAME" 2>&1 | grep -iE "iskra|pushkin|voip|error|Traceback" | tail -20 || true
    echo
    echo "ГОТОВО. Бэкап: $BACKUP"
    exit 0
fi

echo "!!! шлюз не ответил за 20 секунд"
docker logs --tail=80 "$NAME" 2>&1 | tail -40 || true
rollback
