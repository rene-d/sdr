#!/bin/sh
# Réception AIS avec la RTL-SDR, via AIS-catcher.
#
#   ./ais.sh                  # décode et diffuse en UDP 127.0.0.1:10110
#   ./ais.sh -n               # affiche aussi les trames NMEA
#   ./ais.sh -w               # + interface web d'AIS-catcher sur :8100
#   ./ais.sh -t 60            # s'arrête après 60 s
#   ./ais.sh -o ais.nmea      # journalise les trames dans un fichier
#   ./ais.sh -g 40            # gain fixe au lieu de l'AGC
#
# La sortie UDP alimente un traceur de cartes : n'importe quel client NMEA 0183
# sachant lire un flux UDP fait l'affaire (OpenCPN, gnuais, un script maison).
#
# Antenne : brin vertical de 46-48 cm (quart d'onde à 162 MHz), comme la VHF marine.
# Ctrl-C pour arrêter.

set -e
CATCHER=${CATCHER:-../ext/AIS-catcher/build/AIS-catcher}
UDP_HOST=${UDP_HOST:-127.0.0.1}
UDP_PORT=${UDP_PORT:-10110}
GAIN=auto
WEB=0; WEBPORT=8100; SHOW=0; SECONDS_MAX=0; NMEA_FILE=""; PPM=""

while [ $# -gt 0 ]; do
    case "$1" in
        -g) GAIN="$2"; shift 2 ;;
        -p) PPM="$2"; shift 2 ;;
        -w) WEB=1; shift ;;
        -W) WEB=1; WEBPORT="$2"; shift 2 ;;
        -n) SHOW=1; shift ;;
        -t) SECONDS_MAX="$2"; shift 2 ;;
        -o) NMEA_FILE="$2"; shift 2 ;;
        -u) UDP_PORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 1 ;;
    esac
done

[ -x "$CATCHER" ] || {
    echo "AIS-catcher introuvable : $CATCHER" >&2
    echo "Le compiler dans ../ext/AIS-catcher, ou indiquer le chemin par CATCHER=…" >&2
    exit 1
}

# Le dongle est mono-process : un rtl_fm/rtl_power oublié fait échouer l'ouverture.
if pgrep -f 'rtl_fm|rtl_power' > /dev/null; then
    echo "Un process rtl_* tient déjà le dongle, je l'arrête." >&2
    pkill -f 'rtl_fm|rtl_power' || true
    sleep 1
fi
cleanup() { pkill -P $$ 2>/dev/null || true; }
trap cleanup INT TERM EXIT

# -d:0 est obligatoire : AIS-catcher énumère aussi les ports série, et sans index
# explicite il peut tomber sur cu.Bluetooth plutôt que sur la clé.
set -- -d:0 -gr TUNER "$GAIN" RTLAGC on
set -- "$@" -u "$UDP_HOST" "$UDP_PORT"
[ "$SHOW" -eq 1 ] && set -- "$@" -n || set -- "$@" -q
[ "$WEB" -eq 1 ] && set -- "$@" -N "$WEBPORT"
[ -n "$NMEA_FILE" ] && set -- "$@" -f "$NMEA_FILE"
[ -n "$PPM" ] && set -- "$@" -p "$PPM"
[ "$SECONDS_MAX" -gt 0 ] 2>/dev/null && set -- "$@" -T "$SECONDS_MAX"
set -- "$@" -v 10

echo "AIS 161,975 / 162,025 MHz — gain $GAIN — UDP $UDP_HOST:$UDP_PORT"
[ "$WEB" -eq 1 ] && echo "interface AIS-catcher : http://127.0.0.1:$WEBPORT/"
echo "Ctrl-C pour arrêter"
exec "$CATCHER" "$@"
