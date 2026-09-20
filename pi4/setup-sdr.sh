#!/usr/bin/env bash
#
# setup-sdr.sh — à lancer SUR le Raspberry Pi, après le premier démarrage.
# Installe la pile RTL-SDR, neutralise le pilote DVB-T, puis valide avec rtl_test.
#
#   Usage:
#     ./setup-sdr.sh                       # socle rtl-sdr seul
#     ./setup-sdr.sh --with 433,adsb       # + décodeurs
#     ./setup-sdr.sh --all                 # tout sauf gnuradio
#     ./setup-sdr.sh --dry-run             # montre les commandes, n'exécute rien
#
#   Groupes (--with, séparés par des virgules) :
#     soapy     soapysdr-module-rtlsdr soapysdr-tools   (SDR++, CubicSDR)
#     433       rtl-433                                 (capteurs 433 MHz)
#     adsb      dump1090-mutability                     (ADS-B)
#     digital   multimon-ng direwolf                    (POCSAG, APRS)
#     audio     sox                                     (traitement depuis rtl_fm)
#     build     librtlsdr-dev & co                      (compiler AIS-catcher et cie)
#     gnuradio  gnuradio                                (~1,5 Go, hors --all)
#
set -euo pipefail

BASE_PKGS=(rtl-sdr)
DVB_MODULE="dvb_usb_rtl28xxu"
MODPROBE_DIR="${MODPROBE_DIR:-/etc/modprobe.d}"
BLACKLIST_FILE="$MODPROBE_DIR/rtl-sdr-blacklist.conf"

WITH=""
ALL=0
DRY_RUN=0
SKIP_TEST=0

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_g$c_b" "$c_0$c_b" "$*$c_0" >&2; }
warn() { printf '%s[!]%s %s\n' "$c_y$c_b" "$c_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_r$c_b" "$c_0" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with)      WITH="${2:?--with demande une liste}"; shift 2 ;;
    --all)       ALL=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --skip-test) SKIP_TEST=1; shift ;;
    -h|--help)   usage 0 ;;
    *)           die "Option inconnue : $1  (--help pour l'aide)" ;;
  esac
done

# run <cmd...> : exécute, ou affiche seulement si --dry-run
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    %s$%s %s\n' "$c_y" "$c_0" "$*" >&2
  else
    "$@"
  fi
}

# ------------------------------------------------------- contrôles d'hôte

check_host() {
  if [[ "$(uname -s)" != Linux ]]; then
    [[ $DRY_RUN -eq 1 ]] \
      && { warn "hôte $(uname -s), pas Linux — toléré en --dry-run seulement."; return; }
    die "à lancer sur le Raspberry Pi, pas sur le Mac. Copie-le d'abord :
      scp setup-sdr.sh pi@pi4-sdr.local:  &&  ssh pi@pi4-sdr.local ./setup-sdr.sh"
  fi
  grep -qi raspberry /proc/device-tree/model 2>/dev/null \
    || warn "ce ne semble pas être un Raspberry Pi — on continue quand même."
  command -v apt-get >/dev/null || die "apt-get introuvable : distribution non Debian."
}

# root direct, ou sudo
SUDO=""
setup_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
  elif command -v sudo >/dev/null; then
    SUDO="sudo"
    [[ $DRY_RUN -eq 1 ]] || sudo -v || die "sudo requis."
  else
    die "ni root ni sudo."
  fi
}

# ------------------------------------------------------------- les paquets

resolve_packages() {
  PKGS=("${BASE_PKGS[@]}")
  local groups="$WITH"
  [[ $ALL -eq 1 ]] && groups="soapy,433,adsb,digital,audio,build${WITH:+,$WITH}"

  local g
  for g in ${groups//,/ }; do
    case "$g" in
      soapy)    PKGS+=(soapysdr-module-rtlsdr soapysdr-tools) ;;
      433)      PKGS+=(rtl-433) ;;
      adsb)     PKGS+=(dump1090-mutability) ;;
      digital)  PKGS+=(multimon-ng direwolf) ;;
      audio)    PKGS+=(sox) ;;
      # Sans librtlsdr-dev, cmake ne trouve pas la lib : AIS-catcher se compile
      # sans backend RTL-SDR, démarre normalement et annonce « Found 0 device(s) ».
      build)    PKGS+=(build-essential cmake ninja-build pkg-config
                       librtlsdr-dev libusb-1.0-0-dev zlib1g-dev libssl-dev libzmq3-dev) ;;
      gnuradio) PKGS+=(gnuradio) ;;
      "")       ;;
      *)        die "groupe inconnu : $g  (--help pour la liste)" ;;
    esac
  done

  # dédoublonnage en préservant l'ordre
  local seen=() p keep=()
  for p in "${PKGS[@]}"; do
    [[ " ${seen[*]-} " == *" $p "* ]] && continue
    seen+=("$p"); keep+=("$p")
  done
  PKGS=("${keep[@]}")
}

install_packages() {
  log "Installation : ${PKGS[*]}"
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
  run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
}

# --------------------------------------------- neutraliser le pilote DVB-T

