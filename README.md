# jkkonfig

Eine ruhige, schnelle Arbeitsumgebung für macOS, die sich mit einem Befehl ein- und ausschalten lässt. `jkkonfig` richtet **Ghostty** (Terminal in Schwarz und Weiß) und **AeroSpace** (Kacheln mit automatischem Raster) ein, setzt die dazu passenden Systemeinstellungen, versteckt auf Wunsch das Dock, schaltet die Systemanimationen ab und bringt eine Wartung für den Mac mit. Alles in einem Programm, ohne eigene Dauerprozesse.

Gebaut für die deutsche Tastatur (QWERTZ), getestet auf macOS 26 mit Apple Silicon.

## Installation

```bash
git clone https://github.com/jonathank55/jkkonfig.git ~/.config/jkkonfig
cd ~/.config/jkkonfig
brew bundle                      # Ghostty, AeroSpace und die Schrift Kode Mono
mkdir -p ~/bin && ln -sfn ~/.config/jkkonfig/bin/jkkonfig ~/bin/jkkonfig   # ~/bin muss im PATH liegen
jkkonfig ein
```

AeroSpace braucht einmalig die Berechtigung unter *Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen*. Danach Ghostty einmal neu starten.

`jkkonfig` selbst kommt mit der Bash 3.2 aus, die macOS mitbringt. Nur die Wartung (`pflege`) braucht Python 3.9 oder neuer, und das bringen die Entwicklerwerkzeuge von Apple bereits mit.

## Befehle

| Befehl | Wirkung |
| :--- | :--- |
| `jkkonfig` oder `jkkonfig status` | Zustand aller Bausteine (startet AeroSpace automatisch, falls gestoppt) |
| `jkkonfig ein` | Konfigurationen installieren, Systemeinstellungen setzen, Wächter und AeroSpace laden |
| `jkkonfig aus` | Den Zustand vor dem ersten `ein` wiederherstellen |
| `jkkonfig reload` | AeroSpace-Konfiguration prüfen und neu laden (startet AeroSpace bei Bedarf) |
| `jkkonfig autostart [ein/aus]` | Autostart-Wächter (startet bei Anmeldung, hält AeroSpace aktiv) |
| `jkkonfig diff` | Installierte Dateien mit den Vorlagen vergleichen |
| `jkkonfig backup` | Installierte Dateien zusätzlich sichern |
| `jkkonfig theme [Name]` | Ghostty-Farbschema einstellen oder anzeigen (`grau`, `grün`, `rot`) |
| `jkkonfig theme auto [ein/aus]` | Automatische Umschaltung nach Tageszeit (Standard: 04:00 grün, 18:00 rot) |
| `jkkonfig theme auto zeiten` | Umschaltzeiten und Ziel-Farbschemata konfigurieren |
| `jkkonfig schriftart [Name]` | Ghostty-Schriftart einstellen oder anzeigen (z. B. `"Kode Mono"`) |
| `jkkonfig schriftgröße [Zahl]` | Ghostty-Schriftgröße in Punkten einstellen oder anzeigen (z. B. `18`) |
| `jkkonfig dock aus` / `ein` | Dock verstecken oder zeigen (`umschalten`, `status`) |
| `jkkonfig anim aus` / `ein` | Systemanimationen ab- oder anschalten (`status`) |
| `jkkonfig pflege [Baustein ...]` | Wartung, siehe unten |
| `jkkonfig hilfe` | Kurzhilfe |

Jeder verändernde Befehl akzeptiert `--trocken` (kurz `-n`) und zeigt dann nur, was geschehen würde.

## Das Raster

AeroSpace kachelt jedes neue Fenster ohne Zwischenraum. Das Skript `auto-tile.sh` ordnet dabei automatisch an:

| Fenster | Anordnung |
| :--- | :--- |
| 1 | Vollbild |
| 2 | nebeneinander, gleich breit |
| 3 | links ein hoher Master, rechts zwei übereinander |
| 4 | Raster aus zwei mal zwei |
| ab 5 | Standardverhalten von AeroSpace |

Schwebende Fenster (Systemeinstellungen, Rechner, Aktivitätsanzeige und weitere Hilfsfenster, siehe `aerospace.toml`) zählen nicht mit. Ein Akkordeon-Layout bleibt unangetastet. Der Fokus folgt nur Mausklick und Tastatur, der Mauszeiger springt nie.

