"""Aiguillage local / distant des commandes rtl_*, partagé par fmscan.py et mpx.py.

Pendant Python de sdr.sh : même variable SDR_HOST, mêmes conventions.

    SDR_HOST=pi@pi4-sdr.local ./fmscan.py     # dongle sur le Pi
    ./mpx.py -H pi@pi4-sdr.local 101.2 99.8   # idem, en option

SDR_HOST vide = dongle sur cette machine. Le démodulateur tourne toujours du
côté du dongle : seule sa sortie traverse le réseau (quelques ko/s de CSV pour
rtl_power, 342 ko/s de MPX pour rtl_fm -s 171k).
"""
import os
import shlex
import subprocess

HOST = os.environ.get("SDR_HOST", "")

# Multiplexage : une dizaine de connexions dans un mpx.py, 350 ms la première
# puis 40 ms les suivantes.
SSH_OPTS = ["-o", "ConnectTimeout=8",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=/tmp/.sdr-ssh-%r@%h-%p",
            "-o", "ControlPersist=60"]

# Noms exacts des binaires qui monopolisent le dongle, pour pgrep -x.
# « pgrep -f rtl_ » ne convient pas à distance : le motif figure dans la ligne de
# commande du shell lancé par ssh, le pgrep se trouve lui-même.
PROCS = r"rtl_(fm|power|sdr|tcp|test|adsb|biast)"


def where(host=None):
    return (HOST if host is None else host) or "local"


def cmd(argv, host=None):
    """La commande à lancer ici pour que `argv` s'exécute du côté du dongle."""
    h = HOST if host is None else host
    if not h:
        return list(argv)
    return ["ssh", "-n", *SSH_OPTS, h,
            " ".join(shlex.quote(str(a)) for a in argv)]


def _rc(argv, host=None):
    return subprocess.run(cmd(argv, host), stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode


def busy(host=None):
    """Un rtl_* tient-il déjà le dongle ? Il rendrait la capture vide."""
    return _rc(["pgrep", "-x", PROCS], host) == 0


def free(host=None):
    """Libère le dongle. Indispensable à distance : tuer le ssh local ne tue pas
    la commande distante, elle survit et garde le dongle (voir README)."""
    _rc(["pkill", "-x", PROCS], host)


def add_host_arg(parser):
    parser.add_argument("-H", "--host", default=HOST, metavar="USER@HÔTE",
                        help="machine où est branché le dongle, par ssh "
                             "(défaut : $SDR_HOST, vide = locale)")


def use(host):
    """Fixe la machine choisie sur la ligne de commande."""
    global HOST
    HOST = host or ""
