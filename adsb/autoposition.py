#!/usr/bin/env python3
"""Retrouve la position du récepteur à partir des messages ADS-B reçus.

    ./autoposition.py journal.jsonl

Le journal est une ligne JSON par relevé : {"t","hex","lat","lon","alt","rssi"}.

Trois méthodes indépendantes, de la plus fiable à la plus grossière. Elles ne
servent pas la même chose : la première donne le point, la deuxième le confirme,
la troisième garantit une région. Voir le README pour le raisonnement.
"""
from __future__ import annotations

import json
import math
import sys
from collections import defaultdict

import numpy as np

R_TERRE = 6371008.8
GAP_TRACE = 120.0        # s sans nouvelle position : on coupe la trace
MIN_POINTS = 25          # points par trace pour que le maximum ait un sens
MIN_PROEMINENCE = 3.0    # dB entre le pic et les bords, sinon pas de vrai CPA
BORD = 0.15              # pic trop près d'un bout : le CPA est hors couverture


def projette(lat, lon, lat0, lon0):
    """Équirectangulaire local, en mètres. Suffisant sous 300 km."""
    x = np.radians(lon - lon0) * math.cos(math.radians(lat0)) * R_TERRE
    y = np.radians(lat - lat0) * R_TERRE
    return x, y


def deprojette(x, y, lat0, lon0):
    lat = lat0 + math.degrees(y / R_TERRE)
    lon = lon0 + math.degrees(x / (R_TERRE * math.cos(math.radians(lat0))))
    return lat, lon


def charge(chemin):
    traces = defaultdict(list)
    with open(chemin) as f:
        for ligne in f:
            try:
                d = json.loads(ligne)
            except ValueError:
                continue
            if d.get("lat") is None or d.get("rssi") is None:
                continue
            traces[d["hex"]].append(d)
    # Une trace = un passage. Le même appareil revu une heure plus tard est un
    # autre passage, avec son propre point de plus courte approche.
    decoupees = []
    for hex_, pts in traces.items():
        pts.sort(key=lambda p: p["t"])
        courante = [pts[0]]
        for p in pts[1:]:
            if p["t"] - courante[-1]["t"] > GAP_TRACE:
                decoupees.append((hex_, courante))
                courante = []
            courante.append(p)
        decoupees.append((hex_, courante))
    return decoupees


def lisse(v, k=5):
    if len(v) < k:
        return v
    noyau = np.ones(k) / k
    return np.convolve(v, noyau, mode="same")


# ---------------------------------------------------------------- méthode 1
def cpa(traces, lat0, lon0):
    """Perpendiculaires au point de plus courte approche.

    Le long d'UNE trace, c'est le même émetteur, la même antenne, la même
    puissance : le maximum de RSSI ne dépend plus que de la distance. Il tombe
    donc au point de la trajectoire le plus proche du récepteur, et le récepteur
    se trouve sur la perpendiculaire à la trace en ce point. Chaque passage
    fournit une droite ; on les croise.
    """
    droites = []
    for hex_, pts in traces:
        if len(pts) < MIN_POINTS:
            continue
        rssi = lisse(np.array([p["rssi"] for p in pts], float))
        i = int(np.argmax(rssi))
        if not (BORD * len(pts) < i < (1 - BORD) * len(pts)):
            continue    # pic au bord : l'avion est entré ou sorti, pas un CPA
        bords = min(rssi[0], rssi[-1])
        if rssi[i] - bords < MIN_PROEMINENCE:
            continue    # plateau : le passage est trop loin pour trancher
        lat = np.array([p["lat"] for p in pts])
        lon = np.array([p["lon"] for p in pts])
        x, y = projette(lat, lon, lat0, lon0)
        # Cap au point de plus courte approche. L'avion diffuse le sien
        # (« track », route sur le fond) : plus propre que de le dériver des
        # positions, qui sont bruitées à l'échelle de deux relevés.
        trk = pts[i].get("track")
        if trk is not None:
            a = math.radians(trk)
            ux, uy = math.sin(a), math.cos(a)
        else:
            a, b = max(0, i - 6), min(len(pts), i + 7)
            dx, dy = x[b - 1] - x[a], y[b - 1] - y[a]
            n = math.hypot(dx, dy)
            if n < 500:
                continue    # avion quasi immobile : direction indéterminée
            ux, uy = dx / n, dy / n
        droites.append((x[i], y[i], ux, uy, rssi[i] - bords, hex_))
    return droites


def croise(droites, huber=2000.0, tours=12):
    """Moindres carrés sur les droites, repondérés facon Huber.

    Une trace sur dix donne un pic parasite — lobe d'antenne, virage, avion qui
    masque son antenne ventrale en roulis. Sans repondération, une seule de ces
    droites tire le point de plusieurs kilomètres.
    """
    if len(droites) < 3:
        return None, None, 0
    p = np.array([[d[0], d[1]] for d in droites])
    u = np.array([[d[2], d[3]] for d in droites])   # direction de la trace
    w = np.ones(len(droites))
    X = None
    for _ in range(tours):
        # résidu = u . (X - p), nul quand X est sur la perpendiculaire
        A = np.einsum("i,ij,ik->jk", w, u, u)
        b = np.einsum("i,ij,i->j", w, u, np.einsum("ij,ij->i", u, p))
        try:
            X = np.linalg.solve(A, b)
        except np.linalg.LinAlgError:
            return None, None, 0
        r = np.abs(np.einsum("ij,ij->i", u, X - p))
        w = np.where(r <= huber, 1.0, huber / np.maximum(r, 1e-9))
    r = np.abs(np.einsum("ij,ij->i", u, X - p))
    return X, r, int((r < huber).sum())


