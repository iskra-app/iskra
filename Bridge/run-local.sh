#!/usr/bin/env bash
#
# Поднять бридж на этом компьютере.
#
# Ничего пробрасывать не нужно: бридж сам дозванивается до relay наружу, поэтому живёт за любым
# NAT. Единственное требование — с этой машины должен быть доступен homeserver, иначе бридж упрётся
# ровно в ту же стену, что и телефон, и смысла в нём не будет.
#
#   ./run-local.sh
#   HOMESERVER_URL=https://matrix.example.org ./run-local.sh
#   ALLOWED_UPSTREAMS='matrix.org,matrix-client.matrix.org,example.org' ./run-local.sh
#   ALLOWED_UPSTREAMS='*' ./run-local.sh    # любой публичный хоумсервер
#   RELEASE=1 ./run-local.sh          # медленнее собирается, быстрее работает
#
set -euo pipefail

cd "$(dirname "$0")"

KEY_FILE="${BRIDGE_KEY_FILE:-.bridge-key}"
# Куда мосту разрешено ходить. По умолчанию — matrix.org целиком: и имя, которому задают
# .well-known, и адрес, где реально живёт API. Это не перестраховка: discovery спрашивают у
# matrix.org, а всё после него принадлежит matrix-client.matrix.org, так что мост на одном адресе
# не обслужит толком и одного аккаунта. Свой список пишут через запятую; `*` — любой публичный
# хоумсервер, и тогда мост стоит закрыть по ALLOWED_PUBKEYS.
ALLOWED_UPSTREAMS="${ALLOWED_UPSTREAMS:-matrix.org,matrix-client.matrix.org}"
# damus по умолчанию не включён: он регулярно отвечает 503 на само подключение. Список из
# нескольких relay — не запас на будущее, а рабочая отказоустойчивость: событие уходит на все сразу,
# ответ приходит с того, который оказался быстрее.
RELAY_LIST="${RELAY_LIST:-wss://nos.lol,wss://relay.primal.net,wss://relay.nostr.band}"
RATE_LIMIT_PER_MIN="${RATE_LIMIT_PER_MIN:-120}"
REQUEST_TIMEOUT_SECS="${REQUEST_TIMEOUT_SECS:-60}"
RUST_LOG="${RUST_LOG:-info}"

if ! command -v cargo >/dev/null 2>&1; then
  echo "Нужен Rust. Поставить: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" >&2
  exit 1
fi

# Ключ создаётся один раз и лежит рядом. Он определяет pubkey бриджа — тот самый, который вписывают
# в клиент, — поэтому пересоздавать его на каждый запуск значило бы менять адрес бриджа при каждом
# перезапуске.
#
# Создаёт его сам мост (BRIDGE_KEY_FILE): сразу с правами 600, без мгновения, когда файл читается
# всеми, как было с `openssl rand > файл; chmod 600`. И ключ не уходит в окружение процесса, где
# его видно в /proc/<pid>/environ.
if [ ! -f "$KEY_FILE" ]; then
  echo "Ключа нет — мост создаст $KEY_FILE при запуске"
fi

CARGO_ARGS=(run -q -p iskra-bridge)
if [ "${RELEASE:-}" = "1" ]; then
  CARGO_ARGS=(run -q --release -p iskra-bridge)
fi

if [ "$ALLOWED_UPSTREAMS" = "*" ]; then
  echo "серверы    : любой публичный (открытый мост)"
else
  echo "серверы    : $ALLOWED_UPSTREAMS"
fi
echo "relay      : $RELAY_LIST"
echo "лимит      : $RATE_LIMIT_PER_MIN запросов в минуту на клиента"
if [ -n "${ALLOWED_PUBKEYS:-}" ]; then
  echo "доступ     : только перечисленные ключи"
else
  echo "доступ     : открытый (задайте ALLOWED_PUBKEYS, чтобы закрыть)"
fi
echo "pubkey бриджа будет напечатан ниже — его и вписывают в клиент."
echo

exec env \
  ALLOWED_UPSTREAMS="$ALLOWED_UPSTREAMS" \
  ${HOMESERVER_URL:+HOMESERVER_URL="$HOMESERVER_URL"} \
  BRIDGE_KEY_FILE="$KEY_FILE" \
  RELAY_LIST="$RELAY_LIST" \
  RATE_LIMIT_PER_MIN="$RATE_LIMIT_PER_MIN" \
  REQUEST_TIMEOUT_SECS="$REQUEST_TIMEOUT_SECS" \
  ${ALLOWED_PUBKEYS:+ALLOWED_PUBKEYS="$ALLOWED_PUBKEYS"} \
  ${CLIENT_RELAY_LIST:+CLIENT_RELAY_LIST="$CLIENT_RELAY_LIST"} \
  RUST_LOG="$RUST_LOG" \
  cargo "${CARGO_ARGS[@]}"
