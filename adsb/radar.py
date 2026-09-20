#!/usr/bin/env python3
"""Scope radar ADS-B dans le terminal : les avions en vue polaire, sans navigateur.

    ./radar.py                        # portée automatique
    ./radar.py --portee 150           # 150 km fixes
    ./radar.py --once                 # un seul instantané, puis rend la main

Le pendant sommaire d'`adsbmap.py` : mêmes données, aucune dépendance — ni
navigateur, ni Internet, ni tuiles. Utile en SSH, pour pointer l'antenne, et pour
voir d'un coup d'œil si la portée est bridée dans une direction.

Le récepteur est au centre, le nord en haut. Chaque avion est une flèche orientée
selon son cap, colorée par tranche d'altitude, suivie de sa trace en pointillés.
L'état vient du même répertoire JSON que la carte, via `Ciel` d'adsbmap.
"""

from __future__ import annotations

import argparse
import math
import os
import shutil
import sys
import time
from pathlib import Path

from adsbmap import Ciel, distance_cap

FLECHES = "↑↗→↘↓↙←↖"          # indexées par le cap, par pas de 45°
RESET = "\033[0m"

# Tranches d'altitude en pieds, couleurs ANSI 256. Le découpage suit les usages :
# circuit d'aérodrome, montée/descente, transit, croisière.
TRANCHES = [
    (3_000,   203, "< 3 000 ft"),
    (10_000,  215, "3–10 000"),
    (25_000,  114, "10–25 000"),
    (99_999,   81, "> 25 000"),
]
GRIS, CERCLE, AXE = 244, 238, 240


def couleur(n: int, txt: str, actif: bool) -> str:
    return f"\033[38;5;{n}m{txt}{RESET}" if actif else txt


def altitude_ft(a: dict):
    """Altitude exploitable, ou None : dump1090 écrit la chaîne 'ground' au sol."""
    alt = a.get("alt_baro", a.get("alt_geom"))
    return alt if isinstance(alt, (int, float)) else None


def teinte(a: dict) -> int:
    alt = altitude_ft(a)
    if alt is None:
        return GRIS
    for plafond, coul, _ in TRANCHES:
        if alt < plafond:
            return coul
    return TRANCHES[-1][1]


def pas_rond(portee: float) -> float:
    """Espacement de cercle « rond » le plus proche de portee/4, pour un axe lisible.

    Le plus proche, et non le premier au-dessus : à 236 km de portée, arrondir vers
    le haut donnerait des cercles tous les 100 km, soit deux cercles pour tout le
    scope. 50 km en donne quatre, bien plus lisible pour estimer une distance.
    """
    return min((5, 10, 25, 50, 100, 150, 200, 250, 500), key=lambda p: abs(p - portee / 4))


class Grille:
    """Damier de caractères colorés, adressé en (colonne, ligne)."""

    def __init__(self, cols: int, lignes: int, couleurs: bool):
        self.cols, self.lignes, self.couleurs = cols, lignes, couleurs
        self.c = [[" "] * cols for _ in range(lignes)]
        self.t = [[None] * cols for _ in range(lignes)]

    def pose(self, x: int, y: int, car: str, coul: int, force=False):
        if 0 <= x < self.cols and 0 <= y < self.lignes:
            if force or self.c[y][x] == " ":
                self.c[y][x], self.t[y][x] = car, coul

    def texte(self, x: int, y: int, s: str, coul: int, force=False):
        for i, car in enumerate(s):
            self.pose(x + i, y, car, coul, force)

    def rendu(self) -> list[str]:
        out = []
        for cars, teintes in zip(self.c, self.t):
            ligne, courante = [], None
            for car, t in zip(cars, teintes):
                if self.couleurs and t != courante:
                    ligne.append(RESET if t is None else f"\033[38;5;{t}m")
                    courante = t
                ligne.append(car)
            if self.couleurs and courante is not None:
                ligne.append(RESET)
            out.append("".join(ligne).rstrip())
        return out


