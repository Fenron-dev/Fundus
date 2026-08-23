# Konzept-Erweiterung: Modulare Medien-Engine und Manga-/Comic-Reader

> Status: verbindliche Ergänzung zum Fundus-Konzept
>
> Stand: 15. August 2026
> Bezug: [KONZEPT.md](KONZEPT.md) und
> [Bibliotheken, Ordnerstruktur und Peer-Server](KONZEPT_ERWEITERUNG_BIBLIOTHEKEN_UND_PEER_SERVER.md)

## 1. Ziel und Leitentscheidung

Fundus bleibt eine gemeinsame Bibliotheks-, Wiedergabe- und Synchronisations-App
für unterschiedliche Medientypen. Es entsteht jedoch **kein einzelner
Universal-Player**, der jede medienspezifische Funktion kennt.

Stattdessen besteht die Wiedergabe aus zwei Ebenen:

1. Eine gemeinsame **Media Experience Shell** stellt Navigation, Fortschritt,
   Resume, Lesezeichen, Notizen, Playlists, Downloads, Remote-Zugriff,
   Synchronisation und Konfliktbehandlung bereit.
2. Spezialisierte **Media Engines** übernehmen die tatsächliche Wiedergabe oder
   Darstellung und melden der Shell ihre Fähigkeiten.

Damit bleiben gemeinsame Funktionen konsistent, während Audio, Video,
Dokumente und bildbasierte Publikationen ihre jeweils notwendige Tiefe erhalten.

## 2. Begriffe und Modulgrenzen

### 2.1 Media Experience Shell

Die Shell ist kein Decoder und kein Reader. Sie besitzt die
medienübergreifende Benutzer- und Sitzungslogik:

- Werk öffnen, fortsetzen, pausieren und schließen
- kompakte und maximierte Darstellung
- lokaler, Remote- und Offline-Modus
- Resume-Konflikte und Revisionshistorie
- Lesezeichen, Notizen und Anhänge
- Queue, Playlist, Leseliste und Sitzungs-Snapshot
- Download- und Cache-Zustand
- Gerätewechsel und Synchronisation
- Vollbild, System-Zurück, Tastatur-, Touch- und Gestenweitergabe
- gemeinsame Kopf-, Detail- und Navigationsbereiche
- Einstellungsauflösung über mehrere Geltungsbereiche
- Diagnoseereignisse ohne private Pfade oder Zugangsdaten

### 2.2 Media Engines

| Engine | Primäre Medientypen | Spezifische Verantwortung |
|---|---|---|
| Audio Engine | Hörbuch, Hörspiel, Podcast, Musik | Decoder, Zeitleiste, Audio-Fokus, Geschwindigkeit, Kapitel, Sleep-Timer, Hintergrundwiedergabe |
| Video Engine | Film, Serie, Episode, sonstiges Video | Videoausgabe, Tonspuren, Untertitel, Seitenverhältnis, HDR-/Codec-Verhalten |
| Publication Engine Family | PDF, EPUB, Webnovel, Dokument | getrennte Fixed-/Reflow-Renderer, Suche, Schrift, Annotation und Dokumentanker |
| Comic Engine | Manga, Comic, Manhwa, Manhua, Webtoon | feste Bildseiten, RTL/LTR, Doppelseite, Long-Strip, Tap-Zonen, Kapitelübergang |
| Image Engine | Fotos und Bildsammlungen | Galerie, Zoom, Diashow, Bildmetadaten |
| Archive Engine | ZIP und weitere Archive | schreibgeschützte virtuelle Navigation und sichere temporäre Übergabe an passende Engines |

Die Publication Engine ist selbst eine Familie aus Fixed Document Reader für
PDF und Reflow Reader für EPUB/Webnovels. Publication- und Comic-Engine dürfen
gemeinsame Bausteine wie Zoom, Seitencache, Bilddekodierung, Annotationen und
Gestenerkennung verwenden. Ihre Renderer bleiben getrennt, weil reflowbarer
EPUB-Text, feste PDF-Seiten und CBZ-Bildseiten unterschiedliche Positions-,
Layout- und Suchmodelle besitzen. Details stehen in
[Publikationen, Dokumente, Tracking und TTRPG](KONZEPT_ERWEITERUNG_PUBLIKATIONEN_DOKUMENTE_TRACKING_UND_TTRPG.md).

