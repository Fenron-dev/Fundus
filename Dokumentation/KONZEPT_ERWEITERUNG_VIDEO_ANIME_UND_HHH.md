# Konzept-Erweiterung: Video, Anime und appweiter HHH-Schutz

> Status: verbindliche Ergänzung zum Fundus-Konzept
>
> Stand: 30. August 2026
> Bezug: [KONZEPT.md](KONZEPT.md),
> [Bibliotheken und Peer-Server](KONZEPT_ERWEITERUNG_BIBLIOTHEKEN_UND_PEER_SERVER.md)
> und [Modulare Medien-Engine](KONZEPT_ERWEITERUNG_MEDIA_ENGINE_UND_MANGA_READER.md)

## 1. Ziel und Leitentscheidungen

Fundus baut Filme, Serien, Anime und HHH auf derselben **Video Engine** und der
gemeinsamen Media Experience Shell auf. Anime ist eine fachliche Kategorie mit
eigenem Metadatenanbieter und zusätzlichen Nummerierungsregeln, aber kein
zweiter Videoplayer.

**HHH** ist der einzige in der Oberfläche verwendete Name für explizite
Erwachseneninhalte. HHH ist weder nur ein Video-Genre noch ein Ordnername,
sondern eine appweite Sensitivitätsklasse. Sie kann deshalb ebenso ein Manga,
Webnovel, E-Book, Hörbuch, Bild, Dokument oder späteres Medium kennzeichnen.

Die drei zentralen Entscheidungen lauten:

1. **AniList ist Primäranbieter für Anime und HHH-Anime.** AniList liefert
   Seriendaten, alternative Titel, Format, Status, Saison, Episodenzahl,
   Laufzeit, Beziehungen, Mitwirkende, Studios, Cover, Banner, Tags und das
   explizite Feld `isAdult`.
2. **TMDB ist Primäranbieter für normale Filme und Serien.** TMDB bietet Suche,
   Detaildaten, Personen, Staffeln, Episoden, regionale Veröffentlichungen,
   Inhaltsfreigaben und externe IDs. TheTVDB bleibt ein optionaler Adapter und
   ID-Fallback, da dessen Nutzung eine projektspezifische Lizenz, Attribution
   und je nach Einsatz ein Abo beziehungsweise Nutzer-PIN verlangt.
3. **HHH wird zentral und serverseitig geschützt.** Ein ausgeblendeter Tab
   allein reicht nicht. Wenn HHH gesperrt ist, dürfen Titel und Vorschaubilder
   auch nicht in Suche, Dashboard, Fortsetzen, Personen, Tags, Playlists,
   Downloads, Benachrichtigungen, Logs oder Netzwerkantworten erscheinen.

## 2. Medienmodell

### 2.1 Fachliche Hierarchie

```text
Video-Bibliothek
├── Film
│   └── Medienfassung(en)
└── Serie
    ├── Staffel
    │   └── Episode
    │       └── Medienfassung(en)
    └── Specials / Staffel 00
```

- Film, Serie, Staffel und Episode erhalten stabile Werk-IDs.
- Eine Datei ist eine konkrete Medienfassung, nicht das Werk selbst.
- Fassungen können sich durch Auflösung, Schnitt, Sprache, Codec, HDR,
  Synchronisation oder Quelle unterscheiden.
- Anime, Animation, Realfilm, Dokumentation und HHH sind Facetten. Dieselbe
  Engine und dasselbe Fortschrittsmodell bleiben verwendbar.
- Serienfortschritt umfasst aktuelle Episode und Zeitposition; eine Episode
  besitzt zusätzlich ihren eigenen gesehen-/ungesehen-Zustand.
- Specials werden standardmäßig als Staffel 00 geführt. Ein bestätigter
  Provider-Treffer darf eine fachlich passendere Zuordnung liefern.

### 2.2 Klassifikation

Die Trennung von Medientyp, Darstellungsart und Schutzstufe ist verbindlich:

```text
media_kind: video | comic | publication | audio | image | ...
video_kind: movie | series | season | episode | extra
content_style: anime | animation | live_action | mixed | unknown
content_sensitivity: general | mature | adult_explicit | unknown
```

`adult_explicit` wird in der Oberfläche als **HHH** angezeigt. `mature` ist
nicht automatisch HHH. Dadurch verschwinden bei ausgeschaltetem HHH-Modus
nicht versehentlich alle Titel mit Gewalt, Horror oder einer hohen regulären
Altersfreigabe.

