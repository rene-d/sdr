# RTL-SDR V3 sur macOS

Notes de mise en route et outils, pour un RTL-SDR Blog V3 (RTL2832U + tuner R820T)
sur macOS Apple Silicon. Le dongle peut aussi être branché sur un Raspberry Pi 4
du réseau : voir *Dongle à distance*, les scripts marchent des deux façons.

## Installation

```fish
brew install librtlsdr        # rtl_test, rtl_sdr, rtl_fm, rtl_power, rtl_eeprom…
```

Aucun driver ni kext à installer : sur macOS libusb parle directement au dongle,
il n'y a pas d'équivalent du `dvb_usb_rtl28xxu` à blacklister comme sous Linux.

## Recette de validation

À rejouer après tout changement de câble, de hub ou de port.

| # | Commande | Attendu | Mesuré |
|---|----------|---------|----------------------|
| 1 | `ioreg -p IOUSB -w0 -l \| grep -i "USB Product Name"` | `RTL2838UHIDIR` | ✅ `0x0bda:0x2838` |
| 2 | `rtl_test -t` | `Found Rafael Micro R820T tuner` | ✅ 29 crans, 0 → 49,6 dB |
| 3 | `rtl_eeprom` | EEPROM lisible | ✅ SN `00000001` |
| 4 | `rtl_test` | `Samples per million lost: 0` | ✅ 0 sur 20 s |
| 5 | `rtl_test -s 2400000` | `0` à 2,4 MS/s | ✅ 0 sur 20 s |
| 6 | capture IQ à gains croissants | bruit monotone croissant | ✅ −47,6 → −41,3 dBFS |

Le test 5 est le plus important : c'est lui qui attrape les câbles médiocres, les
hubs saturés et les ports sous-alimentés. Tout ce qui n'est pas `0` est un problème
d'USB, pas de radio.

Test 6, chemin RF sans antenne — le plancher de bruit doit monter avec le gain :

```fish
rtl_sdr -f 100000000 -s 2048000 -g 25.4 -n 3000000 /tmp/iq.bin
```

| Gain | RMS I/Q | dBFS |
|------|---------|------|
| 0,9 dB | 0,53 | −47,6 |
| 25,4 dB | 0,57 | −46,9 |
| 49,6 dB | 1,09 | −41,3 |

DC offset mesuré à 127,37 pour I comme pour Q (nominal 127,5) : branches équilibrées.

## Pièges rencontrés

**`-g 0` n'est pas 0 dB.** Dans `rtl_sdr`, la valeur `0` active l'**AGC**, ce qui a
donné un RMS de 3,53 au lieu de 0,53 et un test de gain incohérent. Le plus petit
gain manuel réel est `-g 0.9`.

**Transitoire de démarrage.** Les ~0,5 premières secondes d'une capture sont à jeter
avant toute mesure.

**`ffplay` est muet sur cette machine.** Il est lié à `sdl2-compat`, un shim
SDL2 → SDL3 : aucun vrai `sdl2` n'est installé, seulement `sdl2-compat` et `sdl3`.
L'initialisation SDL réussit (`SDL_AUDIODRIVER=coreaudio` est accepté, un nom bidon
échoue bien), `ffplay` décode et vide sa file d'attente normalement — l'horloge
avance, `aq=` décroît — mais rien ne sort des haut-parleurs. La panne est silencieuse
et imite parfaitement une lecture saine.

Contournement : `ffmpeg` avec la sortie **`audiotoolbox`**, qui n'utilise pas SDL.

```fish
ffmpeg -hide_banner -loglevel warning -re -i test.wav -f audiotoolbox -
```

Pour fabriquer un `test.wav` de contrôle depuis la radio :

```fish
rtl_fm -f 101.2M -M wbfm -s 200000 -r 48000 -g 40 - 2>/dev/null | head -c 960000 \
  | ffmpeg -y -f s16le -ar 48000 -ch_layout mono -i - test.wav
afplay test.wav        # chemin audio macOS connu-bon, indépendant de ffmpeg
```

Réparer `ffplay` imposerait de recompiler ffmpeg contre le vrai `sdl2`, en conflit
avec `sdl2-compat` dans Homebrew — inutile puisque AudioToolbox fait le travail.

