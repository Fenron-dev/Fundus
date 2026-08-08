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
- persistierte Serien-, Cover- und Track-Zuordnung
- durchgehende Desktop-Audiowiedergabe mit Tracknavigation und Geschwindigkeit
- persistenter Resume-Punkt über Dateigrenzen mit Revisionshistorie
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