Die Herkunft der Einstufung wird wie jedes Metadatenfeld gespeichert:

1. manuelle Nutzereinstufung,
2. bestätigter Provider-Treffer,
3. Sidecar,
4. eingebettete Tags,
5. Ordner-/Dateinamenshinweis.

AniLists `isAdult: true` ist ein starkes Signal für `adult_explicit`, aber kein
unumkehrbares Urteil. Eine manuelle Einstufung hat Vorrang. Ein unbekannter
Titel wird niemals allein aufgrund eines mehrdeutigen Wortes automatisch als
HHH eingestuft. Die portable Sidecar-Datei hält Wert, Quelle und Revision.

## 3. HHH-Modus und Schutzumfang

### 3.1 Verhalten

Die Einstellung heißt **„HHH-Inhalte anzeigen“** und ist standardmäßig aus.
Sie gilt zunächst gerätebezogen, damit ein persönliches Gerät und ein gemeinsam
genutztes Gerät unterschiedlich geschützt werden können.

Ist HHH ausgeschaltet, werden zugehörige Werke vollständig ausgeschlossen aus:

- Bibliothekstabs, Ordner- und Serienansichten
- Dashboard, Fortsetzen, Verlauf und zuletzt hinzugefügt
- Suche, Fuzzy-Treffern, Filtern, Sortierwerten und Vorschlägen
- Personen-, Studio-, Autor-, Sprecher-, Tag- und Sammlungsansichten
- Playlists, Queues, Leselisten, Favoriten und Statistiken
- Downloadverwaltung, Offline-Bibliothek und fehlenden Medien
- Cover-, Banner- und Thumbnail-Caches in der sichtbaren Oberfläche
- Android-Medienbenachrichtigung, Sperrbildschirm und System-Recent-Aktivität
- Diagnoseoberfläche und normalen Diagnosemeldungen
- Serverkatalogen, Suchantworten, Fortschrittslisten und Push-Ereignissen für
  einen Client ohne HHH-Berechtigung.

Auch indirekte Lecks werden vermieden: Die normale Oberfläche zeigt weder
„3 ausgeblendete Titel“ noch leere Personen oder Tags, deren einziger Inhalt
HHH wäre. Eine gerade laufende HHH-Wiedergabe wird beim Sperren gestoppt und
aus der System-Mediensteuerung entfernt.

### 3.2 Schutzprofil statt bloßem Schalter

Für das Vorzeigen der App ist ein einfacher Schalter praktisch, aber nicht als
Kindersicherung belastbar. Fundus bietet deshalb zwei Stufen:

- **Sichtbarkeitsschalter:** schnelles Ein-/Ausblenden für das persönliche
  Gerät.
- **Geschützter HHH-Modus:** optional lokale PIN oder Geräteauthentifizierung
  zum Einschalten; sofortiges Sperren ohne erneute Abfrage.

Zusätzliche Optionen:

- bei App-Start, Geräte-Sperre oder nach einstellbarer Inaktivität sperren,
- Schnellaktion „HHH jetzt ausblenden“,
- Vorschaubilder beim Sperren aus dem flüchtigen Cache entfernen,
- pro gekoppeltem Client Berechtigung `allow_adult_explicit` vergeben und
  jederzeit widerrufen.

Der Server erzwingt die Berechtigung unabhängig von der Client-Oberfläche. Ein
älterer oder manipulierter Client darf den Filter nicht umgehen. HHH-Schutz
verschlüsselt jedoch keine frei im Dateisystem liegenden Mediendateien; eine
verschlüsselte Bibliothek wäre ein eigenes späteres Sicherheitsmerkmal.

### 3.3 Server und mehrere Bibliotheken

Der Server führt je Gerätekopplung eine Capability-/Policy-Menge. Ohne
`allow_adult_explicit` liefert er keine HHH-Metadaten, Dateien, Cover,
Fortschritte oder Treffermengen. Die Freigabe einer Bibliothek und die Freigabe
von HHH sind getrennte Entscheidungen.

Ein Client darf HHH zusätzlich lokal ausblenden, selbst wenn der Server es
freigibt. Die wirksame Richtlinie ist immer die strengere aus Serverfreigabe,
Geräteeinstellung und temporärer Sperre.

## 4. Metadatenanbieter

### 4.1 Gemeinsamer Provider-Vertrag

Provider werden als austauschbare Adapter implementiert:

