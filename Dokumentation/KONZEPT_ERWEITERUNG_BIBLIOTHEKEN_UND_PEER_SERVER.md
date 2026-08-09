# Konzept-Erweiterung: Bibliotheken, Ordnerstruktur und Peer-Server

> Stand: 2026-08-09  
> Status: verbindliche Ergänzung zum Fundus-Konzept  
> Betrifft: Bibliotheksgrenzen, physische Ordnerstruktur, Geräteerkennung,
> Freigaben, Streaming und Synchronisation

---

## 1. Entscheidungen in Kurzform

1. Eine Fundus-Bibliothek ist **medienübergreifend**. Sie kann gleichzeitig
   Hörbücher, Filme, Serien, E-Books, Manga, Musik, Podcasts, Bilder,
   Dokumente, Archive und weitere Medientypen enthalten.
2. Medientypen sind **keine eigenen Bibliotheken**, sondern standardmäßig
   Bereiche beziehungsweise oberste Inhaltsordner innerhalb einer Bibliothek.
3. Mehrere Bibliotheken werden nach betrieblichen Grenzen angelegt: anderer
   Datenträger, andere Freigaben, Datenschutz, Backup, Besitzer oder
   Verfügbarkeit — nicht allein wegen des Medientyps.
4. Jede Fundus-Installation ist ein **Gerät/Peer**. Ein Peer kann gleichzeitig
   eigene Bibliotheken bereitstellen und Bibliotheken anderer Peers verwenden.
   Eine feste Rolle `Server` oder `Client` gibt es nicht.
5. Ein Gerät stellt alle freigegebenen und aktuell erreichbaren Bibliotheken
   gleichzeitig bereit. In der lokalen Oberfläche zwischen Bibliotheken zu
   wechseln, verändert die Serverfreigabe nicht.
6. Remote-Bibliotheken und Offline-Downloads werden nicht automatisch erneut
   freigegeben. So entstehen keine Schleifen, ungewollten Kopien oder
   mehrdeutigen Zuständigkeiten.
7. Der Speicherort ist nicht die Identität eines Werks. Fundus soll Werke
   vorrangig über stabile IDs und Metadaten erkennen; Ordnernamen bleiben ein
   wichtiges Erkennungs- und Kompatibilitätssignal.
8. Fundus besitzt feste Grundtypen für die jeweilige Medienlogik. Nutzer dürfen
   zusätzlich eigene Untertypen, Tags, Sammlungen und Eigenschaften anlegen.

---

## 2. Begriffe

| Begriff | Bedeutung |
|---|---|
| **Gerät / Peer** | Eine Fundus-Installation auf Desktop, Laptop, Smartphone, Tablet oder NAS |
| **Bibliothek** | Ein selbstenthaltender Medienbestand mit eigener `library_id`, `.library/` und Datenbank |
| **Medienbereich** | Ein oberster Inhaltsordner einer Bibliothek, beispielsweise `Audiobooks` oder `Movies` |
| **Grundtyp** | Von Fundus definierter Typ mit technischem Verhalten, beispielsweise `audiobook`, `podcast`, `image` oder `document` |
| **Eigener Typ** | Frei benannte Unterkategorie eines Grundtyps, beispielsweise `Backup` unter `archive` |
| **Werk** | Das logische Medium, etwa ein Hörbuch, Film, Serienepisode oder Buch |
| **Datei** | Die physische Datei, die einem Werk mit einer Rolle zugeordnet ist |
| **lokale Bibliothek** | Eine Bibliothek, deren Stammordner auf diesem Gerät erreichbar ist |
| **Remote-Bibliothek** | Eine Bibliothek, die ein gekoppelter Peer bereitstellt |
| **Offline-Kopie** | Lokal heruntergeladene Dateien einer Remote-Bibliothek; zunächst keine eigenständige Bibliothek |

Der Begriff **Server** bezeichnet künftig eine Fähigkeit eines Peers, keine
dauerhafte Geräterolle. In technischen Namen darf `server` weiterhin für den
eingebetteten HTTP-Dienst verwendet werden.

---

## 3. Was eine Bibliothek abgrenzt

### 3.1 Eine Bibliothek darf alle Medientypen enthalten

