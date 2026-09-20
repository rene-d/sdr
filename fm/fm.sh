#!/bin/sh
# Écoute une station FM avec la RTL-SDR, locale ou sur un Pi à distance.
#
#   ./fm.sh 93.0            # écoute 93,0 MHz
#   ./fm.sh 101.2 -g 25     # gain réduit si le son sature
#   ./fm.sh 89.4 -q         # sans le bandeau RDS
#   ./fm.sh -H pi@pi4-sdr.local 101.2   # dongle sur le Pi (ou SDR_HOST)
#
# Ctrl-C pour arrêter. Voir README pour la liste des stations reçues ici.

set -e
FREQ=""
GAIN=40
QUIET=0

while [ $# -gt 0 ]; do
    case "$1" in
        -g) GAIN="$2"; shift 2 ;;
        -q) QUIET=1; shift ;;
        -H|--host) SDR_HOST="$2"; export SDR_HOST; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) FREQ="$1"; shift ;;
    esac
done

[ -n "$FREQ" ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
# Fréquence et gain partent dans une ligne de commande shell quand le dongle est
# distant : on n'y laisse passer que des nombres.
case "$FREQ$GAIN" in *[!0-9.]*) echo "fréquence ou gain invalide" >&2; exit 1 ;; esac

. "$(dirname "$0")/sdr.sh"
sdr_check

# Le dongle est mono-process : un rtl_fm oublié rend muet sans message d'erreur.
sdr_preflight

# Ne tue que nos propres enfants : « kill 0 » viserait tout le groupe de process,
# donc le shell appelant quand le script tourne hors terminal interactif.
# À distance il faut en plus achever le rtl_fm du Pi : la mort du ssh local ne
# l'emporte pas, il continuerait à tenir le dongle (voir README, « Pièges »).
cleanup() {
    pkill -P $$ 2>/dev/null || true
    [ -n "$SDR_HOST" ] && sdr_free
    true
}
trap cleanup INT TERM EXIT

# Nom de la station via RDS, en préambule (le dongle ne fait qu'une chose à la fois).
if [ "$QUIET" -eq 0 ] && sdr_redsea_where >/dev/null; then
    printf 'Identification RDS de %s MHz ... ' "$FREQ"
    PS=$(sdr_rds "$FREQ" "$GAIN" 10 | sdr_ps_of) || PS=""
    [ -n "$PS" ] && echo "$PS" || echo "(pas de RDS)"
    sleep 1
fi

echo "Écoute de $FREQ MHz — gain ${GAIN} dB — dongle $(sdr_where) — Ctrl-C pour arrêter"

# ffmpeg + audiotoolbox : sur cette machine ffplay est muet (SDL, voir README).
# rtl_fm démodule là où est le dongle, seul le 48 kHz mono traverse le réseau
# (96 ko/s) — envoyer l'IQ brut demanderait 4,8 Mo/s.
sdr_run_quiet rtl_fm -f "${FREQ}M" -M wbfm -s 200000 -r 48000 -g "$GAIN" - \
    | ffmpeg -hide_banner -loglevel warning -probesize 32 -fflags nobuffer \
             -flags low_delay -f s16le -ar 48000 -ch_layout mono -i - -f audiotoolbox -
