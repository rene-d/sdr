# AIS avec la RTL-SDR V3

Réception et décodage du trafic AIS (**161,975 et 162,025 MHz**, canaux 87B et 88B)
avec [AIS-catcher](https://github.com/jvde-github/AIS-catcher), et diffusion des
trames NMEA 0183 en UDP vers un traceur de cartes.

Mise en route du dongle et pièges généraux : [`../fm/README.md`](../fm/README.md).
Écoute vocale des canaux VHF : [`../vhf`](../vhf/).
Transpondeurs d'avions : [`../adsb`](../adsb/).

## Démarrage

```fish
./ais.sh                      # décode et diffuse en UDP 127.0.0.1:10110
```

`ais.sh` ne tient que la réception et la diffusion UDP. La flotte, la carte et
l'état persistant sont du ressort du client NMEA en face — OpenCPN, gnuais ou un
traceur maison, n'importe quoi qui lise du NMEA 0183 sur un port UDP.

## Options

```fish
./ais.sh -n                   # affiche aussi les trames NMEA
./ais.sh -w                   # + interface web d'AIS-catcher sur :8100
./ais.sh -t 60                # s'arrête après 60 s
./ais.sh -o ais.nmea          # journalise les trames dans un fichier
./ais.sh -g 40                # gain fixe au lieu de l'AGC
./ais.sh -u 10111             # autre port UDP
./ais.sh -p 3                 # correction de fréquence en ppm
```

Le binaire est cherché en `../ext/AIS-catcher/build/AIS-catcher` ; sinon le donner par
`CATCHER=…`.

## Antenne

Le même brin que la VHF marine : **quart d'onde vertical de 46–48 cm** (46,3 cm exact
à 162 MHz). Rien à changer entre écoute vocale et AIS, les deux sont dans la même
bande.

## Pièges

La dérive rapportée par AIS-catcher reste sous 5 ppm sans correction — le TCXO du V3
tient ses promesses. `-p` n'est utile que si le taux de décodage semble faible.

**`-d:0` est obligatoire.** AIS-catcher énumère aussi les ports série : ici il voit
4 « devices », dont `cu.debug-console` et deux liaisons Bluetooth. Sans index
explicite, il peut ouvrir un port série au lieu de la clé.

```
Found 4 device(s):
0: Realtek, RTL2838UHIDIR, SN: 00000001
1: Serial, USB Serial, SN: cu.debug-console
...
```

**Le dongle est mono-process.** `ais.sh` arrête tout `rtl_fm`/`rtl_power` resté en
vie ; à l'inverse, lancer `../vhf/vhf.sh` pendant qu'AIS-catcher tourne échouera.
Une seule bande à la fois.

**La sortie UDP est silencieuse par nature.** Aucun message n'indique qu'elle
fonctionne. Pour la vérifier sans lancer la carte :

```fish
python3 -c "
import socket
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('127.0.0.1',10110))
for _ in range(5): print(s.recvfrom(4096)[0].decode().strip())"
```

## À faire

- Poser la position du récepteur (`-Z lat lon`) pour qu'AIS-catcher calcule les
  distances, et comparer la portée entre antenne intérieure et extérieure.
- Comparer AGC et gain fixe sur le taux de messages par minute.
- Confronter la réception directe à un flux AIS venu d'internet, pour mesurer ce
  que l'antenne d'ici voit en propre.
