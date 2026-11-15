#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════╗
# ║  WI-FI MONITOR (iw) — без NetworkManager                     ║
# ║  Запуск: ./wifi-monitor-iw.sh [интерфейс] [интервал_сек]     ║
# ║  Ключи:  --list         адаптеры и их диапазоны, и выход     ║
# ║          --band=all|2.4|5|6   диапазон сканирования          ║
# ║          --debug        лог в /tmp/wifi-monitor.debug        ║
# ║  Клавиши: a адаптер · b диапазон · c страна · q выход        ║
# ╚══════════════════════════════════════════════════════════════╝

# Нельзя запускать через `source`: exit/trap/exec убили бы текущую оболочку
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    echo "Запускай скрипт (./wifi-monitor-iw.sh), а не через source." >&2
    return 1
fi

IFACE=""; INTERVAL=3; DEBUG=""; LIST=""; BAND="all"
for a in "$@"; do
    case $a in
        --debug)   DEBUG=1 ;;
        --list)    LIST=1 ;;
        --band=*)  BAND=${a#--band=} ;;
        *)         if [[ $a =~ ^[0-9]+$ ]]; then INTERVAL=$a; else IFACE=$a; fi ;;
    esac
done
(( INTERVAL < 1 )) && INTERVAL=1
case $BAND in all|2.4|5|6) ;; *) echo "--band: all, 2.4, 5 или 6" >&2; exit 1 ;; esac

command -v iw >/dev/null 2>&1 || { echo "Нужен iw: sudo apt install iw" >&2; exit 1; }

# Нужна UTF-8 локаль, иначе кириллица и рамки считаются по байтам и всё «плывёт»
[[ ${LC_ALL:-${LC_CTYPE:-$LANG}} == *[Uu][Tt][Ff]* ]] || export LC_ALL=C.UTF-8

SYSNET=${WIFIMON_SYSNET:-/sys/class/net}

# ── Wi-Fi адаптеры и их диапазоны ───────────────────────────
# Разбор `iw phy phyN info`: частоты по диапазонам (без disabled) и число каналов «no IR» в 5 ГГц
read -r -d '' AWK_BANDS <<'AWK'
/^[ \t]*\* [0-9]+(\.[0-9]+)? MHz/ {
    f = int($2)
    if ($0 ~ /\(disabled\)/) next
    if (f < 3000)      a = a " " f
    else if (f < 5925) { b = b " " f; if ($0 ~ /no IR/) n++ }
    else               c = c " " f
}
END { sub(/^ /, "", a); sub(/^ /, "", b); sub(/^ /, "", c); print a "|" b "|" c "|" n + 0 }
AWK

AD_IF=(); AD_BUS=(); AD_DEV=(); AD_TYPE=(); AD_STATE=(); AD_MAC=()
AD_F24=(); AD_F5=(); AD_F6=(); AD_NOIR5=(); AD_BANDS=()

add_adapter() {   # add_adapter имя тип mac phy
    local ifn=$1 typ=$2 mac=$3 phy=$4 sys="$SYSNET/$1" bus="?" drv="" prod="" man="" st="?"
    local f24="" f5="" f6="" noir="0" bands=""
    [[ -e $sys/device/subsystem ]] && bus=$(basename "$(readlink -f "$sys/device/subsystem")")
    [[ -e $sys/device/driver ]]    && drv=$(basename "$(readlink -f "$sys/device/driver")")
    if [[ $bus == usb ]]; then
        [[ -r $sys/device/../product      ]] && prod=$(<"$sys/device/../product")
        [[ -r $sys/device/../manufacturer ]] && man=$(<"$sys/device/../manufacturer")
        prod="${man:+$man }$prod"
    fi
    [[ -r $sys/operstate ]] && st=$(<"$sys/operstate")
    if [[ -n $phy ]]; then
        IFS='|' read -r f24 f5 f6 noir < <(iw phy "$phy" info 2>/dev/null | awk "$AWK_BANDS")
    fi
    [[ -n $f24 ]] && bands+="2.4/"
    [[ -n $f5  ]] && bands+="5/"
    [[ -n $f6  ]] && bands+="6/"
    bands=${bands%/}
    AD_IF+=("$ifn"); AD_BUS+=("${bus^^}")
    AD_DEV+=("${prod:+$prod }${drv:+[$drv]}")
    AD_TYPE+=("${typ:-?}"); AD_STATE+=("$st"); AD_MAC+=("$mac")
    AD_F24+=("$f24"); AD_F5+=("$f5"); AD_F6+=("$f6"); AD_NOIR5+=("${noir:-0}"); AD_BANDS+=("${bands:-?}")
}