Corollaire de méthode : **`rc=0` et une horloge qui avance ne prouvent pas qu'un son
est audible.** Seuls `afplay` sur un extrait WAV, ou l'oreille, tranchent.

**`ffplay -ac 1` échoue** avec ffmpeg ≥ 9 : `Option not found`. `ffplay` n'a pas de
`-ac` natif, il transmettait l'option au démuxeur `rawaudio`, qui n'expose plus que
`sample_rate` et `ch_layout`. Utiliser **`-ch_layout mono`**. Le binaire `ffmpeg`,
lui, accepte toujours `-ac 1` (option native de son CLI).

**Un `rtl_fm` fantôme rend muet sans erreur.** Le dongle est mono-process : si une
capture précédente tourne encore, le nouveau `rtl_fm` ne reçoit rien, mais `ffplay`
démarre quand même et affiche sa ligne d'état — on « voit » un lecteur actif et on
n'entend rien. Réflexe avant toute écoute :

```fish
pgrep -fl "rtl_|ffplay"; and pkill -f "rtl_|ffplay"
```

Dans `ffplay`, le symptôme est une horloge bloquée à `nan` ou figée. Une lecture
saine fait avancer le compteur (`5.48 M-A: 0.000`).

**Vérifier qu'il y a réellement du son**, plutôt que se fier au lecteur — RMS attendu
bien au-dessus de 1000 sur une station forte (mesuré : 4355, soit −17,5 dBFS sur
101.2 MHz) :

```fish
rtl_fm -f 101.2M -M wbfm -s 200000 -r 48000 -g 40 - 2>/dev/null | head -c 500000 > /tmp/a.raw
python3 -c "import numpy as np; x=np.frombuffer(open('/tmp/a.raw','rb').read(),dtype='<i2').astype(float); print('RMS', round(np.sqrt((x**2).mean())))"
```

Un programme réel a aussi une pente spectrale marquée (graves > voix > aigus) ; un
spectre plat signale du souffle, donc une station absente ou mal accordée.

**`Output at 200000 Hz` de `rtl_fm` ne désigne pas la sortie.** Avec
`-s 200000 -r 48000`, `rtl_fm` affiche `Output at 200000 Hz` alors qu'il écrit bien
du 48 kHz : le message rapporte `rate_out` (l'étage de démodulation), pas `rate_out2`
(le rééchantillonnage final). Ne pas s'y fier pour régler le lecteur — vérifier au
débit réel : `timeout 10 rtl_fm … - | wc -c`, puis octets / 2 / durée.

**`[R82XX] PLL not locked!`** est bénin : `rtl_test -t` sonde une fréquence hors
plage en cherchant un tuner E4000 absent.

**`rtl_fm` n'accorde pas la fréquence demandée** (`Tuned to 100916000 Hz` pour
100,6 MHz) : décalage volontaire pour écarter le signal du spur DC, recentré ensuite
en numérique.

## Dongle à distance (Pi 4)

Le dongle peut être branché sur un Raspberry Pi 4 ([`../pi4`](../pi4/)) plutôt
que sur le Mac — antenne loin du bruit RF du portable, écoute depuis n'importe où
dans la maison. Tous les scripts d'ici l'acceptent :

```fish
set -Ux SDR_HOST pi@pi4-sdr.local     # une fois pour toutes (variable fish universelle)
./fm.sh 101.2                         # ... et tout le reste suit
./mpx.py -H pi@pi4-sdr.local 101.2    # ponctuellement, sans la variable
```

`SDR_HOST` vide = dongle sur cette machine, comportement d'origine inchangé.
`sdr.sh` (pour les scripts shell) et `sdrhost.py` (pour les scripts Python)
portent tout l'aiguillage ; les scripts eux-mêmes ne connaissent qu'une fonction.

**Ce qui traverse le réseau, c'est la sortie du démodulateur, pas l'IQ.**
`rtl_fm` et `rtl_power` tournent sur le Pi, leur stdout revient par ssh :

