#!/usr/bin/env python3
"""Carte ADS-B temps réel : sert les avions vus par dump1090 sur une carte web.

    ./adsbmap.py --json-dir /tmp/adsb-json --open

dump1090-fa du paquet Homebrew n'embarque aucune interface web : il sait
seulement réécrire son état dans un répertoire JSON (`--write-json`). Ce script
lit ce répertoire, garde une trace par appareil — que dump1090 ne conserve pas —
et sert le tout à une page Leaflet.

    /                 la page
    /api/aircraft     avions courants + traces + position du récepteur

Lancé normalement par `./adsb.sh -w`, qui démarre dump1090 à côté.
"""

from __future__ import annotations

import argparse
import json
import math
import threading
import time
import webbrowser
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TRACE_MAX = 400          # points gardés par appareil (~7 min à 1 point/s)
OUBLI = 120.0            # secondes sans message avant de retirer un appareil


class Ciel:
    """État courant du ciel, reconstruit en continu depuis aircraft.json."""

    def __init__(self, json_dir: Path):
        self.dir = json_dir
        self.lock = threading.Lock()
        self.avions: dict[str, dict] = {}
        self.traces: dict[str, deque] = {}
        self.recepteur: dict | None = None
        self.messages = 0
        self.maj = 0.0

    def _lire(self, nom: str):
        try:
            return json.loads((self.dir / nom).read_text())
        except (OSError, ValueError):
            return None

    def boucle(self, periode: float = 1.0):
        while True:
            self.rafraichir()
            time.sleep(periode)

    def rafraichir(self):
        if self.recepteur is None:
            r = self._lire("receiver.json")
            # json-location-accuracy 0 : dump1090 omet lat/lon, on n'insiste pas.
            if r and "lat" in r:
                self.recepteur = {"lat": r["lat"], "lon": r["lon"]}
        data = self._lire("aircraft.json")
        if not data:
            return
        now = data.get("now", time.time())
        with self.lock:
            self.messages = data.get("messages", 0)
            self.maj = now
            vus = set()
            for a in data.get("aircraft", []):
                hexa = a.get("hex")
                if not hexa:
                    continue
                vus.add(hexa)
                a["vu"] = round(a.get("seen", 0.0), 1)
                if (vol := a.get("flight")):
                    a["flight"] = vol.strip()
                if self.recepteur and "lat" in a:
                    a["dist"], a["cap"] = distance_cap(
                        self.recepteur["lat"], self.recepteur["lon"],
                        a["lat"], a["lon"])
                self.avions[hexa] = a
                if "lat" in a and a.get("seen_pos", 99) < 30:
                    t = self.traces.setdefault(hexa, deque(maxlen=TRACE_MAX))
                    p = (round(a["lat"], 5), round(a["lon"], 5))
                    if not t or t[-1] != p:
                        t.append(p)
            # dump1090 sort les appareils de sa liste tout seul ; on purge les
            # traces correspondantes pour ne pas fuir en mémoire sur la durée.
            for hexa in list(self.avions):
                if hexa not in vus and self.avions[hexa].get("seen", 0) > OUBLI:
                    self.avions.pop(hexa, None)
                    self.traces.pop(hexa, None)

    def age(self) -> float:
        """Secondes depuis la dernière écriture d'aircraft.json, 1e9 s'il manque.

        dump1090 réécrit le fichier chaque seconde même quand le ciel est vide :
        un âge qui grimpe veut dire que c'est dump1090 qui est mort, pas le ciel
        qui est désert — deux situations qui se ressemblent trop sur une carte.
        """
        try:
            return round(time.time() - (self.dir / "aircraft.json").stat().st_mtime, 1)
        except OSError:
            return 1e9

    def instantane(self) -> dict:
        with self.lock:
            return {
                "age": self.age(),
                "now": self.maj,
                "messages": self.messages,
                "recepteur": self.recepteur,
                "aircraft": list(self.avions.values()),
                "traces": {h: list(t) for h, t in self.traces.items() if len(t) > 1},
            }


def distance_cap(lat1, lon1, lat2, lon2) -> tuple[float, float]:
    """Distance en km (haversine) et cap vrai en degrés, du récepteur vers l'avion."""
    r = 6371.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    d = 2 * r * math.asin(min(1.0, math.sqrt(a)))
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return round(d, 1), round(math.degrees(math.atan2(y, x)) % 360)


