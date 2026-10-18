#!/bin/bash
#
# Собирает Iskra из ветки dev и ставит её на подключённый iPhone.
#
#   ./device.sh                       # собрать dev и запустить на телефоне
#   ./device.sh --fetch               # сначала подтянуть origin/dev
#   ./device.sh --device 'iPhone (Боря)'
#   ./device.sh --here                # собрать текущее рабочее дерево, а не dev
#   ./device.sh --no-launch           # только поставить
#   ./device.sh --verbose             # весь вывод xcodegen, xcodebuild и devicectl
#   ./device.sh -- --probe-signin matrix.org   # всё после -- уходит приложению
#
# Без --verbose вывод инструментов пишется в .build/logs/<шаг>.log, а в консоли остаются
# шаги, сколько каждый занял и — если какой-то упал — его строки с ошибками и путь к логу.
# Логи самого приложения после запуска печатаются всегда: ради них скрипт и запускают.
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

BUNDLE_ID="wtf.iskra"
BRANCH="dev"
DERIVED="$REPO/.build/xcode-device"
SRC="$REPO/.build/dev-src"
LOGS="$REPO/.build/logs"

device="${ISKRA_DEVICE:-}"
fetch=0
here=0
launch=1
verbose=0
app_args=()

while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="${2:?--device требует имя или UDID}"; shift 2 ;;
    --fetch) fetch=1; shift ;;
    --here) here=1; shift ;;
    --no-launch) launch=0; shift ;;
    --verbose) verbose=1; shift ;;
    --) shift; app_args=("$@"); break ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Неизвестный аргумент: $1 (аргументы приложения — после --)" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$1" >&2; exit 1; }

# quietly <имя лога> <команда...>: вывод команды уходит в .build/logs/<имя>.log, на экран —
# только сколько она шла. Если упала — строки с ошибками из лога, а если инструмент не
# написал ни одной в привычном виде, то хвост лога: причина должна быть на экране, а не
# в двух тысячах строк вызовов компилятора над ней.
quietly() {
  local name="$1"; shift
  if [ "$verbose" -eq 1 ]; then "$@"; return; fi
  mkdir -p "$LOGS"
  local log="$LOGS/$name.log" start=$SECONDS status
  if "$@" >"$log" 2>&1; then
    printf '    готово за %d с\n' $((SECONDS - start))
  else
    status=$?
    printf '\033[1;31m    упало через %d с:\033[0m\n' $((SECONDS - start)) >&2
    { grep -E '(^|[: ])(fatal )?error:|\*\* [A-Z ]+ FAILED \*\*' "$log" || tail -n 30 "$log"; } \
      | awk '!seen[$0]++' | head -n 50 >&2
    printf '    весь лог: %s\n' "$log" >&2
    return "$status"
  fi
}

# ---------------------------------------------------------------- устройство

say "Ищу iPhone"
devices=$(xcrun devicectl list devices 2>/dev/null) || die "devicectl не отвечает — нет Xcode?"
# Физические устройства, одной строкой «UDID<TAB>имя<TAB>состояние». Столбцы фиксированной
# ширины, поэтому UDID ищется по форме, а имя и состояние — как текст до и после него,
# каждое до двух пробелов подряд.
phones=$(printf '%s\n' "$devices" | awk '
  /physical/ {
    if (!match($0, /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f-]{36}/)) next
    udid = substr($0, RSTART, RLENGTH)
    name = substr($0, 1, RSTART - 1)
    sub(/^ +/, "", name); sub(/  .*/, "", name)
    state = substr($0, RSTART + RLENGTH)
    sub(/^ *\(UDID\) */, "", state); sub(/  .*/, "", state)
    printf "%s\t%s\t%s\n", udid, name, state
  }')
[ -n "$phones" ] || die "Ни одного устройства не подключено. Воткни кабель или включи Wi-Fi-отладку, и разблокируй экран."