# ---------------------------------------------------------------- méthode 2
def par_puissance(traces, lat0, lon0):
    """Ajustement RSSI = C - 20 log10(distance).

    Indépendante de la précédente : elle utilise le niveau absolu, pas la forme
    de la courbe. Donc sensible à tout ce que la première annule — classe de
    puissance de l'émetteur, gain adaptatif du récepteur. À ne lire que comme
    un recoupement.
    """
    pts = [p for _, t in traces for p in t]
    if len(pts) < 200:
        return None
    lat = np.array([p["lat"] for p in pts])
    lon = np.array([p["lon"] for p in pts])
    alt = np.array([(p["alt"] or 0) * 0.3048 for p in pts], float)
    rssi = np.array([p["rssi"] for p in pts], float)
    x, y = projette(lat, lon, lat0, lon0)

    def cout(cx, cy):
        d = np.sqrt((x - cx) ** 2 + (y - cy) ** 2 + alt ** 2)
        L = -20 * np.log10(np.maximum(d, 1.0))
        C = np.mean(rssi - L)              # la constante s'élimine
        return np.mean((rssi - (C + L)) ** 2)

    # Grille grossière puis descente : le critère est lisse mais pas convexe.
    best, pas = (0.0, 0.0), 120_000.0
    while pas > 200:
        cx, cy = best
        cand = [(cx + i * pas, cy + j * pas) for i in (-1, 0, 1) for j in (-1, 0, 1)]
        best = min(cand, key=lambda c: cout(*c))
        if best == (cx, cy):
            pas /= 2
    return np.array(best), math.sqrt(cout(*best))


# ---------------------------------------------------------------- méthode 3
def region_horizon(traces, lat0, lon0, h_rx=10.0):
    """Intersection des disques d'horizon radio.

    Un avion reçu est forcément en vue directe : d <= 4,12 (Vh_rx + Vh_avion),
    en mètres et kilomètres. Chaque réception enferme donc le récepteur dans un
    disque. C'est une condition nécessaire, jamais fausse — le relief ne fait
    que raccourcir la portée réelle. D'où une région garantie, la seule des
    trois à ne rien supposer sur la propagation.
    """
    pts = [p for _, t in traces for p in t if p.get("alt")]
    if not pts:
        return None
    lat = np.array([p["lat"] for p in pts])
    lon = np.array([p["lon"] for p in pts])
    alt = np.array([p["alt"] * 0.3048 for p in pts], float)
    x, y = projette(lat, lon, lat0, lon0)
    rayon = 4120.0 * (math.sqrt(h_rx) + np.sqrt(np.maximum(alt, 1.0)))   # m
    # Les plus bas contraignent le plus : inutile de garder les 30 000 pieds.
    ordre = np.argsort(rayon)[:400]
    x, y, rayon = x[ordre], y[ordre], rayon[ordre]

    g = np.arange(-250_000, 250_001, 2000.0)
    gx, gy = np.meshgrid(g, g)
    ok = np.ones(gx.shape, bool)
    for cx, cy, r in zip(x, y, rayon):
        ok &= ((gx - cx) ** 2 + (gy - cy) ** 2) <= r * r
    if not ok.any():
        return None
    return gx[ok], gy[ok]


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        sys.exit(1)
    traces = charge(sys.argv[1])
    pts = sum(len(t) for _, t in traces)
    lat0 = float(np.mean([p["lat"] for _, t in traces for p in t]))
    lon0 = float(np.mean([p["lon"] for _, t in traces for p in t]))
    print(f"{pts} relevés, {len(traces)} passages, "
          f"{len(set(h for h, _ in traces))} appareils")
    print(f"référence de projection : {lat0:.4f}, {lon0:.4f}\n")

    droites = cpa(traces, lat0, lon0)
    X, res, gardees = croise(droites)
    if X is None:
        print(f"méthode CPA : {len(droites)} droites exploitables, il en faut 3.")
        print("Collecter plus longtemps : il faut des passages entiers, entrée")
        print("et sortie de couverture comprises.")
        return
    lat, lon = deprojette(X[0], X[1], lat0, lon0)
    disp = float(np.median(res))
    print(f"CPA            {lat:.4f}, {lon:.4f}"
          f"   ({len(droites)} passages, {gardees} retenus, "
          f"écart médian {disp/1000:.1f} km)")

    p2 = par_puissance(traces, lat0, lon0)
    if p2:
        Xp, rms = p2
        latp, lonp = deprojette(Xp[0], Xp[1], lat0, lon0)
        ecart = math.hypot(Xp[0] - X[0], Xp[1] - X[1]) / 1000
        print(f"puissance      {latp:.4f}, {lonp:.4f}"
              f"   (résidu {rms:.1f} dB, à {ecart:.1f} km de la précédente)")

    reg = region_horizon(traces, lat0, lon0)
    if reg is not None:
        rx, ry = reg
        dedans = math.hypot(X[0] - rx.mean(), X[1] - ry.mean())
        etendue = max(rx.max() - rx.min(), ry.max() - ry.min()) / 1000
        cohe = ((rx - X[0]) ** 2 + (ry - X[1]) ** 2).min() ** 0.5 < 3000
        print(f"horizon        région garantie de {etendue:.0f} km d'étendue, "
              f"centre à {dedans/1000:.1f} km — "
              f"{'CPA dedans ✓' if cohe else 'CPA DEHORS ✗'}")

    print(f"\n  RECEIVER_LAT={lat:.4f}")
    print(f"  RECEIVER_LON={lon:.4f}")


if __name__ == "__main__":
    main()
