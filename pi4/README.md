# Carte microSD Raspberry Pi 4 — SDR

Deux scripts :

- `pi4-sdcard.sh` — **sur le Mac** : télécharge Raspberry Pi OS 64-bit, l'écrit
  sur une carte microSD et y dépose la configuration du premier démarrage
  (Wi-Fi + SSH par clé).
- `setup-sdr.sh` — **sur le Pi**, après le premier démarrage : installe la pile
  RTL-SDR, neutralise le pilote DVB-T, valide avec `rtl_test`.

## Pourquoi Raspberry Pi OS et pas Ubuntu

- Noyau et firmware maintenus par Raspberry Pi Ltd : le Pi 4 (Wi-Fi, GPU, GPIO,
  USB) marche sans réglage.
- Pile SDR packagée dans les dépôts : `rtl-sdr`, `soapysdr`, `gqrx`, `gnuradio`,
  `hackrf`, `airspy`. La plupart des tutos et des règles udev SDR visent cette
  distribution.
- Ubuntu Server arm64 démarre aussi sur Pi 4, mais empile une couche
  supplémentaire (snap, noyau générique) pour aucun gain ici.

Variante `lite` par défaut : sans bureau, c'est ce qu'il faut pour du headless
SSH. `--variant desktop` ou `--variant full` si tu veux gqrx en local sur écran.

## Usage

```sh
./pi4-sdcard.sh --list                  # repérer la carte
./pi4-sdcard.sh --disk /dev/disk6       # télécharger, graver, configurer
```

Le script affiche le contenu actuel de la carte, demande de retaper le nom du
disque avant d'écrire, et refuse les médias non amovibles.

Note : le lecteur SD intégré au Mac se déclare `Device Location: Internal` — le
lecteur est interne, pas la carte. Le critère retenu est donc
`Removable Media: Removable`, et non l'emplacement ; `diskutil list external`
ne montre pas ces cartes.

Options : `--variant lite|desktop|full`, `--config-only` (réécrit seulement la
config sur une carte déjà gravée), `--yes`, `--force`.

Réglages en tête de script, surchargeables par variable d'environnement :
`PI_HOSTNAME`, `PI_USER`, `PI_PASSWORD`, `SSH_PUBKEY`, `VARIANT`, `CACHE_DIR`.

### Wi-Fi

Rien n'est codé en dur : par défaut le Pi reprend **le réseau auquel ce Mac est
connecté**, mot de passe lu dans le trousseau. macOS ouvre alors son dialogue
d'autorisation — le secret reste chez lui, le dépôt n'en garde aucune trace.

```sh
./pi4-sdcard.sh --disk /dev/disk6                        # réseau courant du Mac
./pi4-sdcard.sh --disk /dev/disk6 --wifi-ssid Ailleurs   # autre réseau, mot de passe demandé
./pi4-sdcard.sh --disk /dev/disk6 --no-wifi              # Ethernet seulement
WIFI_SSID=… WIFI_PASS=… ./pi4-sdcard.sh --disk /dev/disk6
```

L'ordre de résolution, pour le SSID comme pour le mot de passe : `--wifi-ssid` /
`--wifi-pass`, puis `WIFI_SSID` / `WIFI_PASS`, puis le Mac (SSID) et le trousseau
(mot de passe), puis une saisie masquée au clavier. Tout se joue **avant** le
téléchargement et la gravure : on bute sur le Wi-Fi tout de suite, pas trois
minutes plus tard.

Le SSID courant vient d'`ipconfig getsummary`, pas de
`networksetup -getairportnetwork` : depuis macOS 15 ce dernier répond « You are
not associated with an AirPort network » même connecté. Le binaire `airport`,
l'autre recette classique, n'existe plus.

## Ce qui est écrit sur la partition de boot

Les images Trixie (2025+) se configurent par **cloud-init**, pas par
`custom.toml` ni `wpa_supplicant.conf` :

