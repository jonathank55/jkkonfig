#!/bin/bash
# auto-tile.sh: ordnet neue Kachelfenster automatisch an.
#
# AeroSpace startet das Skript bei jedem neuen Fenster (siehe aerospace.toml).
# Von Hand aufgerufen ordnet es die Fenster des aktuellen Workspaces.
#
#   1 Fenster: Vollbild
#   2 Fenster: nebeneinander
#   3 Fenster: links Master, rechts zwei übereinander
#   4 Fenster: 2x2-Raster
#   ab 5     : Standardverhalten von AeroSpace
#
# Schwebende Fenster zählen nicht mit, Akkordeon-Layouts bleiben unangetastet.

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
# JKKONFIG_AEROSPACE überschreibt den Pfad (für Tests)
AS=${JKKONFIG_AEROSPACE:-}
[ -n "$AS" ] || AS=$(command -v aerospace) || exit 0

wid=${AEROSPACE_WINDOW_ID:-}
unset AEROSPACE_WINDOW_ID AEROSPACE_WORKSPACE

# Eine Instanz zur Zeit: gleichzeitig gestartete Skripte laufen nacheinander und
# sehen jeweils den aktuellen Stand. Sperren verfallen nach zehn Sekunden.
sperre="${TMPDIR:-/tmp}"
sperre="${sperre%/}/jkkonfig-autotile.lock"
versuche=0
until mkdir "$sperre" 2>/dev/null; do
    versuche=$((versuche + 1))
    [ "$versuche" -gt 80 ] && exit 0
    alter=$(( $(date +%s) - $(stat -f %m "$sperre" 2>/dev/null || echo 0) ))
    if [ "$alter" -gt 10 ]; then
        rmdir "$sperre" 2>/dev/null
        continue
    fi
    sleep 0.05
done
trap 'rmdir "$sperre" 2>/dev/null' EXIT

fenster=$("$AS" list-windows --all \
    --format '%{window-id}|%{workspace}|%{window-layout}|%{workspace-root-container-layout}' \
    2>/dev/null) || exit 0

gekachelt='^[hv]_(tiles|accordion)$'

if [ -n "$wid" ]; then
    # Nur reagieren, wenn das neue Fenster selbst gekachelt ist
    ws=$(printf '%s\n' "$fenster" |
        awk -F'|' -v w="$wid" -v re="$gekachelt" '$1 == w && $3 ~ re { print $2; exit }')
else
    ws=$("$AS" list-workspaces --focused 2>/dev/null)
fi
[ -n "$ws" ] || exit 0
case $ws in *[!A-Za-z0-9_-]*) exit 0 ;; esac

# Gehört das Fenster zu einem anderen macOS-Schreibtisch?
space_bin=""
if [ -z "${JKKONFIG_AEROSPACE:-}" ]; then
    for p in "$HOME/.config/jkkonfig/bin/space_sync" "$HOME/bin/space_sync" /opt/homebrew/bin/space_sync /usr/local/bin/space_sync; do
        if [ -x "$p" ]; then space_bin="$p"; break; fi
    done
    if [ -z "$space_bin" ] && [ -x "${0%/*}/../../bin/space_sync" ]; then
        space_bin="${0%/*}/../../bin/space_sync"
    fi
fi

if [ -n "$wid" ] && [ -n "$space_bin" ]; then
    cur_space=$("$space_bin" --current 2>/dev/null)
    case $cur_space in
        [1-9])
            if [ "$ws" != "$cur_space" ]; then
                "$AS" move-node-to-workspace --window-id "$wid" "$cur_space" >/dev/null 2>&1
                "$AS" workspace "$cur_space" >/dev/null 2>&1
                ws="$cur_space"
                fenster=$("$AS" list-windows --all \
                    --format '%{window-id}|%{workspace}|%{window-layout}|%{workspace-root-container-layout}' \
                    2>/dev/null) || exit 0
            fi
            ;;
    esac
fi

wurzel=$(printf '%s\n' "$fenster" | awk -F'|' -v ws="$ws" '$2 == ws { print $4; exit }')
case $wurzel in *accordion*) exit 0 ;; esac

anzahl=$(printf '%s\n' "$fenster" |
    awk -F'|' -v ws="$ws" -v re="$gekachelt" '$2 == ws && $3 ~ re { n++ } END { print n + 0 }')

case $anzahl in
    2)
        befehl="layout --workspace $ws --root horizontal; balance-sizes --workspace $ws"
        ;;
    3)
        # Auf drei Spalten glätten, dann das neue Fenster mit dem rechten (sonst
        # linken) Nachbarn stapeln: links bleibt immer der Master
        [ -n "$wid" ] || exit 0
        befehl="flatten-workspace-tree --workspace $ws; layout --workspace $ws --root horizontal;"
        befehl="$befehl join-with --window-id $wid right || join-with --window-id $wid left;"
        befehl="$befehl balance-sizes --workspace $ws"
        ;;
    4)
        # Aus dem Master-Stack wird so immer ein 2x2-Raster
        [ -n "$wid" ] || exit 0
        befehl="join-with --window-id $wid left || join-with --window-id $wid right;"
        befehl="$befehl balance-sizes --workspace $ws"
        ;;
    *)
        exit 0
        ;;
esac

"$AS" eval "$befehl" >/dev/null 2>&1
exit 0