### 2.3 Engine-Vertrag

Jede Engine implementiert denselben Lebenszyklus:

1. `probe`: Kann die Engine dieses Werk und dessen Variante öffnen?
2. `prepare`: Metadaten, Kapitel, Seiten oder Streams speicherschonend laden.
3. `open`: An einer typisierten Position starten.
4. `observe`: Position, Dauer beziehungsweise Umfang und Zustand melden.
5. `seek`: Eine für die Engine gültige Position anspringen.
6. `command`: Nur unterstützte Befehle ausführen.
7. `snapshot`: Einen wiederherstellbaren Sitzungsstand erzeugen.
8. `close`: Fortschritt sicher flushen und Ressourcen freigeben.

Lokale, gestreamte und heruntergeladene Quellen verwenden denselben
Engine-Vertrag. Nur der Datenlieferant unterscheidet sich. Dadurch darf ein
Offline-Manga nicht in einem funktionsärmeren Viewer landen als derselbe Manga
vom Server.

## 3. Fähigkeiten statt fest verdrahteter Oberflächen

Eine Engine veröffentlicht eine Capability-Menge. Die Shell zeigt nur
Bedienelemente, die das aktuelle Werk tatsächlich unterstützt.

Vorgesehene Fähigkeiten sind unter anderem:

- zeit- oder seitenbasiertes Seeking
- Play/Pause
- vorheriges/nächstes Medium
- vorheriges/nächstes Kapitel
- Track-, Kapitel- oder Seitenliste
- Abspielgeschwindigkeit
- Sleep-Timer
- Hintergrundwiedergabe
- Untertitel und Tonspuren
- Zoom, Rotation und Layoutwechsel
- Leserichtung
- automatisches Scrollen
- Text- oder Inhaltsuche
- Textauswahl, Annotation und Formularfelder
- OCR-Index und Treffer-Navigation
- Export beziehungsweise Übergabe an externe Geräte
- Lesezeichen und Markierungen
- Queue beziehungsweise Playlist
- Download, Streaming und Vorladen
- System-Mediensteuerung

Die Capability-Prüfung steuert zugleich Tastenkürzel, Gesten, Menüs und Remote-
API. Ein deaktivierter Button ohne Erklärung ist zu vermeiden; nicht vorhandene
Funktionen werden ausgeblendet oder mit einer verständlichen Begründung
angezeigt.

## 4. Gemeinsames Positions- und Fortschrittsmodell

### 4.1 Typisierte Position

Ein universeller Sekundenwert reicht nicht aus. Die vorhandene
`MediaPosition` wird zu einer versionierten, typisierten Position ausgebaut.
Gemeinsame Felder:

- `schema_version`
- `work_id`
- optional `file_id`, `chapter_id` und stabile logische Element-ID
- `kind`
- medienspezifische Positionsdaten
- menschenlesbares Label
- Gesamtumfang und Prozentwert, sofern bestimmbar
- `updated_at`, `device_id`, `user_id`, Revision und Operations-ID

| Positionsart | Technische Daten | Anzeige |
|---|---|---|
| Audio/Video | Track/Stream, Millisekunden, optional Chapter | `Kapitel 7 · 01:12:15 / 12:45:30` |
| Manga/Comic | Chapter-ID, Seitenindex, optional Scrolloffset | `Kapitel 283 · Seite 12 von 18` |
| PDF | Datei-ID, Seite, optional normalisierter Offset | `Seite 147 von 382` |
| EPUB/Webnovel | Kapitel-ID, CFI/Textanker, Prozent | `Kapitel 19 · 63 %` |
| Bildsammlung | Bild-ID oder stabiler Index | `Bild 42 von 180` |
| Playlist/Queue | Session, Eintragsindex, Werkposition | `Eintrag 7 · Kapitel 4 · 00:28:16` |

Indizes allein sind nicht stabil genug. Wo möglich wird zusätzlich eine stabile
Kapitel-, Datei- oder Seiten-ID gespeichert. Nach Verschieben, Umbenennen oder
erneutem Scan wird zuerst über diese ID, danach über Hash und erst zuletzt über
den Index aufgelöst.

### 4.2 Speichern und Synchronisieren