Empfohlenes Beispiel:

```text
Meine Medien/                         ← eine Bibliothek
  .library/
  Inbox/
  Audiobooks/
  Movies/
  TV Shows/
  Books/
  Manga/
  Music/
  Podcasts/
  Pictures/
  Documents/
  TTRPG/
  Archives/
```

`Audiobooks`, `Movies` und `TV Shows` sind hier keine Bibliotheken. Sie gehören
alle zur Bibliothek **Meine Medien**, teilen also:

- eine `library_id`;
- einen Index;
- gemeinsame Tags, Personen, Sammlungen und Suche;
- einheitliche Freigabe- und Backup-Regeln;
- dieselbe Erreichbarkeit, weil sie auf demselben Datenträger liegen.

Die Oberfläche kann trotzdem ausschließlich „Hörbücher“ oder „Filme“ anzeigen.
Die physische Ablage und die aktuelle UI-Ansicht sind voneinander unabhängig.

### 3.2 Wann eine zweite Bibliothek sinnvoll ist

Eine weitere Bibliothek ist sinnvoll, wenn mindestens eine dieser Grenzen
bewusst getrennt werden soll:

- anderer physischer Datenträger oder Netzwerkpfad;
- unterschiedliche Verfügbarkeit, etwa interne SSD und abziehbare Archivplatte;
- andere Personen oder Freigaberechte;
- private und gemeinsam genutzte Inhalte;
- getrennte Backup- und Aufbewahrungsregeln;
- Kinder-/Familienbestand;
- Test-, Arbeits- oder Archivbestand;
- Datenträger soll unabhängig transportierbar bleiben.

Beispiel:

```text
Gerät „Laptop"
  ├── Bibliothek „Meine Medien"       🟢 interne SSD
  │     ├── Audiobooks
  │     ├── Movies
  │     └── Books
  ├── Bibliothek „Familie"            🟢 NAS
  │     ├── Movies
  │     └── TV Shows
  └── Bibliothek „Archiv"             🔴 externe Platte fehlt
        ├── Audiobooks
        ├── Documents
        └── TTRPG
```

Jede dieser Bibliotheken kann wiederum eigene Hörbücher, Filme und andere
Medien enthalten.

---

## 4. Empfohlene physische Ordnerstruktur

### 4.1 Standardstruktur einer gemischten Bibliothek

```text
Meine Medien/
  .library/                            ← ausschließlich Fundus-intern
    version.json
    index.db
    config.yaml                        ← zukünftige Bereichs-/Scan-Konfiguration
    covers/
    thumbnails/

  Inbox/                               ← noch nicht einsortierte Inhalte

  Audiobooks/
    Aaron Oster/
      Master of Monster Arts/
        01 - Master of Monster Arts/
          01 - Master of Monster Arts.m4b
          cover.jpg
          metadata.json
          _fundus/
            meta.yaml
            notes.md
            bookmarks.yaml
            attachments/

  Movies/
    Dune (2021)/
      Dune (2021).mkv
      Dune (2021).de.srt
      cover.jpg
      _fundus/

  TV Shows/
    The Expanse/
      Season 01/
        S01E01 - Dulcinea.mkv
        S01E02 - The Big Empty.mkv
      _fundus/

  Books/
    Frank Herbert/
      Dune/
        01 - Dune/
          Dune.epub
          cover.jpg
          _fundus/

  Manga/
    Berserk/
      Volume 01/
        Berserk 01.cbz
        _fundus/

  Music/
    Artist/
      Album (Year)/
        01 - Track.flac

  Podcasts/
  Pictures/
  Documents/
  TTRPG/
  Archives/
```

Nicht jede Bibliothek muss alle Bereiche besitzen. Leere Standardordner müssen
nicht angelegt werden. Der Einrichtungsdialog bietet die gewünschten Bereiche
an und erstellt nur die ausgewählten.

### 4.2 Namen der Medienbereiche

Die oben genannten Namen sind portable Standardnamen, aber **keine hart
codierten Pflichtnamen**. Fundus speichert zukünftig eine Zuordnung in
`.library/config.yaml`:

```yaml
media_roots:
  audiobook:
    - Audiobooks
    - Hörbücher
  movie:
    - Movies
    - Filme
  tv:
    - TV Shows
    - Serien
  book:
    - Books
    - Bücher
  document:
    - Documents
    - Dokumente
  podcast:
    - Podcasts
  image:
    - Pictures
    - Bilder
    - Fotos
  archive:
    - Archives
    - Backups
```

Dadurch funktionieren deutsche Namen, bestehende Ordner und selbst gewählte
Strukturen. Die Oberfläche zeigt lokalisierte Bezeichnungen; der tatsächliche
Ordnername bleibt unverändert.

Die Medienbereich-Zuordnung ist ein starkes Erkennungssignal, aber nicht das
einzige. Dateityp, Sidecars, eingebettete Metadaten und Ordnerstruktur bleiben
weitere Signale. Fundus darf Inhalte in einem unbekannten Bereich anzeigen und
als „noch nicht zugeordnet“ markieren, statt sie zu ignorieren.

### 4.3 Wie Fundus ein Werk unabhängig vom Speicherort erkennt

Im Zielbild ist es grundsätzlich egal, an welcher Stelle innerhalb einer
Bibliothek ein Werk liegt. Ein Hörbuch bleibt ein Hörbuch, wenn es verschoben
oder in einem neutral benannten Ordner abgelegt wird. Fundus verwendet dazu die
folgenden Signale in absteigender Priorität:

1. stabile `work_id` und expliziter `base_kind` im Fundus-Sidecar;
2. kompatible Fremd-Sidecars wie `metadata.json` oder `_source.json`;
3. eingebettete Metadaten, MIME-Typ und Container-/Codec-Informationen;
4. der in `.library/config.yaml` konfigurierte Medienbereich;
5. Ordner- und Dateinamensmuster als Fallback.

Die Datenbank ist der schnelle lokale Index, aber nicht die einzige Wahrheit:
Sie muss nach Verlust oder auf einem anderen Gerät aus den Dateien, Sidecars
und eingebetteten Metadaten wiederaufgebaut werden können. Ein zukünftiges
Fundus-Sidecar kann beispielsweise enthalten:

```yaml
format_version: 2
work_id: 019fe6f4-6f91-7b30-9de8-98dce07bcfab
base_kind: audiobook
custom_type: null
```

Die physischen Typordner sind deshalb nicht bloß Kosmetik. Sie bieten:

- eine verständliche Ansicht in Finder, Explorer und Dateimanagern;
- einen sicheren Fallback, wenn Sidecars oder Datenbank fehlen;
- weniger Mehrdeutigkeiten und schnellere Teilscans;
- gezielte Quellen für Fremdprogramme: Plex kann beispielsweise nur `Movies/`
  und `TV Shows/`, Audiobookshelf nur `Audiobooks/` verwenden.

Eine neutrale, mit anderen Programmen kompatible Ablage ist ausdrücklich
erlaubt. Fundus darf daraus keine harte Pfadabhängigkeit ableiten. Beim
Verschieben ordnet Fundus die Datei über `work_id`, Hash und Metadaten wieder
dem bestehenden Werk zu, damit Fortschritt, Notizen und Lesezeichen erhalten
bleiben.

### 4.4 Regeln je Medientyp

#### Hörbücher

```text
Audiobooks/Autor/Serie/01 - Titel/Dateien
Audiobooks/Autor/Einzeltitel/Dateien
```

Die bestehende ABS-Struktur bleibt die empfohlene Struktur. Mehrere Tracks
werden zu einem Werk zusammengefasst.

#### Filme

```text
Movies/Titel (Jahr)/Titel (Jahr).mkv
```

Untertitel, Cover, alternative Audiospuren und kompatible Varianten gehören
zum selben Werkordner.

#### Serien und Anime

```text
TV Shows/Serientitel/Season 01/S01E01 - Episodentitel.mkv
```

Serie, Staffel und Episode werden als Werkhierarchie abgebildet. Specials
liegen in `Season 00`, sofern keine bestätigten Metadaten etwas anderes
festlegen.

#### E-Books und PDFs