| Usage | Flux | Débit |
|---|---|---|
| `fm.sh` — audio 48 kHz mono | `rtl_fm -M wbfm -r 48000` | 96 ko/s |
| `mpx.py`, `rdsscan.sh` — MPX 171 kHz | `rtl_fm -M fm -s 171k` | 342 ko/s |
| `fmscan.py` — spectre | CSV de `rtl_power` | quelques ko/s |
| *(non retenu)* IQ brut via `rtl_tcp` | 2,4 MS/s I+Q | **4,8 Mo/s** |

Mesuré 293 ko/s soutenus en Wi-Fi sur le MPX, sans perte — les trois premières
lignes passent très largement. `rtl_tcp` reste utile pour Gqrx ou SDR++, qui
savent le lire ; `rtl_fm` non, et il n'y a aucune raison d'envoyer l'IQ pour
finir par écouter du 48 kHz mono.

### Pièges spécifiques au distant

**ssh ne tue pas la commande distante.** Tuer le `ssh` local (Ctrl-C, timeout,
Wi-Fi qui tombe) laisse `rtl_fm` tourner sur le Pi — vérifié, il survit
indéfiniment, la fermeture du canal ne lui fait rien. Il garde le dongle et
l'écoute suivante est muette sans message : c'est le piège du « rtl_fm fantôme »
en pire, puisque rien ne le trahit sur la machine où on tape. D'où, dans
`sdr.sh` : un contrôle du dongle distant avant chaque capture, et un `pkill`
distant dans le `trap` de `fm.sh` comme dans le `stop()` de `fmscan.py`.

**`pgrep -f rtl_` se trouve lui-même.** Par ssh, le motif figure dans la ligne de
commande du shell distant : `pgrep` se compte lui-même, et `pkill -f` se tue
avant d'avoir tué quoi que ce soit. La parade est `pgrep -x` sur les noms exacts,
motif `rtl_(fm|power|sdr|tcp|test|adsb|biast)` — `-x` accepte une ERE aussi bien
côté macOS que côté Debian.

**`timeout` va du côté du dongle.** `ssh pi 'timeout 25 rtl_fm …'` plutôt que
`timeout 25 ssh pi 'rtl_fm …'` : la capture se termine d'elle-même même si la
liaison meurt. C'est ce que font `mpx.py` et `rdsscan.sh`.

**Multiplexage ssh.** `rdsscan.sh` ou `mpx.py` ouvrent une connexion par station.
Avec `ControlMaster=auto` + `ControlPersist=60`, la première coûte 350 ms et les
suivantes 40 ms. Réglé dans `sdr.sh` / `sdrhost.py`, surchargeable par
`SDR_SSH_OPTS`.

**Le gain de 40 dB sature sur le Pi.** Avec l'antenne du Pi, `mpx.py` voyait un
pilote 19 kHz sur 87,6 MHz, où il n'y a rien : le tuner sature et fabrique des
porteuses partout. À 20 dB, le verdict redevient juste.

| Fréquence | gain 40 | gain 20 |
|---|---|---|
| 87,6 MHz (vide) | pilote **+20,7 dB** — faux | pilote −1,6 dB — artefact ✅ |
| 101,2 MHz (station forte) | pilote +15,8 dB | pilote +19,0 dB ✅ |

D'où `./mpx.py -g 20`, `GAIN=25 ./rdsscan.sh`, `./fm.sh -g 25` quand le dongle
est sur le Pi. Un relevé complet de la bande depuis le Pi reste à faire.

**redsea tourne là où il est.** `sdr.sh` le cherche d'abord sur la machine du
dongle (`$SDR_REDSEA`, défaut : `redsea` dans le PATH) — seul le JSON traverse
alors le réseau — puis ici (`$REDSEA`). S'il manque des deux côtés, `fm.sh` saute
son bandeau RDS et `rdsscan.sh` refuse de démarrer en le disant. Aujourd'hui il
n'est compilé qu'ici : avec le dongle sur le Pi, c'est donc le MPX qui traverse.
La recette est plus bas.

## Scanner la bande

Le RTL2832U ne numérise que **2,4 MHz** à la fois : un GUI ne peut jamais afficher
les 20 MHz de la bande FM d'un coup. Scanner et écouter sont deux outils distincts.

