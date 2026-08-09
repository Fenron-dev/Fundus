# Konzept: Fundus · mAngler · MyFileSorter

> Gemeinsames Konzeptdokument für die drei Anwendungen.
> Stand: 2026-08-08 · Status: Entwurf zur Diskussion, noch nicht umgesetzt
>
> Ergänzend: [Design-Prompt](DESIGN_PROMPT.md) im selben Ordner.
> Verbindliche Erweiterung für gemischte Bibliotheken und das Peer-/Servermodell:
> [Bibliotheken und Peer-Server](KONZEPT_ERWEITERUNG_BIBLIOTHEKEN_UND_PEER_SERVER.md).

---

## 1. Ausgangslage

Über die Zeit sind drei Projekte entstanden, die aufeinander zugewachsen sind:

- **MediaShelf** (Flutter, 37k Zeilen) — flacher Datei-DAM: Index, FTS5-Suche, Thumbnails, Tags, Sammlungen, Smart Filter, Player, PDF-/EPUB-Viewer
- **MediaVault** (Rust/Tauri, 26k Zeilen, im Ordner „MediaShelf 2.0") — Webnovel-Downloader **plus** eine zweite, halbfertige DAM-Implementierung
- **MyFileSorter** (Go/Wails, 10,5k Zeilen) — Hörbuch-Erkennung, Benennung, sicheres Verschieben

Das Problem war nie die Technik, sondern der Zuschnitt: Zwei der drei Apps bauen dieselbe Bibliotheks-Hälfte, und keine davon fertig.

### Der geklärte Bedarf

1. **Eine Bibliotheks- und Abspiel-App** für alle Medientypen — Filme/Serien/Anime, Manga, E-Books/PDF, Hörbücher/Hörspiele/Podcasts, Musik, Bilder, Dokumente. Portabel, auf externen Datenträgern, mit Desktop-Server und Mobile-Clients. Inspiration: Eagle.cool für die Verwaltung, Plex/Kavita/Audiobookshelf für die Wiedergabe — jeweils nur die Grundfunktionen.
2. **Eine Abo-/Download-App** — Webnovels, Mangas, RSS, YouTube-Archivierung.
3. **Benennung und Ordnerstruktur** für extern erworbene Inhalte, quellenunabhängig und möglichst ohne Handarbeit.

### Die Zuordnung

| Anforderung | App | Stack | Status |
|---|---|---|---|
| 1 — Bibliothek & Wiedergabe | **Fundus** | Flutter | Neues Repo, selektiv aus MediaShelf kopiert |
| 2 — Abonnieren & Herunterladen | **mAngler** | Rust/Tauri | Neues Repo als Vollkopie von MediaVault |
| 3 — Benennen & Einsortieren | **MyFileSorter** | Go/Wails | Bleibt wie es ist |

**Warum drei und nicht eine:** Die drei haben unterschiedliche Fehlermodi und Release-Rhythmen. mAngler bricht, wenn eine fremde Website ihr HTML ändert — häufige, kleine Releases. MyFileSorter fasst Nutzerdateien an und darf niemals brechen — seltene, sehr sorgfältige Releases. Fundus bricht kosmetisch. Getrennt wird dort, wo sich Fehlermodi unterscheiden, nicht dort, wo sich Features unterscheiden. Drei ist gleichzeitig die Obergrenze für eine Person.

**Warum Flutter für Fundus:** Die Anforderung nach Android- und Desktop-Clients aus einer Codebasis schließt Go/Wails und Rust/Tauri aus — beide haben keine brauchbare Mobile-Story. `media_kit` (libmpv), `pdfrx` und `photo_view` decken alle Zielplattformen ab.

### Warum MediaShelf nicht weitergeführt wird

Ein struktureller Grund: Das Datenmodell hängt vollständig an einer einzelnen `assetId`. `DocumentPositions`, `MediaBookmarks`, `PlaylistItems`, `AssetProperties` und `CollectionAssets` referenzieren jeweils genau eine Datei. Es gibt kein Konzept eines *Werks*. Ein Hörbuch aus 30 MP3s kann keine gemeinsame Resume-Position haben, eine Serie keinen Status, ein Manga-Kapitel aus 40 Bildern ist kein Objekt.

Das ist keine Lücke, die man füllt, sondern eine fehlende Schicht.

---

## 2. Fundus — Architektur

### 2.1 Datenmodell: drei Schichten

Das flache Modell wird **nicht ersetzt, sondern überbaut**. Beide Welten koexistieren.

**Schicht 1 — `files`: was auf der Platte liegt**
`id`, `path` (relativ, Forward-Slashes), `filename`, `extension`, `size`, `mime_type`, `content_hash`, `phash`, `width`, `height`, `duration_ms`, `file_modified_at`, `indexed_at`, `status`.

Das ist das Eagle-Modell: eine Zeile pro physischer Datei, Duplikaterkennung über den Hash, jede Datei existiert genau einmal. Jederzeit aus dem Dateisystem neu aufbaubar.

**Schicht 2 — `works`: das Werk**
`id`, `kind`, `parent_id`, `title`, `sort_title`, `series_name`, `series_sequence`, `year`, `cover_file_id`, `metadata_json`, `added_at`.

`kind`: `audiobook`, `book_series`, `movie`, `series`/`season`/`episode`, `album`/`track`, `manga`/`chapter`, `book`, `ttrpg_product`, `image`, `document`, `archive`, `podcast`/`podcast_episode`.

`kind` ist der feste technische Grundtyp und bestimmt Player, Viewer,
Fortschrittsformat und typspezifische Prüfungen. Die persönliche Ordnung wird
nicht in diesen Grundtyp gepresst: Frei definierbare Untertypen wie `Backup`
oder `Steuerunterlagen`, Tags wie `Wichtig`, Sammlungen und eigene
Eigenschaften bleiben separat und sind vollständig such-, filter-, gruppier-
und sortierbar. Details zur ortsunabhängigen Erkennung und Ordnerstruktur stehen
in [Konzept-Erweiterung: Bibliotheken, Ordnerstruktur und Peer-Server](KONZEPT_ERWEITERUNG_BIBLIOTHEKEN_UND_PEER_SERVER.md).

**Werke sind nicht überall nötig.** Bei einer Einzeldatei wird das Werk automatisch 1:1 abgeleitet und bleibt in der UI unsichtbar — du siehst weiterhin einfach Dateien. Bei einem Hörbuch aus 30 Tracks oder einem TTRPG-Produkt aus PDF, Karten und Handouts bündelt es. Beide Fälle nutzen dieselben Tags, Bewertungen, Notizen und Sammlungen, weil alles am Werk hängt.

`parent_id` ist bewusst **generisch**, nicht auf „Serie → Band" beschränkt: Es trägt genauso „Produktlinie → Produkt" oder „Kampagne → Abenteuer".

**Schicht 3 — `work_files`: die Verbindung**
`work_id`, `file_id`, `position` (Track-/Seitenreihenfolge), `role` (`content` | `cover` | `subtitle` | `sidecar` | `attachment` | `variant`), optionales Zielprofil für Varianten.

**Daran hängend:**

| Tabelle | Zweck |
|---|---|
| `people` + `work_people` | Autor, Sprecher, Regisseur, Künstler als **Entitäten**, nicht als Textspalte — sonst wird „auf Autor klicken" zum Stringvergleich und „J.R.R. Tolkien" ≠ „Tolkien, J.R.R." |
| `progress` | Aktueller Stand pro Nutzer und Werk: `work_id`, `file_id`, typisierte Position (`time` \| `page` \| `epub_cfi` \| `image_index`), `total`, `finished`, Server-Revision, `updated_at`, `device_id`, `user_id` |
| `play_events` | `work_id`, `started_at`, `ended_at`, `seconds_played`, `device_id`, `user_id` — Ereignisliste, kein Zähler, damit Auswertungen später frei sind |
| `notes` | Freie Notizen zu Werk oder Datei (siehe 2.2) |
| `attachments` | Sprachmemos, Bilder, beliebige Dateien zu einem Werk |
| `bookmarks` | Werk + Position + Label + Notiz + Farbe + Zitat |
| `tags`, `collections`, `playlists` | Referenzieren `work_id`; Sammlungen sind many-to-many = die virtuelle Ablage aus Eagle. Playlists besitzen eine Revision und eine explizite Reihenfolge |
| `playback_sessions` + `playback_session_items` | Eingefrorener Abspiel-Snapshot einer Playlist oder Queue: aufgelöste Werk-/Datei-IDs, Reihenfolge, aktueller Eintrag, Position, Shuffle-Reihenfolge, Repeat-Modus und zugrunde liegende Playlist-Revision |
| `property_definitions` + `work_properties` | Benutzerdefinierte Eigenschaften (EAV), aus MediaShelf übernommen |

`user_id` wird überall dort mitgeführt, wo Nutzerzustand entsteht — mit festem Standardwert und ohne Benutzerverwaltung in der Oberfläche. Es kostet jetzt fast nichts und erspart später eine Migration jeder Fortschritts- und Statistikzeile.

### 2.2 Wo Nutzerdaten leben

Der Datei-Index ist Wegwerf-Material: jederzeit aus dem Dateisystem neu aufbaubar. **Notizen, Tags, Bewertungen, Fortschritt und Lesezeichen sind es nicht** — das sind die eigentlichen Daten.

**Entscheidung: Die Datenbank ist maßgeblich, wird aber kontinuierlich in Klartext-Dateien gespiegelt.**

```
Hoerbuecher/
  .library/
    index.db                    ← Index + Nutzerdaten (schnell, maßgeblich)
    version.json
    thumbnails/  covers/
  Sanderson, Brandon/
    Mistborn/
      01 - Kinder des Nebels/
        01 - Kinder des Nebels.m4b
        _fundus/
          meta.yaml             ← Tags, Bewertung, Eigenschaften, Herkunft
          notes.md              ← Notizen als echtes Markdown
          bookmarks.yaml
          attachments/
            memo-2026-08-08.m4a
```

- **Obsidian-Prinzip.** Notizen sind echte `.md`-Dateien, außerhalb der App les-, durchsuch-, bearbeit- und versionierbar.
- **Datensicherheit.** Geht `index.db` verloren, sind Notizen und Bewertungen trotzdem da und werden beim nächsten Scan wieder eingelesen.
- **Portabilität.** Kopierst du eine Serie oder ein Produkt weg, reisen Notizen und Anhänge mit.
- **Geschwindigkeit.** Suche, Filter und Sortierung laufen über SQLite, nicht über tausende YAML-Dateien.

Der Spiegel läuft asynchron und gebündelt. Sidecar und DB tragen dafür Revision und letzten gemeinsamen Stand. Hat sich seitdem nur eine Seite verändert, wird sie automatisch übernommen. Wurden **dieselben Felder auf beiden Seiten** unterschiedlich geändert, gewinnt nicht pauschal die neuere Datei: Fundus zeigt pro Feld DB-Wert, Sidecar-Wert, Quelle und Änderungszeit und lässt einzeln wählen. Unabhängige Änderungen werden automatisch zusammengeführt und protokolliert. Dasselbe Vergleichsprinzip gilt für Fortschritt, dort mit der menschenlesbaren Position aus 2.4.

### 2.3 Metadaten-Herkunft und Anreicherung

**Fundus reichert selbst an und lässt Felder von Hand ergänzen.** Es darf nie nötig sein, eine andere App zu starten, nur um einen Titel zu korrigieren oder ein Cover zu holen.

Das eigentliche Risiko ist nicht *wer* anreichert, sondern **stilles Überschreiben**. Deshalb trägt jedes Metadatenfeld seine Herkunft mit:

| Priorität | Quelle | Darf überschrieben werden von |
|---|---|---|
| 1 (höchste) | `user` — von Hand gesetzt | nichts, nur wieder vom Nutzer |
| 2 | `online` — bestätigter Treffer (Audible, AniList, …) | `user` |
| 3 | `sidecar` — von MyFileSorter geschrieben | `user`, `online` |
| 4 | `embedded` — ID3/MP4/PDF/EPUB-Tags | alles darüber |
| 5 (niedrigste) | `filename` / `folder` — aus dem Pfad geraten | alles darüber |

Eine Anreicherung überschreibt nie ein Feld höherer Priorität, sondern schlägt die Änderung vor und zeigt beide Werte. Von Hand gesetzte Felder sind damit dauerhaft sicher.

Dieses Modell ist keine Erfindung — MyFileSorter macht es bereits mit seiner `Evidence`-Struktur (`value`, `source`, `confidence`) in `internal/domain/models.go`. Fundus übernimmt es, damit beide Apps dieselbe Sprache sprechen.

**Online-Provider in Fundus**, nach Medientyp:

| Typ | Provider |
|---|---|
| Hörbuch | Audible (regional) + Audnexus für Details — **Meilenstein 1** |
| Anime/Manga | AniList |
| Buch/E-Book | Google Books, Open Library |
| Film/Serie | TMDB |
| Brett-/Videospiel, RPG | BoardGameGeek / RPGGeek |

Audible ist im ersten Meilenstein enthalten. Der Aufwand ist überschaubar: MyFileSorters `internal/providers/audible.go` löst das in 247 Zeilen über denselben Ansatz, den auch Audiobookshelf nutzt, und der AniList-Client aus MediaShelfs `external_metadata_service.dart` ist direkt übernehmbar.

Aufrufe erfolgen **nur auf ausdrückliche Auslösung**, mit Host-Allowlist, HTTPS-Zwang, Zeit- und Größenlimits — nach dem Muster von MyFileSorters `providers.Registry`.

**Cover-Reihenfolge:** eingebettet → `cover.jpg` im Ordner → Sidecar → Online-Provider → vom Nutzer gesetzt. Höhere Priorität gewinnt, Nutzerauswahl immer.

### 2.4 Server und Clients

> **Aktualisiert am 2026-08-09:** Die feste Trennung in Server und Client wird
> durch ein Peer-Modell ersetzt. Jede Fundus-Installation kann gleichzeitig
> eigene Bibliotheken bereitstellen und Bibliotheken anderer Geräte verwenden.
> Die verbindlichen Details stehen in der Erweiterung
> [Bibliotheken und Peer-Server](KONZEPT_ERWEITERUNG_BIBLIOTHEKEN_UND_PEER_SERVER.md).

Der Serverdienst läuft **eingebettet in jeder Fundus-App**, soweit die Plattform
den Betrieb zulässt, aber als eigenes Dart-Paket (`packages/server/`). So bleibt
auch ein späteres headless Binary für NAS oder Raspberry Pi ohne Umbau möglich.

```
Peer „Desktop zuhause"
 ├── stellt Bibliothek „Meine Medien" bereit
 └── verwendet Bibliothek „Familie" vom NAS
Peer „Laptop"
 ├── stellt Bibliothek „Archiv" bereit
 └── verwendet „Meine Medien" vom Desktop
```

**Zwei Ebenen:** Ein Peer kann mehrere lokale Bibliotheken gleichzeitig
bereitstellen und mehrere andere Peers kennen. „Peer" bezeichnet die
Fundus-Installation; „Bibliothek" bezeichnet den selbstenthaltenden Ordner
beziehungsweise Datenträger. Eine Bibliothek kann mehrere Medientypen enthalten.

- Bindung standardmäßig nur aufs LAN-Interface, nicht `0.0.0.0`.
- Auth über Geräteschlüssel und kurzlebige Pairing-Codes; Kopplung per QR, PIN,
  lokaler Suche oder manueller Adresse.
- `shelf` + `shelf_router`, echte HTTP-Statuscodes.
- Datei-Streaming **mit `Range`-Unterstützung** (Pflicht, sonst kein Seeking).
- Cache und Downloads getrennt nach `device_id` + `library_id`.
- Kein automatisches Zusammenführen desselben Titels über Server hinweg.

**Fortschritts-Sync:** Die Schreibautorität gilt pro Bibliothek. Das Gerät,
das ihre lokale `.library/` bereitstellt, vergibt die monotone Revision und die
maßgebliche Änderungszeit. Andere Geräte schreiben beim Pausieren, Stoppen und
alle ~30 s während der Wiedergabe. Jede Operation trägt eine eindeutige ID und
ist wiederholbar, ohne den Stand doppelt anzuwenden. Offline sammelt der Peer
in einer Warteschlange und schiebt beim Verbinden nach. Live-Push per WebSocket
ist wünschenswert, nicht v1. Das gilt einheitlich für Hören, Sehen und Lesen.

Ein eindeutiger neuerer Stand wird automatisch übernommen. Sind zwei Stände unabhängig voneinander weitergelaufen oder widersprechen sich, fragt Fundus nach und zeigt **nicht nur Gerät und Datum, sondern die inhaltliche Position**:

- Audio/Video: Werk, Datei bzw. Kapitel, `HH:MM:SS`, Gesamtdauer und Prozent
- PDF/Manga: Seite bzw. Bildnummer und Gesamtseiten
- EPUB: aufgelöstes Kapitel plus Prozent; der CFI bleibt die technische Position
- Playlist/Queue: Playlist-Revision, aktueller Titel, Position innerhalb des Titels, Listenindex und abweichende Reihenfolge

Die Konfliktansicht stellt „Bibliotheksquelle" und „dieses Gerät" nebeneinander
und bietet **diesen Stand verwenden**, **anderen Stand verwenden** und — wo
semantisch möglich — **zusammenführen**. Bei Metadaten, Notizen, Einstellungen
und Sidecars werden stattdessen alle abweichenden Felder mit Alt-/Neuwert,
Quelle und Änderungszeit angezeigt; unabhängige Felder können einzeln
übernommen werden. Eine kurze Revisionshistorie macht Fehlentscheidungen
rückholbar. `finished` wird durch einen älteren Offline-Stand nie still
zurückgesetzt.

**Playlist- und Queue-Resume:** Beim Start einer Playlist wird ihre tatsächlich abgespielte Folge als `playback_session` eingefroren. Das gilt besonders für Smart Playlists: deren Filterergebnis darf sich später ändern, ohne den alten Resume-Punkt unbrauchbar zu machen. Gespeichert werden Playlist-ID und -Revision, die aufgelösten Werke/Dateien in Reihenfolge, aktueller Eintrag und dessen Position, Shuffle-Reihenfolge, Repeat-Modus und optionale Änderungen an der laufenden Queue. Beim Fortsetzen wird zunächst der Snapshot wiederhergestellt. Hat sich die Ursprungs-Playlist verändert, zeigt Fundus auf Wunsch den Unterschied und bietet „alte Sitzung fortsetzen" oder „auf neue Playlist übertragen" an.

**Zielplattformen:** Android, macOS (ARM), Linux, Windows.

**Codecs und Geräte-Kompatibilität:** `media_kit_libs_video` bündelt libmpv/FFmpeg und bietet eine breite Codec-Abdeckung ohne vorausgesetzte Systeminstallation. Das ist die Direct-Play-Basis, aber keine pauschale Garantie für jede Kombination aus Codec, Profil, Farbtiefe, HDR, Auflösung, Audioformat und konkretem Android-Gerät.

Fundus führt deshalb einen **Codec-Abnahmetest pro Zielprofil**. Mitgelieferte Profile beschreiben die unterstützten Kombinationen für Fundus Desktop und typische Android-Klassen; reale gekoppelte Geräte können zusätzlich einen kurzen Testsatz abspielen und daraus ein eigenes Profil erzeugen. Scanner und Detailansicht vergleichen jede Datei dagegen und zeigen ruhig, aber sichtbar: „Folge 7 kann auf Pixel Tablet nicht direkt abgespielt werden — HEVC Main 10 / TrueHD". Die Prüfung ist erneut ausführbar, nachdem App oder Gerät aktualisiert wurden.

Vom Hinweis führt eine Aktion direkt zur betroffenen Datei. Dort kann der Nutzer:

1. die Originaldatei im Dateisystem anzeigen,
2. trotzdem Direct Play versuchen,
3. in Fundus eine **kompatible Variante erstellen**, oder
4. ein konfiguriertes externes Werkzeug aufrufen.

Die integrierte Umwandlung nutzt eine gekapselte FFmpeg-Task-Engine. Sie schreibt immer in eine temporäre Datei, prüft Dauer, Streams und Lesbarkeit und behält das Original. Erst eine ausdrückliche Bestätigung darf ersetzen; normalerweise entsteht eine zusätzliche `variant` in `work_files`, beispielsweise „Android 1080p". Presets und bevorzugte Zielprofile sind in den Einstellungen wählbar. Damit bleibt die Bedienung direkt, ohne die Umwandlungslogik untrennbar an die Oberfläche zu koppeln.

### 2.5 Portables Layout

```
/Volumes/MeineMedien/
  Apps/
    macos/     Fundus.app
    windows/   Fundus.exe + DLLs
    linux/     Fundus.AppImage
    portable.txt          ← schaltet Konfiguration auf portablen Modus
  Libraries/
    Hoerbuecher/
      .library/
      Autor/Serie/…
    TTRPG/
      .library/
      …
```

Daten und Binaries strikt getrennt: Binaries werden aktualisiert, Daten dürfen dabei nie angefasst werden. Mehrere Bibliotheken teilen sich eine App-Kopie, und das Backup umfasst `Libraries/`, nicht 900 MB Binaries.

**Jede Bibliothek ist selbstenthaltend** — MediaShelfs gute Idee, die bleibt. Die App ist bezüglich Bibliotheken zustandslos, sie zeigt nur auf Ordner.

Bekannte Einschränkung: Drei Plattform-Binaries mit gebündeltem libmpv sind zusammen grob 0,5–1 GB. Auf macOS blockiert Gatekeeper unsignierte Apps von externen Laufwerken — lösbar, aber ein Einrichtungsschritt.

### 2.6 Bibliotheksformat und Versionierung

Muss vor dem ersten Release stehen, nicht danach.

`.library/version.json`:
```json
{ "format_version": 3, "min_reader_version": 2, "created_by": "Fundus 0.4.1" }
```

| Fall | Verhalten |
|---|---|
| `format_version` älter als die App | Migration mit vorheriger automatischer Sicherung von `index.db` |
| `format_version` neuer, aber `min_reader_version` ≤ App | **Öffnen im Lesemodus** mit sichtbarem Hinweis: „Diese Bibliothek stammt aus einer neueren Version. Anzeige eingeschränkt, keine Änderungen." |
| `min_reader_version` > App | Öffnen verweigern, klare Meldung mit benötigter Version |

Eine ältere App zeigt damit so viel wie möglich und ändert nichts, statt Daten zu beschädigen. Voraussetzung: Neue Felder werden immer *additiv* eingeführt.

Dazu von Anfang an: SemVer, GitHub-Releases mit Artefakten und SHA-256-Prüfsummen, gepflegtes `CHANGELOG.md`. MyFileSorters CI ist die Vorlage — sie ist die beste der drei (gofmt, vet, Race-Tests, govulncheck, Lockfile-Prüfung, gepinnte Action-SHAs).

---

## 3. Funktionsumfang

### 3.1 Kern

- Scan mit Ignore-Liste, streamend, abbrechbar, mit Fortschritt ab der ersten Datei
- Volltext- und Fuzzy-Suche über Werke, Dateien, Personen **und Notizen**
- kombinierbare Filter, Smart Collections, Tags, Bewertungen, Farblabels sowie frei wählbare Sortierung
- Thumbnails und Cover
- Werk-Detailseite mit Klick auf Serie (zeigt alle Teile) und auf Person (zeigt alles von Autor/Sprecher/Regisseur)
- Metadaten von Hand bearbeiten und online abgleichen (2.3)
- Wiedergabe mit Resume auf Werk- und Playlist-Ebene, Abspielgeschwindigkeit, Sleep-Timer, Kapitelsprüngen
- manuelle, smarte und serienbasierte Playlists über alle Medientypen; Queue und Sitzungs-Snapshot nach 2.4
- Statistik aus `play_events`: Stunden pro Woche/Monat, meistgehört, zuletzt beendet

#### Suche, Filter und Sortierung

Die Standardsuche kombiniert FTS5-Ranking mit einer fehlertoleranten Fuzzy-Stufe. Exakte Treffer und Präfixe stehen vor Volltexttreffern; erst danach folgen ähnlich geschriebene Titel, Personen, Serien, Tags und Dateinamen. Groß-/Kleinschreibung, Bindestriche und diakritische Zeichen werden für die Suche normalisiert, der Originaltext bleibt unverändert. Die Fuzzy-Schwelle ist einstellbar, damit große Bibliotheken nicht in irrelevanten Treffern ertrinken.

Suchbegriffe lassen sich mit Filter-Chips kombinieren, unter anderem:

- Server, Bibliothek und Medientyp
- Serie, Person, Tag, Sammlung und Ordner
- Fortschritt (`nicht begonnen`, `begonnen`, `beendet`), Bewertung und Farblabel
- lokal verfügbar, nur Server, heruntergeladen, fehlend, laufend oder inkompatibel
- hinzugefügt/geändert/erschienen innerhalb eines Zeitraums
- Dateiformat, Auflösung, Dauer, Größe und benutzerdefinierte Eigenschaften

Sortierung mindestens nach Relevanz, Titel, Sortiertitel, Hinzufügedatum, Dateiänderung, Erscheinungsjahr, zuletzt geöffnet/gehört, Bewertung, Fortschritt, Dauer und Größe — jeweils auf- oder absteigend. Die aktive Kombination kann als Smart Collection beziehungsweise gespeicherter Filter benannt werden. Desktop erhält zusätzlich eine globale Kommandopalette; Such- und Filterzustände sind per URL-/Navigationszustand reproduzierbar und über Zurück/Vorwärts erreichbar.

#### Sleep-Timer

Neben festen Dauern unterstützt der Timer „am Kapitelende", „am aktuellen Titelende" und eine frei wählbare Uhrzeit. Auf Mobil kann optional **Schütteln zum Neustarten** aktiviert werden: nur während ein Sleep-Timer läuft, mit einstellbarer Verlängerungsdauer, Empfindlichkeit, Entprellung und Cooldown gegen versehentliches mehrfaches Auslösen. Vibration und kurze Einblendung bestätigen den Neustart; beides ist abschaltbar. Die Funktion ist standardmäßig aus und kann getrennt nach Gerät konfiguriert werden.

### 3.2 Notizen, Anhänge, Lesezeichen

- **Notizen** als Markdown zu Werk *und* Datei — Rezensionen, Bewertungen, freie Gedanken, untereinander verlinkbar
- **Anhänge**: Sprachmemos, Bilder, beliebige Dateien. Liegen in `_fundus/attachments/` und reisen beim Kopieren mit
- **Lesezeichen mit eigenem Vermerk** an jeder Position: Manga-Seite, Hörbuch-Zeitstempel, PDF-Seite, EPUB-CFI. Mit Farbe, Label und Notiz — für Lehr-Hörbücher und Nachschlagewerke der eigentlich wichtige Teil
- **Benutzerdefinierte Eigenschaften** pro Medientyp (EAV)

### 3.3 Backup und Export

**Backup** — Absicherung gegen Verlust. Früh umsetzen, damit Testläufe nicht bei null anfangen.
- Einstellungen und App-Konfiguration als JSON exportieren/importieren
- `index.db` automatisch sichern vor jeder Migration
- Der Sidecar-Spiegel (2.2) ist die eigentliche Versicherung

**Export / „Mitgeben"** — zwei Modi:
- **Nackt**: nur die Mediendateien, ohne `_fundus/`. Für andere Menschen und fremde Player
- **Vollständig**: plus Notizen, Lesezeichen, Anhänge, Metadaten. Für den Umzug zwischen eigenen Bibliotheken

Beides kopierend oder verschiebend, auf Werk-, Serien- oder Sammlungsebene, mit Vorschau vor der Ausführung.

### 3.4 Duplikate

Für große, gewachsene Sammlungen ein Kernfeature:

- Exakte Duplikate über `content_hash`
- **Nah-Duplikate über pHash** — bei PDFs derselben Ausgabe in unterschiedlicher Qualität greift kein exakter Hash. MediaShelf hat die `phash`-Spalte samt Index bereits, befüllt sie aber nie
- **Duplikat-Ansicht** mit Gruppen, Vorschau nebeneinander und „diese behalten" — MediaVault berechnet Fingerprints und zeigt sie nirgends an
- Verknüpfen statt löschen als Alternative: eine Datei bleibt maßgeblich, die anderen verweisen darauf

### 3.5 Bibliothekswerkzeuge

Vom Nutzer ausgelöste Operationen an den Mediendateien selbst. Kein Echtzeit-Transcoding, sondern einmalige Umwandlungen — aber weil sie Originaldaten berühren, gelten dieselben Regeln wie bei MyFileSorters Dateioperationen: **in eine temporäre Datei schreiben, prüfen, Originale erst nach ausdrücklicher Bestätigung entfernen, journalisiert für Undo.**

- **MP3-Sammlung → eine M4B mit Kapiteln.** Das häufigste Bedürfnis bei gewachsenen Hörbuchsammlungen; Audiobookshelf bietet dasselbe an. Kapitelmarken entstehen aus den Track-Grenzen und -Titeln
- **Tag-Rückschrieb** in die Mediendatei (ID3, MP4-Atome): Damit auch fremde Player die in Fundus korrigierten Titel, Autoren und Serien sehen. Standardmäßig aus, pro Werk oder als Massenoperation auslösbar
- **Kompatible Varianten und Download-Varianten** nach 2.4: zielgerätetaugliche oder kleinere Fassung erzeugen, als eigene `work_files`-Variante behalten und eindeutig mit dem Original verknüpfen

Alles davon nach dem ersten Meilenstein.

### 3.6 Archive als virtuelle Ordner

ZIP-Dateien lassen sich wie in einem Dateimanager **temporär als schreibgeschützte Ordner öffnen**, ohne das gesamte Archiv vorab zu entpacken.

- Fundus liest zunächst nur das Inhaltsverzeichnis und zeigt Ordner, Dateien, Größen, Änderungsdaten und erkannte Medientypen an.
- Vorschau und Öffnen extrahieren nur den gewählten Eintrag in einen begrenzten App-Cache; unterstützte Bilder, Texte, Audio-/Videodateien, PDFs und E-Books öffnen in den normalen Fundus-Viewern.
- Einzelne Einträge oder ausgewählte Ordner können gezielt nach außen extrahiert oder als neues Werk importiert werden.
- Die Ansicht verändert das Archiv nie. Bearbeiten bedeutet immer „entpacken, ändern, bewusst als neues Archiv schreiben".
- Pfade werden vor dem Extrahieren gegen absolute Pfade, `..`, Symlinks und andere Zip-Slip-Varianten geprüft. Grenzen für Eintragszahl, Gesamtausgabe, Einzeldatei, Verschachtelung und Kompressionsverhältnis schützen gegen Zip-Bombs.
- Verschlüsselte oder beschädigte Archive erhalten eine klare Meldung; Passwörter werden nur für die Sitzung gespeichert, sofern der Nutzer nicht ausdrücklich den sicheren Gerätespeicher wählt.
- Cache-Dateien werden beim Schließen beziehungsweise nach einer einstellbaren Frist entfernt; ein Wartungsbefehl leert den Cache sofort.

ZIP ist der erste unterstützte Archivtyp. 7z, RAR, TAR und weitere Formate laufen über dieselbe virtuelle Schnittstelle und können später durch austauschbare Backends ergänzt werden. **CBZ** benutzt technisch ZIP, wird aber beim Manga-Meilenstein als eigenes Werk mit Seitenreihenfolge, Leserichtung und Resume behandelt.

### 3.7 Einstellungen und Individualisierung

Fundus soll möglichst weitgehend an den eigenen Arbeitsablauf anpassbar sein, ohne dass abgeschaltete Oberflächen Nutzerdaten löschen. Einstellungen sind durchsuchbar, nach Kategorien gegliedert, versioniert und als JSON exportier-/importierbar. Jede Seite bietet „Standard wiederherstellen"; Import zeigt vorab, welche Werte sich ändern.

**Geltungsbereiche:** Jede Einstellung ist ausdrücklich `Gerät`, `Server`, `Bibliothek` oder `synchronisiertes Nutzerprofil`. Beispielsweise ist Schütteln gerätespezifisch, eine Scan-Ignore-Liste bibliotheksspezifisch und die bevorzugte Metadatensprache nutzerspezifisch. Die Oberfläche zeigt den Geltungsbereich, damit eine Änderung auf dem Handy nicht überraschend den Desktop umbaut.

**Kategorien und Beispiele:**

| Bereich | Steuerbare Punkte |
|---|---|
| Darstellung | Hell/Dunkel/System, Akzent, Dichte, Rastergröße, Listenzeilen, sichtbare Spalten, Panelbreiten, Cover-Seitenverhältnis, Animationen |
| Navigation | sichtbare Medientypen und Module, angeheftete Sammlungen, Startansicht, Detailpanel-Verhalten, Kürzel und Kommandopalette |
| Suche | Fuzzy an/aus, Fehlertoleranz, Standardscope, Standardfilter, Standardsortierung, Suchverlauf |
| Bibliothek & Scan | Ignore-Regeln, Symlinks, Dateitypen, Hash-Strategie, Watcher, Thumbnail-Qualität, Offline-/Missing-Fristen |
| Metadaten | aktive Provider, Reihenfolge, Region/Sprache, automatische Vorschläge, geschützte Felder, Cover-Regeln |
| Wiedergabe | Resume-Verhalten, Sprungweite, Geschwindigkeitsschritte, Auto-Play, Queue/Repeat, Kapitelverhalten, Audio-Session |
| Sleep-Timer | Vorgabedauer, Kapitel-/Titelende, Ausblenddauer, Schütteln, Empfindlichkeit, Verlängerung, Vibration |
| Downloads & Codecs | Speicherlimit, Zielordner, automatische Bereinigung, Zielgeräteprofile, Varianten-Presets, FFmpeg/externe Werkzeuge |
| Server & Sync | Anzeigename, Interfaces, Pairing, Geräteschlüssel, Sync-Intervall, Konfliktverhalten, Revisionshistorie |
| Notizen & Datenschutz | Editor, Wiki-Links, Anhänge, Diagnoseprotokoll, Verlauf und Statistik einzeln abschaltbar |
| Erweitert | Sidecar-Verhalten, Cache-Limits, experimentelle Funktionen, Diagnose und Datenbankwartung |

Module wie Statistiken, Notizen, Online-Anreicherung, Duplikatprüfung oder Archive können in der Navigation ausgeblendet beziehungsweise funktional deaktiviert werden. Kritische Integritäts-, Sicherheits- und Backup-Prüfungen bleiben aktiv oder verlangen beim Abschalten eine verständliche Bestätigung. Gefährliche Optionen leben in einem expliziten Expertenmodus.

MediaShelfs vorhandene Einstellungen für Rastergröße, Panel-Sichtbarkeit/-breite und frei konfigurierbare Listenspalten sind hierfür ein brauchbares Muster; übernommen wird das Verhalten, nicht die verteilte Speicherung in vielen unabhängigen Preference-Notifiers. Fundus verwendet stattdessen ein typisiertes, migrierbares Einstellungsschema mit Validierung.

---

## 4. Leitprinzipien

Was das Design durchgängig bestimmt:

- **Local-first.** LAN und VPN, keine Cloud, keine Konten nach außen, keine Telemetrie. Der Server bindet standardmäßig nicht auf `0.0.0.0`
- **Ein Nutzer im Fokus, mehrere Geräte.** Keine Benutzerverwaltung in der Oberfläche, aber `user_id` von Anfang an im Schema reserviert
- **Direct Play als Normalfall.** libmpv/FFmpeg deckt eine breite Formatbasis ab; der Geräte-Abnahmetest macht die verbleibenden Ausnahmen sichtbar. Umwandlung ist eine bewusste Aktion (2.4 und 3.5), kein stiller Automatismus
- **Nutzerdaten in Klartext gespiegelt.** Notizen und Metadaten überleben den Verlust der Datenbank und sind ohne Fundus lesbar
- **Nichts wird still überschrieben.** Das Herkunftsmodell (2.3) gilt für jede Anreicherung, jeden Import und jeden Rückschrieb
- **Die Bibliothek bleibt ohne Fundus nutzbar.** Etablierte Ordnerkonventionen statt eigener Erfindungen, damit Audiobookshelf, Plex oder Kavita dieselben Ordner lesen können
- **Ein Schreiber pro Werk, und nur solange nötig** (siehe 5)

---

## 5. Zusammenspiel der drei Apps

Lose gekoppelt: kein Socket, keine gemeinsame Datenbank, kein API-Vertrag, keine synchronisierten Releases. Der Test ist, ob man jede einzelne App löschen kann, ohne dass die anderen brechen.

```
mAngler                MyFileSorter              Fundus
(abonnieren,           (erkennen, benennen,      (verwalten, anreichern,
 herunterladen)         verschieben)              lesen, abspielen)
     │                        │                        │
     └──► Inbox/ ────────────►└──► Bibliothek ────────►┘
          (.staging-Übergabe)      (ABS/Calibre/Plex/
                                    Komga-Konvention)
```

mAngler und MyFileSorter sind **Werkzeuge zur Beschaffung und Benennung**. Sie liefern ab — danach gehört das Werk Fundus. Vieles kommt ohnehin nie durch die beiden hindurch: Dokumente, Office-Dateien, direkt gekaufte Medien landen unmittelbar in der Bibliothek.

### 5.1 Übergabe und befristeter Besitz

**Nach der Übergabe darf Fundus alles** — bearbeiten, anreichern, taggen, umbenennen, verschieben, umwandeln.

Die einzige Ausnahme sind **laufende Werke**: eine Webnovel, die noch Kapitel bekommt, ein Manga, der weiterläuft. Dort muss mAngler nachlegen können und darf den Ordner nicht unter sich weggezogen bekommen. Gelöst über eine Zustandsdatei im Werk-Ordner:

```
Webnovels/Shadow Slave/
  Shadow Slave - Kapitel 1-40.epub
  _source.json          ← gehört mAngler, solange status: ongoing
  _fundus/              ← gehört immer Fundus
    meta.yaml  notes.md  bookmarks.yaml
```

```json
{
  "app": "mangler",
  "adapter": "novelupdates",
  "subscription_id": "a3f9…",
  "url": "https://…",
  "status": "ongoing",
  "known_chapters": [1, 40],
  "last_check": "2026-08-08T12:00:00Z"
}
```

**Getrennte Namensräume.** mAngler fasst `_fundus/` nie an, Fundus fasst `_source.json` nie an. Fundus kann deshalb **ab dem ersten Moment** taggen, bewerten, Notizen schreiben und Fortschritt tracken — auch bei laufenden Werken.

**Befristet gesperrt ist nur Verschieben und Umbenennen**, und nur solange `status: ongoing`. Fundus zeigt das sichtbar an. Steht `status: complete`, gibt mAngler frei und Fundus darf alles. Werke ohne `_source.json` — also der Großteil der Bibliothek — sind nie gesperrt.

`complete` wird gesetzt, wenn die Quelle die Serie als abgeschlossen meldet, oder von Hand in einer der beiden Apps.

**Zwei Nebeneffekte, die wichtiger sind als sie klingen:**

1. **mAngler braucht keine eigene Abo-Datenbank mehr.** Es findet seine Abos durch einen Scan nach `_source.json`. Die Bibliothek *ist* sein Zustand. Das räumt die im MediaVault-Deep-Dive dokumentierte Fehlerklasse ab, bei der Ordnernamen bei jedem Zugriff neu aus dem gescrapten Titel abgeleitet wurden — mit der Folge, dass ein leerer Titel den Papierkorb treffen konnte.
2. **Das System wird selbstheilend.** Wird ein laufendes Werk doch verschoben, findet mAngler es beim nächsten Scan über die `subscription_id` wieder, statt es zu verlieren oder doppelt anzulegen.

### 5.2 Weitere Regeln

- **Zielkonventionen werden nicht erfunden, sondern übernommen**: Audiobookshelf für Hörbücher, Calibre für E-Books, Plex/Jellyfin für Film und Serie, Komga/Kavita für Manga
- **Atomare Übergabe.** mAngler schreibt nach `.staging/` und macht erst am Ende ein `rename` in die Inbox. Ordner ohne Abschlussmarkierung ignoriert MyFileSorter
- **Große Reorganisationen** (Hunderte Dateien über Volume-Grenzen) delegiert Fundus später an MyFileSorters CLI, weil dort Journal, Verifikation und Undo bereits existieren — mit eigenem einfachem Fallback, falls das Binary fehlt. Einzelne Umbenennungen macht Fundus direkt
- **Podcasts** verwaltet Fundus nativ, inklusive Feeds und Episoden-Download. Der Umweg über zwei Apps pro Episode wäre unverhältnismäßig

### 5.3 Zustand der Nachbarprojekte

**MyFileSorter bleibt unverändert.** Es erzeugt heute genau die ABS-Struktur, die Fundus im ersten Meilenstein liest. Die Verallgemeinerung auf `MediaKind` wird erst fällig, wenn dort der zweite Medientyp dazukommt.

**mAngler** entsteht als **vollständige Kopie des MediaVault-Repos** in ein neues Repo. MediaVault bleibt unangetastet als lauffähiger Rückfallstand. In mAngler wird anschließend die DAM-Hälfte entfernt (`vault`, `playlist`, `progress`, `properties`, `import`, `duplicate`, Grid-UI, AniList/Audible/Goodreads/ABS) und der Downloader ausgebaut.

> Hinweis zur Disziplin: Zwei Repos mit gemeinsamer Historie driften auseinander, und es passiert leicht, dass ein Fix im falschen landet. Sobald mAngler läuft, sollte MediaVaults README einen deutlichen Vermerk „archiviert, Weiterentwicklung in mAngler" bekommen.

---

## 6. Bewusst vertagt

Nicht ausgeschlossen, aber nicht jetzt — mit dem Auslöser, der die Entscheidung neu aufwirft:

| Thema | Stand | Wann wieder ansehen |
|---|---|---|
| Echtzeit-Transcoding beim Streamen | Nicht geplant | Nur falls ein Gerät ein Format tatsächlich nicht abspielt. Bisher kein bekannter Fall |
| Kompatible Varianten / kleinere Downloads | Eingeplant (2.4, 3.5) | Task-Engine und Presets nach Meilenstein 1; Codec-Erkennung und Zielprofile bereits in Meilenstein 1 |
| M4B-Zusammenführung, Tag-Rückschrieb | Eingeplant (3.5) | Nach Meilenstein 1 |
| Mehrbenutzer-Oberfläche | Nicht geplant, Spalte reserviert | Wenn jemand im Haushalt eigenen Fortschritt braucht |
| iOS / iPadOS | Zurückgestellt | Sobald ein Apple-Developer-Account vorliegt — reine Distributionsfrage, die Architektur schließt es nicht aus |
| Live-Push des Fortschritts (WebSocket) | Nicht v1 | Wenn der Abgleich beim Verbinden sich zu träge anfühlt |
| Headless-Server auf NAS | Vorbereitet durch `packages/server/` | Wenn der Desktop nicht mehr durchlaufen soll |

**Dauerhaft ausgeschlossen** bleibt nur, was dem Local-first-Prinzip widerspricht: Cloud-Synchronisation, Zugriff über das offene Internet ohne VPN, Telemetrie.

---

## 7. Erster Meilenstein: Hörbücher und Hörspiele

Ein Medientyp vertikal statt einer Schicht horizontal. Hörbücher erzwingen den Entity-Layer ohnehin — 30 Dateien, ein Werk, eine Resume-Position — und die vorhandene Sammlung liegt bereits korrekt in ABS-Struktur: saubere Testdaten, dokumentierte Konvention statt Ratearbeit.

1. **Repo-Grundgerüst** — Flutter, `app/` + `packages/core/` + `packages/server/`
2. **Schema** — `files`, `works`, `work_files`, `people`, `progress`, `play_events`, `notes`, `bookmarks`, `tags`, `collections`, `playlists`, `playback_sessions`, `playback_session_items`; `user_id` reserviert; Format-Versionierung nach 2.6
3. **Scanner** — Ignore-Liste, streamend, abbrechbar; technische Audio-/Codec-Parameter für die Kompatibilitätsprüfung erfassen
4. **ABS-Importer** — `Autor/Serie/NN - Titel/` in Werke überführen, Audiodateien eines Ordners nach Tracknummer zu **einem** Werk gruppieren, eingebettete Tags und Ordner-Cover übernehmen
5. **Metadaten bearbeiten + Audible-Abgleich** mit Herkunftsmodell nach 2.3
6. **Desktop-Wiedergabe auf Werk- und Playlist-Ebene** — durchgehend über Datei- und Titelgrenzen, Sitzungs-Snapshot, Resume, Geschwindigkeit, Sleep-Timer, Kapitelsprünge
7. **Server** — Werkliste, Detail, Cover, Streaming mit `Range`, Download, Fortschritt
8. **Android-Client** — Browsen, Streaming, Offline-Download, Hintergrundwiedergabe mit Lockscreen-Steuerung, Fortschritts-Sync und optionalem Schütteln zum Verlängern des Sleep-Timers
9. **Einstellungszentrum + Backup** — typisiertes Schema nach 3.7 und Export/Import früh, damit Testläufe nicht bei null beginnen
10. **Notizen und Lesezeichen** in der Grundform, inklusive Sidecar-Spiegel
11. **Suche und Bibliotheksansichten** — FTS5 + Fuzzy-Stufe, kombinierbare Filter-Chips, Sortierung und gespeicherte Filter
12. **Audio-Kompatibilitätsprofil** — Desktop/Android-Abnahmetest, Warnung pro Datei und Navigation zur betroffenen Datei; Varianten-Erzeugung folgt als Bibliothekswerkzeug nach Meilenstein 1

**Aus MediaShelf übernehmen** (nach Prüfung): `core/safe_paths.dart` inklusive Tests (bestgebaute Datei des Repos), `core/mime_resolver.dart`, `data/thumbnailer/`, `data/watcher/`, `core/epub_parser.dart`, der AniList-Client aus `external_metadata_service.dart`, der Player-Screen als Ausgangspunkt, der Scanner als Muster, der erprobte Abhängigkeitsblock aus der pubspec. Als Verhaltensvorlage zusätzlich: konfigurierbare Rastergröße, Panelbreiten und Listenspalten aus `settings_provider.dart` sowie Queue-Reihenfolge, Shuffle und Repeat aus `queue_provider.dart`.

**Aus MediaVault als Muster übernehmen:** `core/playlist.rs` trennt bereits manuelle, smarte und serienbasierte Playlists und besitzt einen einfachen `PlaylistCursor`. Fundus erweitert das zu den stabilen, werkbasierten und revisionierten `playback_sessions` aus 2.4; pfadbasierte Cursor werden nicht übernommen.

**Bewusst nicht übernehmen:** das flache Schema; `sidebar.dart` (1490 Zeilen), `detail_panel.dart` (1292), `settings_screen.dart` (966); die Dateinamen-Verschleierung (funktionslos — die Einstellung wird geschrieben und nie gelesen); `decryptToTemp` (schreibt Klartext nach `/tmp` und löscht nie); der DriveThruRPG-Scraper (gehört zu mAngler).

**Von Anfang an anders:** i18n ab dem ersten String (MediaShelf mischt 71 deutsche unter 299 UI-Strings); Light- und Dark-Theme; Tastaturkürzel als eigene Schicht; Logger mit Dateiausgabe (MediaShelf hat 13× `catch (_) {}` und null Logging); Indizes und FTS idempotent in `beforeOpen`; Massenoperationen in Transaktionen; Hash auf **BLAKE3** statt MD5.

### Verifikation

1. **Import** — auf den bestehenden ABS-Ordner richten. Serien als Elternknoten, Bände als Werke, mehrteilige Hörbücher als *ein* Eintrag statt 30 Dateien
2. **Resume über Dateigrenzen** — bei Track 7 Minute 12 verlassen, neu starten, an derselben Stelle fortsetzen. Der Test, den das alte Modell nicht bestehen kann
3. **Herkunftsmodell** — Titel von Hand ändern, danach Audible-Abgleich laufen lassen. Der Handeintrag bleibt erhalten und wird nicht überschrieben
4. **Server** — `curl` mit `Range`-Header, Teilantwort `206`. Zugriff ohne Token wird abgelehnt
5. **Mobile end-to-end** — Handy per QR koppeln, Hörbuch laden, Flugmodus, 10 Minuten hören, wieder verbinden. Fortschritt steht auf dem Desktop. Danach umgekehrt
6. **Sync-Konflikt** — Desktop steht bei `01:12:08`, ein offline weitergelaufenes Handy bei `01:36:41`: Dialog zeigt beide Geräte, Zeiten, Kapitel und Prozentwerte; die Wahl ist anschließend auf beiden Geräten identisch und über die Historie rückholbar
7. **Playlist-Resume** — Smart Playlist starten, Shuffle aktivieren, beim fünften Titel pausieren und danach die Filterregel ändern. Fundus setzt die alte Sitzung mit identischer Reihenfolge und Titelposition fort und bietet getrennt die Übertragung auf die neue Playlist an
8. **Fuzzy-Suche** — absichtlich falsch geschriebenen Autoren-/Titelbegriff suchen, nach Hörbuch + begonnen filtern und nach zuletzt gehört sortieren; Ergebnis und aktiver Zustand bleiben nach Öffnen/Zurück erhalten
9. **Codec-Profil** — eine absichtlich inkompatible Audio-Testdatei wird für das gekoppelte Android-Gerät markiert; der Hinweis führt exakt zur Datei und erklärt Codec/Profil
10. **Sleep-Timer mobil** — Timer läuft, Schütteln ist aktiviert: ein gültiges Schüttelereignis verlängert einmal und bestätigt per Vibration/Einblendung; Bewegungen innerhalb des Cooldowns verlängern nicht erneut
11. **Sidecar-Spiegel** — Notiz anlegen, `index.db` löschen, neu scannen. Notiz ist wieder da
12. **Einstellungen** — gerätespezifisches Schütteln und bibliotheksspezifische Scan-Regel exportieren/importieren; Vorschau und Geltungsbereiche sind korrekt, ungültige Werte werden abgelehnt
13. **Versionierung** — Bibliothek mit erhöhter `format_version` mit älterer App öffnen: Lesemodus mit Hinweis, keine Änderung
14. **Automatisiert** — Unit-Tests für den ABS-Pfad-Parser mit Fixtures aus der echten Sammlung (Umlaute, Dezimal-Bandnummern, Ordner ohne Serie), für Werk-Gruppierung, Playlist-Snapshots, Konfliktvergleich, Suchranking, Einstellungsmigrationen und Server-Endpunkte. MediaShelf hat 3 Testdateien auf 37k Zeilen — das wird nicht wiederholt

---

## 8. Zweiter Meilenstein: TTRPG-Sammlung

Bewusst vor Filmen, weil dieser Typ die *andere* Hälfte des Modells testet — und weil die Sammlung heute unbrauchbar ist.

**Er ist nicht flach.** Eine D&D-5E-Sammlung mit tausenden Dateien gliedert sich nach mehreren Achsen gleichzeitig:

- System (D&D 5E, Pathfinder, d20) · Welt/Setting (Forgotten Realms, Ravenloft, Eberron) · Verlag (offiziell vs. Drittanbieter) · Inhaltsart (Regelwerk, Abenteuer, Karte, Token, Charakterbogen) · Edition/Auflage

**Der entscheidende Punkt: Dasselbe Produkt gehört legitim in mehrere Bäume** — nach System, nach Welt, nach Verlag, nach Kampagne. Ein einzelner Ordnerbaum kann das nicht abbilden. Genau deshalb *fühlt* sich die Sammlung durcheinander an, und genau deshalb ist hier die DAM-Schicht wichtiger als irgendwo sonst.

Das Modell deckt das mit drei Mitteln gleichzeitig ab, ohne Erweiterung:

| Mittel | Rolle bei TTRPG |
|---|---|
| `works` + `parent_id` | Produktlinie → Produkt; ein Boxed Set = **ein** Werk mit PDF, Karten, Handouts, Tokens |
| `collections` (many-to-many) | Die frei wählbaren Bäume: nach System, nach Welt, „Kampagne Sommer 2026" |
| `property_definitions` + Tags | System, Setting, Verlag, Inhaltsart, Edition als filter- und facettierbare Felder |

Bringt zusätzlich: die Duplikat-Ansicht (dieselbe PDF aus mehreren Bundles), Massenbearbeitung (400 Dateien auf einmal taggen — deshalb Transaktionen), die Leistungsprobe bei ~100k Dateien und den **virtuellen Archivbrowser aus 3.6**. Gerade TTRPG-Bundles liegen häufig als ZIP mit PDFs, Karten, Handouts und Tokens vor; Fundus kann den Inhalt vor einem Import prüfen und ausgewählte Teile anschließend zu einem gemeinsamen Werk entpacken. Der Abnahmetest umfasst ein großes Archiv, verschachtelte Ordner, einen beschädigten Eintrag und eine Zip-Slip-/Zip-Bomb-Testdatei.

**Zur Einordnung:** Nach diesen beiden Typen ist die *Architektur* bewiesen — Hierarchie, Facettierung, Werke aus vielen Dateien, Fortschritt, Anreicherung. Filme, Musik und Podcasts sind dann strukturelle Wiederholungen. Was pro Typ trotzdem bleibt, ist die jeweilige Oberfläche: ein Manga-Reader mit Doppelseiten und Leserichtung ist echte Arbeit, auch wenn das Datenmodell steht.

---

## 9. Danach

1. Filme/Serien/Anime, Musik
2. Manga/Comics inklusive Reader (Doppelseiten, Leserichtung, CBZ)
3. Podcasts nativ in Fundus (Feeds, Episoden, Auto-Download)
4. Bibliothekswerkzeuge nach 3.5 (M4B-Zusammenführung, Tag-Rückschrieb, kompatible Geräte-/Download-Varianten)
5. mAngler: Vollkopie anlegen, DAM-Hälfte entfernen, `_source.json` und `.staging`-Übergabe
6. MyFileSorter auf `MediaKind` verallgemeinern, bevor dort der zweite Typ dazukommt

---

## 10. Offene Punkte

- **Namensverfügbarkeit** für „Fundus" und „mAngler" gegen GitHub und Play Store prüfen
- **Umgang mit verschwundenen Dateien**: Werk mit Status `missing` behalten, damit Notizen und Fortschritt nicht verloren gehen — bei portablen Datenträgern der Normalfall, nicht die Ausnahme
- **Leistungsziele** festlegen (Referenz: Scandauer und Scrollverhalten bei ~100k Dateien)
- **Einmaliger Importpfad** aus bestehenden MediaShelf-Bibliotheken
- **Manga-Reader**: Doppelseiten, Leserichtung, CBZ-Handhabung — für die Planung des dritten Typs
- **`_source.json` gegenzeichnen**: Das Schema sollte mit mAngler zusammen festgelegt werden, bevor beide Seiten es implementieren