Belletristik kann wie Hörbücher nach Autor und Reihe strukturiert werden.
Dokumente, Handbücher und lose PDFs gehören in `Documents` oder einen fachlich
benannten Unterordner.

#### Podcasts

```text
Podcasts/Podcasttitel/Episoden
```

Podcasts und Episoden sind eigene Grundtypen. Fundus verwaltet Feed-URL,
Episodennummer beziehungsweise Veröffentlichungsdatum, Downloadstatus und
individuellen Hörfortschritt. Manuell abgelegte Episoden funktionieren auch
ohne Feed; die Feed-Zuordnung ist optionale Metadatenanreicherung.

#### Bilder

```text
Pictures/Sammlung oder Ereignis/Bilddateien
```

Bilder erscheinen als eigener Eintrag in Navigation, Suche, Filterung und
Übersicht. Fundus unterstützt Einzelbilder ebenso wie Sammlungen, Alben oder
Bildfolgen. EXIF-Daten, Aufnahmedatum, Abmessungen, Bewertung, Personen, Tags
und Sammlungen bleiben unabhängig von der physischen Ordnerhierarchie nutzbar.

#### Archive und Backups

Archive können als virtuelle Ordner geöffnet oder als eigenständige Werke
verwaltet werden. `Backup` ist kein eigenes Wiedergabeformat, sondern sinnvoll
als eigener Untertyp des Grundtyps `archive` oder — bei Dokumentensätzen — als
Sammlung beziehungsweise Tag.

#### Gemischte Produkte

Ein TTRPG-Produkt, Kurs oder Archivpaket darf PDFs, Bilder, Audio und Anhänge in
einem Werkordner mischen. Der oberste Bereich beschreibt den **Werktyp**, nicht
jeden einzelnen Dateityp.

### 4.5 Sidecars und Metadaten

- `.library/` gehört zur gesamten Bibliothek.
- `_fundus/` gehört zu genau einem Werkordner.
- `cover.jpg`, eingebettete Cover und kompatible Fremd-Sidecars dürfen neben
  den Mediendateien liegen.
- `metadata.json` oder `_source.json` dürfen als Herkunftsdateien anderer
  Werkzeuge erhalten bleiben.
- Fundus verschiebt oder benennt Nutzerdateien niemals allein durch einen Scan.

### 4.6 Eigene Typen ohne Verlust der Medienlogik

Frei definierbare Typen sind vorgesehen, ersetzen aber nicht den technischen
Grundtyp. Die Trennung verhindert, dass Fundus bei einem selbst benannten Typ
nicht mehr weiß, welchen Player, Viewer, Fortschrittstyp oder Codec-Test es
verwenden muss.

| Wunsch | Empfohlene Abbildung |
|---|---|
| `Wichtig` medienübergreifend | Tag `Wichtig` oder intelligente Sammlung |
| `Wichtige Dokumente` | gespeicherter Filter `Grundtyp = Dokument` und `Tag = Wichtig` |
| `Backup` | eigener Typ `Backup` unter dem Grundtyp `archive` |
| `Steuerunterlagen` | eigener Typ unter `document`, optional zusätzlich Jahr als Eigenschaft |
| eigener physischer Ordner `Backups/` | Medienbereich mit Grundtyp `archive` und optional vorbelegtem eigenen Typ `Backup` |

Eigene Typen sind in Suche, Filterung, Gruppierung und Sortierung gleichwertig
nutzbar. Sie können Farbe, Symbol, sichtbare Eigenschaften, Standardansicht und
zulässige Grundtypen konfigurieren. Tags eignen sich für viele-zu-viele-
Merkmale, Sammlungen für bewusst zusammengestellte oder regelbasierte Mengen
und eigene Eigenschaften für strukturierte Werte wie Frist, Projekt oder
Aufbewahrungsdatum.

---

## 5. Umgang mit bestehenden Bibliotheken

