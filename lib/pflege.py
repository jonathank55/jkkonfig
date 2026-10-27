#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""jkkonfig pflege: Wartung für macOS.

Acht Bausteine laufen parallel: Einstellungen, Speicher und Prozesse,
Datenbanken, Caches, Index-Abschirmung, Git, Netzwerk und Sicherheit.
Nur die Standardbibliothek, Python 3.9 oder neuer.

Grundsätze:
  * Eigene Dateien und Daten Dritter bleiben unberührt: Caches, Logs und
    Temporäres werden bereinigt, Datenbanken nur, wenn keine App sie offen hat.
  * Alles Verändernde lässt sich mit --trocken vorab ansehen.
  * Eingriffe mit Nebenwirkungen (Netzwerkeinstellungen, Schrift- und
    Vorschau-Caches, Shader-Cache) gibt es nur mit --gruendlich.
"""
from __future__ import annotations

import ctypes
import datetime
import glob
import os
import plistlib
import re
import shlex
import shutil
import signal
import socket
import select
import sqlite3
import stat
import subprocess
import sys
import threading
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, wait

BAUSTEINE = [
    ("defaults", "UI & Defaults"),
    ("speicher", "Speicher & Prozesse"),
    ("datenbanken", "SQLite & CoreServices"),
    ("caches", "Caches & Speicherplatz"),
    ("index", "Dateisystem & Index"),
    ("git", "Git & Workspace"),
    ("netz", "Netzwerk & DNS"),
    ("sicherheit", "Sicherheit & Rechte"),
]

TTY = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
MIB = 1024 * 1024
GIB = 1024 * MIB


def farbe(code, text):
    return "\033[%sm%s\033[0m" % (code, text) if TTY else text


# ---------------------------------------------------------------- Grundlagen
class Bericht(object):
    def __init__(self, kennung, titel):
        self.kennung = kennung
        self.titel = titel
        self.status = "OK"
        self.zusammenfassung = ""
        self.details = []
        self.dauer = 0.0

    def d(self, text):
        self.details.append(text)


class Kontext(object):
    def __init__(self, trocken, gruendlich):
        self.trocken = trocken
        self.gruendlich = gruendlich
        self.home = os.path.expanduser("~")
        self.tmp = os.environ.get("JKKONFIG_TMP", "/tmp")  # überschreibbar für Tests
        self.uid = os.getuid()
        self.jetzt = time.time()
        self._projekte = None
        self._sperre = threading.Lock()

    def verb(self, getan, geplant):
        return geplant if self.trocken else getan

    def projekte(self):
        """Git-Projekte und schwere Verzeichnisse, einmal für alle Bausteine."""
        with self._sperre:
            if self._projekte is None:
                self._projekte = entdecke_projekte(self)
            return self._projekte


class Frist(object):
    def __init__(self, sekunden):
        self.ende = time.time() + sekunden

    def abgelaufen(self):
        return time.time() > self.ende


def lies(argv, timeout=10):
    """Führt einen Befehl aus und liefert (Rückgabewert, Ausgabe). Nie eine Ausnahme."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, errors="replace",
                           timeout=timeout, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError):
        return -1, ""


def kurz(pfad, home):
    return pfad.replace(home, "~", 1) if pfad.startswith(home) else pfad


def mb(bytes_):
    return round(bytes_ / MIB, 1)


def groesse(pfad, frist=None):
    summe = 0
    stapel = [pfad]
    while stapel:
        p = stapel.pop()
        try:
            with os.scandir(p) as it:
                for e in it:
                    try:
                        if e.is_symlink():
                            continue
                        if e.is_dir(follow_symlinks=False):
                            stapel.append(e.path)
                        else:
                            summe += e.stat(follow_symlinks=False).st_size
                    except OSError:
                        pass
        except OSError:
            pass
        if frist is not None and frist.abgelaufen():
            break
    return summe


def leeren(ctx, pfad, frist=None):
    """Leert ein Verzeichnis (der Ordner selbst bleibt). Liefert die Bytes."""
    if not os.path.isdir(pfad):
        return 0
    frei = 0
    try:
        eintraege = list(os.scandir(pfad))
    except OSError:
        return 0
    for e in eintraege:
        try:
            if e.is_symlink() or e.is_file(follow_symlinks=False):
                groesse_ = e.stat(follow_symlinks=False).st_size
                if not ctx.trocken:
                    os.remove(e.path)
                frei += groesse_
            elif e.is_dir(follow_symlinks=False):
                groesse_ = groesse(e.path, frist)
                if not ctx.trocken:
                    shutil.rmtree(e.path, ignore_errors=True)
                frei += groesse_
        except OSError:
            pass
    return frei


def entferne_datei(ctx, pfad):
    try:
        groesse_ = os.lstat(pfad).st_size
        if not ctx.trocken:
            os.remove(pfad)
        return groesse_
    except OSError:
        return None


# --------------------------------------------------------------- Telemetrie
class VMStat64(ctypes.Structure):
    _fields_ = [
        ("free_count", ctypes.c_uint32), ("active_count", ctypes.c_uint32),
        ("inactive_count", ctypes.c_uint32), ("wire_count", ctypes.c_uint32),
        ("zero_fill_count", ctypes.c_uint64), ("reactivations", ctypes.c_uint64),
        ("pageins", ctypes.c_uint64), ("pageouts", ctypes.c_uint64),
        ("faults", ctypes.c_uint64), ("cow_faults", ctypes.c_uint64),
        ("lookups", ctypes.c_uint64), ("hits", ctypes.c_uint64),
        ("purges", ctypes.c_uint64), ("purgeable_count", ctypes.c_uint32),
        ("speculative_count", ctypes.c_uint32), ("decompressions", ctypes.c_uint64),
        ("compressions", ctypes.c_uint64), ("swapins", ctypes.c_uint64),
        ("swapouts", ctypes.c_uint64), ("compressor_page_count", ctypes.c_uint32),
        ("throttled_count", ctypes.c_uint32), ("external_page_count", ctypes.c_uint32),
        ("internal_page_count", ctypes.c_uint32),
        ("total_uncompressed_pages_in_compressor", ctypes.c_uint64),
    ]