- `user-data` — hostname, fuseau, clavier, compte `pi` (mot de passe haché
  SHA-512), `ssh_authorized_keys` avec `~/.ssh/id_rsa.pub`, `enable_ssh: true`,
  `ssh_pwauth: false` (pas d'authentification SSH par mot de passe).
- `network-config` — netplan v2 rendu par NetworkManager : le Wi-Fi retenu en
  DHCP, domaine réglementaire FR, plus eth0 en DHCP optionnel. Avec `--no-wifi`,
  le bloc `wifis:` est simplement absent.

Les fichiers d'origine sont sauvegardés en `.orig` sur la carte.
Si l'image ne contient pas de `user-data` (Bookworm ou antérieur), le script
bascule automatiquement sur `custom.toml`.

## Après le premier démarrage

1 à 3 minutes (redimensionnement du système de fichiers + cloud-init), puis :

```sh
ssh pi@pi4-sdr.local
```

Le mot de passe du compte, généré au hasard si `PI_PASSWORD` n'est pas défini,
est affiché en fin de script — il ne sert qu'à la console locale et à `sudo`.

## RTL-SDR Blog V3 sur le Pi

Vérifié contre les paquets Debian Trixie, base de Raspberry Pi OS actuel.

`setup-sdr.sh` enchaîne tout ce qui suit. À copier sur le Pi après le premier
démarrage :

```sh
scp setup-sdr.sh pi@pi4-sdr.local:
ssh pi@pi4-sdr.local ./setup-sdr.sh            # socle rtl-sdr seul
ssh pi@pi4-sdr.local ./setup-sdr.sh --all      # + décodeurs
```

Options : `--with soapy,433,adsb,digital,audio,build,gnuradio`, `--all` (tout sauf
gnuradio), `--dry-run` (affiche les commandes sans rien exécuter), `--skip-test`.
Le script est idempotent et refuse de s'exécuter ailleurs que sur le Pi.

Le détail de ce qu'il fait, si tu préfères le faire à la main :

### Socle

```sh
sudo apt update
sudo apt install -y rtl-sdr
```

`rtl-sdr` (2.0.2-2) tire `librtlsdr0` et fournit `rtl_test`, `rtl_fm`,
`rtl_power`, `rtl_tcp`, `rtl_sdr`, `rtl_adsb`, `rtl_eeprom`, `rtl_biast`.
Rien à compiler pour une V3.

### Blacklister le pilote DVB-T — obligatoire

Le noyau charge `dvb_usb_rtl28xxu` dès le branchement et s'approprie le
périphérique. Trixie n'installe plus de blacklist : `librtlsdr0` 2.0.2-2 ne
contient que 8 fichiers, aucun sous `/etc/modprobe.d/` (retirée suite au bug
Debian #823022). À faire soi-même :

```sh
echo 'blacklist dvb_usb_rtl28xxu' | sudo tee /etc/modprobe.d/rtl-sdr-blacklist.conf
sudo modprobe -r dvb_usb_rtl28xxu     # évite un redémarrage
```

Symptôme si on l'oublie : `usb_claim_interface error -6`.

### Permissions : rien à faire

La règle udev de Trixie est `MODE="0660", GROUP="plugdev"`, et non
`TAG+="uaccess"` qui n'accorderait l'accès qu'aux sessions locales et bloquerait
en SSH. Le `user-data` généré met déjà `pi` dans `plugdev` : ça marche dès la
première connexion, sans `sudo`.

### Vérification

```sh
rtl_test -t
```

Attendu pour une V3 : `Found 1 device(s): 0: Realtek, RTL2838UHIDIR` et
`Tuner: Rafael Micro R820T2`.

### Compiler AIS-catcher : `librtlsdr-dev` est obligatoire

Le socle n'installe que `librtlsdr0`, la bibliothèque d'exécution. Elle suffit à
`rtl_test` et aux outils packagés, mais **pas** à compiler quoi que ce soit
contre elle : il n'y a ni `/usr/include/rtl-sdr.h`, ni le lien `librtlsdr.so`.

Le piège est que rien n'échoue. CMake ne trouve pas la lib, écrit
`RTLSDR_LIBRARY:FILEPATH=RTLSDR_LIBRARY-NOTFOUND`, désactive silencieusement le
backend RTL-SDR, et la compilation réussit. Le binaire obtenu démarre
normalement, affiche sa bannière — et annonce :

```
Found 0 device(s):
```

alors que `lsusb` et `rtl_test` voient parfaitement la clé. On croit à un
problème d'USB, de blacklist DVB-T ou de permissions udev ; c'est le binaire qui
ne sait tout simplement plus parler à un dongle.

```sh
./setup-sdr.sh --with build     # ou --all
```

Le diagnostic en deux commandes, avant de soupçonner le matériel :

```sh
ldd ~/AIS-catcher/build/AIS-catcher | grep rtl    # doit citer librtlsdr.so.0
grep RTLSDR_LIBRARY ~/AIS-catcher/build/CMakeCache.txt
```

Puis reconfigurer et recompiler. CMake retente normalement les entrées
`NOTFOUND` à chaque configuration, mais vider le cache coûte quelques secondes
et lève le doute :

```sh
cd ~/AIS-catcher/build && rm -rf CMakeCache.txt CMakeFiles
cmake -G Ninja .. && ninja        # ~4 min sur un Pi 4
```

Attendu à la configuration :

```
-- RTLSDR: found - /usr/include, /usr/lib/aarch64-linux-gnu/librtlsdr.so
-- RTLSDR: bias-tee support included.
```

### Spécificités V3

- HF sous 24 MHz, échantillonnage direct branche Q : `rtl_sdr -D 2 -f 7100000 …`
  Le pilote osmocom de Debian le gère.
- Bias tee pour un LNA : `sudo rtl_biast -b 1`, `-b 0` pour couper. Jamais sur
  une antenne passive reliée à la masse.
- TCXO 1 ppm : la correction `-p` est quasi inutile, contrairement aux clés
  génériques.
- La V3 se contente du pilote Debian. Seule la **V4** imposerait le fork
  `rtl-sdr-blog` — à retenir en cas de changement de clé.

### Paquets selon l'usage

| Usage | Paquet |
|---|---|
| Apps SoapySDR (SDR++, CubicSDR) | `soapysdr-module-rtlsdr` `soapysdr-tools` |
| Capteurs 433 MHz | `rtl-433` (25.02) |
| ADS-B | `dump1090-mutability` |
| Pager POCSAG, APRS | `multimon-ng`, `direwolf` |
| Traitement audio depuis `rtl_fm` | `sox` |
| Prototypage | `gnuradio` (~1,5 Go) |
| Compiler AIS-catcher | `librtlsdr-dev` `libusb-1.0-0-dev` `zlib1g-dev` `libzmq3-dev` |

En headless, le plus confortable : `rtl_tcp -a 0.0.0.0` sur le Pi, et gqrx ou
SDR++ sur le Mac. Pas de bureau à installer sur le Pi, interface fluide.

### Câblage

Brancher la clé sur un **port USB 2.0** (les noirs) : les ports USB 3 et leurs
câbles rayonnent un bruit large bande qui remonte dans la réception. Rallonge
USB courte et blindée pour éloigner le dongle du Pi — le régulateur à découpage
et le HDMI sont les deux autres sources. La V3 tire ~300 mA, sans souci avec une
alimentation officielle 15 W.

### Références

- <https://packages.debian.org/trixie/rtl-sdr>
- <https://packages.debian.org/trixie/arm64/librtlsdr0/filelist>
- <https://sources.debian.org/src/rtl-sdr/2.0.2-2/rtl-sdr.rules/>
- <https://bugs.debian.org/823022>

## Note

Le mot de passe Wi-Fi n'est plus dans le script, mais il finit **en clair dans
`network-config`** sur la partition de boot de la carte : elle est en FAT32,
lisible par quiconque l'a en main. C'est cloud-init qui l'impose, il n'y a pas
de forme chiffrée. La carte est donc à traiter comme le mot de passe lui-même.