> **Wichtig zum aktuellen Entwicklungsstand:** Der derzeitige Hörbuchimporter
> unterstützt inzwischen sowohl die bisherige Autorenebene unmittelbar unter
> der Bibliothekswurzel als auch konfigurierte Bereiche wie `Audiobooks/` oder
> `Hörbücher/`. Weitere Medientypen und die Oberfläche zur Konfiguration der
> Bereiche folgen schrittweise. Für eingelesene Hörbücher schreibt und liest
> Fundus inzwischen `work_id` und `base_kind` in `_fundus/meta.yaml`; beim
> Verschieben werden Resume und Lesezeichen auf die neuen Track-IDs umgesetzt.
> Für andere Medientypen gilt diese Zusage erst mit deren jeweiligem Importer.
> Größere Bestände sollten weiterhin über den zukünftigen Migrationsassistenten
> umsortiert werden, der vorab eine Vorschau und Konfliktprüfung anbietet.

Die aktuell verwendete Struktur

```text
Bibliothekswurzel/
  Aaron Oster/
  Lange, Cassius/
  William R. Forstchen/
```

ist eine gültige **Legacy-Hörbuchstruktur**. Sie muss nicht sofort geändert
werden. Fundus bietet zwei Wege:

### Weg A — unverändert weiterverwenden

Die Bibliothekswurzel wird als Medienbereich `audiobook` konfiguriert. Das ist
für reine Hörbuchbibliotheken weiterhin sinnvoll.

### Weg B — in eine gemischte Bibliothek überführen

```text
Bibliothekswurzel/
  Audiobooks/
    Aaron Oster/
    Lange, Cassius/
    William R. Forstchen/
  Documents/
    Dokumentation/
```

Dies ist die Empfehlung, wenn später Filme, Serien oder andere Medien auf
demselben Datenträger liegen sollen.

Die Umstellung erfolgt über einen überprüfbaren Migrationsplan:

1. Fundus erkennt vorhandene Autoren-/Serienstrukturen.
2. Die App zeigt jede geplante Verschiebung vorab an.
3. Konflikte, doppelte Zielpfade und fehlender Speicherplatz werden geprüft.
4. Die Anwendung verschiebt nur nach ausdrücklicher Bestätigung.
5. Werk- und Datei-IDs, Fortschritt, Tags, Notizen und Lesezeichen bleiben
   erhalten; die Datenbankpfade werden in derselben Operation aktualisiert.
6. Ein Protokoll und eine Rückgängig-Information werden geschrieben.

Ein manueller Umzug ist ebenfalls möglich, weil `_fundus/` mit dem Werk reist.
Der Index kann daraus neu aufgebaut werden. Für Fortschritt und stabile IDs ist
der Fundus-Migrationsdialog dennoch vorzuziehen.

`Dokumentation` aus dem aktuellen Beispiel sollte entweder als Inhalt unter
`Documents/` einsortiert oder über die Scan-Einstellungen ignoriert werden,
falls es keine zu verwaltenden Medien enthält.

---

## 6. Peer-Modell: Jeder Client kann Server sein

### 6.1 Keine exklusive Rollenwahl

MindFeed dient als Vorlage für:

- eingebetteten HTTP-Server;
- mDNS-Erkennung im lokalen Netz;
- Geräteidentität;
- Kopplung über Suche, QR-Code, PIN oder manuelle Adresse;
- Access-/Refresh-Token und widerrufbare Geräte.

Fundus übernimmt aber nicht die exklusive Auswahl `Server` oder `Client`.
Stattdessen besitzt jedes Gerät zwei unabhängige Fähigkeiten:

```text
[x] Bibliotheken anderer Geräte verwenden
[x] Bibliotheken dieses Geräts bereitstellen
```

Beide dürfen gleichzeitig aktiv sein.

### 6.2 Beispiel

```text
Laptop
  stellt bereit:
    ├── Meine Medien
    └── Archiv
  verwendet:
    └── Familienbibliothek vom NAS

Smartphone
  stellt bereit:
    └── Mobile Aufnahmen
  verwendet:
    ├── Meine Medien vom Laptop
    └── Familienbibliothek vom NAS

NAS
  stellt bereit:
    └── Familienbibliothek
```

Das Öffnen von „Meine Medien“ in der Laptop-Oberfläche beendet weder die
Freigabe von „Archiv“ noch die Verbindung zum NAS.

### 6.3 Identitäten und Adressierung

