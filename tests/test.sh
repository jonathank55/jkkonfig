#!/bin/bash
# Selbsttests für jkkonfig.
#
# Alles läuft gegen Attrappen (tests/stubs) und ein Wegwerf-Heimatverzeichnis.
# Das echte System, die echten Einstellungen und AeroSpace bleiben unberührt.
#
#   tests/test.sh            alle Tests
#   tests/test.sh statisch   nur eine Gruppe (statisch, einaus, aerospace, theme, dock,
#                            anim, kompat, kacheln, pflege)
set -u

HIER=$(cd "$(dirname "$0")" && pwd)
WURZEL=$(cd "$HIER/.." && pwd)
JK=$WURZEL/bin/jkkonfig
PFAD_ORIGINAL=$PATH

OK=0
FEHL=0
T=

pruefe() {  # Beschreibung, Befehl ...
    local text=$1
    shift
    if "$@" >/dev/null 2>&1; then OK=$((OK + 1)); else FEHL=$((FEHL + 1)); printf 'FEHLER: %s\n' "$text"; fi
}

gleich() {  # Beschreibung, erwartet, erhalten
    if [ "$2" = "$3" ]; then OK=$((OK + 1))
    else FEHL=$((FEHL + 1)); printf 'FEHLER: %s\n  erwartet: %s\n  erhalten: %s\n' "$1" "$2" "$3"; fi
}

enthaelt() {  # Beschreibung, Text, Teilstring
    case $2 in
        *"$3"*) OK=$((OK + 1)) ;;
        *) FEHL=$((FEHL + 1)); printf 'FEHLER: %s\n  gesucht: %s\n  in: %s\n' "$1" "$3" "$2" ;;
    esac
}

fehlt() {  # Beschreibung, Text, Teilstring
    case $2 in
        *"$3"*) FEHL=$((FEHL + 1)); printf 'FEHLER: %s\n  unerwartet: %s\n' "$1" "$3" ;;
        *) OK=$((OK + 1)) ;;
    esac
}

neue_umgebung() {
    aufraeumen
    T=$(mktemp -d "${TMPDIR:-/tmp}/jkkonfig-test.XXXXXX")
    export HOME=$T/home STUB_ZUSTAND=$T/stub
    export XDG_CONFIG_HOME=$HOME/.config XDG_STATE_HOME=$HOME/.local/state
    export JKKONFIG_AEROSPACE=$HIER/stubs/aerospace
    export PATH="$HIER/stubs:$PFAD_ORIGINAL"
    mkdir -p "$HOME" "$STUB_ZUSTAND" "$T/bin"
    ZUSTAND=$XDG_STATE_HOME/jkkonfig
}

aufraeumen() {
    [ -n "$T" ] && [ -d "$T" ] && rm -rf "$T"
    T=
}

zaehle() {  # Anzahl Zeilen einer Datei, die ein Muster enthalten (fehlende Datei: 0)
    [ -f "$1" ] || { echo 0; return; }
    grep -c -F -- "$2" "$1" || true
}

