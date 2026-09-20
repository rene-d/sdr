#!/bin/sh
# Écoute la VHF marine avec la RTL-SDR.
#
#   ./vhf.sh 16             # canal 16 (détresse et appel)
#   ./vhf.sh 16 -q 50       # avec squelch : silence tant qu'il n'y a pas de trafic
#   ./vhf.sh 77 -m -g 15    # mètre de niveau : pour tester un émetteur
#   ./vhf.sh 27 -c          # côté station côtière (canaux duplex)
#   ./vhf.sh 156.8M         # fréquence directe
#   ./vhf.sh -l             # liste des canaux
#
# Antenne : brin vertical de 47-48 cm (quart d'onde), ou dipôle 2 x 47,8 cm.
# Ctrl-C pour arrêter.

set -e
ARG=""; GAIN=40; SQUELCH=0; COAST=0; METER=0

while [ $# -gt 0 ]; do
    case "$1" in
        -g) GAIN="$2"; shift 2 ;;
        -q) SQUELCH="$2"; shift 2 ;;
        -c) COAST=1; shift ;;
        -m) METER=1; shift ;;
        -l|--list) ARG="LIST"; shift ;;
        -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) ARG="$1"; shift ;;
    esac
done
[ -n "$ARG" ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# Table ITU. Simplex : navire et station côtière sur la même fréquence.
# Duplex : la côtière émet 4,6 MHz plus haut (option -c).
resolve() {
    python3 - "$1" "$2" <<'PY'
import sys
arg, coast = sys.argv[1], sys.argv[2] == '1'
SIMPLEX = {6,8,9,10,11,12,13,14,15,16,17,67,68,69,70,71,72,73,74,75,76,77,87,88}
NOTES = {
    16: 'détresse, sécurité et appel — veille permanente',
    70: 'ASN/DSC : données numériques, PAS de voix',
    6:  'sécurité navire-navire', 8: 'navire-navire',
    9:  'navire-navire, souvent ports de plaisance',
    13: 'sécurité de la navigation, passerelle à passerelle',
    72: 'navire-navire', 77: 'navire-navire',
}
def freqs(n):
    ship = 156.000 + 0.05*n if n <= 28 else 156.025 + 0.05*(n-60)
    return round(ship,3), (None if n in SIMPLEX else round(ship+4.6,3))
if arg == 'LIST':
    print('LIST')
    for n in list(range(1,29)) + list(range(60,89)):
        s,c = freqs(n)
        print(f"{n:3} | {s:7.3f} | {'simplex' if c is None else f'{c:7.3f}':>7} | {NOTES.get(n,'')}")
    raise SystemExit
if arg.rstrip('Mm').replace('.','',1).isdigit() and ('M' in arg or '.' in arg and float(arg.rstrip('Mm')) > 100):
    f = float(arg.rstrip('Mm'))
    print(f"FREQ {f:.4f} {f:.4f} MHz (direct)")
    raise SystemExit
try: n = int(arg)
except ValueError: print(f"ERR canal ou fréquence invalide : {arg}"); raise SystemExit
if not (1 <= n <= 28 or 60 <= n <= 88): print(f"ERR canal {n} hors table (1-28, 60-88)"); raise SystemExit
ship, cst = freqs(n)
if coast and cst is None: print(f"ERR canal {n} est simplex, pas de fréquence côtière"); raise SystemExit
f = cst if coast else ship
side = 'station côtière' if coast else 'navire'
print(f"FREQ {f:.4f} canal {n} ({side}) {NOTES.get(n,'')}")
PY
}

OUT=$(resolve "$ARG" "$COAST")
case "$OUT" in
    LIST*) echo "can |  navire |  côtière | note"; echo "$OUT" | tail -n +2; exit 0 ;;
    ERR*)  echo "${OUT#ERR }" >&2; exit 1 ;;
esac
FREQ=$(echo "$OUT" | awk '{print $2}')
LABEL=$(echo "$OUT" | cut -d' ' -f3-)

if pgrep -f 'rtl_fm|rtl_power' > /dev/null; then
    echo "Un process rtl_* tient déjà le dongle, je l'arrête." >&2
    pkill -f 'rtl_fm|rtl_power' || true
    sleep 1
fi
cleanup() { pkill -P $$ 2>/dev/null || true; }
trap cleanup INT TERM EXIT

echo "$FREQ MHz — $LABEL"

if [ "$METER" -eq 1 ]; then
    echo "mètre de niveau, gain ${GAIN} dB — Ctrl-C pour arrêter"
    rtl_fm -f "${FREQ}M" -M fm -s 16k -g "$GAIN" -l 0 - 2>/dev/null | python3 -u -c '
import sys, numpy as np
BLOC = 8000                                  # 0,5 s a 16 kHz
while True:
    raw = sys.stdin.buffer.read(BLOC * 2)
    if len(raw) < BLOC * 2:
        break
    x = np.frombuffer(raw, dtype="<i2").astype(float)
    db = 20 * np.log10(np.sqrt((x ** 2).mean()) / 32768 + 1e-12)
    n = max(0, min(50, int((db + 60) * 50 / 60)))
    print("{:6.1f} dBFS |{:<50}|".format(db, "#" * n))
'
    exit 0
fi

if [ "$SQUELCH" -gt 0 ] 2>/dev/null; then
    echo "squelch $SQUELCH, gain ${GAIN} dB — silence = pas de trafic — Ctrl-C pour arrêter"
else
    echo "squelch ouvert (souffle normal), gain ${GAIN} dB — Ctrl-C pour arrêter"
fi

# NBFM : -s fixe la bande passante ET le débit de sortie (le -r de rtl_fm ne sait
# que décimer, jamais interpoler) ; 16 kHz convient aux canaux 25 kHz. C'est ffmpeg
# qui rééchantillonne vers le périphérique.
rtl_fm -f "${FREQ}M" -M fm -s 16k -g "$GAIN" -l "$SQUELCH" - 2>/dev/null \
    | ffmpeg -hide_banner -loglevel error -probesize 32 -fflags nobuffer \
             -flags low_delay -f s16le -ar 16000 -ch_layout mono -i - -f audiotoolbox -