detect_adapters() {
    AD_IF=(); AD_BUS=(); AD_DEV=(); AD_TYPE=(); AD_STATE=(); AD_MAC=()
    AD_F24=(); AD_F5=(); AD_F6=(); AD_NOIR5=(); AD_BANDS=()
    local line ifn="" typ="" mac="" phy="" ifphy=""
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        case $line in
            phy\#*)       phy="phy${line#phy#}" ;;
            Interface\ *) [[ -n $ifn ]] && add_adapter "$ifn" "$typ" "$mac" "$ifphy"
                          ifn=${line#Interface }; typ=""; mac=""; ifphy=$phy ;;
            type\ *)      typ=${line#type } ;;
            addr\ *)      mac=${line#addr } ;;
        esac
    done < <(iw dev 2>/dev/null)
    [[ -n $ifn ]] && add_adapter "$ifn" "$typ" "$mac" "$ifphy"
}

if [[ -n $LIST ]]; then
    detect_adapters
    (( ${#AD_IF[@]} )) || { echo "Wi-Fi адаптеры не найдены."; exit 1; }
    printf '%-3s %-12s %-5s %-9s %-8s %-9s %-18s %s\n' "№" "Интерфейс" "Шина" "Режим" "Статус" "ГГц" "MAC" "Устройство"
    for i in "${!AD_IF[@]}"; do
        printf '%-3s %-12s %-5s %-9s %-8s %-9s %-18s %s\n' "$((i+1))" "${AD_IF[i]}" "${AD_BUS[i]}" \
            "${AD_TYPE[i]}" "${AD_STATE[i]}" "${AD_BANDS[i]}" "${AD_MAC[i]}" "${AD_DEV[i]}"
    done
    exit 0
fi

# Для полного скана нужен root. Пробуем sudo; не вышло — работаем без него
if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1; then
    if [[ -t 0 ]] && sudo -v; then
        exec sudo bash "$(readlink -f "$0")" "$@"
    fi
    echo "sudo недоступен — работаю без root (только кэш ядра)." >&2
    sleep 2
fi
IS_ROOT=$(( EUID == 0 ))

[[ -t 0 && -t 1 ]] || { echo "Нужен интерактивный терминал." >&2; exit 1; }

# Отладка: ./wifi-monitor-iw.sh --debug  → лог в /tmp/wifi-monitor.debug
[[ -n $DEBUG ]] && { exec 2>/tmp/wifi-monitor.debug; set -x; }

# Интерфейс, заданный аргументом, должен существовать
if [[ -n $IFACE ]] && ! iw dev "$IFACE" info >/dev/null 2>&1; then
    echo "Интерфейс '$IFACE' не найден. Доступные адаптеры:" >&2
    detect_adapters; printf '  %s\n' "${AD_IF[@]}" >&2
    exit 1
fi

# ── Цвета (неон) ────────────────────────────────────────────
C0=$'\e[0m'; CB=$'\e[1m'
CY=$'\e[38;5;51m'    # циан
MG=$'\e[38;5;201m'   # маджента
GR=$'\e[38;5;46m'    # зелёный
YL=$'\e[38;5;226m'   # жёлтый
RD=$'\e[38;5;196m'   # красный
WH=$'\e[38;5;255m'   # белый
GY=$'\e[38;5;240m'   # серый
SEP=$'\x01'

TMPD=$(mktemp -d)
WORKER_PID=""
MSG=""; MSG_UNTIL=0; REGDOM=""; REG_T=-99
CUR_F24=""; CUR_F5=""; CUR_F6=""; CUR_NOIR5=0; CUR_BANDS=""; SCAN_FREQS=""

stop_worker() {
    [[ -n $WORKER_PID ]] && kill "$WORKER_PID" 2>/dev/null
    WORKER_PID=""
}

# ── Терминал: альтернативный экран, возврат при выходе ──────
cleanup() {
    stop_worker
    rm -rf "$TMPD"
    printf '\e[0m\e[?25h'
    tput rmcup 2>/dev/null || printf '\e[2J\e[H'
    stty echo 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP
tput smcup 2>/dev/null
printf '\e[2J\e[?25l'

get_size() {
    local s
    s=$(stty size 2>/dev/null) && read -r ROWS COLS <<< "$s"
    [[ $ROWS =~ ^[0-9]+$ && $ROWS -gt 0 ]] || ROWS=24
    [[ $COLS =~ ^[0-9]+$ && $COLS -gt 0 ]] || COLS=80
}

msg() { MSG=$1; MSG_UNTIL=$(( SECONDS + 6 )); }

# ── Парсер вывода `iw scan` (с фильтром по диапазону bsel) ──
read -r -d '' AWK_PROG <<'AWK'
function flush(   s, ch, bb) {
    if (b == "" || seen > 30000) return
    if (bsel != "all") {
        bb = (f < 3000) ? "2.4" : ((f < 5925) ? "5" : "6")
        if (bb != bsel) return
    }
    if (rsn) {
        if (akm ~ /SAE/ && akm ~ /PSK/) s = "WPA2/WPA3"
        else if (akm ~ /SAE/)           s = "WPA3"
        else if (akm ~ /802\.1X/)       s = "WPA2-EAP"
        else                            s = "WPA2"
    } else if (wpa)  s = "WPA"
    else if (priv)   s = "WEP"
    else             s = "Open"
    if (f == 2484)        ch = 14
    else if (f < 2484)    ch = int((f - 2407) / 5)
    else if (f < 5925)    ch = int((f - 5000) / 5)
    else                  ch = int((f - 5950) / 5)
    print assoc, ssid, b, ch, f, sig, s
}
/^BSS / {
    flush()
    b = substr($2, 1, 17)
    assoc = ($0 ~ /-- associated/) ? "*" : " "
    ssid = ""; f = 0; sig = -100; rsn = 0; wpa = 0; priv = 0
    akm = ""; ctx = ""; seen = 0
    next
}
{
    line = $0; sub(/^[ \t]+/, "", line)
    if (line !~ /^\*/) ctx = ""
    if      (line ~ /^freq:/)       f = int($2)
    else if (line ~ /^signal:/)     sig = $2
    else if (line ~ /^last seen:/)  seen = $3
    else if (line ~ /^SSID:/)       ssid = substr(line, 7)
    else if (line ~ /^capability:/ && line ~ /Privacy/) priv = 1
    else if (line ~ /^RSN:/)        { rsn = 1; ctx = "rsn" }
    else if (line ~ /^WPA:/)        { wpa = 1; ctx = "wpa" }
    else if (line ~ /Authentication suites:/ && ctx == "rsn") akm = akm " " line
}
END { flush() }
AWK

# ── Возможности текущего адаптера и частоты для скана ───────
set_scan_freqs() {
    case $BAND in
        2.4) SCAN_FREQS=$CUR_F24 ;;
        5)   SCAN_FREQS=$CUR_F5 ;;
        6)   SCAN_FREQS=$CUR_F6 ;;
        *)   SCAN_FREQS="" ;;
    esac
}

