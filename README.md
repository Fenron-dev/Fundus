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
- gemischte Bibliothekswurzel mit portablem `.library/config.yaml`; Hörbücher
  funktionieren sowohl in der bisherigen Struktur als auch unter
  `Audiobooks/Autor/Serie/01 - Titel`
- persistierte Serien-, Cover- und Track-Zuordnung
- durchgehende Desktop-Audiowiedergabe mit Tracknavigation und Geschwindigkeit
- werkbezogener Resume-Punkt über Datei- und Hörbuchwechsel mit Revisionshistorie
- Sleep-Timer mit festen Laufzeiten, Countdown und Stopp am Trackende
- anspringbare Zeit-Lesezeichen mit optionalem Rücksprung-Lesezeichen
- bearbeitbare Tags mit fuzzy gefilterten Vorschlägen und Markdown-Notizen
- Kachel-/Tabellenansicht und Navigation nach Autor, Serie und Buch
- bis zu zehn zuletzt verwendete Bibliotheken mit Verfügbarkeitsstatus
- datierte Notiz-Historie mit portablem Markdown-Sidecar
- Sprachimport aus Sidecars sowie M4B/M4A- und MP3-Metadaten
- portabler Sidecar-Spiegel unter `_fundus/`, der einen Index-Neuaufbau überlebt
- stabile `work_id` und `base_kind` im Sidecar; Verschieben und Index-Neuaufbau
  erhalten Werkidentität, Resume, Tags, Notizen und Lesezeichen
- responsive Flutter-Oberfläche für Desktop, Tablet und Mobile
- Grundgerüst für den token-geschützten lokalen HTTP-Server

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
