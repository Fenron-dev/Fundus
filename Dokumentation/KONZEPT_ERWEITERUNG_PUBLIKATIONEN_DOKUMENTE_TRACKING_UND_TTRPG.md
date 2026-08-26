# Konzept-Erweiterung: Publikationen, Dokumente, Tracking und TTRPG

> Status: verbindliche Ergänzung zum Fundus-Konzept
>
> Stand: 22. August 2026
> Bezug: [KONZEPT.md](KONZEPT.md),
> [Modulare Medien-Engine und Manga-/Comic-Reader](KONZEPT_ERWEITERUNG_MEDIA_ENGINE_UND_MANGA_READER.md)
> sowie
> [Bibliotheken, Ordnerstruktur und Peer-Server](KONZEPT_ERWEITERUNG_BIBLIOTHEKEN_UND_PEER_SERVER.md)

## 1. Ziel

Diese Erweiterung überträgt geeignete Konzepte aus Kavita, Komga, Floppy,
Calibre-Web, PdfDing, Stirling-PDF, PDF Scan Explorer und Grimoire auf Fundus.
Sie ergänzt vier bislang nur grob beschriebene Bereiche:

1. E-Books und reflowbare Publikationen
2. PDFs, gescannte Dokumente und sichere Dokumentwerkzeuge
3. medienübergreifende Historie, Status und Statistik
4. TTRPG-Produkte, Ressourcen und Arbeitsbereiche

Fundus bleibt eine lokale Medienbibliothek. Es wird weder zu einer
Online-Quellenplattform noch zu einer vollständigen PDF-Suite oder einem
virtuellen Spieltisch.

## 2. Auswertung der Referenzprojekte

