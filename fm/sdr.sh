# Aiguillage local / distant des commandes rtl_*, partagé par fm.sh et rdsscan.sh.
# Pendant Python : sdrhost.py — même variables, même comportement.
#
#   set -Ux SDR_HOST pi@pi4-sdr.local     # fish : le dongle est sur le Pi
#   ./fm.sh 101.2                         # ... et tout le reste suit
#   ./fm.sh -H pi@pi4-sdr.local 101.2     # ponctuellement, sans la variable
#
# SDR_HOST vide = dongle sur cette machine, comportement d'origine.
# Le démodulateur (rtl_fm, rtl_power) tourne toujours du côté du dongle ; seul
# son flux de sortie traverse le réseau : 96 ko/s pour l'audio 48 kHz, 342 ko/s
# pour le MPX 171 kHz. Tenu sans perte en Wi-Fi (mesuré 293 ko/s sur 8 s).

SDR_HOST=${SDR_HOST:-}
# Multiplexage : rdsscan enchaîne une dizaine de connexions, 350 ms la première
# puis 40 ms les suivantes au lieu de 350 ms à chaque fois.
SDR_SSH_OPTS=${SDR_SSH_OPTS:--o ConnectTimeout=8 -o ControlMaster=auto -o ControlPath=/tmp/.sdr-ssh-%r@%h-%p -o ControlPersist=60}

# Noms *exacts* des binaires qui monopolisent le dongle, pour pgrep -x.
# « pgrep -f rtl_ » ne convient pas à distance : le motif figure dans la ligne de
# commande du shell que ssh lance, le pgrep se trouve lui-même et le pkill se tue.
SDR_PROCS='rtl_(fm|power|sdr|tcp|test|adsb|biast)'

REDSEA=${REDSEA:-../ext/redsea/build/redsea}   # redsea sur cette machine
SDR_REDSEA=${SDR_REDSEA:-redsea}               # redsea sur la machine du dongle

sdr_where() { [ -n "$SDR_HOST" ] && echo "$SDR_HOST" || echo "local"; }

# Lance une commande là où est le dongle. Les arguments sont réenveloppés dans
# des apostrophes pour le shell distant, sans quoi « rtl_(fm|power) » ou « 171k »
# se feraient interpréter. -n : ssh ne touche pas au stdin du pipeline appelant.
sdr_run() {
    if [ -n "$SDR_HOST" ]; then
        _cmd=''
        for _a in "$@"; do _cmd="$_cmd '$_a'"; done
        # shellcheck disable=SC2086
        ssh -n $SDR_SSH_OPTS "$SDR_HOST" "$_cmd"
    else
        "$@"
    fi
}

# Idem, mais sans le bavardage de la commande radio sur stderr. Les erreurs de
# ssh lui-même restent visibles : un Pi injoignable ne doit pas être silencieux.
sdr_run_quiet() {
    if [ -n "$SDR_HOST" ]; then
        _cmd=''
        for _a in "$@"; do _cmd="$_cmd '$_a'"; done
        # shellcheck disable=SC2086
        ssh -n $SDR_SSH_OPTS "$SDR_HOST" "$_cmd 2>/dev/null"
    else
        "$@" 2>/dev/null
    fi
}

# Le dongle est joignable et la pile rtl_* installée de son côté ?
sdr_check() {
    [ -n "$SDR_HOST" ] || return 0
    sdr_run command -v rtl_fm >/dev/null 2>&1 && return 0
    echo "SDR_HOST=$SDR_HOST : ssh injoignable, ou rtl_fm absent là-bas." >&2
    return 1
}

sdr_busy() { sdr_run pgrep -x "$SDR_PROCS" >/dev/null 2>&1; }
sdr_free() { sdr_run pkill -x "$SDR_PROCS" >/dev/null 2>&1 || true; }

# À appeler avant toute capture : un rtl_fm oublié rend muet sans message.
# Le cas est plus fréquent à distance qu'en local — ssh ne tue PAS la commande
# distante quand la connexion tombe (vérifié : elle survit indéfiniment).
sdr_preflight() {
    if sdr_busy; then
        echo "Un process rtl_* tient déjà le dongle sur $(sdr_where), je l'arrête." >&2
        sdr_free
        sleep 1
    fi
}

# Où faire tourner redsea : 'remote' (seul le JSON traverse le réseau, quelques
# ko), 'local' (le MPX traverse, 342 ko/s), '' s'il est introuvable des deux côtés.
sdr_redsea_where() {
    if [ -z "$_SDR_RW" ]; then
        if [ -n "$SDR_HOST" ] && sdr_run command -v "$SDR_REDSEA" >/dev/null 2>&1; then
            _SDR_RW=remote
        elif [ -x "$REDSEA" ] || command -v "$REDSEA" >/dev/null 2>&1; then
            _SDR_RW=local
        else
            _SDR_RW=none
        fi
    fi
    [ "$_SDR_RW" = none ] && return 1
    echo "$_SDR_RW"
}

# Flux JSON de redsea pour une station.  $1 fréquence MHz, $2 gain, $3 durée s.
# -M fm et non wbfm : redsea veut le MPX complet jusqu'à 57 kHz, à 171 kHz pile.
sdr_rds() {
    _f=$1; _g=$2; _d=$3
    _mpx="rtl_fm -M fm -l 0 -A std -p 0 -s 171k -g $_g -F 9 -f ${_f}M -"
    case "$(sdr_redsea_where)" in
        remote)
            # shellcheck disable=SC2086
            ssh -n $SDR_SSH_OPTS "$SDR_HOST" \
                "timeout $((_d + 8)) $_mpx 2>/dev/null | timeout $_d $SDR_REDSEA --input mpx -r 171k 2>/dev/null" ;;
        local)
            # shellcheck disable=SC2086
            sdr_run_quiet timeout $((_d + 8)) $_mpx \
                | timeout "$_d" "$REDSEA" --input mpx -r 171k 2>/dev/null ;;
        *)  return 1 ;;
    esac
}

# Extrait le PS le plus fréquent d'un flux JSON redsea sur stdin.
sdr_ps_of() {
    python3 -c "
import json,sys,collections
c=collections.Counter()
for l in sys.stdin:
    try: g=json.loads(l)
    except ValueError: continue
    if 'ps' in g: c[g['ps'].strip()]+=1
print(c.most_common(1)[0][0] if c else '')" 2>/dev/null
}
