#!/usr/bin/env python3
"""Analyseur de spectre TUI pour la bande FM, basé sur rtl_power.

  ./fmscan.py                 # TUI temps réel, bande FM 88-108 MHz
  ./fmscan.py --once          # un seul balayage, rendu texte (scriptable)
  ./fmscan.py -f 118M:137M    # bande aéronautique
  ./fmscan.py -b 12.5k -g 30  # pas de 12,5 kHz, gain 30 dB
  ./fmscan.py -H pi@pi4-sdr.local  # dongle sur un Pi distant (ou $SDR_HOST)

Touches en mode TUI :  q quitter   w cascade on/off   p pics on/off   +/- gain
"""
import argparse, curses, os, shutil, signal, subprocess, sys, threading, time
from collections import deque

import sdrhost

BLOCKS = " ▁▂▃▄▅▆▇█"
# dégradé bleu sombre -> cyan -> vert -> jaune -> rouge (couleurs 256)
RAMP = [232, 17, 18, 20, 26, 32, 39, 45, 51, 50, 46, 82, 118, 154, 190, 226, 220, 214, 208, 202, 196]


def parse_hz(s):
    s = str(s).strip().lower().replace(",", ".")
    mult = 1.0
    if s.endswith("k"): mult, s = 1e3, s[:-1]
    elif s.endswith("m"): mult, s = 1e6, s[:-1]
    elif s.endswith("g"): mult, s = 1e9, s[:-1]
    return float(s) * mult


class Sweeper(threading.Thread):
    """Pilote rtl_power et réassemble les balayages complets."""

    def __init__(self, lo, hi, binsize, gain, integration, crop):
        super().__init__(daemon=True)
        self.lo, self.hi = lo, hi
        # -c recadre les bords de chaque tranche, où le filtre du tuner
        # creuse des trous à la jonction entre deux pas de balayage
        # rtl_power tourne du côté du dongle ; seul son CSV traverse le réseau,
        # quelques ko/s, et il arrive ligne à ligne en temps réel.
        self.cmd = sdrhost.cmd(["rtl_power",
                                "-f", f"{lo:.0f}:{hi:.0f}:{binsize:.0f}",
                                "-c", str(crop),
                                "-g", str(gain), "-i", str(integration), "-"])
        self.lock = threading.Lock()
        self.sweep = None          # (freqs, dbs) du dernier balayage complet
        self.count = 0
        self.err = None
        self.proc = None
        self._chunks = {}
        self._stop = threading.Event()

    def run(self):
        try:
            self.proc = subprocess.Popen(
                self.cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, bufsize=1)
        except FileNotFoundError:
            self.err = ("ssh introuvable" if sdrhost.HOST
                        else "rtl_power introuvable (brew install librtlsdr)")
            return
        for line in self.proc.stdout:
            if self._stop.is_set():
                break
            self._feed(line)
        if self.proc.poll() not in (None, 0) and not self._stop.is_set():
            self.err = (f"rtl_power s'est arrêté sur {sdrhost.where()} "
                        "(dongle débranché ? hôte injoignable ?)")

    def _feed(self, line):
        parts = line.split(",")
        if len(parts) < 7:
            return
        try:
            low, step = float(parts[2]), float(parts[4])
            vals = [float(v) for v in parts[6:] if v.strip()]
        except ValueError:
            return
        # un low déjà vu = le balayage précédent est terminé
        if low in self._chunks:
            self._flush()
        self._chunks[low] = (step, vals)
        if max(self._chunks) + self._chunks[max(self._chunks)][0] * len(
                self._chunks[max(self._chunks)][1]) >= self.hi:
            self._flush()

    def _flush(self):
        if not self._chunks:
            return
        freqs, dbs = [], []
        for low in sorted(self._chunks):
            step, vals = self._chunks[low]
            freqs.extend(low + i * step for i in range(len(vals)))
            dbs.extend(vals)
        self._chunks = {}
        if len(dbs) < 8:
            return
        with self.lock:
            self.sweep = (freqs, dbs)
            self.count += 1

    def get(self):
        with self.lock:
            return self.sweep

    def stop(self):
        self._stop.set()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        # Tuer le ssh local laisse le rtl_power distant en vie, et il garderait
        # le dongle pour lui : il faut aller l'achever sur place.
        if sdrhost.HOST:
            sdrhost.free()


