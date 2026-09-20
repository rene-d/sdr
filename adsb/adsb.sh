#!/bin/sh
# Réception ADS-B (1090 MHz) avec la RTL-SDR, via dump1090-fa.
#
#   ./adsb.sh                   # table des avions dans le terminal
#   ./adsb.sh -w                # carte web sur http://127.0.0.1:8090
#   ./adsb.sh -R                # scope radar dans le terminal
#   ./adsb.sh -P 48.858,2.295   # position du récepteur : distances et caps
#   ./adsb.sh -r                # trames Mode S brutes en hexa
#   ./adsb.sh -s 30             # statistiques toutes les 30 s
#   ./adsb.sh -g 30             # gain fixe (défaut : 49,6 dB, le maximum)
#   ./adsb.sh -a                # gain adaptatif au lieu du gain fixe
#   ./adsb.sh -N                # sortie réseau : SBS 30003, Beast 30005
#   ./adsb.sh -t 60             # s'arrête après 60 s
#
# Antenne : dipôle 2 x 6,9 cm, VERTICAL — l'ADS-B est polarisé verticalement.
# Ctrl-C pour arrêter.

set -e
DUMP=${DUMP1090:-dump1090}
DIR=$(cd "$(dirname "$0")" && pwd)
JSONDIR=${JSONDIR:-${TMPDIR:-/tmp}/adsb-json}
GAIN=49.6; ADAPTIVE=0; WEB=0; WEBPORT=8090; RADAR=0; RAW=0; STATS=0
NET=0; SECONDS_MAX=0; PPM=""; POS=""; MODEAC=0; OPEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        -g) GAIN="$2"; shift 2 ;;
        -a) ADAPTIVE=1; shift ;;
        -p) PPM="$2"; shift 2 ;;
        -P) POS="$2"; shift 2 ;;
        -w) WEB=1; shift ;;
        -R) RADAR=1; shift ;;
        -W) WEB=1; WEBPORT="$2"; shift 2 ;;
        -o) OPEN="--open"; shift ;;
        -r) RAW=1; shift ;;
        -s) STATS="$2"; shift 2 ;;
        -N) NET=1; shift ;;
        -A) MODEAC=1; shift ;;
        -t) SECONDS_MAX="$2"; shift 2 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 1 ;;
    esac
done

command -v "$DUMP" > /dev/null || {
    echo "dump1090 introuvable." >&2
    echo "  brew install dump1090-fa     (ou indiquer le chemin par DUMP1090=…)" >&2
    exit 1
}

# Position du récepteur : -P lat,lon, sinon le fichier ./position (une ligne
# « lat lon »). Sans elle, dump1090 n'affiche ni distance ni cap, et ne décode
# pas les positions au sol, qui sont codées en relatif.
[ -z "$POS" ] && [ -r "$DIR/position" ] && POS=$(tr ',' ' ' < "$DIR/position" | head -1)
LAT=""; LON=""
if [ -n "$POS" ]; then
    LAT=$(echo "$POS" | tr ',' ' ' | awk '{print $1}')
    LON=$(echo "$POS" | tr ',' ' ' | awk '{print $2}')
    [ -n "$LAT" ] && [ -n "$LON" ] || { echo "position illisible : $POS (attendu lat,lon)" >&2; exit 1; }
fi

# Le dongle est mono-process : un rtl_fm, un AIS-catcher ou un dump1090 oublié
# fait échouer l'ouverture, parfois sans message clair.
if pgrep -f 'rtl_fm|rtl_power|AIS-catcher|dump1090' > /dev/null; then
    echo "Un autre process tient déjà le dongle, je l'arrête." >&2
    pkill -f 'rtl_fm|rtl_power|AIS-catcher|dump1090' || true
    sleep 1
fi
# Ne tue que nos propres enfants : « kill 0 » viserait tout le groupe de process.
cleanup() { pkill -P $$ 2>/dev/null || true; }
trap cleanup INT TERM EXIT

set -- --device-type rtlsdr --device 0 --freq 1090000000
if [ "$ADAPTIVE" -eq 1 ]; then
    set -- "$@" --adaptive-burst --adaptive-range
else
    set -- "$@" --gain "$GAIN"
fi
[ -n "$PPM" ] && set -- "$@" --ppm "$PPM"
[ -n "$LAT" ] && set -- "$@" --lat "$LAT" --lon "$LON"
[ "$MODEAC" -eq 1 ] && set -- "$@" --modeac
[ "$NET" -eq 1 ] && set -- "$@" --net --net-bind-address 127.0.0.1
[ "$STATS" -gt 0 ] 2>/dev/null && set -- "$@" --stats-every "$STATS" --stats-range

echo "ADS-B 1090 MHz — gain $([ "$ADAPTIVE" -eq 1 ] && echo adaptatif || echo "$GAIN dB")"
[ -n "$LAT" ] && echo "récepteur : $LAT $LON" || \
    echo "position du récepteur inconnue (-P lat,lon) : ni distance, ni cap, ni position au sol"

# Le mode -t s'appuie sur timeout(1), dump1090 n'a pas de limite de durée.
RUN=""
[ "$SECONDS_MAX" -gt 0 ] 2>/dev/null && RUN="timeout $SECONDS_MAX"

if [ "$WEB" -eq 1 ] || [ "$RADAR" -eq 1 ]; then
    # Le paquet Homebrew ne fournit aucune interface web : dump1090 écrit du JSON
    # dans un répertoire, que la carte comme le scope radar relisent. Donc pas de
    # --interactive ici : ncurses et l'affichage se disputeraient le terminal.
    rm -rf "$JSONDIR"; mkdir -p "$JSONDIR"
    set -- "$@" --quiet --write-json "$JSONDIR" --write-json-every 1 \
                --json-location-accuracy 2
    [ "$WEB" -eq 1 ] && echo "carte : http://127.0.0.1:$WEBPORT/   (Ctrl-C pour arrêter)"
    $RUN "$DUMP" "$@" &
    DPID=$!
    sleep 2
    kill -0 "$DPID" 2>/dev/null || {
        echo "dump1090 s'est arrêté aussitôt — dongle branché ?" >&2
        exit 1
    }
    if [ "$WEB" -eq 1 ]; then
        exec python3 "$DIR/adsbmap.py" --json-dir "$JSONDIR" --port "$WEBPORT" $OPEN
    fi
    exec python3 "$DIR/radar.py" --json-dir "$JSONDIR"
elif [ "$RAW" -eq 1 ]; then
    echo "trames Mode S brutes — Ctrl-C pour arrêter"
    exec $RUN "$DUMP" "$@" --raw
else
    # --interactive : table ncurses, une ligne par avion, rafraîchie en continu.
    set -- "$@" --interactive --interactive-ttl 60 --metric \
                --interactive-show-distance --interactive-distance-units km
    exec $RUN "$DUMP" "$@"
fi