load_caps() {
    local i
    CUR_F24=""; CUR_F5=""; CUR_F6=""; CUR_NOIR5=0; CUR_BANDS=""
    detect_adapters
    for i in "${!AD_IF[@]}"; do
        if [[ ${AD_IF[i]} == "$IFACE" ]]; then
            CUR_F24=${AD_F24[i]}; CUR_F5=${AD_F5[i]}; CUR_F6=${AD_F6[i]}
            CUR_NOIR5=${AD_NOIR5[i]}; CUR_BANDS=${AD_BANDS[i]}
        fi
    done
    case $BAND in
        2.4) [[ -z $CUR_F24 ]] && { BAND=all; msg "Адаптер не поддерживает 2.4 ГГц — сканирую всё"; } ;;
        5)   [[ -z $CUR_F5  ]] && { BAND=all; msg "Адаптер не поддерживает 5 ГГц — сканирую всё"; } ;;
        6)   [[ -z $CUR_F6  ]] && { BAND=all; msg "Адаптер не поддерживает 6 ГГц — сканирую всё"; } ;;
    esac
    set_scan_freqs
}

reg_refresh() {
    REGDOM=$(iw reg get 2>/dev/null | awk '/^country/{gsub(":", "", $2); print $2; exit}')
}

band_label() {
    case $BAND in
        all) if [[ -n $CUR_BANDS && $CUR_BANDS != "?" ]]; then printf '%s ГГц' "${CUR_BANDS//\//+}"
             else printf 'все диапазоны'; fi ;;
        *)   printf 'только %s ГГц' "$BAND" ;;
    esac
}