Arbeitsbereiche sind über `workspace-to-monitor-force-assignment` fest den Bildschirmen zugeordnet (Workspaces 1–5 Hauptbildschirm, 6–7 Zweitbildschirm, 8–9 Drittbildschirm) und interagieren keineswegs miteinander. In Kombination mit `spans-displays = false`, `mru-spaces = false` und `AppleSpacesSwitchOnActivate = false` behält jeder Monitor stets seine eigenen, voneinander isolierten Arbeitsbereiche.

## Tastenkürzel

**Ghostty**

| Kürzel | Wirkung |
| :--- | :--- |
| <kbd>⌘</kbd> <kbd>N</kbd> | Neues Fenster (Ghostty-Standard) |
| <kbd>⌘</kbd> <kbd>D</kbd> / <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd> | Teilen nebeneinander / übereinander |
| <kbd>⌘</kbd> <kbd>M</kbd> | Fenster schließen (ersetzt das Minimieren) |
| <kbd>⌘</kbd> <kbd>T</kbd> | Überall: Ghostty nach vorn holen, ein Fenster öffnen, falls keines offen ist |

**AeroSpace** (Modifikator <kbd>⌥</kbd> <kbd>⌘</kbd>)

| Kürzel | Wirkung |
| :--- | :--- |
| <kbd>H</kbd> <kbd>J</kbd> <kbd>K</kbd> <kbd>L</kbd> oder Pfeile | Fokus links, unten, oben, rechts |
| mit <kbd>⇧</kbd> dazu | Fenster in diese Richtung verschieben |
| <kbd>1</kbd> bis <kbd>9</kbd> | Zu Workspace (Schreibtisch) 1 bis 9 |
| <kbd>⇧</kbd> <kbd>1</kbd> bis <kbd>9</kbd> | Fenster auf Workspace 1 bis 9 verschieben |
| <kbd>⇥</kbd> / <kbd>⇧</kbd> <kbd>⇥</kbd> | Zum vorigen Workspace / Workspace auf den nächsten Monitor |
| <kbd>S</kbd> | Ausrichtung umschalten (waagerecht, senkrecht) |
| <kbd>,</kbd> | Akkordeon an und aus |
| <kbd>R</kbd> / <kbd>B</kbd> | Baum glätten / Größen ausgleichen |
| <kbd>Leertaste</kbd> / <kbd>F</kbd> | Schweben und Kacheln wechseln / Vollbild |
| <kbd>W</kbd> / <kbd>Q</kbd> | Fenster schließen / App beenden, wenn es das letzte Fenster ist |
| Taste <kbd>-</kbd> / <kbd>+</kbd> | Fenster verkleinern / vergrößern (auch <kbd>ß</kbd> und <kbd>´</kbd>) |
| <kbd>⇧</kbd> <kbd>R</kbd> | Größenmodus: Pfeile oder <kbd>H</kbd> <kbd>J</kbd> <kbd>K</kbd> <kbd>L</kbd>, <kbd>B</kbd> gleicht aus, <kbd>⏎</kbd> oder <kbd>Esc</kbd> beendet |
| <kbd>⌃</kbd> mit <kbd>H</kbd> <kbd>J</kbd> <kbd>K</kbd> <kbd>L</kbd> oder Pfeilen | Mit dem Nachbarn in einen Container zusammenlegen |
| <kbd>⇧</kbd> <kbd>Ö</kbd> | Dienstmodus: <kbd>Esc</kbd> lädt neu, <kbd>R</kbd> glättet, <kbd>F</kbd> schwebt, <kbd>⌫</kbd> schließt alle anderen |

## Ghostty-Darstellung und Farbschemata

`jkkonfig theme` verwaltet registrierte Ghostty-Konfigurationen unter `configs/ghostty/themes/`:

| Farbschema | Darstellung |
| :--- | :--- |
| `grau` (Standard) | Minimalistisches Schwarz und samtiges Dunkelgrau mit blendfreiem Off-White |
| `grün` | Exakt identisch zum macOS-Terminal-Profil »grün«: reines Phosphor-Grün auf tiefem Schwarz |
| `rot` | Exakt identisch zum macOS-Terminal-Profil »rot«: reines Signalrot auf samtigem Dunkelrot |

Der Befehl `jkkonfig theme <Name>` aktiviert das Farbschema atomar, prüft die Konfiguration vorab und sichert frühere Stände. Ghostty lädt die Konfiguration nach jeder Änderung im laufenden Betrieb unmittelbar neu (Reload Configuration). Ohne Argument zeigt `jkkonfig theme` das aktive Farbschema an.

