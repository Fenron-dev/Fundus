# Fundus

Fundus ist eine lokale, portable Medienbibliothek für Desktop und Android. Die
Desktop-App soll Bibliotheken zusätzlich für gekoppelte Geräte im lokalen Netz
bereitstellen.

## Workspace

- `app/` — Flutter desktop and Android application
- `packages/core/` — platform-independent model, database, scanner and import
- `packages/server/` — embedded Shelf HTTP server
- `Dokumentation/` — product concept and design source

## Aktueller Stand

Der erste vertikale Schnitt für Hörbücher und Hörspiele ist ausführbar:

- Bibliothek in einem Medienordner anlegen oder erneut öffnen
- versioniertes Manifest unter `.library/version.json`
- transaktionaler SQLite-Index unter `.library/index.db`
- rekursiver, abbrechbarer Dateiscan mit portablen relativen Pfaden
- Import der ABS-Struktur `Autor/Serie/01 - Titel`
- lose Hörbücher direkt im Bibliothekswurzelordner oder unter einem einzelnen
  frei benannten Unterordner werden ebenfalls als Werke erfasst
- gemischte Bibliothekswurzel mit portablem `.library/config.yaml`; Hörbücher
  funktionieren sowohl in der bisherigen Struktur als auch unter
  `Audiobooks/Autor/Serie/01 - Titel`
- persistierte Serien-, Cover- und Track-Zuordnung
- durchgehende Desktop-Audiowiedergabe mit Tracknavigation und Geschwindigkeit
- vergrößerbare Playeransicht mit Dateien, Chapters, Details und Playlist als
  umschaltbarem Kontext
- anspringbare Chapters aus M4B/M4A-`chpl`-Marken sowie Apple/QuickTime-
  Kapitelspuren; bei Mehrdatei-Hörbüchern dienen die sortierten Tracks als
  Kapitel
- werkbezogener Resume-Punkt über Datei- und Hörbuchwechsel mit Revisionshistorie
- Sync-Konfliktdialog mit Gerätenamen, Datei/Chapter, Zeit, Gesamtdauer und
  Prozentwert; frühere Hörstände lassen sich einsehen und als neue Revision
  wiederherstellen
- Sleep-Timer mit festen und freien Laufzeiten, Ziel-Uhrzeit, Countdown sowie
  Stopp am Kapitel- oder Trackende
- optionaler Android-Schüttelneustart für laufende Zeittimer mit einstellbarer
  Empfindlichkeit, Cooldown und haptischer Bestätigung; nach Ablauf bleiben
  zwei Minuten zum Schütteln, erneuten Starten und Weiterhören
- Android-Hintergrundwiedergabe mit nativer Medienbenachrichtigung,
  Lockscreen-, Headset- und Bluetooth-Steuerung für lokale, gestreamte und
  offline heruntergeladene Hörbücher
- anspringbare Zeit-Lesezeichen mit optionalem Rücksprung-Lesezeichen
- bearbeitbare Tags mit fuzzy gefilterten Vorschlägen und Markdown-Notizen
- Kachel-/Tabellenansicht und Navigation nach Autor, Serie und Buch
- bis zu zehn zuletzt verwendete Bibliotheken mit Verfügbarkeitsstatus
- dauerhafte macOS-Freigabe zuletzt verwendeter Bibliotheken über
  Security-Scoped Bookmarks
- datierte Notiz-Historie mit portablem Markdown-Sidecar
- sicherer Metadatenimport per Positivliste: Titel, Album, Autor, Serie,
  Bandnummer und Sprache aus M4B/M4A- sowie MP3-Tags; portable Sidecars haben
  Vorrang vor veränderten Dateitags
- manueller Hörbuch-Metadateneditor für Titel, mehrere Autoren und Sprecher,
  Serie/Band, Sprache, Verlag/Jahr und Beschreibung; Änderungen werden ohne
  Eingriff in die Mediendatei portabel in `_fundus/meta.yaml` gespiegelt
- portabler Sidecar-Spiegel unter `_fundus/`, der einen Index-Neuaufbau überlebt
- stabile `work_id` und `base_kind` im Sidecar; Verschieben und Index-Neuaufbau
  erhalten Werkidentität, Resume, Tags, Notizen und Lesezeichen
- responsive Flutter-Oberfläche für Desktop, Tablet und Mobile
- ein-/ausblendbare Detailleiste und Inline-Details bei mittleren Fensterbreiten
- per Maus verstellbare Breite der linken und rechten Seitenleisten sowie
  sichtbarer Werk-Dateipfad in den Details; Doppelklick setzt die Breite zurück
- rotierendes, exportierbares JSONL-Diagnoseprotokoll ohne absolute Medienpfade
- TLS- und token-geschützter LAN-Mehrbibliotheks-Server mit Werkliste, Details,
  Cover, ID-basiertem `Range`-Streaming und idempotentem Fortschrittsabgleich;
  absolute Medienpfade verlassen das Gerät nicht
- App-Einstellungsdialog für Serverstatus und gleichzeitig freigegebene
  Bibliotheken, explizite LAN-Freigabe und fünf Minuten gültiges QR/PIN-Pairing
- stabile Peer-Identität, Zertifikats-Pinning, nur als Hash gespeicherte
  Server-Tokens und widerrufbare Geräteberechtigungen
- erster Remote-Client mit QR-Scanner, sicherem System-Schlüsselspeicher sowie
  Server-, Bibliotheks-, Werk- und Coverübersicht
- gepinnte Remote-Wiedergabe über eine nur auf Loopback gebundene Range-Brücke
- pfadfreie Kapitelübertragung für Streaming und Offline-Downloads mit
  Kapitelsprüngen und Sleep-Timer am Kapitelende
  sowie Fortschrittssynchronisation im Fünf-Sekunden-Takt und beim Pausieren
- atomare Offline-Downloads mit lokalem Manifest, eigener Offline-Übersicht,
  lokaler Wiedergabe und lokalem Resume auch ohne erreichbaren Server
- gekoppelte Serverbibliotheken in der regulären Bibliotheksauswahl, frei
  benennbare Geräte und per mDNS sicher wiedergefundene Peers nach IP-Wechseln
- automatische Wiederholung ausstehender Offline-Fortschritte, sobald der
  gepinnte Ursprungsserver wieder erreichbar ist

## Entwicklung

```sh
flutter pub get
dart analyze
(cd packages/core && dart test)
(cd packages/server && dart test)
(cd app && flutter test)
(cd app && flutter run -d macos)
```

Für einen nativen macOS-Build werden eine vollständige Xcode-Installation und
CocoaPods benötigt. Die vollständige Produktspezifikation steht in
[`Dokumentation/KONZEPT.md`](Dokumentation/KONZEPT.md).

Ein nicht signierter macOS-Vorschaubuild kann außerdem manuell über den Workflow
`Build macOS Preview` erzeugt und anschließend als Actions-Artefakt geladen
werden.