# devicectl перечисляет каждый телефон, который когда-либо был спарен с этим Mac, — и давно
# унесённый домой тоже, с состоянием «unavailable». Если считать их вместе с подключённым,
# скрипт упирается в «несколько устройств» там, где воткнут один.
connected() { printf '%s\n' "$1" | awk -F'\t' 'NF && $3 !~ /^unavailable/'; }
count() { if [ -n "$1" ]; then printf '%s\n' "$1" | wc -l | tr -d ' '; else echo 0; fi; }

# ${device}, а не $device, перед «»»: /bin/bash 3.2 считает первый байт этой кавычки
# частью имени переменной и падает с «device�: unbound variable» вместо сообщения.
if [ -n "$device" ]; then
  # Сначала точное совпадение с UDID или именем, и только потом подстрока: иначе имя,
  # которое целиком входит в чужое, не выбрать никак.
  match=$(printf '%s\n' "$phones" | awk -F'\t' -v d="$device" 'tolower($1) == tolower(d) || $2 == d')
  [ -n "$match" ] || match=$(printf '%s\n' "$phones" | grep -iF -- "$device" || true)
  [ -n "$match" ] || die "Устройство «${device}» не найдено. Есть такие:
$phones"
  # Из нескольких подходящих берётся подключённое, если оно одно.
  if [ "$(count "$match")" -gt 1 ] && [ "$(count "$(connected "$match")")" -eq 1 ]; then
    match=$(connected "$match")
  fi
  [ "$(count "$match")" -eq 1 ] || die "Под «${device}» подходит больше одного устройства:
$match"
  [ -n "$(connected "$match")" ] || die "«$(printf '%s' "$match" | cut -f2)» сейчас не подключён. Воткни кабель или включи Wi-Fi-отладку, и разблокируй экран."
else
  match=$(connected "$phones")
  [ -n "$match" ] || die "Ни одно из известных устройств сейчас не подключено. Воткни кабель или включи Wi-Fi-отладку, и разблокируй экран:
$phones"
  [ "$(count "$match")" -eq 1 ] || die "Подключено несколько устройств — выбери одно через --device:
$match"
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
  #
  # Переставляется силой, и это не грубость, а единственное честное здесь поведение.
  # Дерево принадлежит скрипту: ничьей работы в нём нет и быть не может, зато грязь
  # заводится сама — xcodegen пишет в него генерируемые файлы, сборка вбивает в плист
  # номер. Обычный checkout об эту грязь спотыкается («Your local changes would be
  # overwritten»), и «собрать из dev» превращается в «не собрать ничего» ровно тогда,
  # когда в dev поменялся состав файлов. Здесь у этой команды одно значение: пусть
  # содержимое станет в точности вершиной dev, чем бы оно ни было до того.
  if [ -e "$SRC/.git" ]; then
    git -C "$SRC" checkout --quiet --detach --force "$BRANCH"
    git -C "$SRC" reset --quiet --hard "$BRANCH"
  else
    mkdir -p "$(dirname "$SRC")"
    git -C "$REPO" worktree add --detach "$SRC" "$BRANCH" >/dev/null
  fi
  src="$SRC"
  say "Собираю $BRANCH ($(git -C "$src" log -1 --format='%h %s'))"
fi

# ---------------------------------------------------------------- сборка

say "Генерирую Iskra.xcodeproj"
(cd "$src/Apps" && quietly xcodegen xcodegen)

say "xcodebuild для устройства"
# -allowProvisioningUpdates: подпись автоматическая, и профиль на новый App ID
# (например, у share-расширения) Xcode обязан выписать сам — иначе сборка встанет
# с «no profiles found» там, где в GUI всё чинится одной галочкой.
quietly build-device xcodebuild -project "$src/Apps/Iskra.xcodeproj" -scheme 'Iskra (iOS)' \
  -destination "id=$device_id" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates build

app="$DERIVED/Build/Products/Debug-iphoneos/Iskra.app"
[ -d "$app" ] || die "Сборка прошла, а $app нет — что-то поменялось в конфигурации."

# ---------------------------------------------------------------- установка

say "Ставлю на $device_name"
quietly install xcrun devicectl device install app --device "$device_id" "$app"

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
