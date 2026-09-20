# VHF marine avec la RTL-SDR V3

Réception des canaux VHF marine (**156–162 MHz**, NBFM, canaux de 25 kHz,
polarisation **verticale**) sur macOS Apple Silicon.

Mise en route du dongle, validation USB et pièges généraux : voir
[`../fm/README.md`](../fm/README.md). Pour l'AIS, qui partage cette bande et cette
antenne : [`../ais`](../ais/). Pour l'ADS-B, qui demande un dipôle sept fois
plus court : [`../adsb`](../adsb/).

Dépendances : `librtlsdr` et `ffmpeg` (`brew install librtlsdr ffmpeg`), plus
`numpy` pour le mètre de niveau. Le son passe par `ffmpeg -f audiotoolbox`, la
sortie native macOS, et non par `ffplay`, muet sur cette machine — explication dans
le README de `../fm`.

## Antenne

| Fréquence | Quart d'onde | × 0,95 (brin réel) |
|---|---|---|
| 156,8 MHz (canal 16) | 47,8 cm | 45,4 cm |
| 159 MHz (milieu de bande) | 47,1 cm | 44,8 cm |
| 162 MHz (haut de bande) | 46,3 cm | 43,9 cm |

Un brin réglé à **47–48 cm** couvre toute la bande sans retoucher. Dipôle du kit v3 :
**2 × 47,8 cm**, monté **vertical** — en horizontal on perd une vingtaine de dB, la
VHF marine étant verticale.

## `vhf.sh` — écouter un canal

```fish
./vhf.sh 16             # canal 16 (détresse et appel)
./vhf.sh 16 -q 50       # avec squelch : silence tant qu'il n'y a pas de trafic
./vhf.sh 77 -m -g 15    # mètre de niveau, pour tester un émetteur
./vhf.sh 27 -c          # côté station côtière (canaux duplex)
./vhf.sh 156.8M         # fréquence directe
./vhf.sh -l             # les 57 canaux
```

Table ITU intégrée : canaux 1–28 et 60–88, simplex et duplex. Les duplex ont la
station côtière **4,6 MHz au-dessus** du navire, d'où `-c`. Le script refuse `-c` sur
un canal simplex plutôt que de sortir une fréquence inventée.

Quelques canaux utiles : **16** détresse et appel (veille permanente), **70** ASN/DSC
(données numériques, pas de voix), **6/8/72/77** navire-navire, **9** souvent ports de
plaisance, **13** sécurité de la navigation.

## Pièges de la NBFM

**`-r` de `rtl_fm` ne sait que décimer.** `-s 12k -r 48k` sort du 12 kHz, pas du
48 kHz : le rééchantillonneur n'interpole jamais, il ignore silencieusement une
demande de montée en fréquence. En NBFM, `-s` fixe donc à la fois la bande passante
et le débit de sortie — 16 kHz convient aux canaux de 25 kHz — et c'est `ffmpeg` qui
adapte au périphérique. (En WBFM, `-s 200k -r 48k` marche parce que c'est une
décimation.)

**Squelch fermé = zéro octet.** `rtl_fm` n'émet pas de silence, il n'émet plus rien.
Vérifié : `ffmpeg` absorbe la famine sans erreur et reprend seul quand le signal
revient — 6 s d'audio coupées par 4 s de famine se jouent en 6 s. Le trou est élidé,
pas comblé : sans conséquence pour l'écoute, mais un enregistrement vers fichier
perdrait la chronologie.

**Le seuil de squelch n'est pas monotone** et dépend du gain. Mesuré sur un canal
silencieux à `-g 40` : ouvert à 0/5/10/25, fermé à 50, **rouvert à 100**. D'où le
défaut `-q 0` (ouvert, on entend le souffle) : prévisible, ne masque jamais un
signal. Le squelch se calibre canal par canal, `-m` aide à trouver le niveau.

## Tester un émetteur

Le mode `-m` affiche le niveau reçu toutes les 0,5 s :

```fish
./vhf.sh 77 -m -g 15
```
```
 -33.1 dBFS |######################                            |
```

Plancher stable = rien ; l'aiguille bondit dès qu'on passe en émission.

**Baisser le gain** (`-g 15`, voire `-g 0.9`) et **s'éloigner de plusieurs mètres** :
un émetteur de quelques watts à courte distance sature complètement l'étage d'entrée
du R820T. Un récepteur saturé peut paraître sourd alors que le signal est énorme.

Pour les essais, rester sur un canal navire-navire comme **77** — jamais le 16
(détresse) ni le 70 (ASN).