| | Couverture | Temps réel | Audio |
|---|---|---|---|
| GUI (Gqrx, CubicSDR) | 2,4 MHz | oui | oui |
| Balayage (`rtl_power`, `fmscan.py`) | toute la bande | non | non |

### `fmscan.py` — analyseur de spectre TUI

Pilote `rtl_power`, affiche spectre + cascade en 256 couleurs et liste les canaux
détectés, alignés sur la grille 100 kHz.

```fish
./fmscan.py                      # TUI temps réel, 88-108 MHz
./fmscan.py --once               # un balayage, sortie texte, scriptable
./fmscan.py -f 118M:137M -b 5k   # bande aéro, pas de 5 kHz
./fmscan.py -g 49.6 -t 10        # gain max, seuil de détection 10 dB
./fmscan.py -H pi@pi4-sdr.local  # dongle sur le Pi (ou $SDR_HOST)
```

Touches : `q` quitter, `w` cascade, `p` liste des pics. `--help` pour tout le reste.

Trois réglages non évidents, tous par défaut dans le script :
`-r 25` impose une plage verticale minimale (sans quoi un spectre plat s'auto-étire
sur 4 dB et sature l'écran) ; le plancher est pris au premier quartile et non au
minimum ; `-c 20%` recadre les bords de tranche, sinon `rtl_power` laisse des creux
aux jonctions entre pas de balayage.

### GUI

```fish
brew install --cask gqrx        # complet : waterfall + démodulation + audio
brew install --cask cubicsdr    # plus simple, agréable pour explorer
```

Device `rtl=0`, sample rate 2,4 MS/s. Si macOS bloque l'app :
`xattr -dr com.apple.quarantine /Applications/Gqrx.app`.

### `fm.sh` — écouter une station

```fish
./fm.sh 93.0            # écoute 93,0 MHz
./fm.sh 101.2 -g 25     # gain réduit si le son sature
./fm.sh 89.4 -q         # sans le bandeau RDS
./fm.sh -H pi@pi4-sdr.local 101.2   # dongle sur le Pi (ou $SDR_HOST)
```

Le script annonce le nom RDS de la station avant de lancer l'audio (une passe de
10 s : le dongle ne peut pas décoder le RDS et sortir du son en même temps), puis
écoute jusqu'à `Ctrl-C`. `-q` saute cette étape et démarre tout de suite.

Il tue au passage tout `rtl_fm`/`rtl_power` resté en vie, sans quoi la lecture serait
muette sans message d'erreur (voir *Pièges*).

La commande sous-jacente :

```fish
rtl_fm -f 101.2M -M wbfm -s 200000 -r 48000 -g 40 - | ffmpeg -hide_banner -loglevel warning -probesize 32 -fflags nobuffer -flags low_delay -f s16le -ar 48000 -ch_layout mono -i - -f audiotoolbox -
```

`ffmpeg` avec la sortie **`audiotoolbox`** (audio natif macOS), et non `ffplay`, qui
ne produit aucun son sur cette machine (voir *Pièges*). Sans `-probesize`/`-fflags`,
il bufferise près d'une seconde. `-ch_layout mono` plutôt que `-ac 1` : les deux
marchent côté `ffmpeg`, mais le premier évite l'avertissement `Guessed Channel
Layout` à chaque lancement.

Si le son sature, descendre `-g` vers 25–30 sur les stations les plus fortes.

## Décoder le RDS

`redsea` donne le nom de station (PS), le code PI, le type de programme et le
radiotexte. Il n'est **pas dans Homebrew**, il faut le compiler. Les sources sont
en sous-module dans [`../ext/redsea`](../ext/redsea/), et le `Justfile` d'ici tient
la recette :

```fish
brew install meson libsndfile liquid-dsp
just build                    # -> ../ext/redsea/build/redsea
```

ce qui revient à :

```fish
cd ../ext/redsea
env CPPFLAGS=-I/opt/homebrew/include CXXFLAGS=-I/opt/homebrew/include \
    LDFLAGS=-L/opt/homebrew/lib meson setup build