`jkkonfig theme auto ein` schaltet die zeitgesteuerte Theme-Änderung über einen ressourcenschonenden LaunchAgent (`com.jkkonfig.theme`) an. Standardmäßig gilt von 04:00 bis 18:00 Uhr das Schema `grün` und von 18:00 bis 04:00 Uhr das Schema `rot`. Über `jkkonfig theme auto zeiten <Tag-Start> <Nacht-Start> [Tag-Theme] [Nacht-Theme]` lassen sich die Uhrzeiten und Schemata flexibel festlegen. `jkkonfig theme auto aus` deaktiviert die Automatik und entfernt den Hintergrunddienst vollständig.

Mit `jkkonfig schriftart <Name>` und `jkkonfig schriftgröße <Punkte>` lassen sich Schriftart und Schriftgröße für alle Schemata sowie die aktive Ghostty-Konfiguration zentral anpassen und im laufenden Ghostty-Fenster neu laden. Die Textauswahl invertiert die Farben stets dynamisch und kontrastreich (`cell-foreground` und `cell-background`), während störende Griffleisten (`drag-handle = never`) dauerhaft deaktiviert sind.

## Autostart und Hintergrundwächter

`jkkonfig ein` richtet den schlanken Hintergrunddienst `com.jkkonfig.agent` ein. Dieser startet unmittelbar bei jeder Benutzeranmeldung (`RunAtLoad = true`) und prüft minütlich (`StartInterval = 60`), ob AeroSpace aktiv ist. Wurde AeroSpace beendet, wird es selbsttätig gestartet. Ebenso sorgt jeder Aufruf von `jkkonfig` oder `jkkonfig status` dafür, dass AeroSpace automatisch gestartet wird, falls es nicht lief. Mit `jkkonfig autostart ein` bzw. `aus` lässt sich der Dienst jederzeit separat steuern.

## Dock und Animationen

`jkkonfig dock aus` versteckt das Dock vollständig, sodass die Fenster den ganzen Bildschirm bekommen. Weil macOS oder andere Werkzeuge die Einstellung zurücksetzen können, richtet der Befehl einen kleinen Wächter ein (LaunchAgent `com.jkkonfig.dock`). Er läuft nicht dauernd, sondern startet nur, wenn sich die Dock-Einstellungen ändern, und stellt das Verstecken dann binnen Sekunden wieder her. `jkkonfig dock ein` entfernt ihn wieder.

`jkkonfig anim aus` schaltet Fenster-, Dock-, Mission-Control-, Finder- und Scrollanimationen ab und reduziert Bewegung und Transparenz. Ein verstecktes Dock bleibt dabei versteckt. Die Tabelle aller Werte steht in `configs/macos/defaults.txt`. Mail und Safari werden nur bei ausdrücklichem Aufruf angefasst, weil macOS dafür eine Berechtigungsabfrage zeigen kann.

## Wartung

`jkkonfig pflege` führt acht Bausteine gleichzeitig aus, in der Regel in wenigen Sekunden:

| Baustein | Aufgabe |
| :--- | :--- |
| `defaults` | Komfortwerte aus der Tabelle setzen, Animationszustand angleichen |
| `speicher` | Speicher prüfen, verwaiste Prozesse beenden, Hintergrunddienste auf die Effizienzkerne legen |
| `datenbanken` | SQLite-Datenbanken verdichten, LaunchServices bereinigen |
| `caches` | Paket-, System- und Entwicklercaches, alte Logs und Absturzberichte |
| `index` | Build- und Cacheordner von Spotlight und Time Machine ausnehmen, `.DS_Store` entfernen |
| `git` | Repositories kompaktieren, veraltete Sperren lösen, verwaiste `.pyc` entfernen |
| `netz` | DNS-Cache leeren und vorwärmen, Netzwerk und offene Ports prüfen |
| `sicherheit` | Dateirechte, LaunchAgents, SIP, FileVault, Gatekeeper prüfen |

Einzelne Bausteine wählt man beim Aufruf, etwa `jkkonfig pflege git caches`. Das Protokoll des letzten Laufs liegt unter `~/.local/state/jkkonfig/pflege.log`. Für den Dauerbetrieb ruft man den Befehl am besten alle paar Tage per LaunchAgent auf.

Die Wartung geht vorsichtig vor:

- Eine Datenbank wird nur verdichtet, wenn keine App sie gerade geöffnet hat und sich die Mühe lohnt. Durchsucht werden nur `~/Library/Application Support` und `~/Library/Caches`, die Ordner von Mail, Nachrichten und Safari nicht.
- Beendet werden nur eigene Prozesse in engen Fällen: verwaiste aerc-Mailsitzungen samt Pager, ein QuickLookSatellite über 256 MB und verwaiste Python-Prozesse ohne Terminal, deren Skript nachweislich nicht mehr existiert.
- `git gc` behält die übliche Frist von zwei Wochen für verlorene Objekte, und läuft nie, solange ein Git-Befehl arbeitet.
- Lokale Time-Machine-Schnappschüsse werden nie gelöscht, nur bei knappem Speicherplatz ausgedünnt.
- Die Quarantäne-Markierung entfernt sie nur bei Dateien in `~/bin` und `~/.local/bin`.

