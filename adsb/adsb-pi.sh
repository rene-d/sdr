#!/bin/sh
# Carte ADS-B sur le Mac, alimentée par le dump1090-fa du Pi 4.
#
#   ./adsb-pi.sh                # carte locale sur http://127.0.0.1:8090
#   ./adsb-pi.sh -o             # et ouvre le navigateur
#   ./adsb-pi.sh -H 192.168.3.14   # autre hôte que pi4-sdr.home
#
# Le Pi sert déjà sa propre carte sur http://pi4-sdr.home/skyaware/ ; ce script
# n'est utile que pour utiliser adsbmap.py, qui veut un répertoire local. On y
# recopie aircraft.json une fois par seconde — lighttpd ajoute l'en-tête CORS
# et sert /run/dump1090-fa sous /skyaware/data/.
#
# Ctrl-C pour arrêter.

set -e
DIR=$(cd "$(dirname "$0")" && pwd)
HOST=${ADSB_HOST:-pi4-sdr.home}
JSONDIR=${JSONDIR:-${TMPDIR:-/tmp}/adsb-pi-json}
PORT=8090; OPEN=""

while [ $# -gt 0 ]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;;
        -W) PORT="$2"; shift 2 ;;
        -o) OPEN="--open"; shift ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "option inconnue : $1" >&2; exit 1 ;;
    esac
done

BASE="http://$HOST/skyaware/data"
mkdir -p "$JSONDIR"

curl -fsS --max-time 5 "$BASE/aircraft.json" -o "$JSONDIR/aircraft.json" || {
    echo "pas de réponse de $BASE — le service tourne-t-il ?" >&2
    echo "  ssh pi@$HOST systemctl status dump1090-fa" >&2
    exit 1
}
# receiver.json ne bouge pas : une seule fois suffit. Absent si la position du
# récepteur n'est pas renseignée dans /etc/default/dump1090-fa.
curl -fsS --max-time 5 "$BASE/receiver.json" -o "$JSONDIR/receiver.json" || true

# Écriture atomique : adsbmap.py relit le fichier chaque seconde et tomberait
# sinon sur des JSON tronqués.
# `kill -0 $$` : $$ reste le PID du shell principal, que l'exec final
# transforme en adsbmap.py. La boucle s'arrête donc d'elle-même si la carte
# meurt sans laisser le trap jouer (SIGKILL, terminal fermé) — sinon elle
# survit en orpheline et continue à interroger le Pi une fois par seconde.
while kill -0 $$ 2>/dev/null; do
    curl -fsS --max-time 5 "$BASE/aircraft.json" -o "$JSONDIR/.aircraft.tmp" \
        && mv "$JSONDIR/.aircraft.tmp" "$JSONDIR/aircraft.json"
    sleep 1
done &
SYNC=$!
trap 'kill $SYNC 2>/dev/null || true' INT TERM EXIT

echo "source : $BASE  →  $JSONDIR"
exec python3 "$DIR/adsbmap.py" --json-dir "$JSONDIR" --port "$PORT" $OPEN
