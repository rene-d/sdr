# RTL-SDR Blog V3

Expérimentations autour d'un dongle RTL-SDR Blog V3 (RTL2832U + tuner R820T2),
sur MacBook Pro Apple Silicon, le dongle branché sur le Mac ou déporté sur un
Raspberry Pi 4.

```fish
brew install librtlsdr ffmpeg      # socle commun
rtl_test -t                        # doit voir « Rafael Micro R820T »
```

La liste complète est plus bas, en [Dépendances](#dépendances).

**Le dongle est mono-process : une seule bande à la fois.** Chaque script tue les
captures restées en vie avant de démarrer, sans quoi l'écoute est muette et sans
message d'erreur.

| Expérimentation | Bande | Contenu |
|---|---|---|
| [`fm/`](fm/) | 88–108 MHz | radio FM, RDS, balayage de bande — **et la mise en route du dongle** |
| [`vhf/`](vhf/) | 156–162 MHz | VHF marine, canaux ITU, NBFM |
| [`ais/`](ais/) | 161,975 / 162,025 MHz | positions des navires, diffusion UDP |
| [`adsb/`](adsb/) | 1090 MHz | transpondeurs d'avions, carte et scope radar |
| [`pi4/`](pi4/) | — | le Pi qui porte le dongle à distance |
| [`ext/`](ext/) | — | sources tierces en sous-modules |

## `fm/` — radio FM et RDS

Le point d'entrée : installation, **recette de validation USB** du dongle, pièges
généraux (AGC caché derrière `-g 0`, `ffplay` muet sur macOS, `rtl_fm` fantôme)
et mode **dongle à distance** (`SDR_HOST`), tous valables pour les autres bandes.

```fish
./fm.sh 101.2                  # écouter, avec le nom RDS de la station
./fmscan.py                    # analyseur de spectre TUI, 88-108 MHz
./rdsscan.sh -s                # balayer puis identifier chaque station en RDS
./mpx.py 99.8                  # vraie station ou artefact ? mesure du MPX
```

Le décodage RDS demande `redsea`, à compiler (recette dans le README).

## `vhf/` — VHF marine

Canaux 1–28 et 60–88 en NBFM, table ITU intégrée, duplex côté navire ou côté
station côtière. Antenne : brin vertical de 47–48 cm.

```fish
./vhf.sh 16                    # détresse et appel
./vhf.sh 77 -m -g 15           # mètre de niveau, pour tester un émetteur
```

Pièges propres à la NBFM : `-r` ne sait que décimer, squelch non monotone,
saturation du R820T sur un émetteur proche.

## `ais/` — positions des navires

[AIS-catcher](https://github.com/jvde-github/AIS-catcher) sur les canaux 87B/88B,
même antenne que la VHF, sortie NMEA en UDP vers une carte temps réel.

```fish
./ais.sh                       # décode et diffuse sur 127.0.0.1:10110
just build                     # compile AIS-catcher depuis ext/
```

## `adsb/` — avions

`dump1090-fa` sur 1090 MHz, en table, en carte Leaflet ou en scope polaire dans le
terminal. Antenne critique : dipôle **vertical**, brins de 6,5–6,9 cm.

```fish
./adsb.sh -R                   # décodeur + scope radar
./adsb.sh -w -o                # carte web, traces et cercles de portée
./adsb-pi.sh -o                # même carte, alimentée par le dump1090 du Pi 4
./autoposition.py journal.jsonl  # retrouve la position du récepteur
```

## `pi4/` — le dongle déporté

Gravure de la carte microSD depuis le Mac, puis installation de la pile RTL-SDR
sur le Pi : blacklistage du pilote DVB-T, règles udev, compilation d'AIS-catcher.

```sh
./pi4-sdcard.sh --disk /dev/disk6      # sur le Mac
./setup-sdr.sh --all                   # sur le Pi
```

Les scripts FM acceptent ensuite `set -Ux SDR_HOST pi@pi4-sdr.local` : seule la
sortie du démodulateur traverse le réseau, jamais l'IQ.

## `ext/` — sources tierces

Les deux décodeurs qui ne sont pas dans Homebrew, en sous-modules :
[redsea](https://github.com/windytan/redsea) (RDS) et
[AIS-catcher](https://github.com/jvde-github/AIS-catcher) (AIS).

```fish
git submodule update --init --recursive
cd ext && just                 # compile les deux
just redsea                    # ou un seul, par son nom de sous-module
```

Les recettes de compilation sont regroupées dans [`ext/Justfile`](ext/Justfile).
Celles de `fm/` et `ais/` n'en sont que des raccourcis.

## Dépendances

### macOS — Homebrew

```fish
brew install librtlsdr ffmpeg              # socle : rtl_test, rtl_fm, rtl_power, lecture audio
brew install dump1090-fa                   # adsb/
brew install just                          # les recettes de compilation de ext/
brew install meson libsndfile liquid-dsp   # compiler redsea (fm/)
brew install cmake ninja libusb            # compiler AIS-catcher (ais/)
brew install zeromq                        # facultatif : sortie ZeroMQ d'AIS-catcher
```

`ninja` arrive de toute façon avec `meson`. Rien à installer pour `vhf/`, qui
n'utilise que le socle. Les scripts Python tiennent dans la bibliothèque
standard, sauf `fm/mpx.py` et `adsb/autoposition.py` :

```fish
pip install numpy
```

Interfaces graphiques, si tu veux explorer le spectre à la souris plutôt qu'en
TUI :

```fish
brew install --cask gqrx        # complet : waterfall + démodulation + audio
brew install --cask cubicsdr    # plus simple, agréable pour explorer
```

### Raspberry Pi OS / Debian — apt

`pi4/setup-sdr.sh` fait tout ça ; la liste est ici pour le cas où tu préfères à
la main. Les noms entre parenthèses sont les groupes `--with` du script.

```sh
sudo apt install -y rtl-sdr                                    # socle
sudo apt install -y soapysdr-module-rtlsdr soapysdr-tools      # (soapy) SDR++, CubicSDR
sudo apt install -y rtl-433                                    # (433) capteurs 433 MHz
sudo apt install -y dump1090-mutability                        # (adsb)
sudo apt install -y multimon-ng direwolf                       # (digital) POCSAG, APRS
sudo apt install -y sox                                        # (audio) traitement depuis rtl_fm
sudo apt install -y gnuradio                                   # (gnuradio) ~1,5 Go
```

Pour compiler AIS-catcher sur le Pi — groupe `build` :

```sh
sudo apt install -y build-essential cmake ninja-build pkg-config \
                    librtlsdr-dev libusb-1.0-0-dev zlib1g-dev libssl-dev libzmq3-dev
```

**`librtlsdr-dev` n'est pas facultatif.** Sans lui cmake désactive silencieusement
le backend RTL-SDR : la compilation réussit, le binaire démarre, et annonce
`Found 0 device(s)` alors que `rtl_test` voit la clé. Détail dans
[`pi4/README.md`](pi4/README.md).

Et pour reconstruire `dump1090-fa` depuis les sources, ce que fait `adsb/` sur le
Pi faute de paquet Debian :

```sh
sudo apt install -y git build-essential devscripts equivs
```

## Autres projets intéressants

Pas utilisés ici, mais dans le même périmètre :

| Projet | Quoi | Pourquoi pas ici |
|---|---|---|
| [multimon-ng](https://github.com/EliasOenal/multimon-ng) | POCSAG, FLEX, APRS, DTMF, ZVEI — décodage de modes numériques à partir d'un flux audio | rien dans ce dépôt ne vise ces modes ; sur le Pi il s'installe par `apt`, sans compilation |
| [rtl-ais](https://github.com/dgiardini/rtl-ais) | AIS sur les deux canaux à la fois, directement depuis le dongle | fait double emploi avec AIS-catcher, retenu pour `ais/` — plus actif, interface web et sortie UDP |
| [SDRangel](https://github.com/f4exb/sdrangel) | station SDR complète en Qt : FM, AIS, ADS-B, APRS, DMR… en modules, plusieurs canaux démodulés en parallèle | couvre à lui seul tout ce dépôt, mais en interface graphique et en un seul bloc — ici on veut des scripts qu'on peut lire, enchaîner et lancer sur le Pi sans écran |
| [Universal Radio Hacker](https://github.com/jopohl/urh) | rétro-ingénierie de protocoles inconnus : capture, démodulation, découpage des trames, fuzzing | les modes visés ici sont tous documentés et déjà décodés par un outil dédié ; URH sert quand on ne sait pas encore ce qu'on écoute |
| [SDR++](https://github.com/AlexandreRouma/SDRPlusPlus) | récepteur graphique moderne, multiplateforme, waterfall fluide et sortie audio propre | commode pour explorer une bande à l'oreille — il passe par SoapySDR, déjà listé en [Dépendances](#dépendances) — mais ne s'automatise pas, là où `fmscan.py` et `rdsscan.sh` rendent un résultat exploitable en ligne de commande |
| [Gqrx](https://github.com/gqrx-sdr/gqrx) | le même rôle, bâti sur GNU Radio, avec une télécommande réseau | même raison ; proposé en cask dans les [Dépendances](#dépendances), aucun script ne l'appelle, et la pile GNU Radio est lourde sur le Pi pour ce qu'on en ferait |

multimon-ng et rtl-ais ont été des sous-modules de `ext/`, retirés une fois
constaté qu'aucun script ne les appelait. `git submodule add` si tu veux les
reprendre. Les quatre derniers sont des applications à part entière : ils
s'installent de leur côté, sans rien à reprendre ici.

## Précautions

**Ne jamais activer le bias-tee** (`rtl_biast -b 1`) sans LNA alimenté au bout :
beaucoup d'antennes passives sont un court-circuit DC. Le connecteur SMA à nu est
sensible à l'ESD.