- `device_id`: stabile Identität einer Fundus-Installation;
- `library_id`: stabile Identität einer selbstenthaltenden Bibliothek;
- `work_id`: Werk innerhalb der Bibliothek;
- `file_id`: Datei innerhalb der Bibliothek;
- Netzwerkadresse: veränderlicher Endpunkt eines Geräts, niemals Identität.

Ein Werk wird über folgende Kombination eindeutig angesprochen:

```text
library_id + work_id
```

Der aktuelle Netzwerkweg enthält zusätzlich `device_id`, weil dieselbe
Bibliothek zu unterschiedlichen Zeiten über verschiedene Geräte erreichbar
sein kann.

### 6.4 Gleichzeitige Bereitstellung mehrerer Bibliotheken

Der eingebettete Server hält eine Registry aller lokalen Bibliotheken. Für jede
Bibliothek werden getrennt geführt:

- Pfad und `library_id`;
- Anzeigename;
- erreichbar / nicht erreichbar;
- Scanstatus;
- read-only / read-write;
- Freigabe aktiviert / deaktiviert;
- erlaubte Funktionen: Browsen, Streaming, Download, Fortschritt, Metadaten;
- zugelassene gekoppelte Geräte.

`GET /v1/libraries` liefert alle für das anfragende Gerät freigegebenen
Bibliotheken. Eine nicht angeschlossene externe Platte bleibt mit rotem Status
sichtbar, liefert aber keine Werke oder Dateien.

### 6.5 Discovery

Jeder Peer mit aktiver Freigabe kündigt einen Dienst wie `_fundus._tcp` per
mDNS an. Veröffentlicht werden nur minimale Angaben:

- `device_id`;
- Gerätename;
- Port;
- Protokollversion;
- unterstützte Fähigkeiten.

Bibliotheksnamen, Pfade, Tokens und Medieninhalte gehören nicht in die
mDNS-Ankündigung. Sie werden erst nach erfolgreicher Kopplung abgefragt.

### 6.6 Kopplung und Rechte

Kopplung erfolgt geräteweise über QR-Code, kurzlebige PIN oder manuelle
Adresse. Tokens werden sicher im Gerätespeicher abgelegt und sind widerrufbar.

Rechte werden pro Gerät und optional pro Bibliothek vergeben:

| Recht | Wirkung |
|---|---|
| `browse` | Bibliothek und Metadaten sehen |
| `stream` | Inhalte mit HTTP-Range streamen |
| `download` | Offline-Kopie anlegen |
| `progress` | Fortschritt, Sessions und Lesezeichen synchronisieren |
| `annotate` | Notizen, Tags und Bewertungen schreiben |
| `manage` | Bibliothek scannen und Einstellungen ändern |

Standard für ein neu gekoppeltes persönliches Gerät ist
`browse + stream + download + progress`. Schreibende Metadatenrechte werden
separat bestätigt.

### 6.7 Zuständigkeit und Konflikte

Die Autorität gilt **pro Bibliothek**, nicht mehr für einen globalen Server:

- Die lokale `.library/index.db` der bereitgestellten Bibliothek ist deren
  maßgeblicher Zustand.
- Clients senden idempotente Operationen mit `operation_id`, `device_id` und
  bekannter Revision.
- Offline-Änderungen warten in einer lokalen Queue.
- Eindeutig neuere Fortschritte werden übernommen.
- Unabhängige widersprüchliche Änderungen öffnen die bereits definierte
  Konfliktansicht mit Position, Zeit, Gerät und Feldunterschieden.

Wird eine externe Bibliothek an einen anderen Rechner gesteckt, reist ihre
`library_id` und Datenbank mit. Der neue Rechner kann sie anschließend unter
derselben Identität bereitstellen.

Eine normale Dateikopie einer Bibliothek wird **nicht automatisch als
schreibfähige Replik** behandelt. Der Kopier-/Klon-Dialog fragt:

- **Neue unabhängige Bibliothek:** neue `library_id`;
- **bewusste Replik:** gleiche `library_id`, zusätzliche Replikationsregeln.

Mehrfach beschreibbare Replikate sind ein späterer Ausbau. Für den ersten
Peer-Meilenstein gibt es pro Bibliothek jeweils nur eine aktive
Schreibautorität.