- Fortschritt wird bei relevanten Übergängen, beim Verlassen sowie regelmäßig
  während der Nutzung gespeichert.
- Eine Engine meldet nur Positionen; Revision, Offline-Warteschlange und
  Konfliktregeln gehören der Shell.
- Ein Konflikt zeigt die Position in der Sprache des Medientyps.
- `finished` ist eine eigene Zustandsentscheidung und wird nicht allein aus
  einem gerundeten Prozentwert abgeleitet.
- Kapitel- und Werkfortschritt bleiben unterscheidbar. Ein gelesenes Kapitel
  kann markiert sein, während das Gesamtwerk noch nicht abgeschlossen ist.
- Ein älterer Offline-Stand setzt einen neueren abgeschlossenen Stand niemals
  still zurück.

## 5. Universelle Listen und Sitzungen

Fundus verwendet ein gemeinsames Listenmodell, aber unterschiedliche
Darstellungen:

- Audio/Video: Playlist beziehungsweise Queue
- Manga, Bücher und Dokumente: Leseliste
- Bilder: Album beziehungsweise Diashow-Liste

Ein Listeneintrag referenziert grundsätzlich ein Werk, nicht jede enthaltene
Datei. Die Engine löst das Werk intern in Tracks, Episoden, Kapitel oder Seiten
auf. Ein Sitzungs-Snapshot enthält die tatsächlich verwendete Reihenfolge und
die typisierte Position des aktuellen Eintrags.

Gemischte Listen sind technisch möglich. Standardmäßig werden sie nach
Capability und Medientyp gefiltert, damit etwa eine Audio-Queue nicht
unbeabsichtigt an einem PDF endet. Ein expliziter gemischter Modus kann später
für Lern- oder Präsentationssammlungen angeboten werden.

## 6. Einstellungsmodell

Einstellungen werden vom Allgemeinen zum Spezifischen aufgelöst:

1. Fundus-Standard
2. Gerät
3. Bibliothek oder Server
4. Engine
5. Medientyp beziehungsweise Reader-Profil
6. Serie oder Werk
7. aktuelle Sitzung

Der spezifischere Wert gewinnt. Die Oberfläche zeigt Herkunft und
Geltungsbereich und bietet „Auf Standard zurücksetzen“.

Engine-Einstellungen werden nur zwischen Geräten synchronisiert, wenn sie dort
sinnvoll und unterstützt sind. Displaybreite oder Android-Tap-Zonen bleiben
beispielsweise gerätebezogen; Leserichtung einer Serie ist werkbezogen.

Heruntergeladene Werke führen ihre gerätebezogenen Reader-Einstellungen im
portablen Offline-Bestand mit. Die Datei `_fundus/offline-media/<Werk>/reader-settings.json`
verwendet stabile Geräteklassen wie `android` und `macos`, nicht den frei
wählbaren Gerätenamen oder eine installationsabhängige Geräte-ID. Damit bleiben
beispielsweise Webtoon-Modus und Breitenanpassung nach einer Neuinstallation
erhalten, sofern der externe Offline-Bestand nicht gelöscht wurde. Beim
Onlinezugriff wird ein vorhandenes Serverprofil in diesen Bestand gespiegelt;
Änderungen werden lokal atomar geschrieben und anschließend zum Server
synchronisiert.

Ein benanntes Profil kann zusätzlich an Engine, Bibliothek, Serie und Gerät
gebunden werden. Änderungen während einer Sitzung dürfen zunächst als
„implizites Profil“ bestehen und anschließend verworfen oder bewusst als
benanntes Profil gespeichert werden.

## 7. Manga-/Comic-Domänenmodell

### 7.1 Inhaltstyp und Reader-Profil sind getrennt

Fundus führt für bildbasierte Publikationen einen fachlichen Untertyp ein:

- Manga
- Comic
- Manhwa
- Manhua
- Webtoon
- benutzerdefiniert beziehungsweise unbekannt

Dieser Untertyp dient Navigation, Suche, Filterung und sinnvollen Vorgaben. Er
bestimmt den Reader-Modus nicht unveränderlich.

Separat wird ein Reader-Profil gespeichert:

- Einzelseite
- Doppelseite
- kontinuierlich vertikal
- kontinuierlich horizontal
- Webtoon/Long-Strip

