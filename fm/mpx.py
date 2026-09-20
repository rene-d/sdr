#!/usr/bin/env python3
"""Mesure les sous-porteuses du MPX d'une station FM.

Distingue une vraie station d'une image ou d'un produit d'intermodulation :
un pilote 19 kHz franc = vraie station stéréo, ni audio ni pilote = artefact.

    ./mpx.py 95.2 101.2 107.6
    ./mpx.py -H pi@pi4-sdr.local 95.2    # dongle sur un Pi distant ($SDR_HOST)
    ./mpx.py -g 20 87.6 101.2            # gain réduit si le tuner sature

La détection du 57 kHz (RDS) par ce biais n'est PAS fiable — utiliser redsea.
"""
import subprocess
import sys

import numpy as np

import sdrhost

RATE = 171000
SECONDS = 6
GAIN = '40'


def measure(freq: str) -> None:
    # timeout est lancé du côté du dongle : la capture s'arrête toute seule même
    # si le ssh meurt en route, sans laisser un rtl_fm accroché au dongle.
    raw = subprocess.run(sdrhost.cmd(
        ['timeout', str(SECONDS), 'rtl_fm', '-M', 'fm', '-l', '0', '-A', 'std',
         '-s', f'{RATE}', '-g', GAIN, '-F', '9', '-f', f'{freq}M', '-']),
        capture_output=True).stdout
    x = np.frombuffer(raw[:len(raw) // 2 * 2], dtype='<i2').astype(float)
    if len(x) < RATE:
        print(f'{freq:>6} MHz | capture trop courte ({len(x)} échantillons) '
              f'— dongle occupé sur {sdrhost.where()} ?')
        return
    x = x[len(x) // 4:]                      # jette le transitoire d'accord
    spec = 20 * np.log10(np.abs(np.fft.rfft(x * np.hanning(len(x)))) + 1e-9)
    fr = np.fft.rfftfreq(len(x), 1 / RATE)

    def band(lo: float, hi: float) -> float:
        m = (fr >= lo) & (fr <= hi)
        return spec[m].max() if m.any() else -99.0

    floor = band(70000, 84000)
    audio, pilot, rds = (band(300, 10000) - floor,
                         band(18900, 19100) - floor,
                         band(56600, 57400) - floor)
    verdict = 'stéréo' if pilot > 3 else ('mono' if audio > 5 else 'ARTEFACT ?')
    print(f'{freq:>6} MHz | audio {audio:5.1f} | pilote19k {pilot:5.1f} | '
          f'RDS57k {rds:5.1f} | {verdict}')


if __name__ == '__main__':
    argv = sys.argv[1:]
    while len(argv) > 1 and argv[0] in ('-H', '--host', '-g', '--gain'):
        # Un tuner qui sature invente des pilotes 19 kHz partout : sur une
        # antenne généreuse, descendre le gain avant de conclure « stéréo ».
        if argv[0] in ('-g', '--gain'):
            GAIN = argv[1]
        else:
            sdrhost.use(argv[1])
        argv = argv[2:]
    if not argv:
        sys.exit(__doc__)
    if any(c not in '0123456789. ' for c in ' '.join(argv)):
        sys.exit('fréquences attendues en MHz, ex. ./mpx.py 101.2 99.8')
    print(f'niveaux en dB au-dessus du plancher 70-84 kHz — gain {GAIN} — dongle '
          f'{sdrhost.where()}')
    try:
        for f in argv:
            measure(f)
    except KeyboardInterrupt:
        sdrhost.free()          # sinon le rtl_fm distant tient le dongle
        sys.exit(130)