blacklist_dvb() {
  # Trixie n'installe plus de blacklist (cf. bug Debian #823022) : sans elle, le
  # noyau s'approprie la clé et rtl_test échoue en "usb_claim_interface error -6".
  if [[ -f "$BLACKLIST_FILE" ]] && grep -q "^blacklist $DVB_MODULE\$" "$BLACKLIST_FILE"; then
    log "Blacklist déjà en place : $BLACKLIST_FILE"
  else
    log "Blacklist du pilote DVB-T -> $BLACKLIST_FILE"
    if [[ $DRY_RUN -eq 1 ]]; then
      printf '    %s$%s echo "blacklist %s" | %s tee %s\n' \
        "$c_y" "$c_0" "$DVB_MODULE" "$SUDO" "$BLACKLIST_FILE" >&2
    else
      printf 'blacklist %s\n' "$DVB_MODULE" | $SUDO tee "$BLACKLIST_FILE" >/dev/null
    fi
  fi

  # décharge le module s'il est déjà chargé : évite un redémarrage
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    %s$%s %s modprobe -r %s   # si chargé\n' "$c_y" "$c_0" "$SUDO" "$DVB_MODULE" >&2
  elif lsmod 2>/dev/null | grep -q "^${DVB_MODULE} "; then
    log "Déchargement de $DVB_MODULE…"
    $SUDO modprobe -r "$DVB_MODULE" \
      || warn "déchargement impossible (module occupé) — un redémarrage réglera ça."
  fi
}

# ------------------------------------------------------------ permissions

RELOGIN_NEEDED=0
ensure_plugdev() {
  local u="${SUDO_USER:-${USER:-$(id -un)}}"
  # La règle udev de Trixie est MODE=0660 GROUP=plugdev : appartenir au groupe
  # suffit, y compris en SSH (contrairement à TAG+="uaccess").
  if id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qx plugdev; then
    log "Utilisateur $u déjà dans plugdev."
  else
    log "Ajout de $u au groupe plugdev…"
    run $SUDO usermod -aG plugdev "$u"
    RELOGIN_NEEDED=1
  fi
}

# ------------------------------------------------------------- validation

DEVICE_LINE=""
TUNER_LINE=""
verify() {
  [[ $SKIP_TEST -eq 1 ]] && { warn "validation ignorée (--skip-test)."; return; }
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    %s$%s timeout 20 rtl_test -t\n' "$c_y" "$c_0" >&2
    return
  fi

  command -v rtl_test >/dev/null || { warn "rtl_test introuvable, validation sautée."; return; }

  log "Validation : rtl_test -t"
  local out rc=0
  # rc 1 est normal avec un tuner R820T ("No E4000 tuner found"), rc 124 = timeout
  out="$(timeout 20 rtl_test -t 2>&1)" || rc=$?

  if grep -q 'No supported devices found' <<<"$out"; then
    warn "aucune clé détectée — branche la RTL-SDR sur un port USB 2.0 (noir), puis relance."
    return
  fi
  if grep -q 'usb_claim_interface error' <<<"$out"; then
    warn "le pilote DVB-T tient encore le périphérique. Redémarre : sudo reboot"
    return
  fi

  DEVICE_LINE="$(grep -m1 -E '^[[:space:]]+0:' <<<"$out" | sed 's/^[[:space:]]*//')"
  TUNER_LINE="$(grep -m1 -i 'tuner' <<<"$out" | sed 's/^[[:space:]]*//')"
  [[ -n "$DEVICE_LINE$TUNER_LINE" ]] \
    || { warn "sortie de rtl_test inattendue (code $rc) :"; printf '%s\n' "$out" >&2; }
}

# ---------------------------------------------------------------- résumé

summary() {
  printf '\n%s%sInstallation terminée.%s\n\n' "$c_g" "$c_b" "$c_0" >&2
  printf '  Paquets  : %s\n' "${PKGS[*]}" >&2
  [[ -n "$DEVICE_LINE" ]] && printf '  Clé      : %s\n' "$DEVICE_LINE" >&2
  [[ -n "$TUNER_LINE"  ]] && printf '  Tuner    : %s\n' "$TUNER_LINE" >&2
  printf '  Blacklist: %s\n' "$BLACKLIST_FILE" >&2

  if [[ $RELOGIN_NEEDED -eq 1 ]]; then
    printf '\n  %sReconnecte-toi%s (exit puis ssh) pour que plugdev prenne effet.\n' "$c_y" "$c_0" >&2
  fi

  cat >&2 <<'EOF'

Pour piloter la clé depuis le Mac (gqrx / SDR++), sur le Pi :

  rtl_tcp -a 0.0.0.0

puis côté Mac, source "RTL-SDR Spyserver/TCP" vers pi4-sdr.local:1234.

Mémo V3 :
  rtl_sdr -D 2 -f 7100000 -s 2048000 hf.bin   # HF < 24 MHz, échantillonnage direct
  sudo rtl_biast -b 1                          # bias tee ON (jamais sur antenne passive)
  sudo rtl_biast -b 0                          # bias tee OFF
EOF
}

# ------------------------------------------------------------------- main

check_host
setup_sudo
resolve_packages
install_packages
blacklist_dvb
ensure_plugdev
verify
summary