Beispiel: Ein Manhwa kann als Manhwa klassifiziert sein, aber manuell dauerhaft
in der Doppelseitenansicht gelesen werden.

### 7.2 Erkennung und manuelle Korrektur

Die Erkennung verwendet diese Priorität:

1. explizite manuelle Zuordnung in Fundus
2. portables Fundus-Sidecar
3. `ComicInfo.xml` oder andere vertrauenswürdige eingebettete Metadaten
4. Tags und Metadaten aus Fremdsystemen
5. konfigurierter Medienwurzel- oder Ordnerhinweis
6. Dateiformat, Seitenabmessungen und Long-Strip-Heuristik
7. neutraler Fallback `Comic/Manga unbekannt`

Ordnernamen sind Hinweise, keine zwingende Wahrheit. Automatisch erkannte Werte
werden mit Herkunft und Konfidenz gespeichert. Eine manuelle Korrektur wird bei
späteren Scans nicht überschrieben.

Die Long-Strip-Heuristik darf einen Webtoon-Modus vorschlagen, aber nie gegen
eine Serien- oder Werkseinstellung erzwingen.

### 7.3 Werkhierarchie

- Serie/Publikation ist das übergeordnete Werk.
- CBZ/CBR/PDF oder ein Bildordner bildet ein Kapitel beziehungsweise einen Band.
- Bilder innerhalb eines Archivs sind Seiten, keine globalen `works`.
- `ComicInfo.xml`, Cover und sonstige Begleitdateien erhalten passende
  `work_files.role`-Werte.
- Natürliche Sortierung ist Pflicht; explizite Metadatenreihenfolge hat Vorrang.

## 8. Funktionsumfang des Manga-/Comic-Readers

### 8.1 Kernfunktionen

- lokale, Remote- und Offline-Werke funktionsgleich öffnen und fortsetzen
- CBZ sowie Bildordner; CBR erst nach Wahl eines sicher verfügbaren Backends
- Einzelseite und Doppelseite
- Leserichtung LTR und RTL
- kontinuierlich vertikal und horizontal
- eigener Webtoon-Modus ohne künstliche Seitenabstände
- Skalierung auf Breite, Höhe, Bildschirm oder Originalgröße
- optionales Strecken und begrenzte Reader-Breite
- konfigurierbarer Seitenabstand
- Versatz der ersten Doppelseite für korrekte Umschläge
- breite Doppelseiten erkennen und wahlweise passend teilen; Reihenfolge folgt
  LTR/RTL und bleibt manuell überschreibbar
- optionaler dezenter Buchfalz-/Schatteneffekt ohne Veränderung der Seite
- Zoom und Pan ohne Verlust der Leseposition
- vorherige/nächste Seite und vorheriges/nächstes Kapitel
- nahtloser Kapitelübergang in kontinuierlichen Modi
- Kapitel- und Seitenübersicht
- Resume, gelesen/ungelesen und abgeschlossen
- Seitenlesezeichen mit Label und Notiz

### 8.2 Bedienung

- konfigurierbare Tap-Zonen mit sichtbarer Vorschau
- horizontale und vertikale Umkehrung der Tap-Zonen
- frei belegbare Desktop-Kürzel
- Pfeiltasten, Mausrad, Trackpad, Swipe und Bildschirmtaps
- Quick Settings im Reader für Modus, Richtung, Skalierung und Doppelseitenversatz
- einblendbare beziehungsweise angeheftete Desktop-Navigation
- auf Mobile automatisch reduzierte Bedienelemente und Safe-Area-Beachtung
- optional Mauszeiger und Overlays nach Inaktivität ausblenden

### 8.3 Fortschritt und Übergänge

- Seitenzahl und Fortschrittsleiste ein-/ausblendbar
- Position der Fortschrittsleiste unten, links, rechts oder automatisch
- gelesene Seiten und aktuelle Seite erkennbar
- vorherige und folgende Bilder konfigurierbar vorladen
- in kontinuierlichen Modi optional voriges und nächstes Kapitel bereits
  sichtbar halten
- Übergangsseite mit altem/neuem Kapitel, Fortschritt und Navigationsaktionen
- Warnung bei fehlenden oder doppelten Kapiteln
- optionaler Hinweis bei Wechsel der Quelle beziehungsweise Übersetzergruppe
- gefilterte oder doppelte Kapitel nach Nutzereinstellung überspringen