- `search`: Kandidaten anhand Titel, Alternativtitel, Jahr und Typ suchen
- `match`: Kandidaten mit Konfidenz und erklärbaren Übereinstimmungen bewerten
- `details`: Werk-, Serien-, Staffel- und Episodenfelder laden
- `artwork`: Cover, Poster, Banner und Herkunft anbieten
- `credits`: Darsteller, Sprecher, Regie, Autor, Studio und Rollen liefern
- `relations`: Fortsetzung, Vorgänger, Spin-off und Franchise abbilden
- `externalIds`: Provider-IDs untereinander verknüpfen
- `ratings`: regionale Alters-/Inhaltsfreigaben liefern

Jedes importierte Feld speichert Provider, Provider-ID, Abrufzeit, Sprache,
Region und Konfidenz. Automatische Treffer mit unzureichender Sicherheit
bleiben Vorschläge. Nutzereingaben werden nie still überschrieben.

Zugangsdaten werden nicht in Bibliothek, Sidecar, Diagnose oder Git abgelegt.
Sie liegen im sicheren Gerätespeicher. Provider-Aufrufe nutzen HTTPS,
Host-Allowlist, Zeit-/Größenlimits, Cache, Backoff und Rate-Limit-Beachtung.

### 4.2 AniList für Anime und HHH

AniList kann öffentliche Mediendaten ohne Nutzeranmeldung liefern. Abgerufen
werden nur benötigte Titel und keine komplette Datenbankkopie. Das ist wegen
der Nutzungsbedingungen und des Rate-Limits zwingend; derzeit dokumentiert
AniList wegen eines eingeschränkten Betriebs vorübergehend 30 statt regulär
90 Anfragen pro Minute.

Matching berücksichtigt:

- Romaji-, englischen, nativen und alternativen Titel,
- Jahr, Saison, Format und Status,
- Episodenzahl und typische Laufzeit,
- Herkunftsland und Quelle,
- Beziehungen zu Vorgänger, Fortsetzung und Side Story,
- optionale AniList- oder MyAnimeList-ID aus Sidecar/Dateiname.

AniList liefert keine vollständige kuratierte Episodenliste mit verlässlichen
lokalisierten Episodentiteln. Deshalb ist die Trennung wichtig:

- **Serienebene:** AniList ist maßgeblich.
- **Episodenebene:** lokale Dateinamen und eingebettete Tags zuerst; danach
  optional TMDB oder TheTVDB über bestätigte externe Zuordnung.
- Fehlende Episodentitel verhindern niemals Scan oder Wiedergabe.

Die öffentliche API ist für nichtkommerzielle Nutzung vorgesehen. Bei einer
späteren kommerziellen Nutzung über der von AniList genannten Umsatzgrenze
muss vor Veröffentlichung eine Lizenz geklärt werden.

### 4.3 TMDB für normale Filme und Serien

TMDB ist der Standardadapter für Film und TV. Fundus verwendet Anwendungsauth,
nicht zwingend ein verbundenes TMDB-Nutzerkonto. Sprache und Region sind
einstellbar, standardmäßig Gerätssprache und Region.

TMDB deckt ab:

- Film-, Serien-, Personen- und Mehrfachsuche,
- Staffel- und Episodendetails,
- alternative Titel und externe IDs,
- Credits, Bilder, Veröffentlichungsdaten und Inhaltsfreigaben,
- regionale Daten und übersetzte Metadaten.

`include_adult` bleibt bei normaler Suche aus und wird nur in einem aktiv
entsperrten HHH-Kontext gesetzt. TMDBs Kennzeichnung und regionale Freigaben
werden in das Fundus-Sensitivitätsmodell übersetzt, ersetzen aber keine
manuelle Entscheidung.

Für nichtkommerzielle Nutzung verlangt TMDB Attribution. Fundus zeigt im
Info-/Credits-Bereich das vorgeschriebene TMDB-Logo und den Hinweis, dass das
Produkt die TMDB-API verwendet, aber nicht von TMDB unterstützt oder
zertifiziert wird. Kommerzielle Nutzung muss separat lizenziert werden.

### 4.4 TheTVDB als optionaler Adapter

TheTVDB wird nicht zum Pflichtanbieter. Der Adapter ist sinnvoll für:

- eine bereits vorhandene TVDB-ID,
- Episoden-/Staffelabgleich, wenn AniList oder TMDB nicht ausreichen,
- Import aus NFO- oder Fremdsystemen mit TVDB-IDs.