PAGE = r"""<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ADS-B</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
  html, body { margin: 0; height: 100%; background: #10141c;
               font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
  #carte { position: absolute; inset: 0; }
  #panneau { position: absolute; top: 10px; right: 10px; z-index: 500; width: 340px;
             max-height: calc(100% - 20px); overflow: auto; color: #dde3ec;
             background: rgba(16,20,28,.88); border: 1px solid #2c3444;
             border-radius: 6px; padding: 10px 12px; }
  #panneau h1 { font-size: 13px; margin: 0 0 6px; font-weight: 600; }
  #etat { color: #8b98ab; font-size: 12px; margin-bottom: 8px; }
  table { border-collapse: collapse; width: 100%; font-size: 12px; }
  th { text-align: left; color: #8b98ab; font-weight: 400; border-bottom: 1px solid #2c3444; }
  td, th { padding: 2px 4px; }
  tbody tr:hover { background: #1d2534; cursor: pointer; }
  td.n { text-align: right; font-variant-numeric: tabular-nums; }
  .avion svg { display: block; filter: drop-shadow(0 0 2px #000); }
  .etiq { color: #dde3ec; font-size: 11px; text-shadow: 0 0 3px #000, 0 0 3px #000;
          white-space: nowrap; }
  .leaflet-container { background: #10141c; }
  .leaflet-tile { filter: invert(1) hue-rotate(180deg) brightness(.85) contrast(.9); }
</style></head><body>
<div id="carte"></div>
<div id="panneau"><h1>ADS-B 1090 MHz</h1><div id="etat">connexion…</div>
<table><thead><tr><th>vol</th><th>hex</th><th class="n">alt</th><th class="n">vit</th>
<th class="n">dist</th></tr></thead><tbody id="liste"></tbody></table></div>
<script>
const carte = L.map('carte', {zoomControl: true}).setView([46.8, 2.5], 6);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom: 18, attribution: '© OpenStreetMap'}).addTo(carte);

const marqueurs = {}, lignes = {};
let recepteurPose = false, cadre = false;

// Couleur par altitude : du bas (rouge) au niveau de croisière (violet).
function couleur(alt) {
  if (alt === undefined || alt === null || alt === 'ground') return '#9aa6b8';
  const t = Math.max(0, Math.min(1, alt / 40000));
  return `hsl(${Math.round(20 + 260 * t)} 85% 60%)`;
}
function icone(a) {
  const c = couleur(a.alt_baro), r = a.track || 0;
  const nom = a.flight || a.hex;
  return L.divIcon({className: 'avion', iconSize: [26, 26], iconAnchor: [13, 13],
    html: `<svg width="26" height="26" viewBox="-12 -12 24 24"
            style="transform: rotate(${r}deg)">
      <path d="M0,-10 L2,-4 L10,2 L10,4 L2,1 L2,6 L5,8.5 L5,10 L0,8.5 L-5,10
               L-5,8.5 L-2,6 L-2,1 L-10,4 L-10,2 L-2,-4 Z"
            fill="${c}" stroke="#0b0e14" stroke-width="1"/></svg>
      <div class="etiq" style="margin-left:28px;margin-top:-20px">${nom}</div>`});
}
function detail(a) {
  const l = [`<b>${a.flight || '(sans indicatif)'}</b> — ${a.hex}`];
  if (a.alt_baro !== undefined) l.push(`altitude ${a.alt_baro} ft` +
      (a.baro_rate ? ` (${a.baro_rate > 0 ? '+' : ''}${a.baro_rate} ft/min)` : ''));
  if (a.gs !== undefined) l.push(`vitesse sol ${Math.round(a.gs)} kt`);
  if (a.track !== undefined) l.push(`cap ${Math.round(a.track)}°`);
  if (a.squawk) l.push(`transpondeur ${a.squawk}`);
  if (a.dist !== undefined) l.push(`${a.dist} km au ${a.cap}° du récepteur`);
  if (a.rssi !== undefined) l.push(`signal ${a.rssi} dBFS — ${a.messages} messages`);
  l.push(`vu il y a ${a.vu} s`);
  return l.join('<br>');
}

async function tick() {
  let d;
  try { d = await (await fetch('/api/aircraft')).json(); }
  catch (e) { document.getElementById('etat').textContent = 'dump1090 injoignable'; return; }

  if (d.recepteur && !recepteurPose) {
    recepteurPose = true;
    L.circleMarker([d.recepteur.lat, d.recepteur.lon],
      {radius: 5, color: '#f5c542', fillOpacity: 1}).addTo(carte).bindPopup('récepteur');
    for (const km of [50, 100, 150, 200, 250])
      L.circle([d.recepteur.lat, d.recepteur.lon], {radius: km * 1000, fill: false,
        color: '#2c3444', weight: 1}).addTo(carte);
    carte.setView([d.recepteur.lat, d.recepteur.lon], 8);
  }

  const vus = new Set(), avec = [];
  for (const a of d.aircraft) {
    vus.add(a.hex);
    if (a.lat === undefined) continue;
    avec.push(a);
    const p = [a.lat, a.lon];
    if (marqueurs[a.hex]) marqueurs[a.hex].setLatLng(p).setIcon(icone(a));
    else marqueurs[a.hex] = L.marker(p, {icon: icone(a)}).addTo(carte);
    marqueurs[a.hex].bindPopup(detail(a));
    const t = d.traces[a.hex];
    if (t) {
      if (lignes[a.hex]) lignes[a.hex].setLatLngs(t);
      else lignes[a.hex] = L.polyline(t, {color: couleur(a.alt_baro), weight: 1.5,
                                          opacity: .6}).addTo(carte);
    }
  }
  for (const h of Object.keys(marqueurs)) if (!vus.has(h)) {
    carte.removeLayer(marqueurs[h]); delete marqueurs[h];
    if (lignes[h]) { carte.removeLayer(lignes[h]); delete lignes[h]; }
  }

  // Premier cadrage automatique seulement : ensuite la carte reste où l'utilisateur
  // l'a mise, sinon impossible de regarder un coin du ciel plus d'une seconde.
  if (!cadre && !recepteurPose && avec.length) {
    cadre = true;
    carte.fitBounds(L.latLngBounds(avec.map(a => [a.lat, a.lon])).pad(.2));
  }

  const etat = document.getElementById('etat');
  if (d.age > 10) {
    etat.innerHTML = `<span style="color:#e06c5a">dump1090 ne donne plus rien ` +
      `(JSON vieux de ${Math.round(d.age)} s)</span>`;
  } else {
    etat.textContent = `${d.aircraft.length} appareils, ${avec.length} avec position — ` +
      `${d.messages.toLocaleString('fr')} messages`;
  }
  const tri = d.aircraft.slice().sort((x, y) =>
    (x.dist ?? 1e9) - (y.dist ?? 1e9) || (x.flight || x.hex).localeCompare(y.flight || y.hex));
  document.getElementById('liste').innerHTML = tri.map(a => `
    <tr data-hex="${a.hex}">
      <td>${a.flight || '—'}</td><td>${a.hex}</td>
      <td class="n">${a.alt_baro ?? '—'}</td>
      <td class="n">${a.gs !== undefined ? Math.round(a.gs) : '—'}</td>
      <td class="n">${a.dist ?? '—'}</td></tr>`).join('');
}
document.getElementById('liste').addEventListener('click', e => {
  const tr = e.target.closest('tr'); if (!tr) return;
  const m = marqueurs[tr.dataset.hex];
  if (m) { carte.setView(m.getLatLng(), Math.max(carte.getZoom(), 9)); m.openPopup(); }
});
tick(); setInterval(tick, 1000);
</script></body></html>
"""


