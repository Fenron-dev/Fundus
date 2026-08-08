# Design-Prompt für Fundus

> Zum Einspeisen in eine Design-Sitzung. Bewusst selbsttragend formuliert, damit
> er ohne Kenntnis von `KONZEPT.md` funktioniert.
> Stand: 2026-08-08

---

## Empfohlener Zuschnitt

Jetzt das **System** entwerfen — Tokens, Navigationsmodell, Komponenten — plus die
Hörbuch-Bildschirme. Die Oberflächen der übrigen Medientypen erst mit dem
jeweiligen Meilenstein.

Sonst entwirfst du fünf Medientypen, bevor einer gebaut ist, und wirfst die Hälfte
nach dem ersten echten Nutzungstest wieder weg. Der Zweck der Vorabplanung ist
nicht, alles zu gestalten, sondern zu verhindern, dass jede spätere Ansicht ihre
eigenen Regeln erfindet.

**Zwei Vorgaben im Prompt sind Geschmacksfragen** — vor dem Absenden prüfen und
gegebenenfalls ändern, weil sie das Ergebnis stark prägen:

1. **Dichte statt Weißraum** (begründet mit großer Sammlung und erfahrenem Nutzer)
2. **Notizen und Lesezeichen als eigene, sichtbare Fläche** statt als Beiwerk

---

## Prompt

Entwirf ein Designsystem und die Kernbildschirme für **Fundus**, eine lokale
Medienbibliothek mit Wiedergabe.

### Was die App ist

Eine selbst gehostete Bibliothek für die eigene Mediensammlung, komplett ohne
Cloud. Die Desktop-App (Windows, macOS, Linux) ist gleichzeitig Server im
Heimnetz; ein Android-Client greift darauf zu, lädt Inhalte für unterwegs
herunter und synchronisiert den Fortschritt zurück. Bibliotheken liegen auf
externen Datenträgern und sind selbstenthaltend.

Verwaltete Medientypen: Hörbücher und Hörspiele, Filme/Serien/Anime, Manga und
Comics, E-Books und PDFs, Musik, Podcasts, Bilder sowie Dokumentsammlungen
(z. B. mehrere tausend TTRPG-PDFs).

### Positionierung

Kein Plex-Klon. Die Mischung ist:

- **Eagle.cool** für die dichte, schnelle Verwaltung mit Tags und Sammlungen
- **Audiobookshelf** für Werke, Serien und Fortschritt
- **Obsidian** für das Gefühl, dass Notizen zu Dingen gehören und in Klartext existieren

### Nutzung

Eine einzelne Person, die eigene Sammlung, über Jahre gewachsen und groß
(100.000+ Dateien). Erfahrener Anwender, tastaturorientiert, will Dichte statt
Weißraum. Deutsch als Hauptsprache, aber mehrsprachig vorbereitet — Labels können
deutlich länger sein als im Englischen.

### Technische Rahmenbedingungen

- Flutter mit Material 3, soll aber nicht nach Standard-Android aussehen
- Hell und Dunkel gleichwertig, nicht als Nachgedanke
- Desktop: dreispaltige Hülle (Navigation · Inhalt · Detail), Spalten verschiebbar und ausblendbar
- Android: Bottom-Navigation, einhändig bedienbar, offline-fähig
- Raster mit tausenden Vorschaubildern, virtualisierte Listen

### Informationsarchitektur

Bestimmt die Navigation, deshalb vollständig:

- **Server → Bibliothek → Werk → Datei.** Ein Client kennt mehrere Server, ein Server liefert mehrere Bibliotheken aus
- Ein **Werk** kann eine Datei sein (ein PDF) oder viele (Hörbuch mit 30 Tracks, Boxed Set mit Karten und Handouts). Bei Einzeldateien bleibt das Werk unsichtbar — der Nutzer sieht einfach eine Datei
- Werke können ineinander verschachtelt sein: Serie → Band, Produktlinie → Produkt
- Querschnittlich: Tags, Sammlungen (n:m — ein Werk in mehreren gleichzeitig), Personen (Autor, Sprecher, Regisseur), benutzerdefinierte Eigenschaften pro Medientyp
- **Dasselbe Werk ist über mehrere Wege erreichbar**: Ordner, Serie, Person, Tag, Sammlung, gespeicherter Filter. Die Navigation muss das tragen, ohne zu zerfasern — das ist die schwierigste Aufgabe in diesem Entwurf

### Zu entwerfen, in dieser Reihenfolge

1. **Design-Tokens** mit konkreten Werten: Farben hell und dunkel, Typoskala,
   Abstände, Radien, Elevation, Zustandsfarben
2. **Navigationsmodell**: Wechsel zwischen Servern, Bibliotheken und Medientypen,
   ohne dass die Seitenleiste zur Müllhalde wird
3. **Kernkomponenten** mit allen Zuständen: Werk-Kachel, Werk-Zeile, Detailpanel,
   Filterleiste, Tag-Chip, Bewertung, Fortschrittsanzeige, Leerzustände,
   Fehlerzustände, Ladezustände
4. **Kernbildschirme am Beispiel Hörbücher**: Bibliotheksraster, Werkdetail (mit
   Verweisen auf Serie und Person, Notizen, Lesezeichen), Player auf Desktop und
   Mobil, Mini-Player
5. **Notizen und Lesezeichen** als eigene, sichtbare Fläche — kein
   Nebenschauplatz, sondern ein Alleinstellungsmerkmal
6. **Mobil**: Bibliothek, Werkdetail, Player, Verwaltung der Downloads

### Ausdrücklich gewünscht

- Dichteumschaltung (komfortabel / kompakt)
- Tastatur zuerst: jede Hauptaktion braucht ein Kürzel, und die Kürzel müssen auffindbar sein
- Fortschritt und Resume auf einen Blick erkennbar, in Raster wie Liste
- Klar unterscheidbare Zustände: auf dem Gerät vs. nur auf dem Server, fehlende Dateien, Duplikate, sowie **laufende Werke** (eine Webnovel, die noch Kapitel bekommt, ist gegen Verschieben gesperrt — das braucht eine ruhige, nicht alarmierende Darstellung)

### Nicht entwerfen

Onboarding-Strecken, Marketingseiten, Anmeldung und Konten (Einzelnutzer),
soziale Funktionen, Transcoding-Einstellungen.

### Ergebnisform

Tokens als konkrete Werte, Komponenteninventar mit Zuständen, kommentierte
Layouts der Kernbildschirme bei drei Breakpoints (~400, ~900, ~1600 px) und je
Entscheidung eine kurze Begründung.