| Projekt | Besonders relevant für Fundus | Bewusste Abgrenzung |
|---|---|---|
| Kavita | getrennte Manga-, EPUB- und PDF-Profile; Geräte-/Serienprofile; Leselisten; Smart Filter; Annotationen; kontinuierliches Lesen | keine Übernahme des Quellcodes oder kostenpflichtiger Dienste |
| Komga | ComicInfo/EPUB-Metadaten, Metadaten-Locks, OPDS 1/2, Kobo-/KOReader-Sync, Duplikatseiten, REST-API | kein eigener Ersatz für alle externen Reader-Ökosysteme in der ersten Ausbaustufe |
| Floppy | einheitliche Historie, Status, Restaufwand, Statistiken, konfigurierbare Startseite/Spalten, Besitz- und Varianteninformationen | keine soziale Plattform, öffentlichen Profile oder Cloud-Empfehlungsmaschine |
| Calibre-Web | OPDS, In-Browser-Reader, Shelves, Metadatenprovider, Custom Columns, Send-to-Reader, optionale Konvertierung | Calibre-Datenbank bleibt Fremdformat; kein stiller Schreibzugriff darauf |
| PdfDing | PDF-Resume, Workspaces, Tags, Sterne/Archiv, Annotationen, Kommentare, Signaturen, Markdown-Notizen, Freigaben | öffentliche Freigaben nur später und niemals standardmäßig im offenen Internet |
| Stirling-PDF | gekapselte PDF-Operationen, API, Pipelines, OCR, Konvertierung, Signaturprüfung und Redaktion | keine 1:1-Nachbildung von über 50 Werkzeugen in Fundus |
| PDF Scan Explorer | Inbox für Scans, OCR-Regeln, Vorschau, Umbenennen/Verschieben, Vorschläge und Unknown-Queue | KI ist optional; keine automatische Dateioperation ohne Vorschau |
| Grimoire | TTRPG-Systeme, Kategorien, Karten, Tokens, Audio, OCR-Volltextsuche, Kampagnenressourcen, Metadaten-Diff und kuratierte Vokabulare | kein vollständiger Kampagnenplaner, Charaktermanager oder VTT im Kernprodukt |
| [flutter_epub_viewer](https://pub.dev/packages/flutter_epub_viewer) | EPUB.js-basierte Darstellung, CFI-Resume, Suche, Annotationen, Textauswahl, Kapitel und ein Controller-Vertrag für Navigation und Laufzeiteinstellungen | keine pauschale Übernahme der WebView-, Cleartext- oder Netzwerkfreigaben; bekannte Scrolled-Flow-/Relocation-Grenzen werden nicht in das Fundus-Positionsmodell übernommen |
| [cosmos_epub](https://github.com/Mamasodikov/cosmos_epub) | mehrstufiges TOC-/Spine-Fallback, verschachtelte Kapitel, RTL, eingebettete Bilder, native Textdarstellung, Themes und lokale Quellen | Kapitel-/Seitenindex allein ist nicht layoutstabil; globale Paketspeicher und paketinterne Fortschrittsdatenbanken werden nicht zur Fundus-Wahrheitsquelle |
| [epubx_kuebiko](https://pub.dev/packages/epubx_kuebiko) | gewarteter, mit `archive` 4 kompatibler Fork für das plattformunabhängige Lesen von EPUB-Paket, Manifest, Spine, Navigation, Metadaten und Ressourcen | Parser bleibt hinter dem Fundus-Adapter austauschbar; Archivgrenzen, Pfadauflösung, aktive Inhalte und Speicherverbrauch werden zusätzlich durch Fundus kontrolliert |

## 3. Publication Engine als Engine-Familie

Die bisherige `Publication Engine` wird als Familie spezialisierter Renderer
verstanden. Sie teilt Shell, Fortschritt, Annotationen und Suche, aber nicht
den eigentlichen Seitenaufbau.

| Renderer | Formate | Positionsmodell |
|---|---|---|
| Reflow Reader | EPUB, HTML-basierte Webnovel, später FB2 | Kapitel + CFI/Textanker + Prozent |
| Fixed Document Reader | PDF, PDF/A, gescannte Dokumente | Seite + normalisierter X/Y-Bereich |
| Comic Reader | CBZ, Bildordner, später CBR/CB7 | Kapitel + Bild-ID/Seite + Scrolloffset |
| Plain Text Reader | TXT, Markdown, einfache Logs | Dokumentanker + Zeile/Absatz |

Gemeinsame Komponenten:

- Inhaltsverzeichnis und Kapitelwechsel
- Suche und Trefferliste
- Lesezeichen, Notizen, Markierungen und Zitate
- Theme, Vollbild, Fortschrittsanzeige und Resume
- Vorladen, Cache und lokale/Remote-/Offline-Quelle
- Export der eigenen Annotationen
- Geräte- und Werkprofile

## 4. E-Book- und Webnovel-Reader

### 4.0 EPUB als Primärformat und Adapterarchitektur

EPUB ist das Primärformat für E-Books, Light Novels und viele abgeschlossene
oder exportierte Webnovels. HTML, TXT und Markdown sind ergänzende Eingaben für
lose Kapitel, Eigenimporte und laufende Download-Quellen; sie bilden nicht den
Hauptumfang des Webnovel-Supports.

Die portable Standardstruktur ist serien- beziehungsweise werkorientiert; eine
Autorenebene ist ausdrücklich nicht vorgeschrieben:

```text
Webnovels/
  Serien- oder Werktitel/
    Serien- oder Werktitel.epub
    cover.webp
```

Weitere Unterordner unterhalb des Werkordners bleiben zulässig. Fundus leitet
den Medientyp aus dem konfigurierten Medienbereich und den Dateien ab, nicht aus
einer starren Autorenhierarchie. Dadurch kann dieselbe Ablage auch von anderen
Bibliotheksprogrammen genutzt werden. Mehrere Ausgaben sollen später über
Varianten desselben Werks modelliert werden und nicht durch eine erzwungene
Ordnerform.

Der Reflow Reader besteht deshalb aus getrennten Schichten:

1. `PublicationSource` liefert lokale, Remote- oder offline gespeicherte Bytes.
2. `PublicationPackageAdapter` liest Container, Metadaten, Manifest, Spine,
   Navigation, Ressourcen, Sprache und Schreibrichtung. Ein EPUB-Adapter kann
   dabei eine Bibliothek wie `epubx_kuebiko` verwenden, bleibt aber durch einen
   Fundus-Vertrag austauschbar.
3. `PublicationDocument` normalisiert Kapitel und Ressourcen zu stabilen IDs,
   ohne die originale EPUB-Datei umzuschreiben.
4. `ReflowRendererAdapter` projiziert ein Kapitel paginiert oder kontinuierlich.
   Eine native Flutter- oder gekapselte EPUB.js/WebView-Implementierung bleibt
   austauschbar und darf das portable Datenmodell nicht bestimmen.
5. `PublicationController` stellt Navigation, Suche, Textauswahl, Annotation,
   Rücksprünge und Laufzeiteinstellungen unabhängig vom Renderer bereit.
6. Die gemeinsame Media Experience Shell verwaltet Profile, Konflikte,
   Vollbild, Gerätewechsel und lokale/Remote-/Offline-Parität.

### Implementierungsstand der Quellenabstraktion

Der erste vertikale Schnitt ist umgesetzt: `PublicationSource` beschreibt
lokale Dateien, dauerhafte Offline-Dateien, Speicherbytes und Callback-basierte
Remote-/Range-Quellen über denselben Vertrag. Bytebereiche sind halb-offen
(`start` inklusive, `end` exklusive), werden vor dem Zugriff validiert und ein
vollständiger Lesevorgang weist unvollständige Antworten sowie zu große Quellen
vor dem Parser zurück. Der EPUB-Paketadapter und der Remote-/Offline-EPUB-Reader
verwenden diesen Vertrag bereits. Zusätzlich erhält die Comic Engine ihre
Seiten über `ComicPageSource`: Der Viewer kennt nur neutrale Seiten-IDs, Namen
und Größen sowie eine Materialisierungsoperation, aber weder einen absoluten
Dateipfad noch `ZipArchiveEntry`. Der vorhandene CBZ-Adapter setzt den Vertrag
für lokale Bibliotheken, Offline-Downloads und den begrenzten Remote-Cache um
und meldet die Herkunft separat für die Diagnose. Als nächster Schritt folgen
ein serverseitiger Seitenmanifest-/Einzelseiten-Endpunkt und der passende
HTTP-Adapter; Remote-Comics werden damit inzwischen seitenweise gestreamt.
Auch Fixed Documents verwenden nun eine neutrale lokale, Offline- oder
Remote-Quelle. Weil der native PDF-Renderer derzeit einen Dateipfad benötigt,
materialisiert der Adapter die Quelle über den begrenzten Dokumentcache, ohne
dass der Viewer Transport oder Cachepolitik kennen muss. Als Nächstes folgen
gemeinsame Detail-ViewModels und ein erweiterter Fixed-Document-Adapter.

Fundus speichert niemals nur eine virtuelle Seite. Die kanonische Position
enthält mindestens Werk-/Datei-ID, Spine-/Kapitel-ID, EPUB-CFI oder stabilen
Textanker, kurzen Textkontext und einen prozentualen Fallback. Kapitel- und
Seitenindex dürfen zusätzlich für die Anzeige und eine letzte Notfallauflösung
gespeichert werden. Damit bleibt Resume nach Änderung von Schrift, Breite,
Spaltenzahl, Gerät oder Renderer möglichst am gleichen Satz.

Für fehlerhafte EPUBs gilt eine nachvollziehbare Fallback-Reihenfolge:

1. EPUB-3-Navigation (`nav.xhtml`)
2. EPUB-2-NCX
3. vorhandene normalisierte Kapitelstruktur des Parser-Adapters
4. lineare Spine-Reihenfolge
5. Diagnosezustand mit einzeln sichtbaren, aber nicht still neu sortierten
   Inhaltsdateien

Ein EPUB wird ausschließlich aus lokalen beziehungsweise bereits autorisierten
Bytes geöffnet. Externe Skripte, Remote-Fonts, Tracker, Formulare und
unaufgeforderte Netzwerkzugriffe bleiben blockiert. Ressourcenpfade werden
normalisiert und dürfen den Container nicht verlassen; Anzahl, Einzelgröße,
Gesamtgröße und Kompressionsverhältnis des Archivs besitzen feste Grenzen.
Eine WebView-Implementierung läuft mit deaktiviertem Netzwerk und Navigation
außerhalb des internen Buchursprungs. Fundus aktiviert dafür insbesondere keine
globale Android-Cleartext-Freigabe.

### 4.1 Darstellung

Der Reflow Reader unterstützt mindestens:

- EPUB mit Inhaltsverzeichnis, Kapitelstruktur und eingebetteten Ressourcen
- ein- und zweispaltiges Layout abhängig von Fensterbreite und Profil
- Schriftfamilie, eigene importierte Schrift, Schriftgröße und Schriftgewicht
- Zeilenabstand, Absatzabstand, Seitenrand und Inhaltsbreite
- Theme, Text- und Hintergrundfarbe, Sepia und hoher Kontrast
- horizontales Blättern oder kontinuierliches vertikales Scrollen
- LTR/RTL sowie horizontale oder vertikale Schreibrichtung, sofern das Werk sie
  sinnvoll unterstützt
- Immersive Mode mit automatisch ausgeblendeten Bedienelementen
- Tap-Zonen, Tastaturkürzel und Touch-Gesten über die gemeinsame Shell
- Zoom nur für eingebettete Bilder, ohne die Textskalierung zu verfälschen

Der Reader verändert die EPUB-Datei nicht. CSS-Overrides werden als Profil
gespeichert und beim Rendern in einer begrenzten, sicheren Umgebung angewendet.
Aktive Inhalte, externe Skripte und unaufgeforderte Netzwerkzugriffe bleiben
deaktiviert.

### 4.2 Inhaltsnavigation und Suche

- hierarchisches Inhaltsverzeichnis
- Kapitel-, Positions- und Prozentanzeige
- Suche im aktuellen Werk mit Trefferkontext
- Rücksprungstapel nach Link-, Fußnoten-, Inhaltsverzeichnis- oder Suchsprung
- interne Links, Fußnoten und Endnoten ohne Verlust der Leseposition
- optional verbleibende Kapitel-, Seiten- und Lesezeit als Schätzung
- „Weiterlesen“ über Werk-, Geräte- und Serverwechsel

„Virtuelle Seiten“ sind nur eine aktuelle Layoutprojektion. Die dauerhafte
Position bleibt CFI/Textanker, weil sich virtuelle Seiten bei Schrift- oder
Fensteränderung verschieben.

### 4.3 Annotationen

Ein einheitliches Annotationsmodell ergänzt `bookmarks` und `notes`:

- Textmarkierung mit Farbe
- Kommentar beziehungsweise Markdown-Notiz
- Zitat-Snapshot plus stabiler Textanker
- Seiten-/Kapitel-Lesezeichen ohne Textauswahl
- optionale Tags und Verknüpfung mit Sammlung oder TTRPG-Arbeitsbereich
- Export als Markdown, JSON und später interoperables Web-Annotation-Format

Annotationen bleiben persönliche Nutzerdaten und werden in Sidecars gespiegelt.
Beim geänderten EPUB versucht Fundus eine erneute Verankerung über Textkontext;
unsichere Treffer werden zur manuellen Prüfung markiert.

## 5. PDF-Reader und Dokumentarbeitsbereiche

### 5.1 Reader

Der Fixed Document Reader unterstützt:

- Einzel- und Doppelseite
- vertikales und horizontales Scrollen
- Coverversatz bei Doppelseiten
- an Seite, Breite, Höhe oder Originalgröße anpassen
- Zoom, Pan, Rotation und Miniaturseitenleiste
- Inhaltsverzeichnis, Seitenlabels und Dokumentlinks
- Textsuche mit Trefferliste und Seitenvorschau
- Auswahl und Kopieren vorhandener Texte
- Resume, Fortschrittsleiste und Seitenlesezeichen
- PDF-Formularfelder zunächst lesen, später kontrolliert ausfüllen und als neue
  Variante speichern
- digitale Signaturen anzeigen und validieren; Signieren ist eine getrennte
  Werkzeugoperation

### 5.2 Annotationen und Ebenen

Fundus speichert Annotationen standardmäßig außerhalb der Quelldatei:

- Text-Highlight, Unterstreichung und Durchstreichung
- Freitext-Kommentar
- Freihandzeichnung und Form
- Seitenmarke, Farbe und Tags
- Markdown-Notiz mit Rücklink zur Seite oder Auswahl

Die portable Sidecar-Ebene ist maßgeblich. „In PDF einbetten“ ist eine
ausdrückliche Exportoperation, die eine neue Variante erzeugt. So bleiben
Originale unverändert und Annotationen trotzdem mit fremden PDF-Programmen
nutzbar.

### 5.3 Arbeitsbereiche

Ein Arbeitsbereich ist eine gespeicherte Sammlung mit zusätzlichem Kontext,
kein eigener Dateispeicher. Beispiele:

- Steuerunterlagen 2026
- Studium – Seminararbeit
- Kampagne – Abomination Vaults
- Gerätedokumentation

Ein Arbeitsbereich kann enthalten:

- Werke, einzelne Seitenanker und Dateien
- angeheftete Suchabfragen und Smart Collections
- Markdown-Übersichtsnotiz
- Tags, Status, Sterne und Archivzustand
- frei sortierbare Abschnitte
- Querverweise auf Personen, Systeme, Kampagnen und andere Arbeitsbereiche

Die Begriffe „Sammlung“, „Leseliste“, „Playlist“ und „Arbeitsbereich“ teilen
eine technische Listenbasis, behalten aber unterschiedliche UI und Regeln.

## 6. Volltext, OCR und Scan-Inbox

### 6.1 Suchindex

Fundus trennt Dateimetadaten, extrahierten Text und OCR-Text:

- extrahierter Text pro Dokumentseite beziehungsweise EPUB-Kapitel
- FTS5-Index mit Werk-, Datei-, Kapitel- und Seitenreferenz
- Suchtreffer mit Textausschnitt und Seiten-/Kapitelthumbnail
- Filter nach Medientyp, Sprache, OCR-Status, System und Arbeitsbereich
- erneute Indexierung pro Werk, Ordner oder kompletter Bibliothek
- OCR-Sprache automatisch vorschlagen, aber manuell überschreibbar

OCR ist ein abgeleiteter Cache. Der originale Scan bleibt unverändert. Eine
durchsuchbare PDF-Variante wird nur auf ausdrücklichen Wunsch erzeugt.

### 6.2 Scan-Inbox

Ein optionales Dokument-Inbox-Modul übernimmt den transparenten Workflow aus
PDF Scan Explorer:

1. Fundus beobachtet konfigurierte Inbox-Ordner.
2. Neue Dateien werden erst nach stabilem Abschluss des Schreibvorgangs geprüft.
3. Text und technische Daten werden extrahiert; bei Bedarf folgt OCR.
4. Regeln schlagen Dokumenttyp, Titel, Dateiname, Tags und Ziel vor.
5. Unsichere Fälle landen in „Ungeklärt“ mit Vorschau und Gründen.
6. Der Nutzer bestätigt, korrigiert oder verwirft den Plan.
7. Erst danach führt eine journalisierte Task die Dateioperation aus.

Regeln unterstützen Schlüsselwörter, reguläre Ausdrücke, Absender, Datum,
Sprache, Barcode/ISBN und vorhandene Metadaten. KI-Vorschläge sind ein optionaler
Provider; sie senden ohne ausdrückliche Freigabe weder Dokumenttext noch Seiten
an einen externen Dienst.

## 7. Dokumentwerkzeuge und Pipeline-Engine

PDF-Manipulation gehört nicht in den Reader. Sie verwendet dieselbe gekapselte
Task-Engine wie Medienvarianten und M4B-Erzeugung.

### 7.1 Startumfang

- Seiten neu ordnen, drehen, extrahieren und löschen
- PDFs zusammenführen und nach Seiten/Bereichen teilen
- Bilder in PDF und PDF-Seiten in Bilder umwandeln
- OCR-Variante erzeugen
- komprimierte beziehungsweise geräteoptimierte Variante erzeugen
- Metadaten anzeigen, bereinigen und bewusst zurückschreiben
- Passwortschutz erkennen; Entschlüsselung nur mit Berechtigung und Passwort
- Signaturen validieren

Spätere oder externe Werkzeuge:

- Schwärzen/Redaktion
- digitale Signatur erzeugen
- Office-, EPUB-, Markdown- und PDF/A-Konvertierung
- Wasserzeichen, Bates-Nummerierung und komplexe Formulare

### 7.2 Sicherheitsregeln

- nie direkt auf dem Original arbeiten
- Eingaben und Zielprofile vor Ausführung anzeigen
- temporäre Ausgabe im selben sicheren Task-Kontext
- Ergebnis auf Format, Seitenzahl, Lesbarkeit und erwartete Operation prüfen
- Original standardmäßig behalten und Ergebnis als `variant` verknüpfen
- Ersetzen nur nach ausdrücklicher Bestätigung und mit Undo-Journal
- Passwörter, Zertifikate und private Schlüssel nur im sicheren Gerätespeicher
- Schwärzung muss Inhalte tatsächlich entfernen; eine schwarze Zeichenfläche
  gilt nicht als Redaktion
- jede Pipeline besitzt Versionsnummer, Schritte, Parameter und Prüfregeln

Stirling-PDF kann später als optionaler lokaler Tool-Provider über dessen API
angebunden werden. Fundus bleibt Orchestrator, zeigt den Plan und importiert das
validierte Ergebnis; es übernimmt nicht dessen vollständige Oberfläche.

## 8. Geräte- und Reader-Interoperabilität

### 8.1 OPDS

Der Fundus-Server soll langfristig OPDS 2 und bei vertretbarem Aufwand OPDS 1.2
bereitstellen. Damit können externe Reader Bibliotheken, Sammlungen und
Leselisten durchsuchen und Dateien beziehen.

- persönliche, widerrufbare Feed-Tokens
- Bibliotheks- und Sammlungsfilter
- Cover, Metadaten und Downloadlinks
- keine absoluten Pfade
- getrennte Berechtigung für Browsen und Download
- Remote-Zugriff weiterhin nur im vertrauenswürdigen Netz/VPN

### 8.2 Geräteprofile und Übergabe

- „An Gerät senden“ erzeugt auf Wunsch eine kompatible Variante
- Geräteprofile speichern unterstützte Formate, Größenlimit und bevorzugte
  Metadaten
- Ausgabe kann Download, Exportordner oder konfigurierter externer Befehl sein
- Kobo- und KOReader-Sync sind optionale Adapter, nicht Teil des Kernschemas
- externer Fortschritt wird in eine Fundus-Position übersetzt und durchläuft
  dieselbe Konfliktprüfung

Calibre- und Komga-Bibliotheken werden zunächst gelesen beziehungsweise über
OPDS/API angebunden. Direkte Schreibzugriffe auf deren Datenbanken sind
ausgeschlossen.

## 9. Medienübergreifende Historie, Status und Statistik

### 9.1 Statusmodell

Zusätzlich zu technischem Fortschritt besitzt ein Nutzerstatus:

- geplant
- begonnen
- pausiert
- abgeschlossen
- abgebrochen
- erneut in Nutzung

Status und Fortschritt sind getrennt. Ein Werk mit 100 % kann bewusst noch als
„begonnen“ gelten, während ein abgebrochenes Werk seinen letzten Stand behält.

### 9.2 Einheitliche Historie

Die Historie wird aus Ereignissen erzeugt und nicht als manuell gepflegter
Zähler gespeichert:

- begonnen, fortgesetzt, pausiert und abgeschlossen
- gelesen, gehört, gesehen oder betrachtet
- Kapitel-/Episoden-/Trackwechsel
- manueller Statuswechsel
- optional Metadaten-, Listen- und Bewertungsänderungen

Sie ist nach Zeitraum, Bibliothek, Gerät, Medientyp, Genre, Person und Status
filterbar. Doppelte oder durch Retry erneut eintreffende Ereignisse werden über
Operations-IDs zusammengeführt.

### 9.3 Statistiken

- Zeit gehört/gesehen und geschätzte Lesezeit
- Seiten, Kapitel, Episoden und Titel abgeschlossen
- Serien- und Lesestreaks
- Restzeit, Restseiten und verbleibende Episoden
- häufigste Autoren, Sprecher, Künstler, Regisseure, Systeme und Tags
- Vergleich frei wählbarer Zeiträume
- Aufschlüsselung pro Medientyp und Bibliothek
- nachvollziehbare Datenbasis mit Drill-down auf Ereignisse

Statistik bleibt abschaltbar. Löschen der Historie entfernt daraus abgeleitete
Statistiken reproduzierbar.

### 9.4 Startseite und Ansichten

Die Startseite besteht aus frei sortierbaren Modulen, beispielsweise:

- Weitermachen
- zuletzt hinzugefügt
- zuletzt genutzt, aber nicht bewertet
- neue Episoden/Kapitel
- angeheftete Sammlung, Leseliste oder Smart Collection
- Offline auf diesem Gerät
- Restzeit beziehungsweise „als Nächstes“

Tabellen erlauben sichtbare Spalten pro Ansicht frei auszuwählen und zu
sortieren. Dieselbe Spalten-/Filterdefinition wird für Smart Collections
wiederverwendet.

## 10. Besitz, Ausgaben und Varianten

Werk und konkrete Kopie werden getrennt:

- Werk: inhaltliche Identität, Titel, Serie und Personen
- Ausgabe: Sprache, Verlag, ISBN, Edition, Veröffentlichungsdatum
- Kopie/Variante: Datei, Format, Auflösung, Codec, Qualität, Quelle,
  Erwerbsdatum, Speicherort und optional physisch/digital

Damit kann Fundus dieselbe Geschichte als EPUB, PDF, Hörbuch und physisches Buch
abbilden, ohne die Dateien zu einem unklaren Eintrag zu verschmelzen. Automatische
Zusammenführung erfolgt nie allein anhand eines ähnlichen Titels.

## 11. TTRPG-Modul

### 11.1 Ordnung

Das bestehende Werk-/Sammlungsmodell wird für TTRPG konkretisiert:

- Systemfamilie → System → Edition
- Produktlinie → Produkt → enthaltene Ressourcen
- Inhaltsarten: Grundregelwerk, Quellenband, Abenteuer, Kampagne, Bestiarium,
  Charakterbogen, Handout, Karte, Token, Audio, Tabelle und Archiv
- kuratierte, aber erweiterbare Werte für System, Edition, Setting, Verlag,
  Lizenz, Würfel-/Materialsystem und Inhaltsart
- systemagnostische und Ein-Seiten-Rollenspiele als reguläre Sammlungen, nicht
  als Sonderpfad im Kernschema

Ordnererkennung darf Vorschläge liefern. Unbekannte Ordner werden als frei
benannte Kategorie erhalten; der Nutzer kann die automatische Zuordnung global
oder pro Medienwurzel deaktivieren.

### 11.2 Ressourcenansichten

- Bücher/PDFs mit Page-by-Page-Reader und OCR-Suche
- Karten-Galerie mit Vollbild, Auflösung, physischer Größe und optionalem
  Rastermaß
- Token-/Portrait-Galerie mit transparentem Hintergrund und Tags
- Audio-Ressourcen über die gemeinsame Audio Engine und Queue
- Archive zunächst virtuell öffnen und gezielt importieren
- Karten, Tokens und Handouts bleiben eigene Werke/Dateien, können aber einem
  Produkt und mehreren Arbeitsbereichen zugeordnet sein

### 11.3 TTRPG-Arbeitsbereich

Eine Kampagne wird in Fundus zunächst als Arbeitsbereich umgesetzt:

- verknüpfte Regelwerke, Abenteuer, Karten, Tokens, Audio und Handouts
- frei sortierbare Ressourcengruppen
- Markdown-Übersicht und verschachtelte Notizseiten
- `[[Wiki-Links]]`, Rückverweise und Links auf Werk, Seite, Karte oder Audio
- eingebettete Fundus-Ressourcen in Notizen
- Sichtbarkeit bleibt zunächst persönlich; Mehrbenutzer-/Spielerfreigaben sind
  eine spätere Servererweiterung
- Export als Markdown-Ordner mit YAML-Frontmatter und stabilem Ressourcenbezug

Terminplanung, Einladungen, Charakterverwaltung und VTT-Funktionen sind nicht
Teil des ersten TTRPG-Umfangs.

### 11.4 Metadaten-Add-ons

Optionale Metadatenprovider werden über deklarative, versionierte Adapter
angebunden:

- Provider liefert Kandidaten und Feldwerte, keine direkten Schreiboperationen
- Fundus zeigt einen Feld-für-Feld-Diff mit Herkunft
- bestehende manuelle Werte sind standardmäßig nicht vorausgewählt
- Adapter hat klar deklarierte Netzwerk-, Auth- und Datenscope-Berechtigungen
- Ausfall oder Entfernung eines Adapters beeinträchtigt lokale Metadaten nicht

Die Adapter-Idee gilt später ebenso für Buch-, Comic-, Film- und Musikprovider.

## 12. Duplikate und Qualitätsprüfung

Zusätzlich zu Datei- und pHash-Duplikaten:

- gleiche Seiten innerhalb eines Buchs erkennen
- bekannte identische Seiten automatisierbar, unbekannte nur als Prüfgruppe
- leere, fast leere oder extrem niedrig aufgelöste Seiten markieren
- doppelte Kapitel-/Bandnummern mit Metadatenvergleich
- OCR-Qualität und Textabdeckung anzeigen
- nebeneinander vergleichen, behalten, verknüpfen oder als legitime Variante
  markieren

Automatisches Entfernen doppelter Seiten ist standardmäßig deaktiviert und
erzeugt immer eine neue Variante.

## 13. Prioritäten

### Phase A – Publication-Grundlage

1. Publication-Engine-Familie und Reflow-/Fixed-Verträge
2. EPUB-Inhaltsverzeichnis, Textanker, Profile und Resume
3. PDF-Seitennavigation, Suche, Thumbnailleiste und Resume
4. gemeinsames Annotationsmodell und Sidecar-Spiegel

### Phase B – Suche und Interoperabilität

1. Text-/OCR-Index pro Seite und Kapitel
2. OPDS 2 und persönliche Feed-Tokens
3. Geräteprofile und „An Gerät senden“
4. externe Fortschrittsadapter später für Kobo/KOReader

### Phase C – Dokument-Workflows

1. Scan-Inbox und Unknown-Queue
2. sichere PDF-Grundoperationen
3. versionierte Pipelines und optionale Stirling-PDF-Anbindung
4. PDF-Annotationsexport und Formularvarianten

### Phase D – TTRPG und Tracking

1. System-/Produkt-/Ressourcenmodell und kuratierte Eigenschaften
2. Karten-, Token- und Audioansichten
3. TTRPG-Arbeitsbereiche mit Markdown-Verknüpfungen
4. einheitliche Historie, Status, Statistik und konfigurierbare Startseite

## 14. Abnahmekriterien

- Ein EPUB setzt nach Schrift- und Gerätewechsel am semantisch gleichen Textort
  fort.
- PDF, EPUB und Comic benutzen dieselbe Shell, aber nachweisbar getrennte
  Renderer und Positionsadapter.
- Eine PDF-Markierung bleibt nach App-Neustart und Geräte-Sync erhalten, ohne
  das Original zu verändern.
- OCR-Suche öffnet exakt die gefundene Seite und markiert den Treffer.
- Eine Scan-Inbox verschiebt ohne bestätigten Plan keine Datei.
- Eine PDF-Pipeline behält das Original, validiert das Ergebnis und ist
  journalisiert rückholbar.
- Ein externer OPDS-Client sieht nur freigegebene Bibliotheken und niemals
  absolute Pfade.
- Ein TTRPG-Produkt bündelt PDF, Karten, Tokens, Handouts und Audio, ohne deren
  eigenständige Verwendung zu verhindern.
- Ein TTRPG-Arbeitsbereich exportiert Notizen und stabile Ressourcenlinks in
  einem lesbaren Markdown-Format.
- Historie und Statistik liefern dieselben Summen aus denselben Ereignissen und
  können vollständig deaktiviert beziehungsweise gelöscht werden.

## 15. Lizenz- und Übernahmegrenze

Die Projekte dienen als Produkt- und Verhaltensreferenz. Fundus übernimmt
keinen Quellcode. Das ist besonders bei GPL-/AGPL-Projekten und der
Open-Core-Lizenz von Stirling-PDF wichtig. Eine spätere technische Integration
verwendet dokumentierte APIs oder externe Prozesse und wird separat auf Lizenz,
Datenschutz und Sicherheitsfolgen geprüft.

Primärquellen:

- <https://github.com/Kareadita/Kavita>
- <https://github.com/gotson/komga>
- <https://github.com/dannyvfilms/Floppy>
- <https://github.com/janeczku/calibre-web>
- <https://github.com/mrmn2/PdfDing>
- <https://github.com/Stirling-Tools/Stirling-PDF>
- <https://github.com/maschhoff/pdfscanexplorer>
- <https://github.com/hunter-read/grimoire>

## 16. Mobile Informationsarchitektur für Publikationen

Die Mobile-App behält die Vault-Auswahl als ersten Screen. Nach Auswahl eines
lokalen oder entfernten Vaults folgt ein Dashboard mit Fortsetzen, zuletzt
hinzugefügten Titeln und direkten Einstiegen nach Medientyp. Lokale, entfernte
und heruntergeladene Werke verwenden anschließend dieselben Karten und
Detailseiten; Herkunft und Offline-Status werden als Zustände angezeigt und
nicht als getrennte Bedienwelten umgesetzt.

Die Detailseite für Manga, Webnovels und E-Books besteht aus:

1. Cover, Titel, Autor/Serie und Fortschritt,
2. den Aktionen „Lesen/Fortsetzen“ und „Zur Bibliothek/Download verwalten“
   unterhalb des Covers,
3. den Hauptbereichen „Info“, „Dateien“, „Kapitel“, „Notizen“ und „Ähnlich“,
4. „Notizen“ mit den Unterbereichen „Notizen“ sowie „Lesezeichen & Highlights“,
5. Filter und Sortierung gesammelt hinter dem Filter-Symbol.

Ein Tippen auf das Cover öffnet eine große, nicht destruktive Vorschau. Der
Download-Dialog bleibt eine explizite Auswahl von Kapiteln beziehungsweise
Dateien. Reader öffnen bildschirmfüllend; ein Tippen in die Mitte blendet die
obere und untere Bedienleiste ein oder aus. Semantischer EPUB-Lesestand,
Reader-Profil, Lesezeichen und Textmarkierungen gehören zum Werk und gelten
unabhängig davon, ob es gerade lokal, remote oder aus dem Offline-Cache gelesen
wird.

„Ähnlich“ ordnet Werke desselben Medientyps nach der Zahl identischer Tags.
Favoriten werden als portabler Tag gespeichert und können direkt in jeder
Bibliotheksansicht gefiltert werden. Das Dashboard berücksichtigt lokale,
entfernte und heruntergeladene Werke gleichermaßen bei „Fortsetzen“ und
„Zuletzt hinzugefügt“.

## 17. Portable Einstellungen und Markdown-Notizen

Abweichende Reader-Einstellungen werden zusätzlich zur lokalen
Gerätekonfiguration im Werk unter `_fundus/reader-settings.yaml` gespiegelt.
Profile sind nach Geräteklasse und Reader-Typ getrennt, damit beispielsweise
Android im Webtoon-Modus „An Breite anpassen“ verwenden kann, während macOS
eine andere Darstellung behält. Bei alleinstehenden Dateien liegt der Spiegel
unter `_fundus/files/<Dateiname>/`, damit Datei- und Verzeichnisnamen nicht
kollidieren. Der Server stellt dieselben Profile über seine authentifizierte
Bibliotheks-API bereit.

Notizen werden als Markdown im Sidecar-Bereich des Werks gespeichert. Ihre
Synchronisation ist einstellbar; bei aktivierter Synchronisation gleichen
Clients Notizen und Tags über den Fundus-Server ab. IDs und Erstellzeitpunkte
bleiben erhalten, damit erneutes Verbinden keine identischen Notizen
dupliziert. Lesezeichen und Highlights bleiben Teil des gemeinsamen
Annotationsmodells und werden medientypspezifisch im Reader angelegt.

## 18. Android-Aktualisierungen

Preview-Builds erhalten eine fortlaufende Buildnummer und werden mit einem
stabilen Preview-Schlüssel signiert. Nach dem einmaligen Wechsel von alten,
wechselnd signierten Test-APKs können neue APKs über die bestehende App
installiert werden; App-Daten, Offline-Downloads und lokale Einstellungen
bleiben dabei erhalten. Für öffentliche Releases wird ein eigener,
langfristig gesicherter Produktionsschlüssel mit Update-Kanal verwendet.

Visuelle Referenzen:

- `Mobile_app_dashboard_UI_mockup_202608221622.jpeg`
- `Mobile_app_ebook_library_mockup_202608221603.jpeg`
- `Mobile_app_UI_mockup_2K_202608221559.jpeg`