# ------------------------------------------------------------------ statisch
test_statisch() {
    echo "== statisch"
    pruefe "bin/jkkonfig: Syntax unter /bin/bash 3.2" /bin/bash -n "$JK"
    pruefe "auto-tile.sh: Syntax" /bin/bash -n "$WURZEL/configs/aerospace/auto-tile.sh"
    pruefe "test.sh: Syntax" /bin/bash -n "$HIER/test.sh"
    local py
    for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 /Library/Developer/CommandLineTools/usr/bin/python3; do
        [ -x "$py" ] || continue
        pruefe "pflege.py: Syntax mit $("$py" --version 2>&1)" env PYTHONDONTWRITEBYTECODE=1 "$py" -c \
            "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$WURZEL/lib/pflege.py"
    done
    local treffer
    treffer=$(LC_ALL=C grep -n -E '\$[A-Za-z_][A-Za-z_0-9]*[^ -~]' "$JK" "$WURZEL/configs/aerospace/auto-tile.sh" 2>/dev/null)
    gleich "keine Variable direkt vor einem Nicht-ASCII-Zeichen (Locale-Falle)" "" "$treffer"
    treffer=$(grep -rn -E '/Users/[A-Za-z]|/home/[a-z]|api[_-]?key|secret|token' "$WURZEL/bin" "$WURZEL/lib" "$WURZEL/configs" "$WURZEL/tests" "$WURZEL/Brewfile" 2>/dev/null | grep -v 'tests/test.sh')
    gleich "keine persönlichen Pfade oder Schlüssel im Projekt" "" "$treffer"
    gleich "Tabelle: nur bekannte Gruppen" "" "$(awk -F'|' '/^[ \t]*(#|$)/ {next} {gsub(/[ \t]/,"",$1); if ($1!="arbeitsplatz" && $1!="komfort" && $1!="anim") print $0}' "$WURZEL/configs/macos/defaults.txt")"
    gleich "Tabelle: jede Zeile hat sieben Felder" "" "$(awk -F'|' '/^[ \t]*(#|$)/ {next} NF!=7 {print NR": "$0}' "$WURZEL/configs/macos/defaults.txt")"
    local g t
    g=/Applications/Ghostty.app/Contents/MacOS/ghostty
    if [ -x "$g" ]; then
        pruefe "Ghostty nimmt die Konfiguration an" "$g" +validate-config --config-file="$WURZEL/configs/ghostty/config"
        for t in "$WURZEL"/configs/ghostty/themes/*; do
            [ -f "$t" ] || continue
            pruefe "Ghostty nimmt Farbschema $(basename "$t") an" "$g" +validate-config --config-file="$t"
        done
    fi
    pruefe "TOML lässt sich lesen" python3 -c "import tomllib; tomllib.load(open('$WURZEL/configs/aerospace/aerospace.toml','rb'))"
}

# ------------------------------------------------------------- ein und aus
test_einaus() {
    echo "== ein und aus"
    local rel ausgabe rc
    neue_umgebung
    ausgabe=$("$JK" ein 2>&1)
    rc=$?
    gleich "ein: Rückgabewert" 0 "$rc"
    for rel in ghostty/config aerospace/aerospace.toml aerospace/auto-tile.sh; do
        pruefe "ein installiert $rel" cmp -s "$WURZEL/configs/$rel" "$HOME/.config/$rel"
        pruefe "Ausgangszustand vermerkt: $rel fehlte" test -e "$ZUSTAND/original/$rel.fehlt"
    done
    pruefe "auto-tile.sh ist ausführbar" test -x "$HOME/.config/aerospace/auto-tile.sh"
    gleich "Rand-Kacheln aus" 0 "$(defaults read com.apple.WindowManager EnableTilingByEdgeDrag)"
    gleich "oberes Rand-Kacheln aus" 0 "$(defaults read com.apple.WindowManager EnableTopTilingByEdgeDrag)"
    gleich "Drei-Finger-Wischen" 2 "$(defaults read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture)"
    gleich "KeyRepeat" 1 "$(defaults read NSGlobalDomain KeyRepeat)"
    gleich "InitialKeyRepeat" 10 "$(defaults read NSGlobalDomain InitialKeyRepeat)"
    gleich "eckige Fenster (NSConvolutionOverride1)" 0.0000001 "$(defaults read NSGlobalDomain NSConvolutionOverride1)"
    pruefe "ein installiert Autostart-Wächter" test -f "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"
    pruefe "Autostart-Wächter ist gültiges Plist" plutil -lint "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"
    enthaelt "ein: Autostart-Wächter wird geladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "launchctl bootstrap"
    enthaelt "ein: WindowManager wird neu gestartet" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "killall WindowManager"
    enthaelt "ein: AeroSpace-Konfiguration wird geladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "reload-config --no-gui"

    ausgabe=$("$JK" ein 2>&1)
    enthaelt "zweites ein: Dateien sind aktuell" "$ausgabe" "bereits aktuell"
    gleich "zweites ein legt keine Sicherung an" 0 "$(ls "$ZUSTAND/sicherungen" 2>/dev/null | wc -l | tr -d ' ')"

    echo "ABWEICHUNG" > "$HOME/.config/ghostty/config"
    "$JK" ein >/dev/null 2>&1
    pruefe "ein stellt die Vorlage wieder her" cmp -s "$WURZEL/configs/ghostty/config" "$HOME/.config/ghostty/config"
    gleich "ein sichert die abweichende Datei" "ABWEICHUNG" "$(cat "$ZUSTAND"/sicherungen/*/ghostty/config)"
    pruefe "Ausgangszustand bleibt unverändert" test -e "$ZUSTAND/original/ghostty/config.fehlt"

    ausgabe=$("$JK" aus 2>&1)
    gleich "aus: Rückgabewert" 0 "$?"
    for rel in ghostty/config aerospace/aerospace.toml aerospace/auto-tile.sh; do
        pruefe "aus lässt $rel installiert" cmp -s "$WURZEL/configs/$rel" "$HOME/.config/$rel"
    done
    pruefe "aus entfernt Autostart-Wächter" test ! -e "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"
    enthaelt "aus: Autostart-Wächter wird entladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "launchctl bootout"
    gleich "aus: Rand-Kacheln bleiben aus" 0 "$(defaults read com.apple.WindowManager EnableTilingByEdgeDrag)"
    gleich "aus: Drei-Finger-Wischen bleibt" 2 "$(defaults read com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture)"
    gleich "aus: Komfortwerte bleiben" 1 "$(defaults read NSGlobalDomain KeyRepeat)"
    pruefe "aus beendet AeroSpace" test -e "$STUB_ZUSTAND/as-gestoppt"

    # Installierte Konfigurationen bleiben nach aus unberührt
    neue_umgebung
    mkdir -p "$HOME/.config/ghostty" "$HOME/.config/aerospace"
    echo "ALT-GHOSTTY" > "$HOME/.config/ghostty/config"
    echo "ALT-AEROSPACE" > "$HOME/.config/aerospace/aerospace.toml"
    "$JK" ein >/dev/null 2>&1
    gleich "Ausgangszustand gesichert (Ghostty)" "ALT-GHOSTTY" "$(cat "$ZUSTAND/original/ghostty/config")"
    "$JK" ein >/dev/null 2>&1
    gleich "Ausgangszustand überlebt ein zweites ein" "ALT-GHOSTTY" "$(cat "$ZUSTAND/original/ghostty/config")"
    "$JK" aus >/dev/null 2>&1
    gleich "aus behält installierte Ghostty-Konfiguration" 0 "$(cmp -s "$WURZEL/configs/ghostty/config" "$HOME/.config/ghostty/config"; echo $?)"
    gleich "aus behält installierte AeroSpace-Konfiguration" 0 "$(cmp -s "$WURZEL/configs/aerospace/aerospace.toml" "$HOME/.config/aerospace/aerospace.toml"; echo $?)"
    pruefe "aus behält auto-tile.sh" test -x "$HOME/.config/aerospace/auto-tile.sh"
    "$JK" ein >/dev/null 2>&1
    gleich "ein nach aus funktioniert" 0 "$(cmp -s "$WURZEL/configs/ghostty/config" "$HOME/.config/ghostty/config"; echo $?)"

    # aus entfernt sämtliche Hintergrunddienste, auch wenn mehrere liefen
    neue_umgebung
    "$JK" ein >/dev/null 2>&1
    "$JK" theme auto ein >/dev/null 2>&1
    "$JK" dock aus >/dev/null 2>&1
    pruefe "alle drei Wächter sind installiert" \
        test -f "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist" \
           -a -f "$HOME/Library/LaunchAgents/com.jkkonfig.theme.plist" \
           -a -f "$HOME/Library/LaunchAgents/com.jkkonfig.dock.plist"
    "$JK" aus >/dev/null 2>&1
    pruefe "aus entfernt com.jkkonfig.agent" test ! -e "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"
    pruefe "aus entfernt com.jkkonfig.theme" test ! -e "$HOME/Library/LaunchAgents/com.jkkonfig.theme.plist"
    pruefe "aus entfernt com.jkkonfig.dock" test ! -e "$HOME/Library/LaunchAgents/com.jkkonfig.dock.plist"
    pruefe "aus löscht die Theme-Absicht" test ! -e "$ZUSTAND/theme_auto.aktiv"
    pruefe "aus löscht die Dock-Absicht" test ! -e "$ZUSTAND/dock"
    "$JK" ein >/dev/null 2>&1
    pruefe "erneutes ein aktiviert Theme nicht von allein" test ! -e "$ZUSTAND/theme_auto.aktiv"
    pruefe "erneutes ein richtet den Theme-Wächter nicht wieder ein" test ! -e "$HOME/Library/LaunchAgents/com.jkkonfig.theme.plist"

    # aus --trocken verändert nichts
    neue_umgebung
    "$JK" ein >/dev/null 2>&1
    "$JK" aus --trocken >/dev/null 2>&1
    pruefe "aus --trocken entfernt keinen Wächter" test -f "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"
    enthaelt "aus --trocken beendet kein AeroSpace" "$("$JK" aerospace status 2>&1)" "aktiv"

    # AeroSpace lehnt die Konfiguration ab: alles wird zurückgenommen
    neue_umgebung
    mkdir -p "$HOME/.config/aerospace"
    echo "ALT-AEROSPACE" > "$HOME/.config/aerospace/aerospace.toml"
    : > "$STUB_ZUSTAND/as-fehler"
    ausgabe=$("$JK" ein 2>&1)
    rc=$?
    gleich "abgelehnte Konfiguration: Rückgabewert 1" 1 "$rc"
    enthaelt "abgelehnte Konfiguration: Meldung" "$ausgabe" "AeroSpace lehnt die Konfiguration ab"
    gleich "abgelehnt: alte AeroSpace-Datei zurück" "ALT-AEROSPACE" "$(cat "$HOME/.config/aerospace/aerospace.toml")"
    pruefe "abgelehnt: neue Ghostty-Datei wieder weg" test ! -e "$HOME/.config/ghostty/config"
    pruefe "abgelehnt: neues Skript wieder weg" test ! -e "$HOME/.config/aerospace/auto-tile.sh"
    fehlt "abgelehnt: keine Einstellungen geschrieben" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "write com.apple.WindowManager"

    # Trockenlauf verändert nichts
    neue_umgebung
    "$JK" ein --trocken >/dev/null 2>&1
    pruefe "ein --trocken legt keine Konfiguration an" test ! -e "$HOME/.config"
    gleich "ein --trocken schreibt keine Einstellungen" 0 "$(zaehle "$STUB_ZUSTAND/aufrufe.log" 'write ')"
    pruefe "ein --trocken legt keinen Zustand an" test ! -e "$ZUSTAND"

    # Ohne AeroSpace läuft ein trotzdem durch
    neue_umgebung
    ausgabe=$(JKKONFIG_AEROSPACE= "$JK" ein 2>&1)
    gleich "ein ohne AeroSpace: Rückgabewert" 0 "$?"
    pruefe "ein ohne AeroSpace installiert Ghostty" cmp -s "$WURZEL/configs/ghostty/config" "$HOME/.config/ghostty/config"

    # status, diff, backup
    neue_umgebung
    "$JK" ein >/dev/null 2>&1
    ausgabe=$("$JK" status 2>&1)
    enthaelt "status zeigt Ghostty aktiv" "$ausgabe" "[AKTIV]"
    fehlt "status: nichts abweichend nach ein" "$ausgabe" "ABWEICHEND"
    echo x >> "$HOME/.config/ghostty/config"
    enthaelt "status erkennt Abweichung" "$("$JK" status 2>&1)" "ABWEICHEND"
    enthaelt "diff zeigt die Abweichung" "$("$JK" diff 2>&1)" "-x"
    "$JK" backup >/dev/null 2>&1
    gleich "backup sichert drei Dateien" 3 "$(find "$ZUSTAND/sicherungen" -type f | wc -l | tr -d ' ')"
    ausgabe=$("$JK" unsinn 2>&1)
    gleich "unbekannter Befehl: Rückgabewert 2" 2 "$("$JK" unsinn >/dev/null 2>&1; echo $?)"
    enthaelt "hilfe nennt die Befehle" "$("$JK" hilfe 2>&1)" "pflege"

    # AeroSpace automatisch starten, wenn gestoppt
    neue_umgebung
    : > "$STUB_ZUSTAND/as-gestoppt"
    ausgabe=$("$JK" status 2>&1)
    enthaelt "status: startet AeroSpace automatisch" "$ausgabe" "automatisch gestartet"
    enthaelt "status: ruft open -a AeroSpace auf" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"
    pruefe "status: AeroSpace läuft wieder" test ! -e "$STUB_ZUSTAND/as-gestoppt"

    # autostart Befehle
    ausgabe=$("$JK" autostart status 2>&1)
    gleich "autostart status: Rückgabewert 0" 0 "$?"
    ausgabe=$("$JK" autostart ein 2>&1)
    gleich "autostart ein: Rückgabewert 0" 0 "$?"
    pruefe "autostart ein: Plist vorhanden" test -f "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"
    ausgabe=$("$JK" autostart aus 2>&1)
    gleich "autostart aus: Rückgabewert 0" 0 "$?"
    pruefe "autostart aus: Plist entfernt" test ! -e "$HOME/Library/LaunchAgents/com.jkkonfig.agent.plist"

    # wachen
    : > "$STUB_ZUSTAND/as-gestoppt"
    "$JK" wachen >/dev/null 2>&1
    pruefe "wachen: startet AeroSpace" test ! -e "$STUB_ZUSTAND/as-gestoppt"
}