Aktivierung erfolgt erst nach Eingabe eigener zulässiger Zugangsdaten und
Bestätigung der aktuellen Lizenz-/Attributionsbedingungen. Fundus darf keine
gemeinsame geheime Projektkennung in ein öffentliches Repository oder eine
Client-Binärdatei einbetten.

## 5. Scanner und Ordnerstruktur

Empfohlene, aber nicht erzwungene Struktur:

```text
Movies/Titel (Jahr)/Titel (Jahr) - [Edition].mkv
TV Shows/Serientitel/Season 01/S01E01 - Episodentitel.mkv
Anime/Serientitel/Season 01/S01E01 - Episodentitel.mkv
Anime/Serientitel/Season 00/S00E01 - Special.mkv
HHH/...
```

Der Ordner `HHH` ist nur eine bequeme Erkennungshilfe. Ein HHH-Werk darf an
jedem Ort liegen; seine bestätigte Sensitivitätsklasse ist maßgeblich. Ebenso
kann Anime in `TV Shows` liegen. Eigene Wurzelzuordnungen bleiben in den
Bibliothekseinstellungen konfigurierbar.

Der Scanner unterstützt:

- `SxxEyy`, `1x02`, absolute Anime-Nummerierung und Specials,
- mehrere Episoden in einer Datei,
- Season-/Staffelordner sowie lose Dateien,
- lokale Poster, Fanart, Logos, Untertitel und NFO-/Sidecar-Dateien,
- eingebettete Titel, Sprache, Kapitel, Ton- und Untertitelspuren,
- technische Analyse von Container, Video-/Audio-Codec, Profil, Auflösung,
  Bildrate, HDR, Bitrate und Dauer,
- erneutes Zuordnen nach Verschieben ohne Verlust von Fortschritt oder
  bestätigten Metadaten.

Eine erkannte Datei wird sofort als abspielbares unbekanntes Video sichtbar.
Die Online-Anreicherung ist optional und blockiert den Bibliotheksscan nicht.

## 6. Video Engine und Bedienung

### 6.1 Gemeinsame Grundfunktionen

Der erste nutzbare Video-Meilenstein umfasst lokal, remote und offline:

- Play/Pause, Seek, Zeitleiste, Sprünge und Fortsetzen,
- Zeitposition mit Gerätehistorie und Konfliktdialog,
- Vollbild und maximierter Player in der bestehenden Shell,
- Auswahl von Tonspur und Untertitel,
- externe Untertitel neben der Videodatei,
- Untertitelversatz und Darstellungsgrundlagen,
- Seitenverhältnis, Einpassen, Füllen und Originalverhältnis,
- Kapitel, nächste/vorherige Episode und Episodenliste,
- „Intro überspringen“ zunächst über manuelle Kapitel/Marker,
- Wiedergabegeschwindigkeit,
- Queue/Playlist auf Werk- beziehungsweise Episodenebene,
- gesehen, teilweise gesehen und ungesehen,
- nächste Episode optional automatisch abspielen,
- Sleep-Timer und System-Mediensteuerung, soweit die Plattform dies erlaubt,
- Codec-Kompatibilitätsprüfung je Zielgerät.

Direktes Abspielen ist der Standard. Eine Transcode-Pipeline ist ein späterer,
getrennter Ausbau und darf den Video-MVP nicht blockieren. Bei inkompatiblen
Dateien zeigt Fundus den genauen Codec/Profil-Grund und führt zur Datei oder zu
einer späteren kompatiblen Variante.

### 6.2 Serien- und Anime-Oberfläche

Die Navigation verwendet dieselben lokalen, Remote- und Offline-Komponenten:

```text
Bibliothek → Serie → Staffel → Episode → Player
```

Seriendetails zeigen Poster/Banner, alternative Titel, Jahr/Saison, Status,
Studio, Genres/Tags, Beschreibung, Mitwirkende und Fortsetzungsstand. Anime
ergänzt Originaltitel, Romaji-Titel, Format, Quelle, Beziehungen und absolute
Episodennummer, sofern vorhanden.

Sortierung und Filter umfassen mindestens Titel, hinzugefügt, veröffentlicht,
zuletzt gesehen, ungesehen/begonnen/gesehen, Staffel, Episode, Jahr, Sprache,
Untertitel, Auflösung, Anime/Realfilm und Server/Quelle.

## 7. Datenschutz, Sicherheit und Caches