### 8.4 Komfort und Barrierearmut

- Hintergrundfarbe: Theme, Schwarz, Grau, Weiß oder aus Seite abgeleitet
- Helligkeit, Kontrast, Sättigung, Farbton, Sepia, Graustufen und Invertierung
- optionaler Farbfilter mit getrennten Kanälen
- automatisches Scrollen mit einstellbarer Geschwindigkeit
- Bildschirm wach halten
- Gesten und Kürzel vollständig abschalt- beziehungsweise anpassbar
- Einstellung „Bewegung reduzieren“ für animierte Übergänge und weiches Scrollen
- ausreichende Touch-Ziele und Bedienbarkeit ohne präzise Gesten

### 8.5 Bibliothek

Manga-/Comic-Ansichten unterstützen zusätzlich zu den Fundus-Standardfiltern:

- Untertyp und Reader-Profil
- ungelesen, begonnen, gelesen und abgeschlossen
- ungelesene Kapitelanzahl
- lokal, remote, vollständig oder teilweise heruntergeladen
- Kapitel mit Lesezeichen
- laufend, abgeschlossen, pausiert oder abgebrochen
- fehlende und doppelte Kapitel
- Sprache und optionale Übersetzergruppe

Sortieroptionen umfassen mindestens Titel, hinzugefügt, zuletzt gelesen,
Fortschritt, ungelesene Kapitel, Gesamtzahl der Kapitel, zuletzt aktualisiert
und zufällig. Grid und Tabelle zeigen auf Wunsch Fortschritt, neue Kapitel und
Offline-Zustand.

## 9. Caching, Downloads und Leistung

- Nur benötigte Archivseiten werden dekodiert; große CBZ-Dateien werden nicht
  vollständig als Bildliste im RAM gehalten.
- Ein begrenzter LRU-Cache trennt Originalbytes, dekodierte Seiten und
  Thumbnails.
- Vorladen ist nach Gerät und Verbindung konfigurierbar.
- Remote-Zugriff unterstützt Range- beziehungsweise seitenweisen Abruf. Wenn
  das Archivformat keinen effizienten Direktzugriff erlaubt, stellt der Server
  einzelne Seiten über stabile IDs bereit.
- Downloads erfolgen atomar mit Manifest, Hashprüfung und freiem Speichercheck.
- Optional können die nächsten N Kapitel vorgeladen werden.
- Ein späteres automatisches Löschen gelesener Kapitel ist nur mit klarer
  Vorschau, Ausschluss von Lesezeichen und Papierkorb-/Rückgängig-Strategie
  zulässig.
- Beschädigte Archive, Zip-Slip, Zip-Bomb, extreme Bildabmessungen und
  Dekompressionslimits gehören in die Abnahmetests.

## 10. Remote-API und Offline-Parität

Serverantworten liefern keine absoluten Pfade. Für Comic-Werke werden benötigt:

- Werk- und Kapitelmetadaten
- stabile Kapitel- und Seiten-IDs
- natürliche Reihenfolge und Leserichtung
- Seitengröße und MIME-Typ vor dem Abruf
- Cover und kleine Seiten-Thumbnails
- einzelne Seiten mit Authentifizierung und Cache-Validatoren
- Fortschritts-, Lesezeichen- und Gelesen-Operationen mit Operations-ID
- Downloadmanifest pro Werk oder Kapitel

Der Client verwendet für lokal, remote und offline dasselbe ViewModel und
dieselbe Comic Engine. Unterschiede dürfen nur Datenquelle, Verfügbarkeit und
Latenz betreffen.

## 11. Diagnose und Datenschutz

Diagnoseereignisse enthalten Engine, Werk-ID, Kapitel-ID, Seitenindex,
Quelle (`local`, `remote`, `offline`), Dauer und Fehlerklasse. Absolute Pfade,
Tokens, Zertifikate und Seitendaten werden nicht protokolliert.

Wichtige Ereignisse:

- Engine-Auswahl und Capability-Aushandlung
- Öffnen, Resume-Auflösung und Positionsspeicherung
- Kapitelwechsel und Vorladeergebnis
- Cachetreffer und begrenzte Leistungsmetriken
- Remote-/Offline-Fallback
- beschädigte oder abgewiesene Archive
- Sync-Konflikt und gewählte Auflösung

