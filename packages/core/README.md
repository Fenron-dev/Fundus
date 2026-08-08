# fundus_core

Plattformunabhängiger Kern der lokalen Fundus-Medienbibliothek.

Das Paket enthält:

- das versionierte Bibliotheksmanifest,
- das SQLite-Schema und die Migrationen,
- den rekursiven Medienscanner,
- den ABS-Hörbuchimport,
- Modelle für Fortschritt und Wiedergabesitzungen.

```dart
final library = await FundusLibrary.open(Directory('/pfad/zur/bibliothek'));
await library.index().drain<void>();
final works = library.listWorks();
library.close();
```

Das Paket ist Bestandteil des Fundus-Workspaces und wird derzeit nicht separat
auf pub.dev veröffentlicht.