- Kein Provider-Token, Pairing-Schlüssel oder privater Dateipfad gelangt in
  Git, Sidecars, Telemetrie oder öffentlich teilbare Diagnoseausgaben.
- Bild-URLs und Providerantworten werden validiert, größenbegrenzt und nicht
  als ausführbarer Inhalt behandelt.
- Beschreibungen werden vor Darstellung bereinigt.
- HHH-Poster werden in getrennten, policy-gebundenen Cacheeinträgen geführt.
- Eine Sperre invalidiert sichtbare HHH-Caches und laufende Requests.
- Download- und Streamendpunkte prüfen Berechtigung bei jeder Anfrage; eine
  zuvor geladene Katalogseite ist keine dauerhafte Autorisierung.
- Logs verwenden Werk-/Datei-IDs statt Titel oder Pfad, wenn HHH betroffen ist.

## 8. Umsetzung in Etappen

### Etappe A – Schutz und Domänenfundament

1. Sensitivitätsfeld, Herkunft und Sidecar-Migration
2. zentraler Policy-Filter in Core, Server und UI
3. Einstellungen, optionale Sperre und Clientberechtigungen
4. Film-/Serien-/Staffel-/Episodenmodell und Scannergrundlage

### Etappe B – Anime-Bibliothek

1. Anime-Erkennung und Nummerierung
2. AniList-Suche, Matching, Bestätigung und Cache
3. Serien-/Staffel-/Episodenansichten
4. manuelle Korrektur und Provider-ID-Verknüpfung

### Etappe C – Video-MVP

1. lokale Wiedergabe und Resume
2. Tonspuren, Untertitel, Kapitel und Episodenwechsel
3. Remote-Range-Streaming und Offline-Dateien über dieselbe Engine
4. Gerätewechsel, Konflikte, Queue und Hintergrund/Systemsteuerung

### Etappe D – normale Filme und Serien

1. TMDB-Anbieter, regionale Daten und Attribution
2. Film-/TV-Matching sowie Episodenmetadaten
3. optionaler TheTVDB-Adapter
4. Codecprofile, Variantenwahl und spätere Transcode-Planung

## 9. Abnahmekriterien

1. HHH ausschalten: Kein HHH-Titel, Cover, Tag, Darsteller, Fortschritt oder
   Treffer erscheint lokal, offline, remote, im Dashboard oder in der
   System-Medienanzeige.
2. Ein Client ohne HHH-Freigabe kann auch mit direkter API-Anfrage weder
   Metadaten noch Dateien eines HHH-Werks abrufen.
3. Anime mit Romaji-Dateinamen wird AniList zugeordnet; Fundus zeigt den
   deutschen/englischen Titel nach Präferenz, behält aber alle Titelvarianten.
4. Eine Serie mit Staffel 00, mehreren Staffeln und einer Mehrfachepisode wird
   korrekt gruppiert und natürlich sortiert.
5. Eine unbekannte Videodatei ist ohne Provider sofort sichtbar und abspielbar.
6. Lokale, gestreamte und offline geladene Episode haben denselben Player und
   dieselben Funktionen.
7. Wechsel Desktop → Tablet → Handy zeigt Gerät, Episode, Zeit und Prozent und
   setzt nach Bestätigung auf exakt demselben Stand fort.
8. Tonspur, Untertitel und Kapitel lassen sich wechseln; die Auswahl wird im
   passenden Geräte-/Werk-Geltungsbereich gespeichert.
9. TMDB-Attribution ist sichtbar; keine API-Zugangsdaten befinden sich in Repo,
   Diagnose oder Bibliotheksdateien.
10. Ein inkompatibler Codec wird vor Download oder Wiedergabe verständlich für
    das konkrete Zielgerät gekennzeichnet.

## 10. Bewusste Nicht-Ziele des ersten Video-Meilensteins

- keine vollständige Plex-/Jellyfin-Transcodefarm,
- keine automatische Intro-/Abspann-Erkennung per Bild-/Audioanalyse,
- kein Live-TV, DVR oder Streamingdienst-Aggregator,
- kein DRM-Umgehen,
- keine automatische Inhaltsanalyse zur verlässlichen HHH-Erkennung,
- keine Dateisystemverschlüsselung durch den Sichtbarkeitsmodus.

Diese Punkte bleiben möglich, dürfen aber Schutz, Bibliothek, direkte
Wiedergabe und sauberen Gerätewechsel nicht verzögern.
