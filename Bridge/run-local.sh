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
#   RELEASE=1 ./run-local.sh          # медленнее собирается, быстрее работает
#
set -euo pipefail

cd "$(dirname "$0")"

KEY_FILE="${BRIDGE_KEY_FILE:-.bridge-key}"
HOMESERVER_URL="${HOMESERVER_URL:-https://matrix-client.matrix.org}"
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
if [ ! -f "$KEY_FILE" ]; then
  echo "Ключа нет, создаю $KEY_FILE"
  openssl rand -hex 32 > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
fi
BRIDGE_NOSTR_PRIVKEY="$(tr -d '[:space:]' < "$KEY_FILE")"

CARGO_ARGS=(run -q -p iskra-bridge)
if [ "${RELEASE:-}" = "1" ]; then
  CARGO_ARGS=(run -q --release -p iskra-bridge)
fi

echo "homeserver : $HOMESERVER_URL"
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
  HOMESERVER_URL="$HOMESERVER_URL" \
  BRIDGE_NOSTR_PRIVKEY="$BRIDGE_NOSTR_PRIVKEY" \
  RELAY_LIST="$RELAY_LIST" \
  RATE_LIMIT_PER_MIN="$RATE_LIMIT_PER_MIN" \
  REQUEST_TIMEOUT_SECS="$REQUEST_TIMEOUT_SECS" \
  ${ALLOWED_PUBKEYS:+ALLOWED_PUBKEYS="$ALLOWED_PUBKEYS"} \
  ${CLIENT_RELAY_LIST:+CLIENT_RELAY_LIST="$CLIENT_RELAY_LIST"} \
  RUST_LOG="$RUST_LOG" \
  cargo "${CARGO_ARGS[@]}"
