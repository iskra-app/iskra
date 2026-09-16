#!/bin/bash
#
# Собирает Iskra из ветки dev и ставит её на подключённый iPhone.
#
#   ./device.sh                       # собрать dev и запустить на телефоне
#   ./device.sh --fetch               # сначала подтянуть origin/dev
#   ./device.sh --device 'iPhone (Боря)'
#   ./device.sh --here                # собрать текущее рабочее дерево, а не dev
#   ./device.sh --no-launch           # только поставить
#   ./device.sh -- --probe-signin matrix.org   # всё после -- уходит приложению
#
# Сборка идёт не в рабочем дереве, а в отдельном git worktree с чистой веткой dev
# (.build/dev-src): «собрать из dev» не должно зависеть от того, что сейчас лежит
# незакоммиченным под руками, и не должно эти изменения трогать. --here отключает это.
#
# CODE_SIGNING_ALLOWED=NO здесь нет и быть не должно. Сборка бы прошла, приложение бы
# встало и умерло с SIGTRAP на первом же входе: неподписанному приложению не выдают
# ни одного entitlement, и контейнер App Group не резолвится. См. CLAUDE.md.

set -euo pipefail

cd "$(dirname "$0")"
REPO="$PWD"

BUNDLE_ID="moscow.swag.iskra"
BRANCH="dev"
DERIVED="$REPO/.build/xcode-device"
SRC="$REPO/.build/dev-src"

device="${ISKRA_DEVICE:-}"
fetch=0
here=0
launch=1
app_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="${2:?--device требует имя или UDID}"; shift 2 ;;
    --fetch) fetch=1; shift ;;
    --here) here=1; shift ;;
    --no-launch) launch=0; shift ;;
    --) shift; app_args=("$@"); break ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1 (аргументы приложения — после --)" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- устройство

say "Ищу iPhone"
devices=$(xcrun devicectl list devices 2>/dev/null) || die "devicectl не отвечает — нет Xcode?"
# Физические устройства, одной строкой «UDID<TAB>имя». Столбцы фиксированной ширины,
# поэтому имя берётся до двух пробелов подряд, а UDID — по форме, а не по позиции.
phones=$(printf '%s\n' "$devices" | awk '
  /physical/ {
    match($0, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f-]{36}/)
    udid = substr($0, RSTART, RLENGTH)
    name = $0
    sub(/  .*/, "", name)
    if (udid != "") printf "%s\t%s\n", udid, name
  }')
[ -n "$phones" ] || die "Ни одного устройства не подключено. Воткни кабель или включи Wi-Fi-отладку, и разблокируй экран."

if [ -n "$device" ]; then
  match=$(printf '%s\n' "$phones" | grep -i -- "$device" || true)
  [ -n "$match" ] || die "Устройство «$device» не найдено. Есть такие:
$phones"
  [ "$(printf '%s\n' "$match" | wc -l)" -eq 1 ] || die "Под «$device» подходит больше одного устройства:
$match"
else
  match="$phones"
  [ "$(printf '%s\n' "$match" | wc -l)" -eq 1 ] || die "Подключено несколько устройств — выбери одно через --device:
$phones"
fi
device_id=$(printf '%s' "$match" | cut -f1)
device_name=$(printf '%s' "$match" | cut -f2)
echo "    $device_name ($device_id)"

# ---------------------------------------------------------------- исходники

if [ "$here" -eq 1 ]; then
  src="$REPO"
  say "Собираю текущее рабочее дерево ($(git -C "$REPO" rev-parse --abbrev-ref HEAD))"
else
  if [ "$fetch" -eq 1 ]; then
    say "git fetch origin $BRANCH"
    git -C "$REPO" fetch origin "$BRANCH"
  fi
  git -C "$REPO" rev-parse --verify --quiet "$BRANCH" >/dev/null || die "Ветки $BRANCH в репозитории нет."

  # Отдельный worktree на detached HEAD в вершине dev: повторный запуск просто
  # переставляет его на новый коммит, клонировать заново ничего не нужно. Detached —
  # чтобы не отбирать ветку dev у основного рабочего дерева: git не даёт одной ветке
  # быть выписанной в двух worktree сразу.
  if [ -e "$SRC/.git" ]; then
    git -C "$SRC" checkout --quiet --detach "$BRANCH"
  else
    mkdir -p "$(dirname "$SRC")"
    git -C "$REPO" worktree add --detach "$SRC" "$BRANCH" >/dev/null
  fi
  src="$SRC"
  say "Собираю $BRANCH ($(git -C "$src" log -1 --format='%h %s'))"
fi

# ---------------------------------------------------------------- сборка

say "Генерирую Iskra.xcodeproj"
(cd "$src/Apps" && xcodegen)

say "xcodebuild для устройства"
# -allowProvisioningUpdates: подпись автоматическая, и профиль на новый App ID
# (например, у share-расширения) Xcode обязан выписать сам — иначе сборка встанет
# с «no profiles found» там, где в GUI всё чинится одной галочкой.
xcodebuild -project "$src/Apps/Iskra.xcodeproj" -scheme 'Iskra (iOS)' \
  -destination "id=$device_id" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build

app="$DERIVED/Build/Products/Debug-iphoneos/Iskra.app"
[ -d "$app" ] || die "Сборка прошла, а $app нет — что-то поменялось в конфигурации."

# ---------------------------------------------------------------- установка

say "Ставлю на $device_name"
xcrun devicectl device install app --device "$device_id" "$app"

if [ "$launch" -eq 1 ]; then
  say "Запускаю"
  # --console держит терминал и печатает логи приложения: ради них этот скрипт обычно
  # и запускают, потому что на подписанной сборке на телефоне отладчика нет.
  # ${a[@]+"${a[@]}"}, а не "${a[@]}": в /bin/bash 3.2 под set -u пустой массив — это
  # unbound variable, то есть падение на последнем шаге после успешной сборки.
  xcrun devicectl device process launch --console --terminate-existing \
    --device "$device_id" "$BUNDLE_ID" ${app_args[@]+"${app_args[@]}"}
else
  say "Готово, приложение установлено"
fi