cycle_band() {
    local -a opts=(all)
    [[ -n $CUR_F24 ]] && opts+=(2.4)
    [[ -n $CUR_F5  ]] && opts+=(5)
    [[ -n $CUR_F6  ]] && opts+=(6)
    if (( ${#opts[@]} == 1 )); then
        msg "Не удалось определить диапазоны адаптера $IFACE"; return
    elif (( ${#opts[@]} == 2 )); then
        msg "Адаптер $IFACE умеет только ${opts[1]} ГГц — переключать нечего"; return
    fi
    local i cur=0
    for i in "${!opts[@]}"; do [[ ${opts[i]} == "$BAND" ]] && cur=$i; done
    BAND=${opts[(cur + 1) % ${#opts[@]}]}
    stop_worker
    rm -f "$TMPD/dump" "$TMPD/parsed" "$TMPD/err"
    data=""
    set_scan_freqs
    start_worker
    msg "Диапазон: $(band_label)"
}

set_country() {
    local cc=""
    if (( ! IS_ROOT )); then msg "Смена страны требует root (запусти через sudo)"; return; fi
    printf '\e[%d;1H\e[K\e[?25h%s' "$ROWS" " Код страны, 2 буквы (например DE; Enter — отмена): "
    read -r -n2 -t 30 cc
    printf '\e[?25l'
    PREV_SIZE=""
    if [[ ! $cc =~ ^[A-Za-z]{2}$ ]]; then msg "Страна не изменена"; return; fi
    cc=${cc^^}
    if iw reg set "$cc" 2>/dev/null; then msg "Регдомен: $cc (действует до перезагрузки)"
    else msg "Не удалось задать регдомен $cc"; fi
    sleep 0.3; reg_refresh; REG_T=$SECONDS
}

# Фоновый сканер: полный блокирующий скан (iw scan), при отказе — кэш (scan dump).
# Результат пишется в файл целиком, так что список не «набегает» по кусочкам.
worker() {
    local out st
    while true; do
        : > "$TMPD/scanning"
        # Свисток после подключения часто «опущен» — поднимаем (нужен root)
        if (( IS_ROOT )) && command -v ip >/dev/null 2>&1; then
            st=$(cat "$SYSNET/$IFACE/operstate" 2>/dev/null)
            [[ $st == down ]] && ip link set "$IFACE" up >/dev/null 2>&1
        fi
        if [[ -n $SCAN_FREQS ]]; then
            out=$(iw dev "$IFACE" scan freq $SCAN_FREQS 2>"$TMPD/err")
        else
            out=$(iw dev "$IFACE" scan 2>"$TMPD/err")
        fi
        [[ -z $out ]] && out=$(iw dev "$IFACE" scan dump 2>/dev/null)
        if [[ -n $out ]]; then
            printf '%s\n' "$out" > "$TMPD/dump.new" && mv -f "$TMPD/dump.new" "$TMPD/dump"
        fi
        rm -f "$TMPD/scanning"
        sleep "$INTERVAL"
    done
}

start_worker() { worker & WORKER_PID=$!; }

parse() {
    awk -v OFS="$SEP" -v bsel="$BAND" "$AWK_PROG" < "$TMPD/dump" \
        | sort -t"$SEP" -k6,6 -nr > "$TMPD/parsed.new" \
        && mv -f "$TMPD/parsed.new" "$TMPD/parsed"
    data=$(<"$TMPD/parsed")
}

# ── Вспомогательные функции ─────────────────────────────────
rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

pad() {
    local s=$1 w=$2 len=${#1}
    if (( len > w )); then s="${s:0:w-1}…"; len=$w; fi
    printf '%s%*s' "$s" $((w - len)) ''
}

hline() {   # hline лево середина право   (использует массив WD вызывающей функции)
    local out="$1" i
    for i in "${!WD[@]}"; do
        out+=$(rep '─' $((WD[i] + 2)))
        if (( i < ${#WD[@]} - 1 )); then out+="$2"; else out+="$3"; fi
    done
    printf '%s%s%s' "$CY" "$out" "$C0"
}

sigbar() {  # sigbar процент → 10 блоков
    local sig=$1 n col out="" i
    n=$(( (sig + 5) / 10 )); (( n > 10 )) && n=10
    if   (( sig >= 70 )); then col=$GR
    elif (( sig >= 40 )); then col=$YL
    else col=$RD; fi
    for ((i = 0; i < 10; i++)); do
        if (( i < n )); then out+="${col}█"; else out+="${GY}░"; fi
    done
    printf '%s%s' "$out" "$C0"
}

# ── Меню выбора адаптера ────────────────────────────────────
draw_menu() {   # draw_menu индекс режим(start|switch)
    local sel=$1 mode=$2
    get_size
    if [[ "$ROWS x $COLS" != "$PREV_SIZE" ]]; then printf '\e[2J'; PREV_SIZE="$ROWS x $COLS"; fi
    if (( COLS < 50 || ROWS < 12 )); then
        printf '\e[H\e[JОкно мало: нужно от 50x12 (сейчас %sx%s)' "$COLS" "$ROWS"
        return
    fi

    local nl=$'\e[K\n' V="${CY}│${C0}" out="" line c i w
    local -a WD=(3 10 5 0 7) HN=("№" "Интерфейс" "Шина" "Устройство" "Диапаз.")
    local opt_mode=0 opt_mac=0
    (( COLS >= 80  )) && { opt_mode=1; WD+=(9 7); HN+=("Режим" "Статус"); }
    (( COLS >= 110 )) && { opt_mac=1;  WD+=(17);  HN+=("MAC"); }
    local n=${#WD[@]} fixed=0
    for w in "${WD[@]}"; do fixed=$(( fixed + w )); done
    local dw=$(( COLS - fixed - 3 * n - 1 ))
    (( dw > 44 )) && dw=44
    (( dw < 8  )) && dw=8
    WD[3]=$dw
    local IW=$(( fixed + dw + 3 * n - 1 ))

    local cnt=${#AD_IF[@]} shown
    shown=$(( cnt > 9 ? 9 : cnt ))
    (( shown > ROWS - 10 )) && shown=$(( ROWS - 10 ))

    local title="▓▒░  ВЫБОР Wi-Fi АДАПТЕРА  ░▒▓"
    (( IW < ${#title} + 2 )) && title="ВЫБОР АДАПТЕРА"
    local tl=${#title} left=$(( (IW - ${#title}) / 2 ))
    out+="${CY}╭$(rep '─' "$IW")╮${C0}${nl}"
    out+="${V}$(rep ' ' "$left")${MG}${CB}${title}${C0}$(rep ' ' $(( IW - left - tl )))${V}${nl}"
    out+="$(hline '├' '┬' '┤')${nl}"
    line="$V"
    for i in "${!HN[@]}"; do line+=" ${MG}${CB}$(pad "${HN[i]}" "${WD[i]}")${C0} ${V}"; done
    out+="${line}${nl}"
    out+="$(hline '├' '┼' '┤')${nl}"

    if (( cnt == 0 )); then
        out+="$V ${YL}$(pad 'Адаптеры не найдены. Подключи свисток — список обновится сам.' $(( IW - 2 )))${C0} $V${nl}"
    else
        local num ifc bus bc devc bandc typc stc stt
        local -a cells
        for ((i = 0; i < shown; i++)); do
            if (( i == sel )); then
                num="${GR}▶ $((i+1))${C0}"
                ifc="${GR}${CB}$(pad "${AD_IF[i]}" 10)${C0}"
                devc="${WH}${CB}$(pad "${AD_DEV[i]}" "$dw")${C0}"
            else
                num="  $((i+1))"
                ifc="${WH}$(pad "${AD_IF[i]}" 10)${C0}"
                devc="${GY}$(pad "${AD_DEV[i]}" "$dw")${C0}"
            fi
            case ${AD_BUS[i]} in
                USB)  bc="${MG}${CB}" ;;
                PCI*) bc="$CY" ;;
                *)    bc="$GY" ;;
            esac
            bus="${bc}$(pad "${AD_BUS[i]}" 5)${C0}"
            if [[ ${AD_BANDS[i]} == *5* || ${AD_BANDS[i]} == *6* ]]; then bandc="${GR}"; else bandc="${YL}"; fi
            bandc="${bandc}$(pad "${AD_BANDS[i]}" 7)${C0}"
            cells=("$num" "$ifc" "$bus" "$devc" "$bandc")
            if (( opt_mode )); then
                case ${AD_TYPE[i]} in managed) typc="${WH}" ;; *) typc="${YL}" ;; esac
                typc="${typc}$(pad "${AD_TYPE[i]}" 9)${C0}"
                stt=${AD_STATE[i]}
                case $stt in up) stc="${GR}" ;; down) stc="${RD}" ;; *) stc="${YL}" ;; esac
                stc="${stc}$(pad "$stt" 7)${C0}"
                cells+=("$typc" "$stc")
            fi
            (( opt_mac )) && cells+=("${GY}$(pad "${AD_MAC[i]}" 17)${C0}")
            line="$V"
            for c in "${cells[@]}"; do line+=" ${c} ${V}"; done
            out+="${line}${nl}"
        done
    fi
    out+="$(hline '╰' '┴' '╯')${nl}"

    local h1=" ↑/↓ — выбор   Enter — сканировать этим адаптером   1-9 — быстрый выбор"
    local h2=" Найдено: ${cnt}   │   список обновляется сам   │   "
    if [[ $mode == start ]]; then h2+="q — выход"; else h2+="Esc/q — назад"; fi
    out+="${CY}${h1:0:COLS-1}${C0}${nl}"
    out+="${GY}${h2:0:COLS-1}${C0}${nl}"

    out=${out%$'\n'}
    printf '\e[H%s\e[J' "$out"
}

menu_adapters() {   # menu_adapters [start|switch] → 0: IFACE выбран, 1: отмена
    local mode=${1:-switch} sel=0 selname=$IFACE key k2 rc i found idx
    while true; do
        detect_adapters
        found=0
        for i in "${!AD_IF[@]}"; do
            [[ ${AD_IF[i]} == "$selname" ]] && { sel=$i; found=1; break; }
        done
        if (( ! found )); then
            (( sel >= ${#AD_IF[@]} )) && sel=$(( ${#AD_IF[@]} - 1 ))
            (( sel < 0 )) && sel=0
        fi
        selname=${AD_IF[sel]:-}

        draw_menu "$sel" "$mode"
        read -rsn1 -t 1 key; rc=$?
        if (( rc == 0 )); then
            case $key in
                $'\e')
                    k2=""; read -rsn2 -t 0.05 k2
                    case $k2 in
                        '[A'|'OA') (( sel > 0 )) && (( sel-- )) ;;
                        '[B'|'OB') (( sel < ${#AD_IF[@]} - 1 )) && (( sel++ )) ;;
                        '')        return 1 ;;
                    esac ;;
                [kKwW]) (( sel > 0 )) && (( sel-- )) ;;
                [jJsS]) (( sel < ${#AD_IF[@]} - 1 )) && (( sel++ )) ;;
                ''|$'\n')
                    if (( ${#AD_IF[@]} > 0 )); then IFACE=${AD_IF[sel]}; return 0; fi ;;
                [1-9])
                    idx=$(( key - 1 ))
                    if (( idx < ${#AD_IF[@]} )); then IFACE=${AD_IF[idx]}; return 0; fi ;;
                [qQйЙ]) return 1 ;;
            esac
            selname=${AD_IF[sel]:-}
        elif (( rc <= 128 )); then
            return 1    # stdin закрыт
        fi
    done
}

switch_adapter() {
    local old=$IFACE
    stop_worker
    menu_adapters switch || IFACE=$old
    if [[ $IFACE != "$old" ]]; then
        rm -f "$TMPD/dump" "$TMPD/parsed" "$TMPD/err"
        data=""
    fi
    load_caps
    PREV_SIZE=""
    start_worker
}

# ── Отрисовка кадра (подстраивается под размер окна) ────────
draw() {
    get_size
    if [[ "$ROWS x $COLS" != "$PREV_SIZE" ]]; then printf '\e[2J'; PREV_SIZE="$ROWS x $COLS"; fi

    if (( COLS < 46 || ROWS < 10 )); then
        printf '\e[H\e[JОкно мало: нужно от 46x10 (сейчас %sx%s). q — выход' "$COLS" "$ROWS"
        return
    fi

    local nl=$'\e[K\n' V="${CY}│${C0}" out="" i w c
    local show_bssid=0 show_band=0 show_sec=0
    (( COLS >= 100 )) && show_bssid=1
    (( COLS >= 70  )) && show_band=1
    (( COLS >= 60  )) && show_sec=1

    # Колонки: маркер, SSID (гибкая), [BSSID], CH, [GHz], сигнал, [защита]
    local -a WD=(1 0) HN=("" "SSID")
    (( show_bssid )) && { WD+=(17); HN+=("BSSID"); }
    WD+=(3);  HN+=("CH")
    (( show_band  )) && { WD+=(4);  HN+=("GHz"); }
    WD+=(18); HN+=("Сигнал")
    (( show_sec   )) && { WD+=(11); HN+=("Защита"); }
    local n=${#WD[@]} fixed=0
    for w in "${WD[@]}"; do fixed=$(( fixed + w )); done
    local sw=$(( COLS - fixed - 3 * n - 1 ))
    (( sw > 30 )) && sw=30
    (( sw < 6  )) && sw=6
    WD[1]=$sw
    local IW=$(( fixed + sw + 3 * n - 1 ))

    # Дополнительные строки-предупреждения
    local -a xl=()
    (( IS_ROOT )) || xl+=(" Без root: только кэш ядра (запусти через sudo)")
    if [[ -n $CUR_F5$CUR_F6 && $REGDOM == 00 ]]; then
        xl+=(" 5 ГГц: регдомен 00 — часть каналов закрыта или только пассивный скан. [c] — задать страну")
    fi
    local nx=${#xl[@]}

    # Вертикальный бюджет: рамка 6 + сети + гистограмма 4 + 2 строки статуса + предупреждения + 1 запас
    local avail=$(( ROWS - 9 - nx )) hist=0
    if (( avail < 1 && nx > 0 )); then xl=(); nx=0; avail=$(( ROWS - 9 )); fi
    if (( COLS >= 56 && avail - 4 >= 3 )); then hist=1; avail=$(( avail - 4 )); fi
    (( avail < 1 )) && avail=1

    # Адаптер мог исчезнуть (свисток выдернули) — не показываем устаревшие данные
    local gone=0 d=$data
    [[ -d $SYSNET/$IFACE ]] || { gone=1; d=""; }

    # Разбор данных
    local use ssid bssid chan freq dbm sec band secc pct mark ssidc line
    local total=0 shown=0 cur="" rows=""
    local -A cnt=()
    local -a cells=()

    while IFS="$SEP" read -r use ssid bssid chan freq dbm sec; do
        [[ -z $bssid ]] && continue
        ssid=${ssid//\\x00/}
        [[ $ssid == *'\x'* ]] && ssid=$(printf '%b' "$ssid")
        [[ -z $ssid ]] && ssid="‹скрытая›"
        dbm=${dbm%.*}; [[ $dbm =~ ^-?[0-9]+$ ]] || dbm=-100
        pct=$(( 2 * (dbm + 100) )); (( pct > 100 )) && pct=100; (( pct < 0 )) && pct=0

        if   (( freq < 3000 )); then band="2.4"; cnt[$chan]=$(( ${cnt[$chan]:-0} + 1 ))
        elif (( freq < 5925 )); then band="5"
        else band="6"; fi

        case $sec in
            Open|WEP) secc="${RD}$(pad "$sec" 11)${C0}" ;;
            WPA)      secc="${YL}$(pad "$sec" 11)${C0}" ;;
            *)        secc="${GR}$(pad "$sec" 11)${C0}" ;;
        esac

        (( total++ ))
        if [[ $use == "*" ]]; then
            mark="${GR}▶${C0}"; ssidc="${GR}${CB}$(pad "$ssid" "$sw")${C0}"
            cur="$ssid (${dbm} dBm)"
        else
            mark=" "; ssidc="${WH}$(pad "$ssid" "$sw")${C0}"
        fi

        if (( shown < avail )); then
            cells=("$mark" "$ssidc")
            (( show_bssid )) && cells+=("${GY}$(pad "$bssid" 17)${C0}")
            cells+=("${MG}$(printf '%3s' "$chan")${C0}")
            (( show_band )) && cells+=("${CY}$(pad "$band" 4)${C0}")
            cells+=("$(sigbar "$pct") ${WH}$(printf '%4ddBm' "$dbm")${C0}")
            (( show_sec )) && cells+=("$secc")
            line="$V"
            for c in "${cells[@]}"; do line+=" ${c} ${V}"; done
            rows+="${line}${nl}"
            (( shown++ ))
        fi
    done <<< "$d"

    # Шапка
    local title="▓▒░  W I - F I   M O N I T O R  ░▒▓"
    (( IW < ${#title} + 2 )) && title="WI-FI MONITOR"
    local tl=${#title} left=$(( (IW - ${#title}) / 2 ))
    out+="${CY}╭$(rep '─' "$IW")╮${C0}${nl}"
    out+="${V}$(rep ' ' "$left")${MG}${CB}${title}${C0}$(rep ' ' $(( IW - left - tl )))${V}${nl}"
    out+="$(hline '├' '┬' '┤')${nl}"
    line="$V"
    for i in "${!HN[@]}"; do line+=" ${MG}${CB}$(pad "${HN[i]}" "${WD[i]}")${C0} ${V}"; done
    out+="${line}${nl}"
    out+="$(hline '├' '┼' '┤')${nl}"

    if (( total == 0 )); then
        local m='Сети не найдены (идёт сканирование?)' e=""
        [[ -s $TMPD/err ]] && e=$(head -c 70 "$TMPD/err" | tr '\n\r' '  ')
        [[ -n $e ]] && m="Сети не найдены: $e"
        (( gone )) && m="Адаптер $IFACE отключён — нажми [a], чтобы выбрать другой"
        out+="$V ${YL}$(pad "$m" $(( IW - 2 )))${C0} $V${nl}"
    else
        out+="$rows"
    fi
    out+="$(hline '╰' '┴' '╯')${nl}"

    # Загрузка каналов 2.4 ГГц
    if (( hist )); then
        local lv=("·" ▁ ▂ ▃ ▄ ▅ ▆ ▇ █) k m lab="" blk=""
        for k in {1..13}; do
            m=${cnt[$k]:-0}; (( m > 8 )) && m=8
            lab+=$(printf '%3d ' "$k")
            if   (( m >= 5 )); then blk+=" ${RD}${lv[m]}${C0}  "
            elif (( m >= 3 )); then blk+=" ${YL}${lv[m]}${C0}  "
            else blk+=" ${GR}${lv[m]}${C0}  "; fi
        done
        out+="${nl}  ${CY}Загрузка каналов 2.4 ГГц${C0}${nl}  ${GY}${lab}${C0}${nl}  ${blk}${nl}"
    fi

    # Статус: строка 1 — состояние, строка 2 — подсказки или сообщение
    local st=" ${IFACE}"
    [[ -e $TMPD/scanning ]] && st+=" ⟳ скан…"
    st+=" │ $(band_label) │ рег:${REGDOM:-?} │ Сетей: ${total}"
    (( total > shown )) && st+=" (показано ${shown})"
    st+=" │ Подключено: ${cur:-—} │ $(date +%H:%M:%S)"
    out+="${CY}${st:0:COLS-1}${C0}${nl}"
    if (( SECONDS < MSG_UNTIL )); then
        st=" ${MSG}"; out+="${YL}${CB}${st:0:COLS-1}${C0}${nl}"
    else
        st=" [a] адаптер   [b] диапазон   [c] страна   [q] выход"; out+="${GY}${st:0:COLS-1}${C0}${nl}"
    fi
    for st in "${xl[@]}"; do out+="${YL}${st:0:COLS-1}${C0}${nl}"; done

    out=${out%$'\n'}   # без последнего перевода строки — иначе экран прокрутится
    printf '\e[H%s\e[J' "$out"
}

# ── Выбор адаптера при старте ───────────────────────────────
data=""; PREV_SIZE=""
if [[ -z $IFACE ]]; then
    detect_adapters
    if (( ${#AD_IF[@]} == 1 )); then
        IFACE=${AD_IF[0]}              # адаптер один — выбирать нечего
    else
        menu_adapters start || exit 0  # ноль или несколько — меню (ждёт и подключение свистка)
        PREV_SIZE=""
    fi
fi

# ── Главный цикл ────────────────────────────────────────────
load_caps
reg_refresh; REG_T=$SECONDS
start_worker
while true; do
    (( SECONDS - REG_T >= 5 )) && { reg_refresh; REG_T=$SECONDS; }
    [[ $TMPD/dump -nt $TMPD/parsed ]] && parse
    draw
    read -rsn1 -t 0.5 key; rc=$?
    if (( rc == 0 )); then
        case $key in
            [qQйЙ])         break ;;
            [aAфФ]|$'\t')   switch_adapter ;;
            [bBиИ])         cycle_band ;;
            [cCсС])         set_country ;;
        esac
    elif (( rc <= 128 )); then
        break    # stdin закрыт — не крутимся впустую
    fi
done