### 6.8 Keine automatische Weitergabe fremder Inhalte

Ein Peer stellt standardmäßig nur seine **lokalen, ausdrücklich freigegebenen
Bibliotheken** bereit.

- Remote-Bibliotheken werden nicht über einen zweiten Peer weitergereicht.
- Offline-Downloads bleiben Cache der Ursprungsbibliothek.
- Eine Weitergabe als Relay wäre eine eigene, standardmäßig deaktivierte
  Funktion mit sichtbarer Quelle und Rechteprüfung.

Das verhindert Kreise wie `Laptop → Handy → Laptop`, doppelte Suchtreffer und
unklare Fortschrittsautorität.

### 6.9 Mobile Geräte

Smartphones und Tablets besitzen dieselbe Peer-Fähigkeit. Der tatsächlich
erreichbare Serverbetrieb hängt jedoch davon ab, ob das Betriebssystem die App
aktiv laufen lässt. Die UI zeigt deshalb ausdrücklich:

- Freigabe aktiv und erreichbar;
- Freigabe aktiv, aber Betriebssystem hat den Dienst pausiert;
- nur im Vordergrund bereitstellen;
- dauerhaftes Bereitstellen nicht verfügbar.

Desktop, Laptop und NAS bleiben die bevorzugten dauerhaft erreichbaren Peers;
Mobile ist trotzdem kein künstlich eingeschränkter Nur-Client.

---

## 7. Oberfläche

Die primäre Medienübersicht enthält mindestens die Grundbereiche Hörbücher,
Filme & Serien, E-Books/PDFs, Musik, Podcasts, Bilder und Dokumente/Archive.
Weitere Grundtypen und eigene Typen können über die Einstellungen ein- oder
ausgeblendet, umbenannt und angeordnet werden. Eigene Typen erscheinen je nach
Wahl als Navigationseintrag, Filter oder gespeicherte Ansicht.

### 7.1 Quellenansicht

```text
Auf diesem Gerät
  ├── Meine Medien                 🟢
  └── Archiv                       🔴 Datenträger fehlt

Geräte
  ├── NAS zuhause                  🟢
  │     └── Familie                🟢
  └── Smartphone                   🟡 nur im Vordergrund
        └── Mobile Aufnahmen
```

Filter und Suche können wahlweise gelten für:

- aktuelle Bibliothek;
- alle Bibliotheken eines Geräts;
- alle erreichbaren Bibliotheken;
- lokale und heruntergeladene Inhalte.

Suchtreffer zeigen immer Gerät und Bibliothek. Derselbe Titel aus zwei
unabhängigen Bibliotheken wird nicht still zusammengeführt.

### 7.2 Geräteeinstellungen

- Gerätename;
- Bibliotheken anderer Geräte verwenden;
- eigene Bibliotheken bereitstellen;
- Netzwerkinterfaces und Port;
- nur LAN beziehungsweise zusätzlich VPN;
- gekoppelte Geräte und letzter Kontakt;
- Rechte je Gerät und Bibliothek;
- Pairing-Code/QR erzeugen;
- Serverstatus und Diagnose;
- Autostart und Verhalten im Hintergrund.

### 7.3 Bibliothekseinstellungen

- Anzeigename;
- Medienbereiche und zugehörige Ordner;
- Bereich hinzufügen, umbenennen oder zuordnen;
- Scan-/Ignore-Regeln;
- Freigabe aktiv;
- Berechtigungen;
- read-only und Datenträgerstatus;
- Migrationsassistent für Legacy-Strukturen.

---

## 8. Technische API-Richtung

Mindestendpunkte des eingebetteten Peer-Servers:

```text
GET  /v1/health
GET  /v1/capabilities
POST /v1/pairing/claim
POST /v1/pairing/refresh
GET  /v1/libraries
GET  /v1/libraries/{libraryId}/works
GET  /v1/libraries/{libraryId}/works/{workId}
GET  /v1/libraries/{libraryId}/files/{fileId}
GET  /v1/libraries/{libraryId}/files/{fileId}/content
GET  /v1/libraries/{libraryId}/progress/{workId}
PUT  /v1/libraries/{libraryId}/progress/{workId}
POST /v1/libraries/{libraryId}/sync/operations
```