# ----------------------------------------------------------------- aerospace
test_aerospace() {
    echo "== aerospace (Abschaltung)"
    local ausgabe

    neue_umgebung
    "$JK" ein >/dev/null 2>&1
    ausgabe=$("$JK" aerospace status 2>&1)
    enthaelt "aerospace status: AeroSpace ist aktiv" "$ausgabe" "aktiv"

    "$JK" aerospace aus --trocken >/dev/null 2>&1
    pruefe "aerospace aus --trocken setzt keinen Schalter" test ! -e "$ZUSTAND/aerospace.aus"

    : > "$STUB_ZUSTAND/aufrufe.log"
    ausgabe=$("$JK" aerospace aus 2>&1)
    gleich "aerospace aus: Rückgabewert 0" 0 "$?"
    pruefe "aerospace aus: Schalter liegt" test -f "$ZUSTAND/aerospace.aus"
    enthaelt "aerospace aus: beendet AeroSpace" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "killall AeroSpace"
    fehlt "aerospace aus: startet AeroSpace nicht" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"
    enthaelt "aerospace aus: Meldung" "$ausgabe" "abgeschaltet"

    enthaelt "aerospace status: abgeschaltet" "$("$JK" aerospace status 2>&1)" "abgeschaltet"

    # Nichts startet AeroSpace mehr automatisch
    : > "$STUB_ZUSTAND/aufrufe.log"
    enthaelt "status zeigt die Abschaltung" "$("$JK" status 2>&1)" "abgeschaltet"
    fehlt "status startet AeroSpace nicht" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"
    pruefe "status lässt AeroSpace gestoppt" test -e "$STUB_ZUSTAND/as-gestoppt"

    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" wachen >/dev/null 2>&1
    pruefe "wachen startet AeroSpace nicht" test -e "$STUB_ZUSTAND/as-gestoppt"
    fehlt "wachen: kein open -a AeroSpace" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"

    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" ein >/dev/null 2>&1
    fehlt "ein startet AeroSpace nicht" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"
    fehlt "ein lädt AeroSpace nicht" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "reload-config"

    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" reload >/dev/null 2>&1
    fehlt "reload startet AeroSpace nicht" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"

    # Wieder einschalten
    ausgabe=$("$JK" aerospace ein 2>&1)
    gleich "aerospace ein: Rückgabewert 0" 0 "$?"
    pruefe "aerospace ein: Schalter entfernt" test ! -e "$ZUSTAND/aerospace.aus"
    enthaelt "aerospace ein: startet AeroSpace" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "open -a AeroSpace"
    pruefe "aerospace ein: AeroSpace läuft wieder" test ! -e "$STUB_ZUSTAND/as-gestoppt"
    enthaelt "aerospace status: wieder aktiv" "$("$JK" aerospace status 2>&1)" "aktiv"

    # Schalter ohne laufendes AeroSpace
    : > "$STUB_ZUSTAND/as-gestoppt"
    ausgabe=$("$JK" aerospace aus 2>&1)
    gleich "aerospace aus bei gestoppt: Rückgabewert 0" 0 "$?"
    pruefe "aerospace aus bei gestoppt: Schalter liegt" test -f "$ZUSTAND/aerospace.aus"
    fehlt "aerospace aus bei gestoppt beendet nichts" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "killall AeroSpace"

    gleich "aerospace mit falschem Argument: Rückgabewert 2" 2 "$("$JK" aerospace quatsch >/dev/null 2>&1; echo $?)"
    enthaelt "hilfe nennt aerospace" "$("$JK" hilfe 2>&1)" "aerospace"
}