def telemetrie():
    """RAM (Mach-VM) und Datenträger ohne Unterprozesse."""
    t = {"ram_frei": 0, "ram_belegt": 0, "ram_fest": 0, "ram_komprimiert": 0,
         "ram_leerbar": 0, "swapins": 0, "swapouts": 0, "platte_frei": 0}
    try:
        st = os.statvfs("/")
        t["platte_frei"] = st.f_bavail * st.f_frsize
    except OSError:
        pass
    try:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        vm = VMStat64()
        anzahl = ctypes.c_uint32(ctypes.sizeof(vm) // 4)
        if lib.host_statistics64(lib.mach_host_self(), 4, ctypes.byref(vm), ctypes.byref(anzahl)) == 0:
            seite = os.sysconf("SC_PAGE_SIZE")
            # Spekulative Seiten sind in free_count bereits enthalten
            t["ram_frei"] = (vm.free_count + vm.inactive_count) * seite
            t["ram_belegt"] = (vm.active_count + vm.wire_count + vm.compressor_page_count) * seite
            t["ram_fest"] = vm.wire_count * seite
            t["ram_komprimiert"] = vm.compressor_page_count * seite
            t["ram_leerbar"] = vm.purgeable_count * seite
            t["swapins"] = int(vm.swapins)
            t["swapouts"] = int(vm.swapouts)
    except (OSError, AttributeError, ValueError):
        pass
    return t


# ------------------------------------------------------------ erweiterte Attribute
try:
    _LIBC = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    _LIBC.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    _LIBC.getxattr.restype = ctypes.c_ssize_t
    _LIBC.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                               ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    _LIBC.setxattr.restype = ctypes.c_int
    _LIBC.removexattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    _LIBC.removexattr.restype = ctypes.c_int
except OSError:
    _LIBC = None
XATTR_NOFOLLOW = 0x0001
TM_AUSSCHLUSS = b"com.apple.metadata:com_apple_backup_excludeItem"
QUARANTAENE = b"com.apple.quarantine"
TM_NUTZLAST = plistlib.dumps("com.apple.backupd", fmt=plistlib.FMT_BINARY)


def hat_xattr(pfad, name):
    return bool(_LIBC) and _LIBC.getxattr(os.fsencode(pfad), name, None, 0, 0, XATTR_NOFOLLOW) >= 0


def setze_xattr(pfad, name, wert):
    return bool(_LIBC) and _LIBC.setxattr(os.fsencode(pfad), name, wert, len(wert), 0, XATTR_NOFOLLOW) == 0


def entferne_xattr(pfad, name):
    return bool(_LIBC) and _LIBC.removexattr(os.fsencode(pfad), name, XATTR_NOFOLLOW) == 0


# ------------------------------------------------------- Projekte entdecken
SCHWER = {"node_modules", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
          ".vercel", ".gradle", ".venv", "venv", "__pycache__", ".pytest_cache",
          ".mypy_cache", ".ruff_cache", "DerivedData", "Pods"}
BAUORDNER = ("dist", "build", "out", "target")
HOME_UEBERSPRINGEN = {"Library", "Pictures", "Music", "Movies", "Public", "Applications",
                      ".Trash", ".local", ".gemini", ".npm", ".cache", ".bun", ".cargo",
                      ".rustup", ".nvm", ".pyenv"}
GLOBALE_CACHES = ["~/.npm", "~/.cache", "~/.bun", "~/.cargo/registry", "~/.local/share/pnpm",
                  "~/Library/Caches/Homebrew", "~/Library/Caches/pip"]


def git_ignoriert(repo, pfad):
    rc, _ = lies(["git", "-C", repo, "check-ignore", "-q", pfad], timeout=5)
    return rc == 0


def entdecke_projekte(ctx):
    """Liefert (Repositories, schwere Verzeichnisse) bis drei Ebenen unter dem Home."""
    home = ctx.home
    frist = Frist(25)
    repos, schwer = [], set()
    for g in GLOBALE_CACHES:
        g = os.path.expanduser(g)
        if os.path.isdir(g):
            schwer.add(g)
    for root, dirs, _ in os.walk(home):
        if frist.abgelaufen():
            break
        tiefe = root[len(home):].count(os.sep)
        if root == home:
            dirs[:] = [d for d in dirs if d not in HOME_UEBERSPRINGEN and not d.startswith(".")]
        if ".git" in dirs:
            repos.append(root)
            for name in BAUORDNER:
                pfad = os.path.join(root, name)
                if os.path.isdir(pfad) and git_ignoriert(root, pfad):
                    schwer.add(pfad)
        weiter = []
        for d in dirs:
            if d in SCHWER:
                schwer.add(os.path.join(root, d))
            elif d == ".git" or d.startswith("."):
                continue
            elif tiefe < 3:
                weiter.append(d)
        dirs[:] = weiter
    return sorted(set(repos)), sorted(schwer)


# ===================================================================== Bausteine
def baustein_defaults(ctx, b):
    exe = os.environ.get("JKKONFIG_BIN") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "bin", "jkkonfig")
    argv = [exe, "defaults"] + (["--trocken"] if ctx.trocken else [])
    rc, aus = lies(argv, timeout=120)
    zeilen = []
    for z in aus.splitlines():
        z = re.sub(r"\x1b\[[0-9;]*m", "", z).strip()
        z = re.sub(r"^(ok|warn|fehler|würde|\.\.)\s+", "", z)
        if z:
            zeilen.append(z)
            b.d(z)
    if rc != 0:
        b.status = "ERR"
        b.zusammenfassung = "jkkonfig defaults scheiterte (Rückgabewert %s)" % rc
        return
    b.zusammenfassung = "; ".join(zeilen) if zeilen else "keine Änderungen"


# --- Speicher und Prozesse
# Reine Last-Erzeuger im Hintergrund: laufen auf den Effizienzkernen
HINTERGRUND = {
    "mds_stores", "spotlightknowledged", "photoanalysisd", "mediaanalysisd", "suggestd",
    "ContextStoreAgent", "knowledge-agent", "parsec-fbf", "routined", "triald", "assistantd",
    "sirittsd", "biomeagent", "commerce", "studentd", "GoogleUpdater",
    "GoogleSoftwareUpdateAgent", "Keystone", "Microsoft Update Assistant",
    "OneDriveStandaloneUpdater",
}
# Synchronisations- und Zugriffsdienste: Drosseln verlangsamt iCloud, Fotos, Kalender
SYNC_DIENSTE = {"bird", "cloudd", "cloudphotod", "photolibraryd", "remindd", "calaccessd"}


def prozesse():
    rc, aus = lies(["ps", "-axo", "pid=,ppid=,uid=,tty=,stat=,nice=,rss=,command="], timeout=8)
    liste = []
    for zeile in aus.splitlines():
        t = zeile.split(None, 7)
        if len(t) < 8:
            continue
        try:
            liste.append((int(t[0]), int(t[1]), int(t[2]), t[3], t[4], int(t[5]), int(t[6]), t[7].strip()))
        except ValueError:
            continue
    return liste


def skriptpfad(befehl):
    """Das Python-Skript hinter einem Prozess, sofern eindeutig erkennbar."""
    try:
        teile = shlex.split(befehl)
    except ValueError:
        return None
    for t in teile[1:]:
        if t in ("-m", "-c"):
            return None
        if t.startswith("-"):
            continue
        return t if (t.endswith(".py") and os.path.isabs(t)) else None
    return None


def skript_fehlt(pfad):
    """Nur ein sicheres »gibt es nicht« zählt, keine Zugriffsfehler."""
    try:
        os.stat(pfad)
        return False
    except FileNotFoundError:
        return True
    except OSError:
        return False


