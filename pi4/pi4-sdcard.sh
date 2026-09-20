#!/usr/bin/env bash
#
# pi4-sdcard.sh — prépare une carte microSD Raspberry Pi OS (64-bit) pour un Pi 4,
# prête à démarrer en headless : Wi-Fi configuré + SSH par clé publique.
#
#   Usage:
#     ./pi4-sdcard.sh --disk /dev/disk6                # télécharge, grave, configure
#     ./pi4-sdcard.sh --disk /dev/disk6 --variant full # variante avec bureau
#     ./pi4-sdcard.sh --disk /dev/disk6 --config-only  # re-applique juste la config
#     ./pi4-sdcard.sh --list                           # liste les disques externes
#
#   Variantes : lite (défaut, headless) | desktop | full
#
#   Wi-Fi : par défaut le réseau auquel ce Mac est connecté, mot de passe lu dans
#   le trousseau (macOS demande l'autorisation). Sinon --wifi-ssid / --wifi-pass,
#   les variables WIFI_SSID / WIFI_PASS, ou une saisie au clavier. --no-wifi pour
#   une carte Ethernet seule.
#
#   La config du premier démarrage est écrite via cloud-init (user-data /
#   network-config), mécanisme des images Trixie ; repli automatique sur
#   custom.toml pour les images Bookworm plus anciennes.
#
set -euo pipefail

############################  CONFIGURATION  ############################

VARIANT="${VARIANT:-lite}"                  # lite | desktop | full
PI_HOSTNAME="${PI_HOSTNAME:-pi4-sdr}"       # nom réseau -> pi4-sdr.local
PI_USER="${PI_USER:-pi}"                    # compte créé au premier boot
PI_PASSWORD="${PI_PASSWORD:-}"              # vide => mot de passe aléatoire affiché à la fin
SSH_PUBKEY="${SSH_PUBKEY:-$HOME/.ssh/id_rsa.pub}"

WIFI_SSID="${WIFI_SSID:-}"                  # vide => le réseau courant de ce Mac
WIFI_PASS="${WIFI_PASS:-}"                  # vide => trousseau, sinon saisie au clavier
WLAN_COUNTRY="FR"                           # domaine réglementaire (bandes Wi-Fi autorisées)

TIMEZONE="Europe/Paris"
KEYMAP="fr"

CACHE_DIR="${CACHE_DIR:-$HOME/.cache/raspios}"

#########################################################################

DISK=""
CONFIG_ONLY=0
LIST_ONLY=0
NO_WIFI=0
ASSUME_YES=0
FORCE=0

c_r=$'\033[31m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_b=$'\033[1m'; c_0=$'\033[0m'
log()  { printf '%s==>%s %s\n' "$c_g$c_b" "$c_0$c_b" "$*$c_0" >&2; }
warn() { printf '%s[!]%s %s\n' "$c_y$c_b" "$c_0" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_r$c_b" "$c_0" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disk)        DISK="${2:?--disk demande un argument}"; shift 2 ;;
    --variant)     VARIANT="${2:?--variant demande un argument}"; shift 2 ;;
    --wifi-ssid)   WIFI_SSID="${2:?--wifi-ssid demande un argument}"; shift 2 ;;
    --wifi-pass)   WIFI_PASS="${2:?--wifi-pass demande un argument}"; shift 2 ;;
    --no-wifi)     NO_WIFI=1; shift ;;
    --config-only) CONFIG_ONLY=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --force)       FORCE=1; shift ;;
    --list)        LIST_ONLY=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             die "Option inconnue : $1  (--help pour l'aide)" ;;
  esac
done

for bin in curl shasum xz diskutil openssl; do
  command -v "$bin" >/dev/null 2>&1 || die "commande manquante : $bin"
done

case "$VARIANT" in
  lite)    SLUG="raspios_lite_arm64_latest" ;;
  desktop) SLUG="raspios_arm64_latest" ;;
  full)    SLUG="raspios_full_arm64_latest" ;;
  *)       die "variante inconnue : $VARIANT (lite | desktop | full)" ;;
esac

[[ -r "$SSH_PUBKEY" ]] || die "clé publique introuvable : $SSH_PUBKEY"
PUBKEY="$(tr -d '\r\n' < "$SSH_PUBKEY")"
[[ "$PUBKEY" == ssh-* || "$PUBKEY" == ecdsa-* ]] \
  || die "$SSH_PUBKEY ne ressemble pas à une clé publique OpenSSH"

# --------------------------------------------------------- 1. image disque

BASE_URL="https://downloads.raspberrypi.com/$SLUG"