Mit `--gruendlich` kommen Eingriffe mit Nebenwirkungen dazu: die Reihenfolge der Netzwerkdienste, IPv6 nur noch Link-local, die Schrift-, Vorschau- und Metal-Shader-Caches sowie das Drosseln der iCloud- und Kalenderdienste. Das gehört bewusst nicht in den Dauerbetrieb.

## Sicherung und Rückkehr

Vor dem allerersten `ein` hält `jkkonfig` den vorgefundenen Zustand fest (`~/.local/state/jkkonfig/original`) und überschreibt ihn nie wieder. `aus` stellt genau diesen Zustand her. Jede überschriebene Datei landet außerdem zeitgestempelt in `~/.local/state/jkkonfig/sicherungen`, die zehn neuesten bleiben erhalten.

## Robustheit

- **Prüfen, bevor etwas gilt.** Ghostty prüft die Vorlage vor der Installation, AeroSpace die installierte Datei im Probelauf. Lehnt eines ab, nimmt `jkkonfig` alles selbsttätig zurück.
- **Festgelegtes Verhalten.** `config-version = 2` in der AeroSpace-Konfiguration friert deren Bedeutung ein, auch wenn AeroSpace sich weiterentwickelt.
- **Fristen.** Hängt ein Schreibzugriff auf die Systemeinstellungen, etwa wegen einer Berechtigungsabfrage, bricht `jkkonfig` ihn nach 30 Sekunden ab, statt alles zu blockieren.
- **Ohne Gewicht.** Kein Dauerprozess, keine Abhängigkeit außer macOS selbst, Python nur für die Wartung.

Nach einem Update von macOS, AeroSpace oder Ghostty zeigt `tests/live.sh`, ob das Raster noch stimmt.

## Tests

```bash
tests/test.sh            # Alles gegen Attrappen und ein Wegwerf-Heimatverzeichnis, rund 15 Sekunden
tests/test.sh pflege     # Nur eine Gruppe (statisch, einaus, theme, dock, anim, kompat, kacheln, pflege)
tests/live.sh            # Echte Fenster auf dem leeren Workspace 9 und Zeitmessung
```

Die Tests berühren weder die echten Einstellungen noch das laufende AeroSpace. Nur `live.sh` öffnet kurz TextEdit und den Rechner auf einem leeren Workspace.

## Aufbau

```
bin/jkkonfig                 der Befehl (Bash)
lib/pflege.py                die Wartung (Python)
configs/ghostty/config       Ghostty (Standardkonfiguration grau)
configs/ghostty/themes/      registrierte Farbschemata (grau, gruen, rot)
configs/aerospace/           aerospace.toml und auto-tile.sh
configs/macos/defaults.txt   alle macOS-Einstellungen in einer Tabelle
tests/                       test.sh, live.sh und Attrappen
Brewfile                     Abhängigkeiten
```

## Hinweise

- **⌘T öffnet kein zweites Fenster.** `open -a Ghostty` bringt Ghostty nach vorn und öffnet nur dann ein Fenster, wenn keines offen ist. Zusätzliche Fenster öffnet <kbd>⌘</kbd> <kbd>N</kbd> in Ghostty. Wer bei jedem Druck ein neues Fenster möchte, kann laut Ghostty-Dokumentation `keybind = global:super+t=new_window` setzen und das Kürzel in `aerospace.toml` entfernen. Ghostty braucht dafür nach eigener Dokumentation die Bedienungshilfen-Berechtigung, und ⌘T tut nichts, solange Ghostty nicht läuft.
- **⌘T ersetzt in Ghostty „Neuer Tab“.** Tabs lassen sich weiter über das Menü öffnen.
- **Alte Namen.** `optimi` und `dockhide`, die Vorgänger dieser Wartung und der Dock-Steuerung, funktionieren als Symlinks weiter auf `jkkonfig`. Bei `dockhide` bedeutet `ein` wie früher „verstecken“.
- **Dateien:** Ghostty liest `~/.config/ghostty/config`, AeroSpace `~/.config/aerospace/aerospace.toml`. Ist `XDG_CONFIG_HOME` gesetzt, gilt dieser Ordner.
