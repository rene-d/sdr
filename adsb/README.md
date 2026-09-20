# ADS-B avec la RTL-SDR V3

Réception des transpondeurs d'avions (**1090 MHz**, Mode S Extended Squitter) avec
[dump1090-fa](https://github.com/flightaware/dump1090), en table dans le terminal ou
sur une carte temps réel.

Mise en route du dongle et pièges généraux : [`../fm/README.md`](../fm/README.md).
Autres bandes : [`../vhf`](../vhf/), [`../ais`](../ais/).

Dépendance : `brew install dump1090-fa` pour le dongle branché sur le Mac. Rien
d'autre — la carte n'utilise que la bibliothèque standard de Python. Le dongle peut
aussi rester sur le Pi 4, voir [plus bas](#le-pi-4--dump1090-fa-en-service).

## Antenne — la seule chose qui change vraiment

**1090 MHz, polarisation verticale.** Les avions émettent par une antenne lame sous
le fuselage, brin vertical : une antenne réceptrice couchée à l'horizontale perd
20 dB et plus. Le dipôle se monte **vertical**.

λ = 27,50 cm à 1090 MHz. Un dipôle demi-onde, c'est **deux brins d'un quart d'onde** :

| | Théorique | × 0,95 (brin réel) |
|---|---|---|
| Quart d'onde = un brin | 6,88 cm | **6,5 cm** |
| Dipôle complet = les deux brins | 13,75 cm | 13,1 cm |

**Règle : chaque brin à 6,5–6,9 cm**, mesuré depuis le point d'alimentation — le
centre du dipôle, là où le brin se visse sur la base — et pas depuis le haut de la
bague. Le facteur 0,95 tient au fait qu'un conducteur réel est un peu plus lent que
le vide ; à 1090 MHz l'écart n'est que de 4 mm, donc viser 6,7 cm et ne pas se
crisper. La bande ADS-B est une fréquence unique, il n'y a aucun compromis à faire
comme en VHF marine.

**Attention au kit du V3 s'il s'agit du dipôle RTL-SDR Blog** : il contient deux
paires de brins télescopiques. Les longs (23 cm → 1 m) servent à la FM et à la VHF ;
ils **ne se rétractent pas sous 23 cm**, largement trop pour 1090 MHz. C'est la paire
courte (5 → 13 cm) qu'il faut, et c'est précisément pour l'ADS-B qu'elle est fournie.
Un brin de 23 cm n'est pas résonant à 1090 MHz et le décodage s'effondre.

Si les brins ne descendent pas à 6,9 cm, la solution de repli est un demi-onde
complet par brin, soit **2 × 13,8 cm** : le diagramme se pince vers l'horizon mais
l'antenne reste résonante. Ne pas se contenter d'une longueur quelconque.

### Deux façons de l'orienter

```
   dipôle vertical              V-dipôle (120°)
                                
        |  6,9 cm                 \     /   6,9 cm chacun
        |                          \   /
        o  ← câble                  \ /
        |                            o  ← câble, la pointe en bas
        |  6,9 cm                    |
```

**Dipôle vertical droit** — les deux brins alignés, l'un vers le haut, l'autre vers
le bas. Diagramme en tore : maximum vers l'horizon, **trou au zénith**. C'est ce
qu'il faut pour la portée, les avions lointains étant tous à faible élévation.

**V-dipôle, brins écartés de 90 à 120°**, la pointe du V en bas, le tout **dans un
plan vertical**. On perd un peu sur l'horizon, on bouche le trou au zénith : les
avions qui passent au-dessus restent reçus. La polarisation reste majoritairement
verticale tant que le V n'est pas trop ouvert. C'est le montage classique de l'ADS-B
quand on est sous un couloir aérien.

Commencer par le dipôle vertical droit. Passer au V seulement si des appareils
disparaissent en passant à la verticale du récepteur.

### Ce qui compte plus que la longueur des brins

**Le câble.** À 1090 MHz le RG174 du kit perd environ **1 dB par mètre** — contre
0,1 dB/m à 100 MHz. La rallonge de 3 m mange 3 dB, soit la moitié du signal reçu.
Utiliser le câble court de 60 cm de la base du dipôle, et rapprocher le Mac de la
fenêtre plutôt que d'allonger le coaxial.

**La vue dégagée.** L'ADS-B est de la propagation optique. L'horizon radio, en
kilomètres, vaut à peu près `3,57 × (√h_antenne + √h_avion)`, hauteurs en mètres :
un avion à 10 000 m est visible jusqu'à **~360 km** depuis le sol, et ~390 km depuis
un balcon à 10 m. En intérieur derrière un mur porteur, la portée tombe à quelques
dizaines de kilomètres. Un mètre de plus près de la fenêtre vaut mieux que n'importe
quel réglage logiciel.

**Le gain, au maximum** (49,6 dB, le défaut du script). Contrairement à la VHF avec
un émetteur proche, il n'y a ici aucun risque de saturation : les signaux arrivent
de 10 km d'altitude. Ne baisser le gain que si `-s` rapporte un fort taux de
messages corrompus.

## `adsb.sh` — écouter

```fish
./adsb.sh                     # table des avions dans le terminal
./adsb.sh -w                  # carte web sur http://127.0.0.1:8090
./adsb.sh -R                  # scope radar dans le terminal
./adsb.sh -P 48.858,2.295     # position du récepteur : distances et caps
./adsb.sh -r                  # trames Mode S brutes en hexa
./adsb.sh -s 30               # statistiques toutes les 30 s
./adsb.sh -g 30               # gain fixe (défaut 49,6 dB)
./adsb.sh -a                  # gain adaptatif
./adsb.sh -N                  # sortie réseau : SBS 30003, Beast 30005
./adsb.sh -t 60               # s'arrête après 60 s
./adsb.sh -A                  # décode aussi les vieux transpondeurs Mode A/C
```

La table par défaut est celle de dump1090 : une ligne par appareil, indicatif,
altitude, vitesse, cap, distance, qualité du signal.

### Position du récepteur

`-P lat,lon`, ou un fichier `position` à côté du script contenant une ligne
`48.858 2.295`. Sans elle, pas de distance ni de cap affichés, et **les avions au sol
restent invisibles** : les positions de surface sont transmises en coordonnées
relatives, indécodables sans référence. Le fichier `position` est l'adresse du domicile :
un `.gitignore` local l'écarte.

## `adsbmap.py` — la carte

Le paquet Homebrew de dump1090-fa **n'embarque aucune interface web** : il sait
seulement réécrire son état dans un répertoire JSON. `adsbmap.py` lit ce répertoire,
y ajoute une trace par appareil — que dump1090 ne conserve pas — et sert une page
Leaflet qui se rafraîchit chaque seconde.

```fish
./adsb.sh -w -o               # -o ouvre le navigateur
./adsb.sh -w -W 9000          # autre port
```

Avions colorés par altitude, orientés selon leur cap, étiquetés par indicatif ;
trace derrière chacun ; cercles de portée tous les 50 km autour du récepteur ; table
latérale triée par distance, cliquable pour centrer la carte.

Utilisable seul sur un répertoire JSON déjà alimenté :

```fish
./adsbmap.py --json-dir $TMPDIR/adsb-json --port 8090 --open
```

La page distingue « ciel vide » de « dump1090 est mort » : dump1090 réécrit son JSON
chaque seconde même sans aucun avion, donc un fichier qui vieillit signale une panne
du décodeur, pas un ciel désert. Au-delà de 10 s, la carte le dit en rouge.

## `radar.py` — la vue sommaire

Le pendant sans navigateur de la carte : un scope polaire en caractères, récepteur
au centre, nord en haut.

```fish
./adsb.sh -R                  # décodeur + scope, en une commande
./radar.py --portee 150       # sur un JSON déjà alimenté, portée forcée
./radar.py --once             # un instantané, puis rend la main
```

```
                                    N
                              .......|.......
                          .....      |      .....
                       ....       ...|...       ....
                     ..    .← EZY4471|.....     ..    ..
                    ..   ...    ...  ↖|IBE31PM    ...   ..
                    .    .    .    ..   |   50   100  150  200
                O───────────────────────+↑─DLH9R────────────────E
                    .    .    .    ..   |   ..    .    ↗ AFR77QN
                   ↓.BAW572   ..    ....|..→.SWR1TS   ..    .
                     ..    ..     ..↗.RYR88QW     ..    ..
                          .....      |      .....
                                    S
```

Chaque avion est une flèche orientée selon son cap, colorée par tranche d'altitude
(rouge sous 3 000 ft, orange, vert, cyan en croisière), suivie de son indicatif et
de sa trace en pointillés. Les cercles sont chiffrés en km sur l'axe est, la portée
s'ajuste toute seule à l'appareil le plus lointain — `--portee` la fige pour
comparer deux essais d'antenne.

Aucune dépendance : ni navigateur, ni Internet, ni tuiles. C'est ce qui reste
utilisable en SSH, et c'est la bonne vue pour **pointer l'antenne** — un secteur
vide ou une portée bridée d'un côté se voient d'un coup d'œil, là où la carte les
noie dans le fond OSM. Il lit le même répertoire JSON que `adsbmap.py`, en
réutilisant sa classe `Ciel`.

Les avions reçus sans position (CPR incomplet, cf. ci-dessous) sont listés sous le
scope plutôt que passés sous silence : ce sont eux qui disent qu'on reçoit quelque
chose avant que la première position ne tombe.

## Le Pi 4 — `dump1090-fa` en service

Le Mac n'est pas obligé de tenir le dongle : le Pi 4 (`pi4-sdr.home`, Debian 13
trixie, arm64) fait tourner `dump1090-fa` 11.1 compilé depuis les sources, et le Mac
ne fait plus qu'afficher. C'est le montage qui permet de laisser l'antenne à la
fenêtre et l'ordinateur ailleurs.

### Installation

Le dépôt APT FlightAware ne publie rien pour trixie : il faut compiler. Le paquet se
construit proprement, inutile de deviner la liste des dépendances — `mk-build-deps`
la lit dans `debian/control` :

```bash
sudo apt install -y git build-essential devscripts equivs
git clone https://github.com/flightaware/dump1090.git
cd dump1090
sudo mk-build-deps -i -r
dpkg-buildpackage -b --no-sign
sudo apt install ../dump1090-fa_*.deb
```

Le blacklistage du pilote DVB-T est un préalable, il est décrit dans le
[README du Pi](../pi4/README.md#blacklister-le-pilote-dvb-t--obligatoire).

### Configuration

`dump1090-fa` 11 ne lit plus les blocs `RECEIVER_OPTIONS=` / `DECODER_OPTIONS=` de
ses anciennes versions : `/etc/default/dump1090-fa` est en clés simples, marqué
`CONFIG_STYLE=6`. Les valeurs livrées conviennent telles quelles, **sauf la position
du récepteur**, vide par défaut :

```bash
sudo sed -i 's/^RECEIVER_LAT=.*/RECEIVER_LAT=48.xxxx/; s/^RECEIVER_LON=.*/RECEIVER_LON=2.xxxx/' \
    /etc/default/dump1090-fa
sudo systemctl restart dump1090-fa
```

Sans elle, `receiver.json` ne contient aucune coordonnée, la carte n'affiche ni
distances ni cercles de portée, et les avions au sol restent invisibles — même
conséquence que l'absence de fichier `position` côté Mac.

Le gain est en **adaptatif** (`ADAPTIVE_DYNAMIC_RANGE=yes`, plage 0 → 58,6 dB), et
c'est le bon défaut ici : pas la peine de figer 49,6 dB comme le fait `adsb.sh`.

### Démarrage à la main, délibérément

```bash
ssh pi@pi4-sdr.home sudo systemctl start dump1090-fa
ssh pi@pi4-sdr.home sudo systemctl stop dump1090-fa
ssh pi@pi4-sdr.home systemctl status dump1090-fa
```

Le service est **`disabled`** : il ne démarre pas au boot. Ce n'est pas un oubli. Le
dongle est mono-process, et un `dump1090-fa` lancé automatiquement confisquerait le
Pi à toute autre bande — AIS, VHF, FM — dès l'allumage. Le laisser désactivé rend le
dongle libre par défaut ; on le réclame quand on veut de l'ADS-B.

`lighttpd`, lui, reste activé au boot : il ne touche pas au dongle, et sans
`dump1090-fa` il sert simplement une carte vide.

### La carte, depuis le Mac

`lighttpd` publie SkyAware et le répertoire JSON, avec l'en-tête CORS sur
`/skyaware/data/*.json` — le Mac peut donc lire le flux depuis n'importe quelle page.

| | Adresse |
|---|---|
| Carte SkyAware | `http://pi4-sdr.home/skyaware/` (ou `:8080/`) |
| JSON | `http://pi4-sdr.home/skyaware/data/aircraft.json` |
| Beast | `pi4-sdr.home:30005` |
| SBS / BaseStation | `pi4-sdr.home:30003` |
| Raw | `pi4-sdr.home:30002` |

SkyAware suffit pour regarder. Pour retrouver `adsbmap.py` — ses traces, ses cercles
de portée, sa table triée par distance — il faut un répertoire local, puisqu'il lit
des fichiers et non une URL : `adsb-pi.sh` recopie `aircraft.json` du Pi une fois par
seconde et lance la carte dessus.

```fish
./adsb-pi.sh -o                  # carte sur http://127.0.0.1:8090
./adsb-pi.sh -H 192.168.3.14     # si le .home ne résout pas
```

La recopie est atomique (écriture dans un `.tmp` puis `mv`) : `adsbmap.py` relit le
fichier chaque seconde et tomberait sinon sur des JSON tronqués.

## Ce que contient une trame

Mode S Extended Squitter, 112 bits à 1 Mbit/s en modulation d'impulsions. Chaque
appareil émet plusieurs types de messages, qu'il faut combiner :

| | |
|---|---|
| adresse ICAO 24 bits | l'identifiant matériel du transpondeur, toujours présent |
| indicatif | émis toutes les ~5 s seulement — d'où les avions « sans indicatif » au début |
| position | latitude/longitude en **CPR**, deux trames complémentaires nécessaires |
| altitude | barométrique, parfois GNSS |
| vitesse et cap | vitesse sol, taux de montée |

Le codage **CPR** explique le délai avant qu'un avion n'apparaisse sur la carte : il
faut une trame paire *et* une trame impaire pour lever l'ambiguïté de position. Un
avion peut donc être listé, avec son altitude, plusieurs dizaines de secondes avant
d'être plaçable.

## Pièges

**Le dongle est mono-process.** `adsb.sh` arrête tout `rtl_fm`, `rtl_power`,
`AIS-catcher` ou `dump1090` resté en vie. Une seule bande à la fois. Côté Pi, c'est
la raison pour laquelle le service `dump1090-fa` est laissé `disabled` : démarré au
boot, il tiendrait le dongle en permanence.

**1090 MHz est haut dans la plage du R820T** (24–1766 MHz) : la sensibilité y est
moindre qu'en VHF, et la moindre perte de câble compte double. Un LNA d'antenne
alimenté par bias-tee est le vrai remède — mais voir les précautions bias-tee du
[README FM](../fm/README.md#précautions) avant de l'activer.

**`--interactive` prend le terminal** (ncurses) : d'où le mode `-w` qui lance
dump1090 en `--quiet` à côté du serveur de carte, et non les deux ensemble.

**978 MHz (UAT) n'existe qu'aux États-Unis.** En Europe, tout est sur 1090 MHz.

## État actuel

| Script | Rôle |
|---|---|
| `adsb.sh` | lance dump1090 : table, scope radar, carte, trames brutes, réseau |
| `radar.py` | scope polaire en terminal, sans navigateur ni Internet |
| `adsbmap.py` | carte Leaflet temps réel, avec traces et cercles de portée |
| `adsb-pi.sh` | même carte, mais alimentée par le `dump1090-fa` du Pi 4 |

Écrit et testé d'abord sans dongle : analyse des options, chemins d'erreur, serveur
de carte, page et scope validés sur un `aircraft.json` fabriqué, puis sur un faux
décodeur qui fait bouger les avions.

Chaîne complète ensuite validée en réception réelle sur le Pi 4, jusqu'à
`adsbmap.py` sur le Mac via `adsb-pi.sh`. La position du récepteur n'étant pas
renseignée, **la portée réelle reste à mesurer** : c'est le premier point de la
liste ci-dessous.

## À faire

- Renseigner `RECEIVER_LAT` / `RECEIVER_LON` sur le Pi : sans position, aucune des
  mesures de portée ci-dessous n'est possible.
- Premier relevé : nombre d'appareils, portée maximale, taux de messages, avec le
  dipôle court à l'intérieur puis près d'une fenêtre. `./radar.py --portee 250`
  fige l'échelle pour que deux essais soient comparables à l'œil.
- Comparer le dipôle vertical droit et le V-dipôle à 120° sur les passages au zénith.
- Mesurer ce que coûte réellement la rallonge RG174 de 3 m, en portée et en nombre
  d'appareils.
- `--stats-range` sur une heure pour tracer le diagramme de portée réel par azimut.
- Comparer gain fixe à 49,6 dB et `-a` (adaptatif) sur le taux de messages corrompus.