def to_columns(freqs, dbs, width):
    """Réduit les bins à `width` colonnes en gardant le max de chaque tranche."""
    n = len(dbs)
    if n == 0 or width <= 0:
        return [], []
    cols, cfreqs = [], []
    for c in range(width):
        a = c * n // width
        b = max(a + 1, (c + 1) * n // width)
        seg = dbs[a:b]
        cols.append(max(seg))
        cfreqs.append(freqs[a + seg.index(max(seg))])
    return cfreqs, cols


def find_peaks(freqs, dbs, floor, thresh_db, grid):
    """Maxima locaux au-dessus du plancher, agrégés sur la grille de canaux."""
    peaks = {}
    for i in range(1, len(dbs) - 1):
        v = dbs[i]
        if v - floor < thresh_db:
            continue
        if v >= dbs[i - 1] and v >= dbs[i + 1]:
            ch = round(freqs[i] / grid) * grid
            if ch not in peaks or v > peaks[ch]:
                peaks[ch] = v
    return sorted(peaks.items(), key=lambda kv: -kv[1])


def levels(cols, floor, ceil, height):
    """-> matrice [ligne][colonne] = (caractère, intensité 0..1), ligne 0 en haut."""
    span = max(ceil - floor, 1e-6)
    grid = [[(" ", 0.0)] * len(cols) for _ in range(height)]
    for c, v in enumerate(cols):
        frac = min(max((v - floor) / span, 0.0), 1.0)
        total = frac * height
        full = int(total)
        rest = total - full
        for r in range(full):
            grid[height - 1 - r][c] = ("█", frac)
        if full < height and rest > 0.05:
            grid[height - 1 - full][c] = (BLOCKS[max(1, int(rest * 8))], frac)
    return grid


def scale(dbs, min_range):
    """Plancher = quartile bas, plafond = crête, avec une plage minimale imposée.

    Sans la plage minimale, un spectre plat (pas d'antenne) s'auto-étire sur
    quelques dB et remplit tout l'écran, ce qui est illisible."""
    ordered = sorted(dbs)
    floor = ordered[len(ordered) // 4]
    return floor, max(ordered[-1], floor + min_range)


def axis_line(cfreqs, width):
    """Ligne d'échelle avec des repères en MHz espacés régulièrement."""
    if not cfreqs:
        return " " * width
    line = [" "] * width
    step = max(12, width // 8)
    for c in range(0, width, step):
        lbl = f"{cfreqs[min(c, len(cfreqs) - 1)] / 1e6:.1f}"
        pos = min(c, width - len(lbl))
        if pos >= 0 and all(line[pos + k] == " " for k in range(len(lbl))):
            line[pos:pos + len(lbl)] = list(lbl)
    return "".join(line)


def render_once(sw, args):
    """Rendu ANSI simple d'un balayage, sans curses."""
    term = shutil.get_terminal_size((100, 30))
    width = max(20, min(term.columns, 200)) - 8
    height = max(6, min(term.lines - 12, 20))
    freqs, dbs = sw
    cfreqs, cols = to_columns(freqs, dbs, width)
    floor, ceil = scale(dbs, args.range)
    grid = levels(cols, floor, ceil, height)
    out = []
    for r, row in enumerate(grid):
        db = ceil - (ceil - floor) * (r + 0.5) / height
        line = f"{db:6.1f} "
        for ch, frac in row:
            if ch == " ":
                line += " "
            else:
                line += f"\033[38;5;{RAMP[int(frac * (len(RAMP) - 1))]}m{ch}\033[0m"
        out.append(line)
    out.append(" " * 7 + axis_line(cfreqs, width))
    out.append("")
    peaks = find_peaks(freqs, dbs, floor, args.threshold, args.grid)
    if peaks:
        out.append(f"  {len(peaks)} canaux au-dessus de +{args.threshold:g} dB :")
        for f, v in peaks[:args.top]:
            out.append(f"    {f/1e6:8.2f} MHz   {v:7.1f} dB   +{v-floor:5.1f} dB")
    else:
        out.append(f"  Aucun canal à +{args.threshold:g} dB au-dessus du plancher "
                   f"({floor:.1f} dB) — antenne connectée ?")
    print("\n".join(out))


def tui(stdscr, sweeper, args):
    curses.curs_set(0)
    stdscr.nodelay(True)
    curses.start_color()
    curses.use_default_colors()
    usable = min(curses.COLORS, 256)
    pairs = []
    for i, col in enumerate(RAMP):
        idx = i + 1
        try:
            curses.init_pair(idx, col if col < usable else curses.COLOR_WHITE, -1)
            pairs.append(curses.color_pair(idx))
        except curses.error:
            pairs.append(curses.A_NORMAL)
    show_wf, show_peaks = True, True
    waterfall = deque(maxlen=64)
    last = -1
    while True:
        ch = stdscr.getch()
        if ch in (ord("q"), 27):
            return
        if ch == ord("w"):
            show_wf = not show_wf
        if ch == ord("p"):
            show_peaks = not show_peaks

        if sweeper.err:
            stdscr.erase()
            stdscr.addstr(1, 2, f"Erreur : {sweeper.err}"[:curses.COLS - 4])
            stdscr.addstr(3, 2, "q pour quitter")
            stdscr.refresh()
            time.sleep(0.2)
            continue

        sw = sweeper.get()
        if sw is None:
            stdscr.erase()
            stdscr.addstr(1, 2, "Premier balayage en cours…")
            stdscr.addstr(2, 2, f"  {sweeper.lo/1e6:.1f} – {sweeper.hi/1e6:.1f} MHz")
            stdscr.refresh()
            time.sleep(0.2)
            continue

        if sweeper.count != last:
            last = sweeper.count
            freqs, dbs = sw
            H, W = stdscr.getmaxyx()
            width = max(20, W - 8)
            floor, ceil = scale(dbs, args.range)
            peaks = find_peaks(freqs, dbs, floor, args.threshold, args.grid)
            npk = min(len(peaks), args.top) if show_peaks else 0
            wf_h = 10 if show_wf else 0
            spec_h = max(4, H - 4 - wf_h - (npk + 1 if npk else 0))
            cfreqs, cols = to_columns(freqs, dbs, width)
            waterfall.append((cols, floor, ceil))

            stdscr.erase()
            hdr = (f" FM scan  {sweeper.lo/1e6:.1f}–{sweeper.hi/1e6:.1f} MHz  "
                   f"gain {args.gain}  {sdrhost.where()}  balayage #{sweeper.count}  "
                   f"plancher {floor:.1f} dB  crête {ceil:.1f} dB")
            stdscr.addstr(0, 0, hdr[:W - 1], curses.A_REVERSE)

            row0 = 1
            for r, line in enumerate(levels(cols, floor, ceil, spec_h)):
                db = ceil - (ceil - floor) * (r + 0.5) / spec_h
                try:
                    stdscr.addstr(row0 + r, 0, f"{db:6.1f} ")
                except curses.error:
                    pass
                for c, (chr_, frac) in enumerate(line):
                    if chr_ == " ":
                        continue
                    try:
                        stdscr.addstr(row0 + r, 7 + c, chr_,
                                      pairs[int(frac * (len(pairs) - 1))])
                    except curses.error:
                        pass
            y = row0 + spec_h
            try:
                stdscr.addstr(y, 7, axis_line(cfreqs, min(width, W - 8)))
            except curses.error:
                pass
            y += 1

            if show_wf and wf_h:
                for r, (cols_, fl, ce) in enumerate(list(waterfall)[-wf_h:][::-1]):
                    span = max(ce - fl, 1e-6)
                    for c in range(min(len(cols_), W - 8)):
                        frac = min(max((cols_[c] - fl) / span, 0.0), 1.0)
                        try:
                            stdscr.addstr(y + r, 7 + c, "█",
                                          pairs[int(frac * (len(pairs) - 1))])
                        except curses.error:
                            pass
                y += min(wf_h, len(waterfall))

            if npk:
                try:
                    stdscr.addstr(y, 2, f"Canaux détectés (+{args.threshold:g} dB) :",
                                  curses.A_BOLD)
                except curses.error:
                    pass
                for i, (f, v) in enumerate(peaks[:npk]):
                    if y + 1 + i >= H - 1:
                        break
                    try:
                        stdscr.addstr(y + 1 + i, 4,
                                      f"{f/1e6:8.2f} MHz  {v:7.1f} dB  "
                                      f"+{v-floor:5.1f} dB")
                    except curses.error:
                        pass
            try:
                stdscr.addstr(H - 1, 0, " q quitter   w cascade   p pics "[:W - 1],
                              curses.A_REVERSE)
            except curses.error:
                pass
            stdscr.refresh()
        time.sleep(0.05)


def main():
    p = argparse.ArgumentParser(description="Scanner de spectre TUI pour RTL-SDR")
    p.add_argument("-f", "--freq", default="88M:108M",
                   help="bande basse:haute (défaut 88M:108M)")
    p.add_argument("-b", "--bin", default="25k", help="résolution (défaut 25k)")
    p.add_argument("-g", "--gain", default="40", help="gain tuner dB (défaut 40)")
    p.add_argument("-c", "--crop", default="20%",
                   help="recadrage des bords de tranche (défaut 20%%)")
    p.add_argument("-i", "--integration", default="1",
                   help="secondes par balayage (défaut 1)")
    p.add_argument("-t", "--threshold", type=float, default=6.0,
                   help="seuil de détection en dB au-dessus du plancher (défaut 6)")
    p.add_argument("-r", "--range", type=float, default=25.0,
                   help="plage verticale minimale en dB (défaut 25)")
    p.add_argument("--grid", type=float, default=100e3,
                   help="pas de la grille de canaux en Hz (défaut 100k)")
    p.add_argument("-n", "--top", type=int, default=12,
                   help="nombre de canaux listés (défaut 12)")
    p.add_argument("--once", action="store_true",
                   help="un seul balayage, sortie texte, puis quitte")
    sdrhost.add_host_arg(p)
    args = p.parse_args()
    sdrhost.use(args.host)

    try:
        lo, hi = (parse_hz(x) for x in args.freq.split(":"))
    except ValueError:
        sys.exit(f"bande invalide : {args.freq!r} (attendu 88M:108M)")
    if hi <= lo:
        sys.exit("la fréquence haute doit être supérieure à la basse")

    sweeper = Sweeper(lo, hi, parse_hz(args.bin), args.gain,
                      args.integration, args.crop)
    sweeper.start()
    try:
        if args.once:
            deadline = time.time() + 60
            while sweeper.get() is None and time.time() < deadline:
                if sweeper.err:
                    sys.exit(sweeper.err)
                time.sleep(0.1)
            sw = sweeper.get()
            if sw is None:
                sys.exit(f"aucun balayage reçu de {sdrhost.where()} "
                         "(dongle occupé par une autre appli ?)")
            render_once(sw, args)
        else:
            curses.wrapper(tui, sweeper, args)
    except KeyboardInterrupt:
        pass
    finally:
        sweeper.stop()


if __name__ == "__main__":
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    main()