# --------------------------------------------------------------------- theme
test_theme() {
    echo "== theme"
    local ausgabe rc
    neue_umgebung

    # Ohne Argument: Status und verfügbare Schemata
    ausgabe=$("$JK" theme 2>&1)
    rc=$?
    gleich "theme ohne Argument: Rückgabewert 0" 0 "$rc"
    enthaelt "theme zeigt Standard grau" "$ausgabe" "grau"
    enthaelt "theme nennt verfügbare Farbschemata" "$ausgabe" "grün"

    ausgabe=$("$JK" theme status 2>&1)
    gleich "theme status: Rückgabewert 0" 0 "$?"
    enthaelt "theme status zeigt grau" "$ausgabe" "grau"

    # Farbschema grün aktivieren
    ausgabe=$("$JK" theme grün 2>&1)
    gleich "theme grün: Rückgabewert 0" 0 "$?"
    enthaelt "theme grün: Erfolgsmeldung" "$ausgabe" "Farbschema »grün« aktiviert"
    pruefe "theme grün: Datei geschrieben" test -f "$HOME/.config/ghostty/config"
    pruefe "theme grün entspricht Vorlage gruen" cmp -s "$WURZEL/configs/ghostty/themes/gruen" "$HOME/.config/ghostty/config"
    gleich "theme grün im Zustand vermerkt" "gruen" "$(cat "$ZUSTAND/theme")"
    enthaelt "theme status zeigt nun grün" "$("$JK" theme status 2>&1)" "grün"
    enthaelt "jkkonfig status zeigt grün" "$("$JK" status 2>&1)" "(grün)"

    # Farbschema gruen (ohne Umlaut) ist bereits aktiv
    ausgabe=$("$JK" theme gruen 2>&1)
    gleich "theme gruen erneut: Rückgabewert 0" 0 "$?"
    enthaelt "theme gruen erneut: bereits aktiv" "$ausgabe" "bereits aktiv"

    # Farbschema rot aktivieren
    ausgabe=$("$JK" theme rot 2>&1)
    gleich "theme rot: Rückgabewert 0" 0 "$?"
    pruefe "theme rot entspricht Vorlage rot" cmp -s "$WURZEL/configs/ghostty/themes/rot" "$HOME/.config/ghostty/config"
    gleich "theme rot im Zustand vermerkt" "rot" "$(cat "$ZUSTAND/theme")"
    enthaelt "jkkonfig status zeigt rot" "$("$JK" status 2>&1)" "(rot)"

    # diff gegen das aktive Farbschema ist sauber
    gleich "diff zeigt keine Abweichung bei aktivem Theme" "" "$("$JK" diff | grep -E '^\+[^+]|^\-[^-]')"

    # Farbschema grau aktivieren
    ausgabe=$("$JK" theme grau 2>&1)
    gleich "theme grau: Rückgabewert 0" 0 "$?"
    pruefe "theme grau entspricht Vorlage grau" cmp -s "$WURZEL/configs/ghostty/themes/grau" "$HOME/.config/ghostty/config"
    gleich "theme grau im Zustand vermerkt" "grau" "$(cat "$ZUSTAND/theme")"

    # Trockenlauf verändert nichts
    neue_umgebung
    "$JK" theme rot --trocken >/dev/null 2>&1
    pruefe "theme --trocken legt keine Datei an" test ! -e "$HOME/.config/ghostty/config"
    pruefe "theme --trocken legt keinen Zustand an" test ! -e "$ZUSTAND/theme"

    # Fehlerfall bei unbekanntem Farbschema
    ausgabe=$("$JK" theme unbekannt 2>&1)
    rc=$?
    gleich "unbekanntes Farbschema: Rückgabewert 2" 2 "$rc"
    enthaelt "unbekanntes Farbschema: Fehlermeldung" "$ausgabe" "Unbekanntes Farbschema"

    # Schriftart und Schriftgröße abfragen und setzen
    ausgabe=$("$JK" schriftart 2>&1)
    gleich "schriftart status: Rückgabewert 0" 0 "$?"
    enthaelt "schriftart zeigt Kode Mono" "$ausgabe" "Kode Mono"

    ausgabe=$("$JK" schriftgröße 2>&1)
    gleich "schriftgröße status: Rückgabewert 0" 0 "$?"
    enthaelt "schriftgröße zeigt 18" "$ausgabe" "18"

    # Schriftgröße Trockenlauf
    ausgabe=$("$JK" schriftgröße 20 --trocken 2>&1)
    gleich "schriftgröße --trocken: Rückgabewert 0" 0 "$?"
    enthaelt "schriftgröße --trocken: Meldung" "$ausgabe" "würde"
    gleich "Schriftgröße blieb 18" "18" "$("$JK" schriftgröße 2>&1 | sed -n 's/.*Schriftgröße: //p')"

    # Fehlerfall ungültige Schriftgröße
    ausgabe=$("$JK" schriftgröße ungueltig 2>&1)
    gleich "ungültige Schriftgröße: Rückgabewert 2" 2 "$?"
    enthaelt "ungültige Schriftgröße: Fehlermeldung" "$ausgabe" "Ungültige Schriftgröße"

    # Schriftgröße und Schriftart ändern und wieder herstellen
    "$JK" schriftgröße 18 >/dev/null 2>&1
    "$JK" schriftart "Kode Mono" >/dev/null 2>&1

    # Automatische Farbschema-Umschaltung nach Tageszeit
    neue_umgebung
    local theme_plist=$HOME/Library/LaunchAgents/com.jkkonfig.theme.plist
    ausgabe=$("$JK" theme auto 2>&1)
    gleich "theme auto status: Rückgabewert 0" 0 "$?"
    enthaelt "theme auto status: inaktiv" "$ausgabe" "inaktiv"
    enthaelt "theme auto status: Standard 04:00" "$ausgabe" "04:00"
    enthaelt "theme auto status: Standard 18:00" "$ausgabe" "18:00"

    # Auto-Theme aktivieren
    ausgabe=$("$JK" theme auto ein 2>&1)
    gleich "theme auto ein: Rückgabewert 0" 0 "$?"
    pruefe "theme auto ein: Wächter-Datei vorhanden" test -f "$theme_plist"
    pruefe "theme auto ein: Wächter-Datei ist gültiges Plist" plutil -lint "$theme_plist"
    enthaelt "theme auto ein: Wächter ruft jkkonfig auf" "$(cat "$theme_plist")" "theme"
    enthaelt "theme auto ein: Wächter ruft auto anwenden auf" "$(cat "$theme_plist")" "anwenden"
    enthaelt "theme auto ein: Wächter wird geladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "launchctl bootstrap"
    pruefe "theme auto ein: Zustand aktiviert" test -f "$ZUSTAND/theme_auto.aktiv"

    # Umschaltzeiten ändern
    ausgabe=$("$JK" theme auto zeiten 06:00 22:00 gruen rot 2>&1)
    gleich "theme auto zeiten: Rückgabewert 0" 0 "$?"
    enthaelt "theme auto zeiten: Bestätigung" "$ausgabe" "06:00"
    enthaelt "theme auto zeiten: Nacht 22:00" "$ausgabe" "22:00"
    pruefe "theme auto zeiten: Konfigurationsdatei geschrieben" test -f "$ZUSTAND/theme_auto.conf"

    # Gezieltes Anwenden nach Uhrzeit
    "$JK" theme auto anwenden 12:00 >/dev/null 2>&1
    gleich "theme auto 12:00 -> grün" "gruen" "$(cat "$ZUSTAND/theme")"
    "$JK" theme auto anwenden 23:00 >/dev/null 2>&1
    gleich "theme auto 23:00 -> rot" "rot" "$(cat "$ZUSTAND/theme")"

    # Auto-Theme deaktivieren
    ausgabe=$("$JK" theme auto aus 2>&1)
    gleich "theme auto aus: Rückgabewert 0" 0 "$?"
    pruefe "theme auto aus: Wächter-Datei entfernt" test ! -e "$theme_plist"
    pruefe "theme auto aus: Zustand entfernt" test ! -e "$ZUSTAND/theme_auto.aktiv"
    enthaelt "theme auto aus: Wächter wird entladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "launchctl bootout"

    # Auto-Theme Trockenlauf
    "$JK" theme auto ein --trocken >/dev/null 2>&1
    pruefe "theme auto ein --trocken legt keinen Wächter an" test ! -e "$theme_plist"
    pruefe "theme auto ein --trocken legt keinen Zustand an" test ! -e "$ZUSTAND/theme_auto.aktiv"
}

