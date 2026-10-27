#!/bin/bash
# Livetest des automatischen Kachelns mit echten Fenstern.
#
# Öffnet nacheinander vier TextEdit-Fenster (und danach den Rechner) auf einem LEEREN
# Workspace, prüft nach jedem Schritt die Anordnung, misst, wie lange AeroSpace samt
# auto-tile.sh dafür braucht, und räumt auf: nur die selbst geöffneten Fenster werden
# geschlossen, der Fokus kehrt zum ursprünglichen Workspace zurück.
#
# Sinnvoll nach jedem AeroSpace-Update. Aufruf: tests/live.sh [Workspace, Vorgabe 9]
set -u

AS=$(command -v aerospace) || { echo "aerospace nicht gefunden"; exit 2; }
WS=${1:-9}
ORIG=$("$AS" list-workspaces --focused 2>/dev/null) || { echo "AeroSpace läuft nicht"; exit 2; }
TMP=${TMPDIR:-/tmp}
TMP=${TMP%/}/jkkonfig-live.$$

if [ "$("$AS" list-windows --workspace "$WS" --count 2>/dev/null)" != 0 ]; then
    echo "Workspace $WS ist nicht leer, der Test läuft nur auf einem leeren Workspace"
    exit 2
fi
pgrep -x TextEdit >/dev/null 2>&1 && TEXTEDIT_VORHER=1 || TEXTEDIT_VORHER=0

OK=0
FEHL=0

aufraeumen() {
    local id
    trap - EXIT INT TERM
    for id in $("$AS" list-windows --workspace "$WS" --format '%{window-id}' 2>/dev/null); do
        if [ "$TEXTEDIT_VORHER" = 0 ]; then "$AS" close --quit-if-last-window --window-id "$id" >/dev/null 2>&1
        else "$AS" close --window-id "$id" >/dev/null 2>&1; fi
        sleep 0.15
    done
    rm -rf "$TMP"
    "$AS" workspace "$ORIG" >/dev/null 2>&1
}
trap aufraeumen EXIT INT TERM

jetzt() { python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || echo 0; }

form() { "$AS" list-windows --workspace "$WS" --format '%{window-layout}' 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
wurzel() { "$AS" list-windows --workspace "$WS" --format '%{workspace-root-container-layout}' 2>/dev/null | head -1; }
anzahl() { "$AS" list-windows --workspace "$WS" --count 2>/dev/null; }

# Wartet bis zu 6 s auf die erwartete Form und liefert die Millisekunden seit $1
warte_auf() {  # Startzeit, erwartete Form
    local t0=$1 soll=$2 i=0
    while [ "$i" -lt 300 ]; do
        [ "$(form)" = "$soll" ] && { echo $(( $(jetzt) - t0 )); return 0; }
        sleep 0.02
        i=$((i + 1))
    done
    echo -1
    return 1
}

schritt() {  # Datei, erwartete Anzahl, erwartete Form, Beschreibung
    local t0 ms
    t0=$(jetzt)
    open -a TextEdit "$1"
    ms=$(warte_auf "$t0" "$3")
    if [ "$ms" -ge 0 ] && [ "$(anzahl)" = "$2" ] && [ "$(wurzel)" = h_tiles ]; then
        OK=$((OK + 1))
        printf 'ok      %-34s nach %s ms\n' "$4" "$ms"
    else
        FEHL=$((FEHL + 1))
        printf 'FEHLER  %-34s erwartet »%s« (Wurzel h_tiles), erhalten »%s« (Wurzel %s, %s Fenster)\n' "$4" "$3" "$(form)" "$(wurzel)" "$(anzahl)"
    fi
    sleep 0.3
}

mkdir -p "$TMP"
for n in 1 2 3 4; do printf 'Testfenster %s\n' "$n" > "$TMP/fenster$n.txt"; done

"$AS" workspace "$WS" >/dev/null 2>&1
sleep 0.5

schritt "$TMP/fenster1.txt" 1 "h_tiles"                              "1 Fenster: Vollbild"
schritt "$TMP/fenster2.txt" 2 "h_tiles h_tiles"                      "2 Fenster: nebeneinander"
schritt "$TMP/fenster3.txt" 3 "h_tiles v_tiles v_tiles"              "3 Fenster: Master links, Stack rechts"
schritt "$TMP/fenster4.txt" 4 "v_tiles v_tiles v_tiles v_tiles"      "4 Fenster: 2x2-Raster"

# Ein schwebendes Fenster darf die Anordnung nicht stören
vorher=$(form)
open -a Calculator
sleep 1.5
nachher=$(form)
if [ "$(anzahl)" = 5 ] && [ "$nachher" = "floating $vorher" ]; then
    OK=$((OK + 1)); printf 'ok      %-34s Raster unverändert\n' "Rechner schwebt"
else
    FEHL=$((FEHL + 1)); printf 'FEHLER  Rechner schwebt nicht wie erwartet: vorher »%s«, nachher »%s« (%s Fenster)\n' "$vorher" "$nachher" "$(anzahl)"
fi

printf '\n%d Prüfungen bestanden, %d fehlgeschlagen\n' "$OK" "$FEHL"
[ "$FEHL" -eq 0 ]
