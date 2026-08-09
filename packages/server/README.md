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
Werkdetails, Cover, Datei-Metadaten, Streaming mit `Range`/`206`/`ETag` sowie
idempotente Fortschrittsoperationen. Pairing und LAN-Discovery folgen; bis
dahin muss das Token explizit übergeben werden.