meson compile -C build
```

Les trois variables sont **indispensables** sur Apple Silicon : `meson` détecte bien
la bibliothèque `liquid` via `brew`, mais ne transmet pas `/opt/homebrew/include` au
compilateur, et la compilation échoue sur `fatal error: 'liquid/liquid.h' file not
found`. L'erreur survient à `meson compile`, pas à `meson setup`, ce qui la rend
trompeuse.

Écoute RDS d'une station, en direct :

```fish
rtl_fm -M fm -l 0 -A std -p 0 -s 171k -g 40 -F 9 -f 101.2M - | ./build/redsea --input mpx -r 171k
```

Le débit MPX doit être **171 kHz** de part et d'autre : c'est le taux natif de
`redsea`, et il faut la bande complète (jusqu'à 57 kHz) — d'où `-M fm` et non
`-M wbfm`, qui ne sortirait que l'audio.

Sortie : une ligne JSON par groupe. Pour enchaîner plusieurs stations, `rdsscan.sh`
fait le tour et résume PS / PI / PTY :

```fish
./rdsscan.sh 89.4 93.0 101.2 107.6
./rdsscan.sh -s                    # balayage de la bande, puis le tour des stations
DUR=120 ./rdsscan.sh 96.3          # dwell long, pour un PS récalcitrant
GAIN=25 ./rdsscan.sh 101.2         # gain réduit si le tuner sature
```

`-s` délègue le repérage des porteuses à `fmscan.py --once` et enchaîne sur les
fréquences trouvées, remises dans l'ordre de la bande ; les fréquences données à la
main s'y ajoutent. Deux variables le règlent :

| | Défaut | Rôle |
|---|---|---|
| `BAND` | `88M:108M` | bande balayée, syntaxe de `fmscan.py -f` |
| `THRESH` | `12` | seuil de détection, en dB au-dessus du plancher |

Le seuil par défaut de `fmscan.py` (6 dB) est trop bas ici : sur un balayage court il
remonte une cinquantaine de pics, dont les épaules des porteuses fortes et des
produits d'intermodulation, et chacun coûte un `DUR` complet. 12 dB donne une
trentaine de canaux sur la bande entière — soit un bon quart d'heure à `DUR=25`.

Le balayage est demandé avec `-n 200` : `fmscan.py` n'affiche que les 12 canaux les
plus forts par défaut, et le tour serait tronqué sans le dire.

Il attend `redsea` en `../ext/redsea/build/redsea` ; sinon lui indiquer le chemin par
`REDSEA=…`. C'est aussi ce que cherche `fm.sh` pour son bandeau RDS.

### Vérifier qu'une station est réelle

Le balayage seul confond station, image et intermodulation. La mesure des
sous-porteuses du MPX tranche — audio 0,3–10 kHz, pilote 19 kHz, RDS 57 kHz :

```fish
rtl_fm -M fm -l 0 -A std -s 171k -g 40 -F 9 -f 95.2M - | head -c 400000 > mpx.raw
```

puis FFT sur les échantillons `<i2`, en jetant le premier quart (transitoire
d'accord). Un pilote 19 kHz franc = vraie station stéréo, ni audio ni pilote =
artefact. `mpx.py` fait la mesure et rend le verdict :

```fish
./mpx.py 101.2 99.8
./mpx.py -g 20 -H pi@pi4-sdr.local 101.2 99.8    # dongle sur le Pi, gain réduit
```
```
 101.2 MHz | audio  34.5 | pilote19k  45.1 | RDS57k  -0.4 | stéréo
  99.8 MHz | audio   2.0 | pilote19k -17.8 | RDS57k -17.2 | ARTEFACT ?