# ---------------------------------------------------------------------- dock
test_dock() {
    echo "== dock"
    local plist
    neue_umgebung
    plist=$HOME/Library/LaunchAgents/com.jkkonfig.dock.plist
    "$JK" dock aus >/dev/null 2>&1
    gleich "dock aus: autohide" 1 "$(defaults read com.apple.dock autohide)"
    gleich "dock aus: delay" 3600 "$(defaults read com.apple.dock autohide-delay)"
    gleich "dock aus: modifier" 0 "$(defaults read com.apple.dock autohide-time-modifier)"
    gleich "dock aus: Absicht gespeichert" aus "$(cat "$ZUSTAND/dock")"
    pruefe "dock aus: Wächter-Datei vorhanden" test -f "$plist"
    pruefe "dock aus: Wächter-Datei ist gültiges Plist" plutil -lint "$plist"
    enthaelt "dock aus: Wächter beobachtet die Dock-Einstellungen" "$(cat "$plist")" "com.apple.dock.plist"
    enthaelt "dock aus: Wächter wird geladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "launchctl bootstrap"
    enthaelt "dock aus: Dock wird neu gestartet" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "killall Dock"
    enthaelt "dock status: versteckt" "$("$JK" dock status 2>&1)" "versteckt"

    # Abweichung, die der Wächter beheben muss
    defaults write com.apple.dock autohide-delay -float 0
    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" dock pruefen >/dev/null 2>&1
    gleich "dock pruefen stellt das Verstecken wieder her" 3600 "$(defaults read com.apple.dock autohide-delay)"
    enthaelt "dock pruefen startet das Dock neu" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "killall Dock"
    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" dock pruefen >/dev/null 2>&1
    gleich "dock pruefen tut nichts, wenn alles stimmt" 0 "$(zaehle "$STUB_ZUSTAND/aufrufe.log" 'killall')"

    "$JK" dock ein >/dev/null 2>&1
    gleich "dock ein: autohide" 0 "$(defaults read com.apple.dock autohide)"
    gleich "dock ein: delay gelöscht" "" "$(defaults read com.apple.dock autohide-delay 2>/dev/null)"
    gleich "dock ein: Absicht gespeichert" ein "$(cat "$ZUSTAND/dock")"
    pruefe "dock ein: Wächter-Datei entfernt" test ! -e "$plist"
    enthaelt "dock ein: Wächter wird entladen" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "launchctl bootout"
    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" dock pruefen >/dev/null 2>&1
    gleich "dock pruefen versteckt nichts, wenn die Absicht »ein« ist" 0 "$(zaehle "$STUB_ZUSTAND/aufrufe.log" 'write')"

    "$JK" dock umschalten >/dev/null 2>&1
    gleich "dock umschalten: sichtbar zu versteckt" 3600 "$(defaults read com.apple.dock autohide-delay)"
    "$JK" dock umschalten >/dev/null 2>&1
    gleich "dock umschalten: versteckt zu sichtbar" 0 "$(defaults read com.apple.dock autohide)"
    gleich "dock mit falschem Argument: Rückgabewert 2" 2 "$("$JK" dock quatsch >/dev/null 2>&1; echo $?)"

    # Bei ausgeschalteten Animationen bekommt ein sichtbares Dock Modifier 0
    "$JK" anim aus >/dev/null 2>&1
    "$JK" dock aus >/dev/null 2>&1
    "$JK" dock ein >/dev/null 2>&1
    gleich "dock ein bei Animationen aus: Modifier 0" 0 "$(defaults read com.apple.dock autohide-time-modifier)"
    neue_umgebung
    "$JK" dock aus --trocken >/dev/null 2>&1
    pruefe "dock aus --trocken legt keinen Wächter an" test ! -e "$HOME/Library/LaunchAgents"
    gleich "dock aus --trocken schreibt nichts" 0 "$(zaehle "$STUB_ZUSTAND/aufrufe.log" 'write')"
}