Dateistreaming unterstützt zwingend `Range`, `206 Partial Content`, `ETag` und
Abbruch. Alle Pfade werden über IDs aufgelöst; absolute Dateisystempfade werden
nie an Clients übertragen.

Der Dienst bindet nur an ausdrücklich freigegebene LAN-/VPN-Interfaces. Keine
Freigabe ins öffentliche Internet, kein ungefragtes Port-Forwarding und keine
Tokens in Logs, QR-Verlauf oder mDNS.

---

## 9. Umsetzungsschritte

1. **Bibliotheksregistry lokal:** mehrere Bibliotheken gleichzeitig öffnen,
   Status prüfen und unabhängig von der aktuellen UI-Auswahl verwalten.
2. **Medienbereiche:** `config.yaml`, Standardbereiche, Legacy-Zuordnung und
   Scanner-Unterstützung für gemischte Bibliotheken einschließlich Podcasts
   und Bilder.
3. **Migrationsassistent:** Vorschau, Konfliktprüfung, sichere Verschiebung und
   Erhalt der Werk-/Nutzerdaten.
4. **Mehrbibliotheks-Server:** `/v1/libraries`, Werkliste, Details, Cover,
   `Range`-Streaming und Rechte pro Bibliothek.
5. **Peer-Identität und Discovery:** stabile `device_id`, mDNS und
   Fähigkeitsabfrage.
6. **Pairing:** QR/PIN/manuell, sichere Tokens, Widerruf und Berechtigungen.
7. **Remote-Quellenansicht:** Geräte → Bibliotheken → Werke, Status und
   kombinierte Suche.
8. **Fortschritt und Offline-Queue:** idempotente Operationen, Revisionen und
   Konfliktvergleich.
9. **Offline-Downloads:** Cache nach `device_id + library_id + work_id`, ohne
   automatische Weiterfreigabe.
10. **Mobile Peer-Fähigkeit:** sichtbare Laufzeitgrenzen und kontrollierter
    Vorder-/Hintergrundbetrieb.
11. **Ortsunabhängige Werke und eigene Typen:** stabile Werk-IDs und Grundtypen
    in Sidecars, Wiederzuordnung nach Verschieben sowie konfigurierbare
    Untertypen, Eigenschaften und gespeicherte Ansichten.

---

## 10. Abnahmekriterien

- Eine Bibliothek mit `Audiobooks`, `Movies` und `TV Shows` wird als **eine**
  Bibliothek geöffnet und kann nach Medientyp gefiltert werden.
- Podcasts und Bilder besitzen eigene Einträge in Navigation, Suche und
  Filterung und können innerhalb derselben Bibliothek liegen.
- Ein verschobenes Werk mit stabiler `work_id` wird wiedererkannt; Fortschritt,
  Tags, Notizen und Lesezeichen bleiben erhalten.
- Ein eigener Typ `Backup` unter dem Grundtyp `archive` kann angelegt, gesucht,
  gefiltert, gruppiert und sortiert werden, ohne die Archivlogik zu verlieren.
- Eine reine Legacy-Hörbuchbibliothek ohne Typ-Überordner bleibt lesbar.
- Der Migrationsplan verschiebt nichts ohne Bestätigung und erhält Fortschritt,
  Tags, Notizen und Lesezeichen.
- Ein Laptop stellt zwei lokale Bibliotheken gleichzeitig bereit, auch wenn in
  seiner UI nur eine dritte Remote-Bibliothek geöffnet ist.
- Ein Smartphone kann gleichzeitig vom Laptop streamen und eine eigene lokale
  Bibliothek freigeben.
- Eine fehlende externe Bibliothek bleibt rot sichtbar, ohne den Server oder
  andere Bibliotheken zu blockieren.
- Remote-Inhalte werden nicht automatisch über einen weiteren Peer angeboten.
- Ein nicht gekoppeltes Gerät sieht weder Bibliotheksnamen noch Inhalte.
- Streaming unterstützt Seek über HTTP-Range.
- Fortschrittsoperationen können nach Verbindungsabbruch wiederholt werden,
  ohne doppelte Revisionen zu erzeugen.