def beende(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    except OSError:
        return False
    for _ in range(30):
        time.sleep(0.05)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except OSError:
            break
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    return True


def drossle(pid, nice_):
    ok = False
    if os.path.exists("/usr/sbin/taskpolicy"):
        rc, _ = lies(["/usr/sbin/taskpolicy", "-b", "-p", str(pid)], timeout=2)
        ok = rc == 0
    if nice_ < 10:
        try:
            os.setpriority(os.PRIO_PROCESS, pid, 15)
            ok = True
        except OSError:
            pass
    return ok


def baustein_speicher(ctx, b):
    vorher = telemetrie()
    prozs = prozesse()
    eltern = {p[0]: p[1] for p in prozs}
    geschuetzt = {1, os.getpid()}
    p = os.getpid()
    while p in eltern and eltern[p] > 1:
        p = eltern[p]
        geschuetzt.add(p)

    verwaist_aerc = {p[0] for p in prozs if os.path.basename(p[7].split(" ")[0]) == "aerc"
                     and p[1] == 1 and p[3] == "??"}
    beendet, zombies, freigegeben = 0, 0, 0
    ziele = []
    for pid, ppid, uid, tty, stat_, nice_, rss, cmd in prozs:
        if "Z" in stat_:
            zombies += 1
            continue
        if uid != ctx.uid or pid in geschuetzt:
            continue
        exe = os.path.basename(cmd.split(" ")[0])
        grund = None
        if pid in verwaist_aerc:
            grund = "verwaiste aerc-Sitzung"
        elif ("less -Rc" in cmd or "w3m -I" in cmd) and tty == "??" and (ppid in verwaist_aerc or ppid == 1):
            grund = "verwaister Pager"
        elif "QuickLookSatellite" in exe and rss > 256 * 1024:
            grund = "aufgeblähter QuickLookSatellite (%d MB)" % (rss // 1024)
        elif exe.lower().startswith("python") and ppid == 1 and tty == "??":
            skript = skriptpfad(cmd)
            if skript and skript_fehlt(skript):
                grund = "Skript gelöscht (%s)" % kurz(skript, ctx.home)
        if grund:
            if not ctx.trocken:
                beende(pid)
            beendet += 1
            freigegeben += rss
            b.d("%s: pid=%d rss=%dKB %s" % (ctx.verb("beendet", "würde beenden"), pid, rss, grund))
            continue
        if exe in HINTERGRUND or exe.startswith("mdworker") or (ctx.gruendlich and exe in SYNC_DIENSTE):
            ziele.append((pid, nice_, exe))

    if os.environ.get("JKKONFIG_OHNE_DROSSELN"):  # Haken für Tests: fremde Prozesse nie anfassen
        ziele = []
    gedrosselt = 0
    if ctx.trocken:
        gedrosselt = len(ziele)
        for pid, _, exe in ziele:
            b.d("würde drosseln: pid=%d %s" % (pid, exe))
    elif ziele:
        with ThreadPoolExecutor(max_workers=8) as pool:
            for (pid, _, exe), erfolg in zip(ziele, pool.map(lambda z: drossle(z[0], z[1]), ziele)):
                if erfolg:
                    gedrosselt += 1
                    b.d("gedrosselt: pid=%d %s" % (pid, exe))

    # Verwaiste Semaphore und Debug-Logs von toten Prozessen
    aktiv = {p[0] for p in prozs}
    bereinigt = 0
    gesehen = set()
    for muster in (ctx.tmp + "/sem.*", ctx.tmp + "/mat-debug-*.log"):
        for pfad in glob.glob(muster):
            real = os.path.realpath(pfad)
            if real in gesehen:
                continue
            gesehen.add(real)
            try:
                if os.lstat(pfad).st_uid != ctx.uid:
                    continue
            except OSError:
                continue
            m = re.search(r"(\d+)", os.path.basename(pfad))
            if m and int(m.group(1)) in aktiv:
                continue
            if entferne_datei(ctx, pfad) is not None:
                bereinigt += 1
                b.d("%s: %s" % (ctx.verb("entfernt", "würde entfernen"), pfad))

    rc, aus = lies(["sysctl", "-n", "kern.num_files", "kern.maxfiles"], timeout=3)
    werte = aus.split()
    dateien, maximum = (int(werte[0]), int(werte[1])) if len(werte) == 2 and all(w.isdigit() for w in werte) else (0, 0)
    prozent = round(dateien * 100.0 / maximum, 2) if maximum else 0.0

    nachher = telemetrie()
    teile = ["%d Daemons auf E-Cores" % gedrosselt,
             "%d Geisterprozesse %s" % (beendet, ctx.verb("beendet", "zu beenden"))]
    if freigegeben:
        teile[-1] += " (%s MB)" % mb(freigegeben * 1024)
    teile.append("Dateideskriptoren %s%% (%d)" % (prozent, dateien))
    if nachher["ram_frei"]:
        teile.append("RAM verfügbar %.2f GB (komprimiert %.2f GB)"
                     % (nachher["ram_frei"] / GIB, nachher["ram_komprimiert"] / GIB))
    b.d("vm_vorher: frei=%sMB belegt=%sMB fest=%sMB komprimiert=%sMB swapins=%d swapouts=%d" % (
        mb(vorher["ram_frei"]), mb(vorher["ram_belegt"]), mb(vorher["ram_fest"]),
        mb(vorher["ram_komprimiert"]), vorher["swapins"], vorher["swapouts"]))
    b.d("zombies=%d verwaiste_ipc=%d" % (zombies, bereinigt))
    b.zusammenfassung = ", ".join(teile)


# --- Datenbanken und Systemdienste
SQLITE_KOPF = b"SQLite format 3\x00"
DB_UEBERSPRINGEN = ("com.apple.TCC", "ProtectedCloudStorage", "Knowledge/knowledgeC.db",
                    ".enc.db", "CloudKit", "Keychains")
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")


def ist_sqlite(pfad):
    try:
        if not os.path.isfile(pfad) or os.path.islink(pfad):
            return False
        if not os.access(pfad, os.R_OK | os.W_OK):
            return False
        gr = os.path.getsize(pfad)
        if gr < 32768 or gr > 512 * MIB:
            return False
        with open(pfad, "rb") as f:
            return f.read(16) == SQLITE_KOPF
    except OSError:
        return False


def sqlite_kandidaten(ctx, frist):
    wurzeln = [os.path.join(ctx.home, "Library", "Application Support"),
               os.path.join(ctx.home, "Library", "Caches")]
    gefunden, gesehen = [], set()
    for wurzel in wurzeln:
        if not os.path.isdir(wurzel):
            continue
        basis = wurzel.rstrip(os.sep).count(os.sep)
        for root, dirs, files in os.walk(wurzel):
            if frist.abgelaufen():
                return gefunden
            if root.count(os.sep) - basis >= 3:
                dirs[:] = []
            if any(s in root for s in DB_UEBERSPRINGEN):
                dirs[:] = []
                continue
            for name in files:
                if not name.endswith((".db", ".sqlite", ".sqlite3")):
                    continue
                if any(s in name for s in DB_UEBERSPRINGEN):
                    continue
                pfad = os.path.join(root, name)
                if pfad not in gesehen and ist_sqlite(pfad):
                    gesehen.add(pfad)
                    gefunden.append(pfad)
    return gefunden


def offene_dateien(pfade):
    """Alle Dateien aus der Liste, die irgendein Prozess gerade offen hat."""
    offen = set()
    for i in range(0, len(pfade), 150):
        stueck = pfade[i:i + 150]
        rc, aus = lies(["lsof", "-w", "-n", "-P", "-F", "n", "--"] + stueck, timeout=40)
        if rc < 0:
            return None
        for z in aus.splitlines():
            if z.startswith("n"):
                offen.add(os.path.realpath(z[1:]))
    return offen


def db_belegung(pfad):
    uri = "file:" + urllib.parse.quote(pfad) + "?mode=ro"
    con = sqlite3.connect(uri, uri=True, timeout=0.05)
    try:
        frei = con.execute("PRAGMA freelist_count").fetchone()[0] or 0
        seite = con.execute("PRAGMA page_size").fetchone()[0] or 4096
        gesamt = con.execute("PRAGMA page_count").fetchone()[0] or 0
    finally:
        con.close()
    return frei * seite, gesamt * seite


def gesamtgroesse(pfad):
    summe = 0
    for suffix in ("", "-wal", "-shm"):
        try:
            summe += os.path.getsize(pfad + suffix)
        except OSError:
            pass
    return summe


def baustein_datenbanken(ctx, b):
    frist = Frist(45)
    kandidaten = sqlite_kandidaten(ctx, frist)
    offen = offene_dateien([os.path.realpath(p) for p in kandidaten]) if kandidaten else set()
    if offen is None:
        offen = set(os.path.realpath(p) for p in kandidaten)
        b.d("lsof nicht verfügbar: keine Datenbank wird angefasst")
    geprueft = verdichtet = journale = offene = 0
    gespart = 0
    for pfad in kandidaten:
        if frist.abgelaufen():
            b.status = "WARN"
            b.d("Zeitbudget erreicht, Rest übersprungen")
            break
        if os.path.realpath(pfad) in offen:
            offene += 1
            continue
        try:
            frei, gesamt = db_belegung(pfad)
        except sqlite3.Error:
            continue
        geprueft += 1
        lohnt = frei >= 256 * 1024 and gesamt > 0 and frei * 10 >= gesamt
        wal = pfad + "-wal"
        wal_gross = os.path.exists(wal) and os.path.getsize(wal) > 65536
        if not (lohnt or wal_gross):
            continue
        if ctx.trocken:
            if lohnt:
                verdichtet += 1
                gespart += frei
                b.d("würde verdichten: %s (frei %dKB)" % (kurz(pfad, ctx.home), frei // 1024))
            else:
                journale += 1
                b.d("würde Journal zusammenführen: %s" % kurz(pfad, ctx.home))
            continue
        vorher = gesamtgroesse(pfad)
        try:
            con = sqlite3.connect(pfad, timeout=0.05, isolation_level=None)
            try:
                if wal_gross:
                    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
                if lohnt:
                    pruefung = con.execute("PRAGMA quick_check(1)").fetchone()
                    if pruefung and pruefung[0] == "ok":
                        con.execute("VACUUM")
                con.execute("PRAGMA optimize")
            finally:
                con.close()
        except sqlite3.Error:
            continue
        diff = max(0, vorher - gesamtgroesse(pfad))
        if lohnt:
            verdichtet += 1
        else:
            journale += 1
        gespart += diff
        b.d("%s: %s vorher=%dKB nachher=%dKB" % (
            "verdichtet" if lohnt else "Journal zusammengeführt",
            kurz(pfad, ctx.home), vorher // 1024, (vorher - diff) // 1024))

    dienste = []
    if os.path.exists(LSREGISTER):
        if ctx.trocken:
            b.d("würde ausführen: lsregister -gc")
            dienste.append("LaunchServices-GC")
        else:
            rc, _ = lies([LSREGISTER, "-gc"], timeout=40)
            b.d("lsregister -gc: rc=%d" % rc)
            if rc == 0:
                dienste.append("LaunchServices-GC")
    if ctx.gruendlich:
        for name, argv in (("Font-Cache", ["atsutil", "databases", "-removeUser"]),
                           ("QuickLook", ["qlmanage", "-r", "cache"])):
            if ctx.trocken:
                b.d("würde ausführen: %s" % " ".join(argv))
                dienste.append(name)
            else:
                rc, _ = lies(argv, timeout=15)
                b.d("%s: rc=%d" % (" ".join(argv), rc))
                if rc == 0:
                    dienste.append(name)
    b.zusammenfassung = "%d Datenbanken geprüft (%d %s, %d Journale %s, %s MB frei), %d von Apps benutzte übersprungen, %s" % (
        geprueft, verdichtet, ctx.verb("verdichtet", "zu verdichten"), journale,
        ctx.verb("zusammengeführt", "zusammenzuführen"), mb(gespart), offene,
        "/".join(dienste) if dienste else "CoreServices geprüft")


# --- Caches und Speicherplatz
def baustein_caches(ctx, b):
    frist = Frist(90)
    jetzt = ctx.jetzt
    pakete, paket_bytes = 0, 0
    home = ctx.home

    brew_cache = os.path.join(home, "Library/Caches/Homebrew")
    vor = groesse(brew_cache, frist)
    brew = shutil.which("brew") or ("/opt/homebrew/bin/brew" if os.path.exists("/opt/homebrew/bin/brew") else None)
    if vor > 5 * MIB and brew:
        if ctx.trocken:
            b.d("würde ausführen: brew cleanup --prune=all -s (Cache %s MB)" % mb(vor))
            pakete += 1
            paket_bytes += vor
        else:
            lies([brew, "cleanup", "--prune=all", "-s"], timeout=90)
            delta = max(0, vor - groesse(brew_cache, frist))
            pakete += 1
            paket_bytes += delta
            b.d("brew cleanup: %dKB frei" % (delta // 1024))
    for name, pfad, schwelle in (
            ("pip", os.path.join(home, "Library/Caches/pip"), 5 * MIB),
            ("npm", os.path.join(home, ".npm/_cacache"), 15 * MIB),
            ("yarn", os.path.join(home, ".cache/yarn"), 10 * MIB),
            ("yarn", os.path.join(home, "Library/Caches/Yarn"), 10 * MIB),
            ("cocoapods", os.path.join(home, "Library/Caches/CocoaPods"), 10 * MIB)):
        if groesse(pfad, frist) > schwelle:
            frei = leeren(ctx, pfad, frist)
            pakete += 1
            paket_bytes += frei
            b.d("%s %s: %dKB" % (name, ctx.verb("bereinigt", "würde bereinigen"), frei // 1024))
    pnpm_store = os.path.join(home, ".local/share/pnpm/store")
    pnpm = shutil.which("pnpm")
    if pnpm and os.path.isdir(pnpm_store):
        vor = groesse(pnpm_store, frist)
        if vor > 50 * MIB:
            if ctx.trocken:
                b.d("würde ausführen: pnpm store prune (Store %s MB)" % mb(vor))
            else:
                lies([pnpm, "store", "prune"], timeout=60)
                delta = max(0, vor - groesse(pnpm_store, frist))
                paket_bytes += delta
                pakete += 1 if delta else 0
                b.d("pnpm store prune: %dKB frei" % (delta // 1024))

    system_bytes = 0
    teilcaches = [("geoservices", "Library/Caches/GeoServices"), ("helpd", "Library/Caches/com.apple.helpd"),
                  ("passkit", "Library/Caches/PassKit")]
    if ctx.gruendlich:
        teilcaches.append(("metal-shader", "Library/Caches/com.apple.metal"))
    for label, rel in teilcaches:
        pfad = os.path.join(home, rel)
        if groesse(pfad, frist) > MIB:
            frei = leeren(ctx, pfad, frist)
            system_bytes += frei
            b.d("%s %s: %dKB" % (label, ctx.verb("geleert", "würde leeren"), frei // 1024))

    derived = os.path.join(home, "Library/Developer/Xcode/DerivedData")
    if os.path.isdir(derived):
        for e in os.scandir(derived):
            try:
                if jetzt - e.stat().st_mtime > 7 * 86400:
                    gr = groesse(e.path, frist) if e.is_dir() else e.stat().st_size
                    if not ctx.trocken:
                        if e.is_dir():
                            shutil.rmtree(e.path, ignore_errors=True)
                        else:
                            os.remove(e.path)
                    system_bytes += gr
                    b.d("DerivedData %s: %s (%dKB)" % (ctx.verb("entfernt", "würde entfernen"), e.name, gr // 1024))
            except OSError:
                pass

    try:
        for e in os.scandir(home):
            if e.name.startswith(".zcompdump") and e.is_file():
                st = e.stat()
                if jetzt - st.st_mtime > 3 * 86400 or e.name.endswith(".bak"):
                    if entferne_datei(ctx, e.path) is not None:
                        system_bytes += st.st_size
                        b.d("%s: %s" % (ctx.verb("entfernt", "würde entfernen"), e.name))
    except OSError:
        pass
    for muster in (ctx.tmp + "/*.tmp", ctx.tmp + "/*.html", ctx.tmp + "/*.pdf"):
        for pfad in glob.glob(muster):
            try:
                st = os.lstat(pfad)
                if stat.S_ISREG(st.st_mode) and st.st_uid == ctx.uid and jetzt - st.st_mtime > 86400:
                    if entferne_datei(ctx, pfad) is not None:
                        system_bytes += st.st_size
            except OSError:
                pass

    berichte, logs, log_bytes = 0, 0, 0
    abstuerze = {}
    for basis in (os.path.join(home, "Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"):
        if not os.path.isdir(basis) or not os.access(basis, os.R_OK):
            continue
        for root, _, files in os.walk(basis):
            for name in files:
                if name.startswith("."):
                    continue
                pfad = os.path.join(root, name)
                try:
                    st = os.stat(pfad)
                    prozess = name.split("-")[0].split("_")[0].split(".")[0]
                    abstuerze[prozess] = abstuerze.get(prozess, 0) + 1
                    if (jetzt - st.st_mtime > 7 * 86400 or "Retired" in root) and os.access(pfad, os.W_OK):
                        if entferne_datei(ctx, pfad) is not None:
                            berichte += 1
                            log_bytes += st.st_size
                except OSError:
                    pass
    schleifen = sorted(((p, n) for p, n in abstuerze.items() if n >= 5), key=lambda x: -x[1])
    if schleifen:
        b.d("Absturzschleifen: " + ", ".join("%s:%d" % x for x in schleifen[:5]))
        b.status = "WARN"
    logwurzel = os.path.join(home, "Library/Logs")
    for root, _, files in os.walk(logwurzel):
        if "DiagnosticReports" in root:
            continue
        for name in files:
            if name == "system_maintenance.log" or not name.endswith((".log", ".old", ".asl", ".out", ".err")):
                continue
            pfad = os.path.join(root, name)
            try:
                st = os.stat(pfad)
                if jetzt - st.st_mtime > 14 * 86400 and entferne_datei(ctx, pfad) is not None:
                    logs += 1
                    log_bytes += st.st_size
            except OSError:
                pass

    # Lokale Time-Machine-Schnappschüsse dünnt macOS bei Platzmangel selbst aus.
    # Hier wird nur nachgeholfen, wenn der Datenträger knapp wird, und nie gelöscht.
    rc, aus = lies(["tmutil", "listlocalsnapshots", "/"], timeout=8)
    schnapp = [z.strip() for z in aus.splitlines() if "com.apple.TimeMachine" in z]
    frei_platte = telemetrie()["platte_frei"]
    ausgedunnt = False
    if schnapp and frei_platte < 20 * GIB:
        if ctx.trocken:
            b.d("würde ausdünnen: tmutil thinlocalsnapshots (%d Schnappschüsse, %.1f GB frei)" % (len(schnapp), frei_platte / GIB))
        else:
            lies(["tmutil", "thinlocalsnapshots", "/", "10000000000", "4"], timeout=30)
        ausgedunnt = True
    b.d("apfs_schnappschuesse: timemachine=%d ausgedünnt=%s frei=%.1fGB" % (len(schnapp), ausgedunnt, frei_platte / GIB))

    gesamt = paket_bytes + system_bytes + log_bytes
    b.zusammenfassung = "%s MB %s (Pakete: %s MB, System: %s MB, Logs/Absturzberichte: %d Dateien), Time-Machine-Schnappschüsse: %d%s" % (
        mb(gesamt), ctx.verb("bereinigt", "bereinigbar"), mb(paket_bytes), mb(system_bytes),
        berichte + logs, len(schnapp), " (ausgedünnt)" if ausgedunnt else "")
    if schleifen:
        b.zusammenfassung += ", Absturzschleifen: " + ", ".join("%s (%d)" % x for x in schleifen[:3])


# --- Dateisystem und Index
def baustein_index(ctx, b):
    repos, schwer = ctx.projekte()
    spot_neu = tm_neu = tm_gesamt = 0
    for pfad in schwer:
        if not os.path.isdir(pfad) or not os.access(pfad, os.W_OK):
            continue
        if os.path.basename(pfad) != "__pycache__":
            marke = os.path.join(pfad, ".metadata_never_index")
            if not os.path.exists(marke):
                if ctx.trocken:
                    spot_neu += 1
                    b.d("würde abschirmen: %s" % kurz(pfad, ctx.home))
                else:
                    try:
                        open(marke, "wb").close()
                        spot_neu += 1
                        b.d("Spotlight abgeschirmt: %s" % kurz(pfad, ctx.home))
                    except OSError:
                        pass
        if hat_xattr(pfad, TM_AUSSCHLUSS):
            tm_gesamt += 1
        elif ctx.trocken:
            tm_neu += 1
        elif setze_xattr(pfad, TM_AUSSCHLUSS, TM_NUTZLAST):
            tm_gesamt += 1
            tm_neu += 1
            b.d("Time Machine ausgeschlossen: %s" % kurz(pfad, ctx.home))

    # Quarantäne nur in den eigenen Programmordnern, .DS_Store in Projekten
    quarantaene = dsstore = 0
    for ordner in (os.path.join(ctx.home, "bin"), os.path.join(ctx.home, ".local", "bin")):
        if not os.path.isdir(ordner):
            continue
        for root, dirs, files in os.walk(ordner):
            dirs[:] = [d for d in dirs if d not in SCHWER and d != ".git"]
            for name in files:
                pfad = os.path.join(root, name)
                if os.path.islink(pfad) or not hat_xattr(pfad, QUARANTAENE):
                    continue
                if ctx.trocken or entferne_xattr(pfad, QUARANTAENE):
                    quarantaene += 1
                    b.d("%s: %s" % (ctx.verb("Quarantäne entfernt", "würde Quarantäne entfernen"), kurz(pfad, ctx.home)))
    for repo in repos:
        for root, dirs, files in os.walk(repo):
            dirs[:] = [d for d in dirs if d not in SCHWER and d != ".git"]
            if ".DS_Store" in files:
                if entferne_datei(ctx, os.path.join(root, ".DS_Store")) is not None:
                    dsstore += 1

    rc, aus = lies(["ps", "-axo", "%cpu=,comm="], timeout=4)
    cpu = 0.0
    for z in aus.splitlines():
        if "mds" in z or "mdworker" in z:
            try:
                cpu += float(z.split()[0].replace(",", "."))
            except (ValueError, IndexError):
                pass
    b.d("spotlight_cpu: %.1f%%" % cpu)
    b.zusammenfassung = "%d Build-/Cache-Ordner von Spotlight und Time Machine abgeschirmt (+%d neu), %d Quarantäne-Flags und %d .DS_Store %s (mds-Last %.1f%%)" % (
        len(schwer), spot_neu + tm_neu, quarantaene, dsstore, ctx.verb("entfernt", "zu entfernen"), cpu)


# --- Git und Workspace
GIT_MUSTER = r"(^|/)git( |$)"


def git_zaehlen(repo):
    try:
        r = subprocess.run(["git", "count-objects", "-v"], cwd=repo, capture_output=True, text=True,
                           timeout=8, stdin=subprocess.DEVNULL, errors="replace")
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    werte = {}
    for z in r.stdout.splitlines():
        if ":" in z:
            k, v = [x.strip() for x in z.split(":", 1)]
            if v.isdigit():
                werte[k] = int(v)
    return werte


def git_lauf(repo, args, timeout):
    try:
        r = subprocess.run(["git"] + args, cwd=repo, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, errors="replace")
        return r.returncode
    except (OSError, subprocess.SubprocessError):
        return -1


def baustein_git(ctx, b):
    repos, _ = ctx.projekte()
    frist = Frist(240)
    # Läuft gerade ein git-Befehl? Der Dauerläufer fsmonitor--daemon zählt nicht mit.
    rc, aus = lies(["pgrep", "-fl", GIT_MUSTER], timeout=3)
    git_aktiv = any("fsmonitor--daemon" not in z for z in aus.splitlines() if z.strip())
    geprueft = kompaktiert = sperren = 0
    gespart_kb = 0
    for repo in repos:
        if frist.abgelaufen():
            b.status = "WARN"
            b.d("Zeitbudget erreicht, Rest übersprungen")
            break
        git_dir = os.path.join(repo, ".git")
        if not os.path.isdir(git_dir):
            continue
        name = os.path.basename(repo)
        sperre = os.path.join(git_dir, "index.lock")
        if os.path.exists(sperre) and not git_aktiv:
            try:
                if ctx.jetzt - os.path.getmtime(sperre) > 300:
                    if entferne_datei(ctx, sperre) is not None:
                        sperren += 1
                        b.d("%s: %s" % (ctx.verb("veraltete Sperre entfernt", "würde veraltete Sperre entfernen"), kurz(sperre, ctx.home)))
            except OSError:
                pass
        z = git_zaehlen(repo)
        if z is None:
            continue
        geprueft += 1
        lose, pakete, muell = z.get("count", 0), z.get("packs", 0), z.get("garbage", 0)
        vor = z.get("size", 0) + z.get("size-pack", 0)
        # Standard-Verfallszeit (zwei Wochen) bleibt: kein --prune=now
        if (lose > 1000 or pakete > 10 or muell > 0) and not git_aktiv:
            if ctx.trocken:
                kompaktiert += 1
                b.d("würde kompaktieren: %s (%d lose Objekte, %d Pakete)" % (name, lose, pakete))
                continue
            git_lauf(repo, ["worktree", "prune"], 10)
            if git_lauf(repo, ["gc", "--quiet"], 180) == 0:
                kompaktiert += 1
                nach = git_zaehlen(repo) or {}
                danach = nach.get("size", 0) + nach.get("size-pack", 0)
                gespart_kb += max(0, vor - danach)
                b.d("git gc: %s vorher=%dKB nachher=%dKB" % (name, vor, danach))
        else:
            b.d("in Ordnung: %s (%dKB, %d lose, %d Pakete)" % (name, vor, lose, pakete))

    # Verwaiste .pyc-Dateien ohne Quelle
    pyc = 0
    for repo in repos:
        for root, dirs, _ in os.walk(repo):
            dirs[:] = [d for d in dirs if d not in {"node_modules", ".git", ".venv", "venv", "dist", "build", ".next"}]
            if "__pycache__" not in dirs:
                continue
            cache = os.path.join(root, "__pycache__")
            dirs.remove("__pycache__")
            try:
                for e in os.scandir(cache):
                    if e.is_file() and e.name.endswith(".pyc"):
                        modul = e.name.split(".")[0]
                        if not os.path.exists(os.path.join(root, modul + ".py")) and not os.path.exists(os.path.join(root, modul)):
                            if entferne_datei(ctx, e.path) is not None:
                                pyc += 1
                if not ctx.trocken and not os.listdir(cache):
                    shutil.rmtree(cache, ignore_errors=True)
            except OSError:
                pass
    b.zusammenfassung = "%d Git-Repos geprüft (%d %s, %d Sperren %s), %d verwaiste .pyc %s" % (
        geprueft, kompaktiert, ctx.verb("kompaktiert", "zu kompaktieren"), sperren,
        ctx.verb("gelöst", "zu lösen"), pyc, ctx.verb("entfernt", "zu entfernen"))


# --- Netzwerk und DNS
VORWAERMEN = ["apple.com", "icloud.com", "github.com", "api.github.com", "pypi.org",
              "registry.npmjs.org", "cloudflare.com", "cdn.jsdelivr.net"]


def netz_topologie(b):
    t = {"schnittstelle": "en0", "gateway": "unbekannt", "dienst": "Wi-Fi", "reihenfolge": [], "mtu": 1500, "dns": []}
    rc, aus = lies(["route", "-n", "get", "default"], timeout=3)
    m = re.search(r"interface:\s*([a-zA-Z0-9]+)", aus)
    if m:
        t["schnittstelle"] = m.group(1)
    m = re.search(r"gateway:\s*([0-9a-fA-F.:]+)", aus)
    if m:
        t["gateway"] = m.group(1)
    rc, aus = lies(["networksetup", "-listnetworkserviceorder"], timeout=3)
    aktuell = None
    for z in aus.splitlines():
        s = z.strip()
        m = re.match(r"^\(\d+\)\s+(.+)$", s)
        if m and not s.startswith("(Hardware"):
            aktuell = m.group(1).strip()
            t["reihenfolge"].append(aktuell)
        elif "Device:" in s and aktuell and "Device: %s)" % t["schnittstelle"] in s:
            t["dienst"] = aktuell
    rc, aus = lies(["networksetup", "-getMTU", t["dienst"]], timeout=3)
    m = re.search(r"Active MTU:\s*(\d+)", aus)
    if m:
        t["mtu"] = int(m.group(1))
    rc, aus = lies(["scutil", "--dns"], timeout=3)
    for z in aus.splitlines():
        if "nameserver[" in z and ":" in z:
            ip = z.split(":", 1)[1].strip()
            if ip and "." in ip and ip not in t["dns"]:
                t["dns"].append(ip)
    b.d("topologie: schnittstelle=%s dienst='%s' gateway=%s mtu=%d dns=%s" % (
        t["schnittstelle"], t["dienst"], t["gateway"], t["mtu"], ",".join(t["dns"][:4])))
    return t


def dns_laufzeit(server, timeout=0.6):
    anfrage = b"\x88\x99\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x05apple\x03com\x00\x00\x01\x00\x01"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setblocking(False)
    t0 = time.time()
    try:
        s.sendto(anfrage, (server, 53))
        bereit, _, _ = select.select([s], [], [], timeout)
        if bereit and len(s.recvfrom(512)[0]) >= 12:
            return round((time.time() - t0) * 1000.0, 1)
    except (OSError, ValueError):
        pass
    finally:
        s.close()
    return -1.0


def baustein_netz(ctx, b):
    t = netz_topologie(b)
    geaendert = []
    if ctx.gruendlich:
        dienst, reihe = t["dienst"], t["reihenfolge"]
        if reihe and dienst in reihe and reihe[0] != dienst:
            neu = [dienst] + [s for s in reihe if s != dienst]
            if ctx.trocken:
                b.d("würde Dienstreihenfolge ändern: '%s' an Position 1" % dienst)
            else:
                rc, _ = lies(["networksetup", "-ordernetworkservices"] + neu, timeout=5)
                b.d("Dienstreihenfolge: rc=%d" % rc)
            geaendert.append("Reihenfolge")
        rc, aus = lies(["networksetup", "-getinfo", dienst], timeout=4)
        hat_router = "IPv6 Router:" in aus and "IPv6 Router: none" not in aus
        if not hat_router and "IPv6: Link-local only" not in aus:
            if ctx.trocken:
                b.d("würde IPv6 auf »nur Link-local« stellen: %s" % dienst)
            else:
                rc, _ = lies(["networksetup", "-setv6linklocal", dienst], timeout=5)
                b.d("IPv6 Link-local: rc=%d" % rc)
            geaendert.append("IPv6")

    if ctx.trocken:
        b.d("würde ausführen: dscacheutil -flushcache")
    else:
        lies(["dscacheutil", "-flushcache"], timeout=4)
    ziel = t["dns"][0] if t["dns"] else "1.1.1.1"
    rtt = dns_laufzeit(ziel)
    if rtt < 0 and ziel != "1.1.1.1":
        rtt = dns_laufzeit("1.1.1.1")
    b.d("dns_rtt: server=%s ms=%s" % (ziel, rtt))

    def aufloesen(domain):
        try:
            socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)
            return True
        except OSError:
            return False

    with ThreadPoolExecutor(max_workers=len(VORWAERMEN)) as pool:
        gewaermt = sum(1 for ok in pool.map(aufloesen, VORWAERMEN) if ok)

    rc, aus = lies(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"], timeout=6)
    lauscher, offen, gesehen = 0, 0, set()
    for z in aus.splitlines()[1:]:
        teile = z.split()
        if len(teile) >= 9:
            schluessel = "%s:%s:%s" % (teile[0], teile[1], teile[8])
            if schluessel in gesehen:
                continue
            gesehen.add(schluessel)
            lauscher += 1
            if teile[8].startswith("*:") or teile[8].startswith("0.0.0.0:"):
                offen += 1
            b.d("lauscht: %s pid=%s %s" % (teile[0], teile[1], teile[8]))
    b.zusammenfassung = "%s (%s, MTU %d), DNS-Cache %s und %d/%d Domains vorgewärmt (RTT %s), %d Ports (%d Wildcard)%s" % (
        t["schnittstelle"], t["dienst"], t["mtu"], ctx.verb("geleert", "zu leeren"), gewaermt, len(VORWAERMEN),
        "%s ms" % rtt if rtt >= 0 else "n/a", lauscher, offen,
        ", geändert: " + "/".join(geaendert) if geaendert else "")


# --- Sicherheit und Rechte
def baustein_sicherheit(ctx, b):
    geprueft = gehaertet = 0
    home = ctx.home

    def haerten(pfad, soll):
        nonlocal geprueft, gehaertet
        try:
            modus = stat.S_IMODE(os.stat(pfad).st_mode)
        except OSError:
            return
        geprueft += 1
        if modus != soll:
            if not ctx.trocken:
                try:
                    os.chmod(pfad, soll)
                except OSError:
                    return
            gehaertet += 1
            b.d("%s: %s %s -> %s" % (ctx.verb("gehärtet", "würde härten"), kurz(pfad, home), oct(modus), oct(soll)))

    for d in (".ssh", ".gnupg", ".local/logs"):
        pfad = os.path.join(home, d)
        if os.path.isdir(pfad):
            haerten(pfad, 0o700)
    geheim = [os.path.join(home, p) for p in (".netrc", ".git-credentials", ".aws/credentials", ".aws/config")]
    ssh = os.path.join(home, ".ssh")
    if os.path.isdir(ssh):
        try:
            for name in os.listdir(ssh):
                if (name.startswith("id_") and not name.endswith(".pub")) or name in ("authorized_keys", "config"):
                    geheim.append(os.path.join(ssh, name))
        except OSError:
            pass
    for pfad in geheim:
        if os.path.isfile(pfad) and not os.path.islink(pfad):
            haerten(pfad, 0o600)
    for pfad in os.environ.get("PATH", "").split(os.pathsep):
        if pfad and os.path.isdir(pfad):
            try:
                modus = stat.S_IMODE(os.stat(pfad).st_mode)
            except OSError:
                continue
            geprueft += 1
            if modus & stat.S_IWOTH:
                haerten(pfad, modus & ~stat.S_IWOTH)

    kerne = 0
    if os.path.isdir("/cores"):
        try:
            for name in os.listdir("/cores"):
                pfad = os.path.join("/cores", name)
                if name.startswith("core.") and os.access(pfad, os.W_OK) and entferne_datei(ctx, pfad) is not None:
                    kerne += 1
        except OSError:
            pass

    plists = leer = kaputt = 0
    for ordner in (os.path.join(home, "Library/LaunchAgents"), "/Library/LaunchAgents", "/Library/LaunchDaemons"):
        try:
            namen = sorted(os.listdir(ordner))
        except OSError:
            continue
        for name in namen:
            if not name.endswith(".plist"):
                continue
            plists += 1
            pfad = os.path.join(ordner, name)
            try:
                with open(pfad, "rb") as f:
                    daten = plistlib.load(f)
                if not daten:
                    if os.access(pfad, os.W_OK) and entferne_datei(ctx, pfad) is not None:
                        leer += 1
                    continue
                prog = daten.get("Program")
                argumente = daten.get("ProgramArguments", [])
                ziel = prog or (argumente[0] if isinstance(argumente, list) and argumente else None)
                if ziel and ziel.startswith("/") and not os.path.exists(ziel):
                    kaputt += 1
                    b.d("LaunchAgent ohne Ziel: %s -> %s" % (kurz(pfad, home), ziel))
            except Exception:
                try:
                    if os.access(pfad, os.W_OK) and os.path.getsize(pfad) == 0 and entferne_datei(ctx, pfad) is not None:
                        leer += 1
                except OSError:
                    pass

    sip = filevault = gatekeeper = False
    rc, aus = lies(["csrutil", "status"], timeout=4)
    sip = "enabled" in aus.lower()
    rc, aus = lies(["fdesetup", "status"], timeout=4)
    filevault = "is on" in aus.lower()
    rc, aus = lies(["spctl", "--status"], timeout=4)
    gatekeeper = "enabled" in aus.lower()
    xprotect = "n/a"
    xp = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
    if os.path.exists(xp):
        try:
            with open(xp, "rb") as f:
                xprotect = str(plistlib.load(f).get("CFBundleShortVersionString", "aktiv"))
        except Exception:
            xprotect = "aktiv"
    b.d("macos_schutz: sip=%s filevault=%s gatekeeper=%s xprotect=%s" % (sip, filevault, gatekeeper, xprotect))
    marken = [n for n, an in (("SIP", sip), ("FileVault", filevault), ("Gatekeeper", gatekeeper)) if an]
    marken.append("XProtect v%s" % xprotect)
    b.status = "OK" if (sip and filevault) else "WARN"
    b.zusammenfassung = "%s aktiv, %d Pfade/Schlüssel geprüft (%d %s), %d LaunchAgents (%d %s, %d ohne Ziel)" % (
        "/".join(marken), geprueft, gehaertet, ctx.verb("gehärtet", "zu härten"), plists, leer,
        ctx.verb("bereinigt", "zu bereinigen"), kaputt)


FUNKTIONEN = {
    "defaults": baustein_defaults, "speicher": baustein_speicher, "datenbanken": baustein_datenbanken,
    "caches": baustein_caches, "index": baustein_index, "git": baustein_git,
    "netz": baustein_netz, "sicherheit": baustein_sicherheit,
}


def fuehre_aus(ctx, kennung, titel):
    b = Bericht(kennung, titel)
    t0 = time.time()
    try:
        FUNKTIONEN[kennung](ctx, b)
    except Exception as e:  # ein Baustein darf die anderen nie mitreißen
        b.status = "ERR"
        b.zusammenfassung = "Fehler: %s: %s" % (type(e).__name__, e)
        b.d("ausnahme: %s: %s" % (type(e).__name__, e))
    b.dauer = round(time.time() - t0, 2)
    return b


# ------------------------------------------------------------------ Protokoll
def schreibe_atomar(pfad, inhalt):
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    tmp = "%s.neu.%d" % (pfad, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(inhalt)
    os.replace(tmp, pfad)


def haenge_an(pfad, text, grenze=256 * 1024):
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    try:
        if os.path.getsize(pfad) > grenze:
            os.replace(pfad, pfad + ".1")
    except OSError:
        pass
    with open(pfad, "a", encoding="utf-8") as f:
        f.write(text)


def protokoll(modus, beginn, dauer, vor, nach, berichte):
    u = os.uname()
    zeilen = [
        "zeit=%s" % beginn, "modus=%s" % modus,
        "rechner=%s system=%s %s %s" % (u.nodename, u.sysname, u.release, u.machine),
        "uid=%d pid=%d dauer_s=%s" % (os.getuid(), os.getpid(), dauer),
        "ram_vorher: frei=%sMB belegt=%sMB fest=%sMB komprimiert=%sMB" % (
            mb(vor["ram_frei"]), mb(vor["ram_belegt"]), mb(vor["ram_fest"]), mb(vor["ram_komprimiert"])),
        "ram_nachher: frei=%sMB belegt=%sMB fest=%sMB komprimiert=%sMB" % (
            mb(nach["ram_frei"]), mb(nach["ram_belegt"]), mb(nach["ram_fest"]), mb(nach["ram_komprimiert"])),
        "platte: vorher_frei=%.2fGB nachher_frei=%.2fGB" % (vor["platte_frei"] / GIB, nach["platte_frei"] / GIB),
        "",
    ]
    for i, r in enumerate(berichte, 1):
        zeilen.append('[%d/%d] baustein=%s status=%s dauer_s=%s zusammenfassung="%s"' % (
            i, len(berichte), r.kennung, r.status, r.dauer, r.zusammenfassung))
        zeilen.extend("  " + d for d in r.details)
        zeilen.append("")
    return "\n".join(zeilen).rstrip() + "\n"


HILFE = """jkkonfig pflege: Wartung für macOS

Aufruf: jkkonfig pflege [Baustein ...] [--trocken] [--gruendlich]

Bausteine (ohne Angabe laufen alle):
  defaults     Komfortwerte setzen, Animationszustand angleichen
  speicher     Speicher prüfen, Geisterprozesse beenden, Hintergrunddienste drosseln
  datenbanken  SQLite-Datenbanken verdichten (nur wenn keine App sie offen hat), LaunchServices
  caches       Paket-, System- und Entwickler-Caches, alte Logs und Absturzberichte
  index        Spotlight- und Time-Machine-Abschirmung, .DS_Store, Quarantäne in ~/bin
  git          Repositories kompaktieren, veraltete Sperren lösen, verwaiste .pyc entfernen
  netz         DNS-Cache leeren und vorwärmen, Netzwerk und offene Ports prüfen
  sicherheit   Dateirechte, LaunchAgents, SIP, FileVault, Gatekeeper

Schalter:
  --trocken, -n   Nur anzeigen, was geschehen würde
  --gruendlich    Zusätzlich Eingriffe mit Nebenwirkungen: Dienstreihenfolge und IPv6
                  im Netzwerk, Schrift-, Vorschau- und Metal-Shader-Cache
  --hilfe, -h     Diese Hilfe
"""


def lies_argumente(argv):
    trocken = gruendlich = False
    auswahl = []
    bekannt = [k for k, _ in BAUSTEINE]
    for a in argv:
        if a in ("--trocken", "-n"):
            trocken = True
        elif a == "--gruendlich":
            gruendlich = True
        elif a in ("--hilfe", "-h", "--help"):
            print(HILFE)
            sys.exit(0)
        elif a.startswith("-"):
            sys.stderr.write("jkkonfig pflege: unbekannter Schalter %s (jkkonfig pflege --hilfe)\n" % a)
            sys.exit(2)
        elif a in bekannt:
            auswahl.append(a)
        else:
            sys.stderr.write("jkkonfig pflege: unbekannter Baustein »%s« (möglich: %s)\n" % (a, ", ".join(bekannt)))
            sys.exit(2)
    return trocken, gruendlich, auswahl


def main():
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(130))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(143))
    trocken, gruendlich, gewaehlt = lies_argumente(sys.argv[1:])
    auswahl = [(k, t) for k, t in BAUSTEINE if not gewaehlt or k in gewaehlt]

    ctx = Kontext(trocken, gruendlich)
    zustand = os.environ.get("JKKONFIG_ZUSTAND") or os.path.join(
        os.environ.get("XDG_STATE_HOME") or os.path.join(ctx.home, ".local", "state"), "jkkonfig")
    beginn = datetime.datetime.now().isoformat(timespec="seconds")
    t0 = time.time()
    vor = telemetrie()

    pool = ThreadPoolExecutor(max_workers=len(auswahl))
    futures = [pool.submit(fuehre_aus, ctx, k, t) for k, t in auswahl]
    fertig, offen = wait(futures, timeout=600)
    berichte = []
    for (k, t), f in zip(auswahl, futures):
        if f in fertig:
            berichte.append(f.result())
        else:
            r = Bericht(k, t)
            r.status, r.zusammenfassung, r.dauer = "ERR", "Zeitüberschreitung nach 600 s", 600.0
            berichte.append(r)
    nach = telemetrie()
    dauer = round(time.time() - t0, 2)

    modus = " ".join(filter(None, ["pflege", "trocken" if trocken else "", "gruendlich" if gruendlich else ""]))
    log = protokoll(modus, beginn, dauer, vor, nach, berichte)
    letztes = os.path.join(zustand, "pflege.log")
    if not trocken:
        try:
            schreibe_atomar(letztes, log)
            fehler = [r for r in berichte if r.status == "ERR"]
            if fehler:
                haenge_an(os.path.join(zustand, "pflege-fehler.log"),
                         "".join("[%s] %s: %s\n" % (beginn, r.kennung, r.zusammenfassung) for r in fehler))
        except OSError:
            pass

    delta = round((nach["platte_frei"] - vor["platte_frei"]) / MIB, 1)
    delta_text = " (%+.1f MB)" % delta if abs(delta) >= 0.5 else ""
    kopf = "jkkonfig pflege%s" % (" (Trockenlauf, nichts wird verändert)" if trocken else "")
    print("%s | RAM %.2f -> %.2f GB | SSD %.2f -> %.2f GB%s | %.2fs" % (
        farbe("1", kopf), vor["ram_frei"] / GIB, nach["ram_frei"] / GIB,
        vor["platte_frei"] / GIB, nach["platte_frei"] / GIB, delta_text, dauer))
    for r in berichte:
        marke = {"OK": farbe("32", "ok  "), "WARN": farbe("33", "warn")}.get(r.status, farbe("31", "err "))
        print("  %s  %-22s %s %s" % (marke, r.titel, r.zusammenfassung, farbe("2", "(%.2fs)" % r.dauer)))
    if trocken:
        for r in berichte:
            for d in r.details:
                if "würde" in d:
                    print("    %s" % d)
    else:
        print(farbe("2", "log: %s" % letztes))
    sys.stdout.flush()
    if offen:
        os._exit(0)
    return 0


if __name__ == "__main__":
    sys.exit(main())