# ---------------------------------------------------------------------- anim
test_anim() {
    echo "== anim"
    neue_umgebung
    mkdir -p "$HOME/Library/Containers/com.apple.mail/Data/Library/Preferences"
    "$JK" anim aus >/dev/null 2>&1
    gleich "anim aus: Fensteranimation" 0 "$(defaults read NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"
    gleich "anim aus: Fenstergröße" 0.001 "$(defaults read NSGlobalDomain NSWindowResizeTime)"
    gleich "anim aus: WindowResizeTime" 0.001 "$(defaults read NSGlobalDomain WindowResizeTime)"
    gleich "anim aus: WindowManager AnimationSpeed" 0 "$(defaults read com.apple.WindowManager AnimationSpeed)"
    gleich "anim aus: Bewegung reduzieren" 1 "$(defaults read com.apple.universalaccess reduceMotion)"
    gleich "anim aus: Accessibility-Schlüssel" 1 "$(defaults read com.apple.Accessibility ReduceMotionEnabled)"
    gleich "anim aus: Mini-Effekt" scale "$(defaults read com.apple.dock mineffect)"
    gleich "anim aus: sichtbares Dock ohne Verzögerung" 0.0 "$(defaults read com.apple.dock autohide-delay)"
    gleich "anim aus: currentHost" 0 "$(defaults read host:NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"
    enthaelt "anim aus: Mail-Container wird beschrieben" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "Containers/com.apple.mail"
    enthaelt "anim aus: Dienste starten neu" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "killall Dock Finder SystemUIServer ControlCenter WindowManager"
    enthaelt "anim status: aus" "$("$JK" anim status 2>&1)" "aus"

    : > "$STUB_ZUSTAND/aufrufe.log"
    "$JK" anim aus >/dev/null 2>&1
    gleich "zweites anim aus startet nichts neu" 0 "$(zaehle "$STUB_ZUSTAND/aufrufe.log" 'killall')"

    "$JK" anim ein >/dev/null 2>&1
    gleich "anim ein: Fensteranimation" 1 "$(defaults read NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"
    gleich "anim ein: Fenstergröße gelöscht" "" "$(defaults read NSGlobalDomain NSWindowResizeTime 2>/dev/null)"
    gleich "anim ein: Mini-Effekt" genie "$(defaults read com.apple.dock mineffect)"
    gleich "anim ein: sichtbares Dock ohne Sonderwerte" "" "$(defaults read com.apple.dock autohide-delay 2>/dev/null)"

    # Ein verstecktes Dock bleibt auch bei anim ein/aus versteckt
    "$JK" dock aus >/dev/null 2>&1
    "$JK" anim aus >/dev/null 2>&1
    "$JK" anim ein >/dev/null 2>&1
    gleich "verstecktes Dock: delay bleibt 3600" 3600 "$(defaults read com.apple.dock autohide-delay)"
    gleich "verstecktes Dock: modifier bleibt 0" 0 "$(defaults read com.apple.dock autohide-time-modifier)"
    gleich "verstecktes Dock: autohide bleibt" 1 "$(defaults read com.apple.dock autohide)"

    # Die stille Wartung berührt keine sandboxed Apps
    neue_umgebung
    mkdir -p "$HOME/Library/Containers/com.apple.mail/Data/Library/Preferences"
    "$JK" defaults >/dev/null 2>&1
    fehlt "defaults (Wartung): kein Mail-Zugriff" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "com.apple.mail"
    fehlt "defaults (Wartung): kein Safari-Zugriff" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "com.apple.Safari"
    gleich "defaults (Wartung): Komfortwerte gesetzt" 10 "$(defaults read NSGlobalDomain InitialKeyRepeat)"
    gleich "defaults (Wartung): eckige Fenster gesetzt" 0.0000001 "$(defaults read NSGlobalDomain NSConvolutionOverride1)"
    gleich "defaults (Wartung): Animationszustand angeglichen" 1 "$(defaults read NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"
    fehlt "defaults (Wartung): berührt keine Arbeitsplatz-Werte" "$(cat "$STUB_ZUSTAND/aufrufe.log")" "EnableTilingByEdgeDrag"
    "$JK" anim aus --trocken >/dev/null 2>&1
    gleich "anim aus --trocken ändert nichts" 1 "$(defaults read NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"

    # Ein hängender defaults-Aufruf blockiert nicht alles (Frist je Domain)
    neue_umgebung
    local t0 dauer
    t0=$(date +%s)
    STUB_HAENGT=KeyRepeat JKKONFIG_ZEITLIMIT=2 "$JK" defaults >/dev/null 2>&1
    gleich "hängender defaults-Aufruf: Rückgabewert" 0 "$?"
    dauer=$(( $(date +%s) - t0 ))
    gleich "hängender defaults-Aufruf: endet nach der Frist (unter 10 s)" 1 "$([ "$dauer" -lt 10 ] && echo 1 || echo 0)"
    gleich "hängender defaults-Aufruf: andere Domains sind fertig" clmv "$(defaults read com.apple.finder FXPreferredViewStyle)"
    pkill -f 'sleep 97' 2>/dev/null
    sleep 1
    gleich "keine verwaisten Prozesse von jkkonfig" 0 "$(pgrep -f "$JK" 2>/dev/null | wc -l | tr -d ' ')"
}

# --------------------------------------------------------------------- kompat
test_kompat() {
    echo "== alte Namen"
    neue_umgebung
    ln -s "$JK" "$T/bin/optimi"
    ln -s "$JK" "$T/bin/dockhide"
    "$T/bin/optimi" -d aus >/dev/null 2>&1
    gleich "optimi -d aus: Dock versteckt" 3600 "$(defaults read com.apple.dock autohide-delay)"
    "$T/bin/optimi" -d ein >/dev/null 2>&1
    gleich "optimi -d ein: Dock sichtbar" 0 "$(defaults read com.apple.dock autohide)"
    "$T/bin/optimi" --anim aus >/dev/null 2>&1
    gleich "optimi --anim aus" 0 "$(defaults read NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"
    "$T/bin/optimi" --anim ein -d aus >/dev/null 2>&1
    gleich "optimi --anim ein -d aus: Animationen" 1 "$(defaults read NSGlobalDomain NSAutomaticWindowAnimationsEnabled)"
    gleich "optimi --anim ein -d aus: Dock" 1 "$(defaults read com.apple.dock autohide)"
    "$T/bin/dockhide" aus >/dev/null 2>&1
    gleich "dockhide aus macht das Dock sichtbar" 0 "$(defaults read com.apple.dock autohide)"
    "$T/bin/dockhide" ein >/dev/null 2>&1
    gleich "dockhide ein versteckt das Dock" 3600 "$(defaults read com.apple.dock autohide-delay)"
    enthaelt "dockhide status" "$("$T/bin/dockhide" status 2>&1)" "versteckt"
    "$T/bin/dockhide" toggle >/dev/null 2>&1
    gleich "dockhide toggle" 0 "$(defaults read com.apple.dock autohide)"
    gleich "dockhide daemon beendet sich still" 0 "$("$T/bin/dockhide" daemon >/dev/null 2>&1; echo $?)"
}

# -------------------------------------------------------------------- kacheln
# Führt auto-tile.sh gegen eine vorgegebene Fensterliste aus und liefert den eval-Befehl
kacheln() {  # Fensterliste (Zeilen id|ws|layout|root), neue Fenster-ID (leer: von Hand)
    printf '%s\n' "$1" > "$STUB_ZUSTAND/fenster.txt"
    : > "$STUB_ZUSTAND/eval.log"
    AEROSPACE_WINDOW_ID=$2 /bin/bash "$WURZEL/configs/aerospace/auto-tile.sh" >/dev/null 2>&1
    cat "$STUB_ZUSTAND/eval.log"
}