## 12. Architektur- und Abnahmetests

### 12.1 Gemeinsame Shell

- Eine künstliche Test-Engine beweist Öffnen, Seek, Snapshot und Close.
- Nicht unterstützte Fähigkeiten erscheinen nicht in UI oder API.
- Derselbe Fortschritt wird lokal, remote und offline identisch formatiert.
- Wechsel zwischen Engines verliert weder Queue noch Werkzustand.
- Konfliktdialoge stellen Zeit-, Seiten- und Textposition korrekt dar.

### 12.2 Comic Engine

- Einzel-, Doppel-, vertikaler, horizontaler und Webtoon-Modus
- LTR/RTL einschließlich Tastatur, Tap-Zonen und Fortschrittsrichtung
- Kapitelwechsel vorwärts und rückwärts
- Resume nach Neustart, Verschieben, Neu-Scan und Gerätewechsel
- Seitensprung zu Lesezeichen
- große und beschädigte CBZ-Datei bei begrenztem Speicher
- Remote-Verbindungsabbruch und Offline-Fortsetzung
- keine Funktionsabweichung zwischen lokaler und Remote-Detailansicht
- Scanner übernimmt `ComicInfo.xml`, ohne manuelle Werte zu überschreiben
- automatische Typ-/Long-Strip-Erkennung ist jederzeit korrigierbar

## 13. Umsetzungsetappen

### Etappe A – medienübergreifendes Fundament

1. Shell-/Engine-Vertrag und Capability-Modell
2. versionierte typisierte Position und Migration des vorhandenen Modells
3. gemeinsame Source-Abstraktion für lokal, remote und offline
4. Einstellungsauflösung nach Geltungsbereich
5. Audio-Player als erste Engine an den Vertrag anbinden, ohne Regression

### Etappe B – Comic-Grundreader

1. Comic-Domänenmodell und `ComicInfo.xml`
2. Einzelseite, Doppelseite, LTR/RTL
3. kontinuierlich vertikal/horizontal und Webtoon
4. Kapitel-/Seiten-Navigation, Resume und Lesezeichen
5. Quick Settings, Tastatur und Tap-Zonen

### Etappe C – Parität und Komfort

1. Remote-Seitenendpunkte und Offline-Manifeste
2. nahtlose Kapitelübergänge und Vorladen
3. Fortschrittsleiste, Kapitelübersicht und Reader-Overlays
4. Bibliotheksfilter, Typkorrektur und Serienvorgaben
5. Bildfilter, Auto-Scroll und Barrierearmut

### Etappe D – spätere Erweiterungen

- CBR und weitere Comic-Archive nach Sicherheitsprüfung
- Kapitel-Download-Automatik und Löschregeln
- externe Tracking-Dienste nur als optionale Provider
- Text- und OCR-Funktionen separat, nicht als Voraussetzung des Readers

## 14. Referenz und Abgrenzung zu Suwayomi

Suwayomi dient als Funktionsreferenz für Reader-Modi, Profile, Tap-Zonen,
Fortschritt, Kapitelübergänge, Vorladen und Bibliotheksfilter. Fundus übernimmt
keinen Quellcode und bildet keine Online-Quellen- oder Erweiterungsplattform
nach.

Die Referenzprojekte stehen unter MPL-2.0. Konzeptideen und beobachtetes
Verhalten werden eigenständig in der Flutter-/Fundus-Architektur umgesetzt.
Ein späteres Übernehmen einzelner Implementierungen wäre separat rechtlich und
technisch zu prüfen und ist nicht Teil dieses Konzepts.

Primärquellen:

- <https://github.com/Suwayomi/Suwayomi-Server>
- <https://github.com/Suwayomi/Suwayomi-WebUI/tree/master/src/features/reader>
- <https://github.com/Suwayomi/Suwayomi-WebUI/blob/master/src/features/reader/Reader.types.ts>
- <https://github.com/Suwayomi/Suwayomi-WebUI/blob/master/src/features/manga/Manga.types.ts>
- <https://github.com/Suwayomi/Suwayomi-WebUI/blob/master/src/features/manga/Manga.constants.ts>
