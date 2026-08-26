# Fundus Server

Der eingebettete Shelf-Server stellt mehrere lokale Fundus-Bibliotheken
gleichzeitig über opake Bibliotheks-, Werk- und Datei-IDs bereit. Absolute
Dateisystempfade werden nicht an Clients übertragen.

## Lokaler Entwicklungsstart

```sh
FUNDUS_TOKEN='ein-lokales-test-token' \
  dart run packages/server/bin/server.dart \
  '/Pfad/zu/Bibliothek Eins' '/Pfad/zu/Bibliothek Zwei'
```

Ohne weitere Konfiguration bindet der Entwicklungsserver ausschließlich an
`127.0.0.1:8080`. Jede als Argument angegebene Bibliothek bleibt gleichzeitig
freigegeben, unabhängig davon, welche Ansicht ein Client gerade geöffnet hat.

```sh
curl -H 'Authorization: Bearer ein-lokales-test-token' \
  http://127.0.0.1:8080/v1/libraries
```

Implementiert sind aktuell Capabilities, Bibliotheks- und Werklisten,
Werkdetails, Cover, Datei-Metadaten, Streaming mit `Range`/`206`/`ETag`,
idempotente Fortschrittsoperationen sowie authentifizierte Comic-Manifeste und
Einzelseiten. Remote-Reader müssen dadurch kein vollständiges CBZ laden:

```text
GET /v1/libraries/{libraryId}/files/{fileId}/comic/pages
GET /v1/libraries/{libraryId}/files/{fileId}/comic/pages/{pageIndex}
```

Das Manifest enthält stabile Archivpfade als Seiten-IDs und – soweit das
Bildformat sie bereitstellt – Breite und Höhe für eine sprungfreie
Webtoon-Geometrie. Lokale Pfade werden auch über diese Endpunkte nicht
übertragen. Alle Routen außer Health und Pairing-Claim verlangen ein gültiges,
widerrufbares Geräte-Token.