class Serveur(BaseHTTPRequestHandler):
    ciel: Ciel

    def _envoi(self, corps: bytes, mime: str):
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(corps)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(corps)

    def do_GET(self):
        if self.path.startswith("/api/aircraft"):
            self._envoi(json.dumps(self.ciel.instantane()).encode(),
                        "application/json; charset=utf-8")
        elif self.path in ("/", "/index.html"):
            self._envoi(PAGE.encode(), "text/html; charset=utf-8")
        else:
            self.send_error(404)

    def log_message(self, *a):        # une ligne par seconde et par client, inutile
        pass


def main():
    ap = argparse.ArgumentParser(description="Carte ADS-B temps réel (dump1090 --write-json)")
    ap.add_argument("--json-dir", required=True, type=Path,
                    help="répertoire alimenté par dump1090 --write-json")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--open", action="store_true", help="ouvre le navigateur")
    args = ap.parse_args()

    ciel = Ciel(args.json_dir)
    threading.Thread(target=ciel.boucle, daemon=True).start()
    Serveur.ciel = ciel

    url = f"http://127.0.0.1:{args.port}/"
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Serveur)
    print(f"carte ADS-B : {url}   (Ctrl-C pour arrêter)", flush=True)
    if args.open:
        threading.Timer(0.6, webbrowser.open, (url,)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
