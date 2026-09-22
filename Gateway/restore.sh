#!/usr/bin/env bash
# Поднимает шлюз в том виде, в каком он был ДО звонков. Без pushkin, без voip-записей.
# Цель одна: чтобы ходили обычные пуши. Звонки — потом, отдельно.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "нужен root: sudo bash restore.sh" >&2; exit 1; }

CLEAN=/opt/sygnal/backup-20260922-072645     # самый ранний: в нём нет ни одной строки про voip
grep -q voip "$CLEAN/sygnal.yaml" && { echo "этот бэкап не чистый, остановись" >&2; exit 1; }

echo "==> возвращаю sygnal.yaml до звонков"
cp -a "$CLEAN/sygnal.yaml" /opt/sygnal/sygnal.yaml

echo "==> поднимаю контейнер без pushkin"
docker rm -f sygnal >/dev/null 2>&1 || true
docker run -d --name sygnal --restart unless-stopped \
  -p 127.0.0.1:5400:5000 \
  -v /opt/sygnal/sygnal.yaml:/sygnal.yaml:ro \
  -v /opt/sygnal/keys:/keys:ro \
  matrixdotorg/sygnal:latest >/dev/null

for _ in $(seq 1 20); do
  sleep 1
  if [ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 -X POST \
      -H "Content-Type: application/json" -d "{}" \
      http://127.0.0.1:5400/_matrix/push/v1/notify || true)" = "400" ]; then
    echo "==> шлюз отвечает. Обычные пуши снова ходят."
    exit 0
  fi
done

echo "!!! не поднялся. docker logs --tail=100 sygnal" >&2
docker logs --tail=60 sygnal 2>&1 | tail -30 >&2
exit 1