def dessiner(snap: dict, cols: int, lignes: int, portee: float | None,
             couleurs: bool) -> list[str]:
    avions = snap["aircraft"]
    # Sans position du récepteur, dump1090 ne calcule ni distance ni cap : on les
    # refait ici autour du barycentre des avions vus, ce qui donne une vue relative
    # exploitable pour juger la répartition, à défaut d'être géoréférencée.
    centre = snap.get("recepteur")
    place = [a for a in avions if "lat" in a]
    relatif = centre is None
    if relatif and place:
        centre = {"lat": sum(a["lat"] for a in place) / len(place),
                  "lon": sum(a["lon"] for a in place) / len(place)}
    for a in place:
        if "dist" not in a:
            a["dist"], a["cap"] = distance_cap(centre["lat"], centre["lon"],
                                               a["lat"], a["lon"])

    rayon = (lignes - 1) // 2
    cx, cy = cols // 2, rayon
    auto = portee is None
    if auto:
        portee = max((a["dist"] for a in place), default=50.0) * 1.15
        portee = max(portee, 10.0)
    pas = pas_rond(portee)
    portee = max(portee, pas)                      # au moins un cercle complet
    hors = [a for a in place if a["dist"] > portee]
    place = [a for a in place if a["dist"] <= portee]

    g = Grille(cols, 2 * rayon + 1, couleurs)
    # Cercles et traces sont tous deux des semis de points : en couleur la teinte
    # les sépare, en monochrome il faut deux glyphes différents.
    pt_cercle = "·" if couleurs else "."

    def vers_ecran(dist: float, cap: float) -> tuple[int, int]:
        r = min(1.0, dist / portee) * rayon
        th = math.radians(cap)
        # Une cellule de terminal est deux fois plus haute que large : sans le
        # facteur 2 en x, les cercles sortiraient en ellipses écrasées.
        return cx + round(2 * r * math.sin(th)), cy - round(r * math.cos(th))

    for deg, lettre in ((0, "N"), (90, "E"), (180, "S"), (270, "O")):
        x, y = vers_ecran(portee * 1.02, deg)
        g.pose(min(max(x, 0), cols - 1), min(max(y, 0), 2 * rayon), lettre, AXE, force=True)
    # Les axes se tracent en cellules, pas en polaire : une colonne sur deux étant
    # atteinte par vers_ecran, la version polaire sortait en tirets espacés.
    for f in range(1, rayon + 1):
        g.pose(cx, cy - f, "|", AXE)
        g.pose(cx, cy + f, "|", AXE)
    for dx in range(1, 2 * rayon + 1):
        g.pose(cx - dx, cy, "─", AXE)
        g.pose(cx + dx, cy, "─", AXE)
    # Sur un scope étroit, les étiquettes de cercles se chevauchent et se mêlent aux
    # noms d'avions : au-dessous de 5 colonnes entre deux cercles, seul le dernier
    # est chiffré — l'échelle reste lisible, l'encombrement disparaît.
    nb = int(portee / pas)
    chiffre_tous = 2 * rayon * pas / portee >= 5
    for k in range(1, nb + 1):                      # cercles de portée
        d = k * pas
        if d > portee:
            break
        for deg in range(0, 720):
            g.pose(*vers_ecran(d, deg / 2), pt_cercle, CERCLE)
        # Étiquette posée une ligne au-dessus de l'axe est : sur l'axe même, elle se
        # mêlait aux tirets et se faisait écraser par le « E » du bord.
        if chiffre_tous or k == nb:
            x, y = vers_ecran(d, 90)
            g.texte(x - 1, y - 1, f"{d:g}", CERCLE, force=True)

    g.pose(cx, cy, "+", 220, force=True)             # le récepteur

    for a in place:                                  # traces, puis les avions
        for d_, c_ in [distance_cap(centre["lat"], centre["lon"], la, lo)
                       for la, lo in snap["traces"].get(a["hex"], [])]:
            g.pose(*vers_ecran(d_, c_), "·", teinte(a))
    for a in sorted(place, key=lambda a: -(altitude_ft(a) or 0)):
        x, y = vers_ecran(a["dist"], a["cap"])
        cap = a.get("track")
        car = FLECHES[round((cap % 360) / 45) % 8] if cap is not None else "●"
        g.pose(x, y, car, teinte(a), force=True)
        nom = (a.get("flight") or a["hex"])[:8]
        g.texte(x + 2, y, nom, teinte(a), force=True)

    lignes_out = g.rendu()
    lignes_out.append("")
    lignes_out.append(legende(snap, portee, pas, place, relatif, couleurs))
    if hors:
        lignes_out.append(f"{len(hors)} hors portée, jusqu'à "
                          f"{max(a['dist'] for a in hors):.0f} km")
    muets = [a for a in avions if "lat" not in a]
    if muets:
        noms = " ".join(couleur(teinte(a), (a.get("flight") or a["hex"])[:8], couleurs)
                        for a in muets[:8])
        lignes_out.append(f"sans position ({len(muets)}) : {noms}"
                          + (" …" if len(muets) > 8 else ""))
    return lignes_out


def legende(snap, portee, pas, place, relatif, couleurs) -> str:
    # Deux lignes plutôt qu'une : d'un seul tenant, la légende dépasse 110 colonnes
    # et s'enroule au milieu d'un nom de tranche.
    bandes = "  ".join(couleur(c, f"■ {lib}", couleurs) for _, c, lib in TRANCHES)
    tete = (f"{len(snap['aircraft'])} appareils, {len(place)} positionnés — "
            f"cercles tous les {pas:g} km, portée {portee:.0f} km\n{bandes}")
    if relatif:
        tete += "\n⚠ position du récepteur inconnue : vue centrée sur les avions, " \
                "distances relatives (voir ./adsb.sh -P lat,lon)"
    if snap["age"] > 10:
        tete += f"\n⚠ dump1090 ne donne plus rien (JSON vieux de {snap['age']:.0f} s)"
    return tete


def main():
    defaut = Path(os.environ.get("TMPDIR", "/tmp")) / "adsb-json"
    ap = argparse.ArgumentParser(description="Scope radar ADS-B en terminal")
    ap.add_argument("--json-dir", type=Path, default=defaut,
                    help=f"répertoire alimenté par dump1090 --write-json ({defaut})")
    ap.add_argument("--portee", type=float, help="rayon affiché en km (défaut : auto)")
    ap.add_argument("--interval", type=float, default=1.0, help="rafraîchissement en s")
    ap.add_argument("--once", action="store_true", help="un seul instantané")
    ap.add_argument("--no-color", action="store_true")
    args = ap.parse_args()

    couleurs = not args.no_color and sys.stdout.isatty()
    if not args.json_dir.is_dir():
        sys.exit(f"répertoire introuvable : {args.json_dir}\n"
                 f"lancer d'abord   ./adsb.sh -w   ou   ./adsb.sh -R")
    ciel = Ciel(args.json_dir)

    try:
        while True:
            ciel.rafraichir()
            cols, lignes = shutil.get_terminal_size((100, 32))
            # Deux colonnes par ligne pour les cercles, plus la place des étiquettes.
            lignes = max(9, min(lignes - 5, (cols - 12) // 2))
            sortie = dessiner(ciel.instantane(), cols, lignes, args.portee, couleurs)
            if args.once:
                print("\n".join(sortie))
                return
            sys.stdout.write("\033[H\033[J" + "\n".join(sortie) + "\n")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        sys.stdout.write(RESET + "\n")


if __name__ == "__main__":
    main()