download_image() {
  mkdir -p "$CACHE_DIR"
  log "Résolution de l'image ($VARIANT)…"
  local real_url
  real_url="$(curl -fsIL -o /dev/null -w '%{url_effective}' "$BASE_URL")" \
    || die "impossible de joindre downloads.raspberrypi.com"
  IMG_XZ="$CACHE_DIR/$(basename "$real_url")"
  log "Image : $(basename "$IMG_XZ")"

  curl -fL --progress-bar -C - -o "$IMG_XZ" "$real_url" || die "échec du téléchargement"
  curl -fsSL -o "$IMG_XZ.sha256" "$BASE_URL.sha256"     || die "échec du téléchargement du SHA256"

  log "Vérification de l'empreinte SHA256…"
  ( cd "$CACHE_DIR" && shasum -a 256 -c "$(basename "$IMG_XZ").sha256" ) \
    || die "empreinte invalide — image corrompue, supprime $IMG_XZ et relance"
}

# ------------------------------------------------------------- 2. le disque

# Un lecteur SD intégré au Mac se déclare "Internal" : le critère utile est
# "Removable Media: Removable", pas l'emplacement du lecteur.
disk_field() { sed -n "s/.*$2: *//p" <<<"$1" | head -1; }

is_removable() {
  local info; info="$(diskutil info "$1" 2>/dev/null)" || return 1
  [[ "$(disk_field "$info" 'Removable Media')" == Removable ]] && return 0
  [[ "$(disk_field "$info" 'Device Location')" == External  ]] && return 0
  return 1
}

list_candidates() {
  local d info found=0
  printf '\n  %-11s %-26s %-9s %s\n' 'DISQUE' 'LECTEUR / MÉDIA' 'TAILLE' 'BUS' >&2
  for d in $(diskutil list physical 2>/dev/null | awk '/^\/dev\/disk/{print $1}'); do
    is_removable "$d" || continue
    info="$(diskutil info "$d")"
    found=1
    printf '  %-11s %-26s %-9s %s\n' "$d" \
      "$(disk_field "$info" 'Device \/ Media Name')" \
      "$(disk_field "$info" 'Disk Size' | sed 's/ (.*//')" \
      "$(disk_field "$info" 'Protocol')" >&2
  done
  [[ $found -eq 1 ]] || printf '  (aucun média amovible détecté)\n' >&2
  printf '\n' >&2
}

