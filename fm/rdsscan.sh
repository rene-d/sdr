#!/bin/sh
# Décode le RDS de plusieurs stations FM, une à la fois (le dongle est mono-process).
#
#   ./rdsscan.sh 89.4 93.0 101.2 107.6
#   ./rdsscan.sh -s                  # balaye la bande, puis fait le tour des stations
#   DUR=120 ./rdsscan.sh 96.3        # dwell long, pour un PS récalcitrant
#   GAIN=25 ./rdsscan.sh 101.2       # gain réduit si le tuner sature
#   ./rdsscan.sh -H pi@pi4-sdr.local 101.2   # dongle sur le Pi (ou SDR_HOST)
#
# -s confie le repérage des porteuses à fmscan.py : BAND=88M:108M au seuil
# THRESH=12 dB au-dessus du plancher. Compter DUR par station — la bande entière
# fait une trentaine de canaux, soit un bon quart d'heure.
#
# Écrit rds/<freq>.json (une ligne JSON par groupe) et résume PS / PI / PTY.
# Nécessite redsea compilé, ici ou sur la machine du dongle : voir README.

set -e
DUR=${DUR:-25}
OUT=${OUT:-rds}
GAIN=${GAIN:-40}
BAND=${BAND:-88M:108M}
THRESH=${THRESH:-12}

SCAN=0
ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -H|--host) SDR_HOST="$2"; export SDR_HOST; shift 2 ;;
        -s|--scan) SCAN=1; shift ;;
        *) ARGS="$ARGS $1"; shift ;;
    esac
done
# shellcheck disable=SC2086
set -- $ARGS
[ $# -ge 1 ] || [ "$SCAN" = 1 ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

. "$(dirname "$0")/sdr.sh"
sdr_check
WHERE=$(sdr_redsea_where) || {
    echo "redsea introuvable : $REDSEA ici, $SDR_REDSEA sur $(sdr_where) (voir README)" >&2
    exit 1
}

# Ici on refuse au lieu de tuer : un rdsscan de dix stations écrase une écoute
# en cours pour plusieurs minutes.
if sdr_busy; then
    echo "Un process rtl_* tient déjà le dongle sur $(sdr_where) — le libérer d'abord." >&2
    exit 1
fi

# Le timeout tourne du côté du dongle : chaque capture se termine seule, même si
# le ssh meurt. Reste le cas du Ctrl-C en plein dwell, d'où le trap.
trap 'sdr_free; exit 130' INT TERM

echo "redsea tourne en $WHERE, dongle $(sdr_where)"

if [ "$SCAN" = 1 ]; then
    printf 'balayage %s à +%s dB ... ' "$BAND" "$THRESH"
    # -n 200 : sans ça fmscan s'arrête aux 12 canaux les plus forts et le tour
    # serait tronqué sans le dire. Le spectre ANSI part à la poubelle : on ne garde
    # que les lignes « <freq> MHz <niveau> dB », d'où le test sur $2 et non un
    # grep MHz. Les fréquences sont remises dans l'ordre de la bande, plus lisible
    # à l'écran que l'ordre par puissance de fmscan.
    # Le pipe est séparé du balayage : sinon awk réussit toujours et un fmscan
    # qui échoue (dongle pris, antenne débranchée) passerait pour une bande vide.
    PEAKS=$("$(dirname "$0")/fmscan.py" --once -f "$BAND" -g "$GAIN" \
                -t "$THRESH" -n 200) || { echo; exit 1; }
    FOUND=$(echo "$PEAKS" | awk '$2 == "MHz" {print $1}' | sort -n)
    [ -n "$FOUND" ] || { echo; echo "aucune porteuse à +$THRESH dB (antenne ?)" >&2; exit 1; }
    echo "$(echo "$FOUND" | wc -l | tr -d ' ') stations"
    # shellcheck disable=SC2086
    set -- $FOUND "$@"
fi

mkdir -p "$OUT"
for f in "$@"; do
    case "$f" in *[!0-9.]*) echo "fréquence invalide : $f" >&2; exit 1 ;; esac
    printf '%6s MHz (%ss) ... ' "$f" "$DUR"
    sdr_rds "$f" "$GAIN" "$DUR" > "$OUT/$f.json" || true
    python3 - "$OUT/$f.json" <<'PY'
import json, sys, collections
ps = collections.Counter(); pi = collections.Counter(); pty = collections.Counter()
n = 0
for line in open(sys.argv[1]):
    try: g = json.loads(line)
    except ValueError: continue
    n += 1
    if 'ps' in g: ps[g['ps'].strip()] += 1
    if 'pi' in g: pi[g['pi']] += 1
    if g.get('prog_type', 'No PTY') != 'No PTY': pty[g['prog_type']] += 1
top = lambda c: c.most_common(1)[0][0] if c else '—'
print(f'{n:4} groupes | PS {top(ps):<9} PI {top(pi):<7} {top(pty)}')
PY
done