test_kacheln() {
    echo "== Kacheln (auto-tile.sh)"
    local e
    neue_umgebung
    export TMPDIR=$T/tmp/
    mkdir -p "$TMPDIR"

    e=$(kacheln "10|1|h_tiles|h_tiles" 10)
    gleich "1 Fenster: nichts tun" "" "$e"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles" 11)
    enthaelt "2 Fenster: Wurzel horizontal" "$e" "layout --workspace 1 --root horizontal"
    enthaelt "2 Fenster: ausgleichen" "$e" "balance-sizes --workspace 1"
    fehlt "2 Fenster: keine Verbindung" "$e" "join-with"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles
12|1|h_tiles|h_tiles" 12)
    enthaelt "3 Fenster: erst glätten" "$e" "flatten-workspace-tree --workspace 1"
    enthaelt "3 Fenster: Master links (erst rechts, sonst links verbinden)" "$e" "join-with --window-id 12 right || join-with --window-id 12 left"
    enthaelt "3 Fenster: ausgleichen" "$e" "balance-sizes --workspace 1"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|v_tiles|h_tiles
12|1|v_tiles|h_tiles
13|1|h_tiles|h_tiles" 13)
    enthaelt "4 Fenster: Raster (erst links, sonst rechts verbinden)" "$e" "join-with --window-id 13 left || join-with --window-id 13 right"
    fehlt "4 Fenster: nicht neu glätten" "$e" "flatten-workspace-tree"

    e=$(kacheln "10|1|v_tiles|h_tiles
11|1|v_tiles|h_tiles
12|1|v_tiles|h_tiles
13|1|v_tiles|h_tiles
14|1|h_tiles|h_tiles" 14)
    gleich "5 Fenster: AeroSpace-Standard, nichts tun" "" "$e"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles
12|1|floating|h_tiles" 12)
    gleich "neues Fenster schwebt: nichts tun" "" "$e"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles
12|1|floating|h_tiles
13|1|floating|h_tiles" 11)
    enthaelt "schwebende Fenster zählen nicht mit (2 gekachelte)" "$e" "layout --workspace 1 --root horizontal"
    fehlt "schwebende Fenster zählen nicht mit (kein Master-Stack)" "$e" "flatten"

    e=$(kacheln "10|1|h_accordion|h_accordion
11|1|h_accordion|h_accordion" 11)
    gleich "Akkordeon bleibt unangetastet" "" "$e"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles
20|2|h_tiles|h_tiles
21|2|h_tiles|h_tiles
22|2|h_tiles|h_tiles" 11)
    enthaelt "Workspace 1 wird getrennt gezählt" "$e" "layout --workspace 1 --root horizontal"
    fehlt "Workspace 2 bleibt außen vor" "$e" "workspace 2"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles" 99)
    gleich "unbekannte Fenster-ID (Fenster schon weg): nichts tun" "" "$e"

    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles" "")
    enthaelt "von Hand: 2 Fenster werden geordnet" "$e" "layout --workspace 1 --root horizontal"
    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles
12|1|h_tiles|h_tiles" "")
    gleich "von Hand: 3 Fenster brauchen ein neues Fenster, nichts tun" "" "$e"

    # Veraltete Sperre wird übergangen, frische schützt
    mkdir "$TMPDIR/jkkonfig-autotile.lock"
    touch -t 202001010000 "$TMPDIR/jkkonfig-autotile.lock"
    e=$(kacheln "10|1|h_tiles|h_tiles
11|1|h_tiles|h_tiles" 11)
    enthaelt "veraltete Sperre blockiert nicht" "$e" "layout --workspace 1"
    pruefe "Sperre wird am Ende freigegeben" test ! -e "$TMPDIR/jkkonfig-autotile.lock"
    unset TMPDIR
}

# --------------------------------------------------------------------- pflege
spawn_verwaist() {  # Skriptdatei: startet einen vom Terminal gelösten, verwaisten Python-Prozess
    python3 - "$1" <<'EOF'
import os, sys
pfad = sys.argv[1]
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        null = os.open("/dev/null", os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        os.execvp(sys.executable, [sys.executable, pfad])
    os._exit(0)
os.wait()
EOF
}

test_pflege() {
    echo "== pflege"
    local H alt neu ausgabe pid
    neue_umgebung
    H=$HOME
    export JKKONFIG_TMP=$T/tmp JKKONFIG_OHNE_DROSSELN=1
    mkdir -p "$JKKONFIG_TMP"
    alt=$(date -v-20d +%Y%m%d%H%M)
    neu=$(date +%Y%m%d%H%M)

    # Caches, Logs, Berichte
    mkdir -p "$H/Library/Caches/pip" "$H/.npm/_cacache" "$H/Library/Logs/DiagnosticReports"
    dd if=/dev/zero of="$H/Library/Caches/pip/gross.bin" bs=1048576 count=6 2>/dev/null
    dd if=/dev/zero of="$H/.npm/_cacache/gross.bin" bs=1048576 count=16 2>/dev/null
    echo alt > "$H/Library/Logs/alt.log";                    touch -t "$alt" "$H/Library/Logs/alt.log"
    echo neu > "$H/Library/Logs/neu.log"
    echo wartung > "$H/Library/Logs/system_maintenance.log"; touch -t "$alt" "$H/Library/Logs/system_maintenance.log"
    echo bericht > "$H/Library/Logs/DiagnosticReports/alt.ips"; touch -t "$alt" "$H/Library/Logs/DiagnosticReports/alt.ips"
    echo x > "$H/.zcompdump";     touch -t "$alt" "$H/.zcompdump"
    echo x > "$H/.zcompdump-neu"; touch -t "$neu" "$H/.zcompdump-neu"
    echo x > "$JKKONFIG_TMP/alt.pdf"; touch -t "$alt" "$JKKONFIG_TMP/alt.pdf"
    echo x > "$JKKONFIG_TMP/neu.pdf"

    # Projekt mit Git, schweren Ordnern, Resten
    git init -q "$H/proj"
    mkdir -p "$H/proj/node_modules" "$H/proj/dist" "$H/proj/build" "$H/proj/__pycache__"
    echo "dist/" > "$H/proj/.gitignore"
    : > "$H/proj/.DS_Store"
    : > "$H/proj/__pycache__/waise.cpython-39.pyc"
    : > "$H/proj/.git/objects/pack/tmp_pack_test"
    : > "$H/proj/q.txt"
    xattr -w com.apple.quarantine '0081;00000000;Test;' "$H/proj/q.txt"
    mkdir -p "$H/bin"
    printf '#!/bin/sh\n' > "$H/bin/werkzeug"
    xattr -w com.apple.quarantine '0081;00000000;Test;' "$H/bin/werkzeug"

    # SSH-Rechte
    mkdir -p "$H/.ssh"; chmod 755 "$H/.ssh"
    : > "$H/.ssh/id_test"; chmod 644 "$H/.ssh/id_test"

    # Datenbanken: eine frei, eine von einem Prozess offen gehalten
    mkdir -p "$H/Library/Application Support/Test"
    python3 - "$H/Library/Application Support/Test" <<'EOF'
import os, sqlite3, sys
for name in ("frei.sqlite", "gehalten.sqlite"):
    pfad = os.path.join(sys.argv[1], name)
    con = sqlite3.connect(pfad)
    con.execute("create table t(b blob)")
    con.executemany("insert into t values (?)", [(b"x" * 2048,) for _ in range(2000)])
    con.commit()
    con.execute("delete from t")
    con.commit()
    con.close()
EOF
    python3 -c "
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1]); con.execute('select count(*) from t').fetchone(); time.sleep(60)
" "$H/Library/Application Support/Test/gehalten.sqlite" >/dev/null 2>&1 &
    HALTER=$!
    local gr_frei_vorher gr_gehalten_vorher
    gr_frei_vorher=$(stat -f %z "$H/Library/Application Support/Test/frei.sqlite")
    gr_gehalten_vorher=$(stat -f %z "$H/Library/Application Support/Test/gehalten.sqlite")
    sleep 0.5

    # Verwaister Python-Prozess ohne Skript
    mkdir -p "$T/skripte"
    printf 'import time\ntime.sleep(120)\n' > "$T/skripte/weg.py"
    spawn_verwaist "$T/skripte/weg.py"
    sleep 0.5
    pid=$(pgrep -f "$T/skripte/weg.py" | head -1)
    rm -f "$T/skripte/weg.py"
    pruefe "Testprozess läuft" test -n "$pid"

    # Gegenprobe: ein Trockenlauf ändert nichts
    local vorher nachher
    vorher=$(find "$H" -type f | LC_ALL=C sort | xargs stat -f '%N %z %m' 2>/dev/null | md5)
    "$WURZEL/bin/jkkonfig" pflege --trocken >/dev/null 2>&1
    gleich "pflege --trocken: Rückgabewert" 0 "$?"
    nachher=$(find "$H" -type f | LC_ALL=C sort | xargs stat -f '%N %z %m' 2>/dev/null | md5)
    gleich "pflege --trocken verändert keine Datei" "$vorher" "$nachher"
    pruefe "pflege --trocken lässt den Prozess leben" kill -0 "$pid"
    pruefe "pflege --trocken schreibt kein Protokoll" test ! -e "$ZUSTAND/pflege.log"

    # Echter Lauf
    ausgabe=$("$WURZEL/bin/jkkonfig" pflege 2>&1)
    gleich "pflege: Rückgabewert" 0 "$?"
    enthaelt "pflege: Kopfzeile" "$ausgabe" "jkkonfig pflege |"
    fehlt "pflege: kein Baustein meldet einen Fehler" "$ausgabe" "err "
    pruefe "pflege: Protokoll geschrieben" test -s "$ZUSTAND/pflege.log"

    pruefe "pip-Cache geleert" test ! -e "$H/Library/Caches/pip/gross.bin"
    pruefe "npm-Cache geleert" test ! -e "$H/.npm/_cacache/gross.bin"
    pruefe "altes Log entfernt" test ! -e "$H/Library/Logs/alt.log"
    pruefe "neues Log bleibt" test -e "$H/Library/Logs/neu.log"
    pruefe "system_maintenance.log bleibt" test -e "$H/Library/Logs/system_maintenance.log"
    pruefe "alter Absturzbericht entfernt" test ! -e "$H/Library/Logs/DiagnosticReports/alt.ips"
    pruefe "alte zcompdump entfernt" test ! -e "$H/.zcompdump"
    pruefe "neue zcompdump bleibt" test -e "$H/.zcompdump-neu"
    pruefe "altes Temporäres entfernt" test ! -e "$JKKONFIG_TMP/alt.pdf"
    pruefe "neues Temporäres bleibt" test -e "$JKKONFIG_TMP/neu.pdf"

    pruefe ".DS_Store im Projekt entfernt" test ! -e "$H/proj/.DS_Store"
    pruefe "verwaiste .pyc entfernt" test ! -e "$H/proj/__pycache__/waise.cpython-39.pyc"
    pruefe "node_modules vom Spotlight abgeschirmt" test -e "$H/proj/node_modules/.metadata_never_index"
    pruefe "ignorierter dist-Ordner abgeschirmt" test -e "$H/proj/dist/.metadata_never_index"
    pruefe "nicht ignorierter build-Ordner bleibt unberührt" test ! -e "$H/proj/build/.metadata_never_index"
    pruefe "node_modules aus Time Machine ausgeschlossen" xattr -p com.apple.metadata:com_apple_backup_excludeItem "$H/proj/node_modules"
    pruefe "Quarantäne in ~/bin entfernt" test -z "$(xattr -p com.apple.quarantine "$H/bin/werkzeug" 2>/dev/null)"
    pruefe "Quarantäne im Projekt bleibt" xattr -p com.apple.quarantine "$H/proj/q.txt"
    enthaelt "git gc lief (Müll im Objektordner); git meldet: $(git -C "$H/proj" count-objects -v 2>&1 | tr '\n' ' ')" \
        "$(grep -E 'git|proj|Git' "$ZUSTAND/pflege.log")" "git gc: proj"

    gleich ".ssh auf 700" 700 "$(stat -f %Lp "$H/.ssh")"
    gleich "Schlüssel auf 600" 600 "$(stat -f %Lp "$H/.ssh/id_test")"

    gleich "freie Datenbank wurde verdichtet" 1 "$([ "$(stat -f %z "$H/Library/Application Support/Test/frei.sqlite")" -lt $((gr_frei_vorher / 4)) ] && echo 1 || echo 0)"
    gleich "von einem Prozess gehaltene Datenbank blieb unberührt" "$gr_gehalten_vorher" "$(stat -f %z "$H/Library/Application Support/Test/gehalten.sqlite")"
    sleep 0.3
    if kill -0 "$pid" 2>/dev/null; then FEHL=$((FEHL + 1)); echo "FEHLER: verwaister Prozess ohne Skript wurde nicht beendet"; kill "$pid" 2>/dev/null
    else OK=$((OK + 1)); fi
    gleich "Wartung stellt Komfortwerte her (Attrappe)" 10 "$(defaults read NSGlobalDomain InitialKeyRepeat)"
    kill "$HALTER" 2>/dev/null
    wait "$HALTER" 2>/dev/null

    # Auswahl und Fehlerfälle
    ausgabe=$("$WURZEL/bin/jkkonfig" pflege netz --trocken 2>&1)
    enthaelt "Auswahl: nur der gewählte Baustein" "$ausgabe" "Netzwerk & DNS"
    fehlt "Auswahl: kein anderer Baustein" "$ausgabe" "Git & Workspace"
    gleich "unbekannter Baustein: Rückgabewert 2" 2 "$("$WURZEL/bin/jkkonfig" pflege quatsch >/dev/null 2>&1; echo $?)"
    unset JKKONFIG_TMP JKKONFIG_OHNE_DROSSELN
}

# ------------------------------------------------------------------------ Lauf
GRUPPEN=${*:-statisch einaus aerospace theme dock anim kompat kacheln pflege}
for g in $GRUPPEN; do
    case $g in
        statisch|einaus|aerospace|theme|dock|anim|kompat|kacheln|pflege) "test_$g" ;;
        *) echo "unbekannte Gruppe: $g"; exit 2 ;;
    esac
done
aufraeumen
printf '\n%d Prüfungen bestanden, %d fehlgeschlagen\n' "$OK" "$FEHL"
[ "$FEHL" -eq 0 ]