normalize_disk() {
  [[ -n "$DISK" ]] || { list_candidates
                        die "précise la carte SD avec --disk /dev/diskN"; }
  [[ "$DISK" == /dev/* ]] || DISK="/dev/$DISK"
  RDISK="${DISK/\/dev\/disk//dev/rdisk}"
}

confirm_disk() {
  local info
  info="$(diskutil info "$DISK" 2>/dev/null)" || die "disque introuvable : $DISK"

  if ! is_removable "$DISK" && [[ $FORCE -eq 0 ]]; then
    die "$DISK n'est pas un média amovible (disque fixe) — refus. (--force à tes risques)"
  fi
  if grep -qE 'Whole:[[:space:]]+No' <<<"$info"; then
    die "$DISK est une partition. Donne le disque entier : /dev/diskN, sans le sX."
  fi

  printf '\n  %sCible :%s %s\n  Lecteur: %s (%s)\n  Taille : %s\n  Contenu actuel :\n' \
    "$c_b" "$c_0" "$DISK" \
    "$(disk_field "$info" 'Device \/ Media Name')" \
    "$(disk_field "$info" 'Protocol')" \
    "$(disk_field "$info" 'Disk Size')" >&2
  diskutil list "$DISK" | sed -n '3,$p' | sed 's/^/    /' >&2
  printf '\n' >&2
  warn "TOUT le contenu de ce disque sera DÉTRUIT."

  if [[ $ASSUME_YES -eq 0 ]]; then
    local answer
    read -r -p "Tape le nom du disque pour confirmer ($(basename "$DISK")) : " answer </dev/tty
    [[ "$answer" == "$(basename "$DISK")" ]] || die "annulé."
  fi
}

# ---------------------------------------------------------- 3. la gravure

write_image() {
  log "Démontage de ${DISK}…"
  diskutil unmountDisk "$DISK" || die "impossible de démonter $DISK"

  log "Écriture de l'image (plusieurs minutes)…"
  # xz -v affiche sa progression ; dd écrit sur le device brut (rdisk = bien plus rapide)
  xz -dcv "$IMG_XZ" | sudo dd of="$RDISK" bs=4m || die "échec de l'écriture"

  sync
  log "Image écrite."
}

# ------------------------------------------- 4. config du premier démarrage

mount_bootfs() {
  log "Montage de la partition de boot…"
  diskutil mountDisk "$DISK" >/dev/null 2>&1 || true

  BOOT=""
  local _attempt
  for _attempt in $(seq 1 20); do
    for candidate in /Volumes/bootfs /Volumes/boot; do
      [[ -f "$candidate/config.txt" ]] && { BOOT="$candidate"; break 2; }
    done
    diskutil mount "$(basename "$DISK")s1" >/dev/null 2>&1 || true
    sleep 1
  done
  [[ -n "$BOOT" ]] || die "partition de boot non montée — éjecte/réinsère la carte, puis relance avec --config-only"
  log "Partition de boot : $BOOT"
}

make_password() {
  GENERATED=0
  if [[ -z "$PI_PASSWORD" ]]; then
    # cut (et non head -c) : head ferme le tube tôt -> SIGPIPE -> pipefail tue le script
    PI_PASSWORD="$(openssl rand -base64 24 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-14)"
    GENERATED=1
  fi
  PWHASH="$(openssl passwd -6 "$PI_PASSWORD")"
}

# Guillemets et antislashs doivent survivre à l'insertion dans les chaînes YAML/TOML.
esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }

# SSID courant. `networksetup -getairportnetwork` répond « You are not associated
# with an AirPort network » sur macOS 15+ même connecté ; `ipconfig getsummary`,
# lui, donne toujours le SSID.
mac_wifi_ssid() {
  local dev
  dev="$(networksetup -listallhardwareports 2>/dev/null \
         | awk '/^Hardware Port: Wi-Fi$/ {getline; print $2; exit}')"
  [[ -n "$dev" ]] || return 1
  ipconfig getsummary "$dev" 2>/dev/null \
    | awk -F' SSID : ' '/ SSID : / {print $2; exit}'
}

# Le secret reste chez macOS : on le redemande au trousseau à chaque gravure plutôt
# que de le garder ici. Trois formes d'item selon la version et la façon dont le
# réseau a été rejoint ; la dernière vise le trousseau système, où atterrissent les
# réseaux partagés par tous les comptes. Un dialogue d'autorisation peut s'ouvrir.
keychain_wifi_pass() {
  local ssid="$1"
  security find-generic-password -w -D 'AirPort network password' -a "$ssid" 2>/dev/null \
    || security find-generic-password -w -a "$ssid" 2>/dev/null \
    || security find-generic-password -w -a "$ssid" /Library/Keychains/System.keychain 2>/dev/null
}

ask_wifi_pass() {
  local a b
  [[ -t 0 ]] || die "mot de passe Wi-Fi inconnu et pas de terminal : passe --wifi-pass"
  while :; do
    read -rsp "Mot de passe Wi-Fi de « $WIFI_SSID » : " a; printf '\n' >&2
    read -rsp "Confirme                            : " b; printf '\n' >&2
    if [[ -n "$a" && "$a" == "$b" ]]; then printf '%s' "$a"; return 0; fi
    warn "vide ou non concordant — on recommence"
  done
}

# Appelé avant toute opération longue : mieux vaut buter sur le Wi-Fi tout de suite
# que trois minutes de gravure plus tard.
resolve_wifi() {
  if [[ $NO_WIFI -eq 1 ]]; then
    WIFI_SSID=""; WIFI_PASS=""
    warn "Carte sans Wi-Fi : le Pi ne joindra le réseau que par Ethernet."
    return 0
  fi

  if [[ -z "$WIFI_SSID" ]]; then
    WIFI_SSID="$(mac_wifi_ssid || true)"
    [[ -n "$WIFI_SSID" ]] \
      || die "réseau Wi-Fi courant introuvable (Mac en Ethernet ?) : --wifi-ssid, ou --no-wifi"
    log "Wi-Fi courant de ce Mac : $WIFI_SSID"
  fi

  if [[ -z "$WIFI_PASS" ]]; then
    log "Mot de passe dans le trousseau (macOS peut demander ton autorisation)…"
    WIFI_PASS="$(keychain_wifi_pass "$WIFI_SSID" || true)"
    if [[ -n "$WIFI_PASS" ]]; then
      log "Trouvé dans le trousseau."
    else
      warn "absent du trousseau, ou autorisation refusée."
      WIFI_PASS="$(ask_wifi_pass)"
    fi
  fi
}

# Images Trixie et suivantes : cloud-init (NoCloud, dsmode local)
write_cloud_init() {
  log "Configuration via cloud-init (user-data + network-config)…"
  [[ -f "$BOOT/user-data.orig"      ]] || cp "$BOOT/user-data"      "$BOOT/user-data.orig"      2>/dev/null || true
  [[ -f "$BOOT/network-config.orig" ]] || cp "$BOOT/network-config" "$BOOT/network-config.orig" 2>/dev/null || true

  cat > "$BOOT/user-data" <<EOF
#cloud-config
# Généré par pi4-sdcard.sh — appliqué au premier démarrage par cloud-init.

hostname: $PI_HOSTNAME
manage_etc_hosts: true
timezone: $TIMEZONE

keyboard:
  model: pc105
  layout: $KEYMAP

users:
  - name: $PI_USER
    groups: users,adm,dialout,audio,netdev,video,plugdev,cdrom,games,input,gpio,spi,i2c,render,sudo
    shell: /bin/bash
    lock_passwd: false
    passwd: "$PWHASH"
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - "$PUBKEY"

# SSH : activé, par clé uniquement (pas de mot de passe sur le réseau)
enable_ssh: true
ssh_pwauth: false
EOF

  local wifis=""
  [[ -n "$WIFI_SSID" ]] && wifis="
  wifis:
    renderer: NetworkManager
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: \"$WLAN_COUNTRY\"
      access-points:
        \"$(esc "$WIFI_SSID")\":
          password: \"$(esc "$WIFI_PASS")\""

  cat > "$BOOT/network-config" <<EOF
# Généré par pi4-sdcard.sh — netplan v2, rendu par NetworkManager.
network:
  version: 2

  ethernets:
    eth0:
      dhcp4: true
      optional: true
$wifis
EOF
}

# Images Bookworm plus anciennes : custom.toml
write_custom_toml() {
  warn "Image sans cloud-init : repli sur custom.toml (schéma Bookworm)."
  local WLAN_TOML=""
  [[ -n "$WIFI_SSID" ]] && WLAN_TOML="[wlan]
ssid = \"$(esc "$WIFI_SSID")\"
password = \"$(esc "$WIFI_PASS")\"
password_encrypted = false
hidden = false
country = \"$WLAN_COUNTRY\"
"
  cat > "$BOOT/custom.toml" <<EOF
# Généré par pi4-sdcard.sh
config_version = 1

[system]
hostname = "$PI_HOSTNAME"

[user]
name = "$PI_USER"
password = "$PWHASH"
password_encrypted = true

[ssh]
enabled = true
password_authentication = false
authorized_keys = [ "$PUBKEY" ]

$WLAN_TOML
[locale]
keymap = "$KEYMAP"
timezone = "$TIMEZONE"
EOF
}

write_config() {
  make_password

  if [[ -f "$BOOT/user-data" ]]; then
    write_cloud_init
  else
    write_custom_toml
  fi

  # Filet de sécurité : sshswitch active sshd si ce fichier est présent
  touch "$BOOT/ssh"

  sync
  log "Éjection…"
  diskutil eject "$DISK" >/dev/null 2>&1 || warn "éjection impossible — démonte la carte à la main"

  cat >&2 <<EOF

${c_g}${c_b}Carte prête.${c_0}

  Hôte         : $PI_HOSTNAME  (mDNS : $PI_HOSTNAME.local)
  Compte       : $PI_USER
  Mot de passe : $PI_PASSWORD$( [[ $GENERATED -eq 1 ]] && printf '   %s(généré — note-le, il ne sera pas réaffiché)%s' "$c_y" "$c_0" )
  Wi-Fi        : ${WIFI_SSID:-aucun (--no-wifi), Ethernet seulement}$( [[ -n "$WIFI_SSID" ]] && printf '   (domaine réglementaire %s)' "$WLAN_COUNTRY" )
  Clé SSH      : $SSH_PUBKEY

Insère la carte dans le Pi 4 et alimente-le. Le premier démarrage prend 1 à 3
minutes (redimensionnement du système de fichiers + cloud-init), puis :

  ssh $PI_USER@$PI_HOSTNAME.local

Si le nom .local ne répond pas, cherche l'IP sur ton routeur, ou :
  ping -c1 ${PI_HOSTNAME}.local ; arp -a | grep -iE 'b8:27:eb|dc:a6:32|e4:5f:01|2c:cf:67'

EOF
}

# ------------------------------------------------------------------- main

if [[ $LIST_ONLY -eq 1 ]]; then
  list_candidates
  exit 0
elif [[ $CONFIG_ONLY -eq 1 ]]; then
  resolve_wifi
  normalize_disk
  mount_bootfs
  write_config
else
  resolve_wifi
  download_image
  normalize_disk
  confirm_disk
  sudo -v || die "sudo requis pour écrire sur la carte"
  write_image
  mount_bootfs
  write_config
fi