```

Les niveaux varient d'une mesure à l'autre (instantané de 6 s) : c'est le signe du
pilote qui compte, pas sa valeur exacte.

Attention, cette mesure ne vaut **que pour le pilote et l'audio** : la détection du
57 kHz par FFT sur 6 s s'est révélée non fiable (101.2 et 107.6 décodent 270 groupes
RDS tout en sortant négatives à ce test). Pour le RDS, seul `redsea` fait foi.


## Autres bandes

| | |
|---|---|
| [`../vhf`](../vhf/) | VHF marine : `vhf.sh`, table des canaux ITU, longueurs d'antenne, pièges de la NBFM |
| [`../ais`](../ais/) | AIS : `ais.sh` (AIS-catcher), décodage et diffusion NMEA en UDP |
| [`../adsb`](../adsb/) | ADS-B 1090 MHz : `adsb.sh` (dump1090-fa), scope radar `radar.py`, carte `adsbmap.py` |
| [`../pi4`](../pi4/) | le Pi qui porte le dongle à distance : carte SD, installation de la pile rtl-sdr |

Le dongle est mono-process : une seule de ces bandes à la fois.

## Précautions

**Ne jamais activer le bias-tee** (`rtl_biast -b 1`) sans LNA alimenté au bout :
beaucoup d'antennes passives sont un court-circuit DC et mettraient le régulateur
4,5 V en court-circuit. `rtl_biast -b 0` force l'état OFF.

Le connecteur SMA à nu est sensible à l'ESD : toucher une masse avant manipulation.

## À faire

- **Compiler redsea sur le Pi** (voir *Décoder le RDS*) : sans lui, le chemin RDS
  en dongle distant fait traverser tout le MPX au réseau, au lieu du seul JSON.
- **Refaire le relevé de la bande depuis le Pi**, au gain 20 : l'antenne et
  l'emplacement n'y sont pas ceux du Mac, le relevé fait ici n'y vaut pas.
- **Mesurer le vrai PPM.** `rtl_test -p` a donné −20 ppm cumulés sur 60 s, mais ce
  chiffre n'est pas exploitable : il compare l'horloge d'échantillonnage à celle de
  macOS, et sur une fenêtre courte l'erreur de mesure domine. Le TCXO du V3 est
  spécifié à 1 ppm. Désormais faisable sur un signal de fréquence connue : le pilote
  19 kHz d'une station forte (97.8 ou 93.0) sert de référence — mesurer son écart à
  19 000 Hz exact donne le PPM directement.
- **Confirmer 99.8** en pointant le balayage sur 99.6–100.0 MHz seul : si le pic
  disparaît quand les porteuses voisines sortent de la tranche numérisée, c'est bien
  de l'intermodulation.
- **Récupérer les PS manquants** (96.3, 101.7, 102.7, 103.5) avec des dwells de
  2–3 min au lieu de 25 s.
- **Sensibilité et facteur de bruit** : mesurables maintenant, référence nécessaire.
- **Direct sampling HF** (`-D 2`), la fonction phare du V3 sous 24 MHz.
- Brancher le dongle en **USB-C direct plutôt que sur le hub**, et ajouter une
  rallonge pour l'éloigner du Mac : un MacBook est une source de bruit RF large
  bande importante. Le débit passe très bien via le hub, c'est purement une question
  de bruit reçu.

## État actuel

Dongle fonctionnel et validé de bout en bout, **antenne branchée et opérationnelle**.
Chaîne complète éprouvée, du balayage au son dans les haut-parleurs.

| Script | Rôle |
|---|---|
| `fmscan.py` | analyseur de spectre TUI, balayage large bande |
| `fm.sh` | écoute d'une station FM, avec son nom RDS |
| `rdsscan.sh` | identification RDS de plusieurs stations à la suite |
| `mpx.py` | vraie station ou artefact ? mesure des sous-porteuses |
| `sdr.sh` | aiguillage local / distant pour les scripts shell |
| `sdrhost.py` | le même, pour les scripts Python |
| `Justfile` | `just build` : compile redsea depuis `../ext/redsea` |

**Dongle à distance** validé sur `pi@pi4-sdr.local` : `fm.sh` (audio),
`fmscan.py --once` (balayage) et `mpx.py` (MPX) tournent avec le dongle sur le
Pi, et le dongle est bien rendu à la fin. Le chemin RDS n'est pas vérifié
en distant — **redsea n'est compilé qu'ici**, pas encore sur le Pi ; `sdr.sh` le
détecte et rapatrie alors le MPX pour le décoder localement.

**VHF marine** ([`../vhf`](../vhf/)) validée à l'écoute sur le canal 77, avec un
émetteur local et une antenne retaillée en quart d'onde. Reste à faire : un relevé
d'activité de la bande 156–162 MHz avec cette antenne (le premier essai, mené avec
l'antenne FM, n'était pas exploitable).

**AIS** ([`../ais`](../ais/)) reçu dès le premier essai avec la même antenne.
