# Testcheckliste: Manga-/Comic-MVP

> Zweck: Stabilisierung des Manga-/Comic-Bereichs vor Beginn des Webnovel-
> Readers. Die Reihenfolge ist bewusst nach Risiko gewählt. Tritt in Abschnitt
> 1 bis 6 ein reproduzierbarer Fehler auf, sollte er vor dem Webnovel-Meilenstein
> behoben werden.

## Testprotokoll

- Fundus-Version/Commit:
- macOS-Version und Gerät:
- Android-Version und Gerät:
- Getestete Bibliotheken/Server:
- Testdatum:
- Zugehöriges Diagnoseprotokoll:

Für Fehler bitte möglichst notieren:

- Quelle: lokal, Remote-Stream oder Offline-Download
- Werk und Kapitel
- Reader-Modus und Skalierung
- erwartete und tatsächliche Seite
- genaue Bedienfolge
- ob der Fehler nach App-Neustart erneut auftritt

## 1. Installation, Bibliothek und Bestandsschutz (Blocker)

- [ ] Bestehende App aktualisieren, ohne sie vorher zu deinstallieren.
  - Erwartung: Downloads, Lesestände, Reader-Profile und gekoppelte Server
    bleiben erhalten.
- [ ] Lokale Bibliothek nach dem Update öffnen.
  - Erwartung: Keine erneute Berechtigungsabfrage, sofern Android/macOS die
    Berechtigung nicht entzogen hat.
- [ ] App vollständig beenden und erneut starten.
  - Erwartung: Zuletzt verwendete Bibliotheken und Server sind weiterhin
    vorhanden und lassen sich öffnen.
- [ ] Einen bereits teilweise heruntergeladenen Manga kontrollieren.
  - Erwartung: Vorhandene Kapitel fehlen nicht und werden als offline markiert.
- [ ] Einen Bibliotheksscan durchführen.
  - Erwartung: Lesestände, Lesezeichen, Gelesen-Markierungen und Downloads
    bleiben erhalten.

## 2. Erkennung und Bibliotheksansicht (Blocker)

- [ ] Einen Manga als Ordner mit mehreren CBZ-Dateien scannen.
  - Erwartung: Ein Werk mit natürlich sortierten Kapiteln statt vieler
    einzelner Werke.
- [ ] Einen Manga außerhalb einer starren `Manga/Serie`-Ordnerhierarchie
  scannen.
  - Erwartung: Er wird anhand Inhalt und Metadaten weiterhin erkannt.
- [ ] Coverdateien wie `cover.jpg`, `cover.png` und macOS-Dateien mit `._`-
  Präfix prüfen.
  - Erwartung: Das richtige Cover erscheint; `._`-Dateien werden nicht als
    Kapitel angeboten.
- [ ] Manga-, TTRPG-, Webnovel-, Buch-, Dokument-, Bild- und Archivbereiche in
  der Navigation kontrollieren.
  - Erwartung: Jeder Bereich zeigt nur passende Werke.
- [ ] Kachel- und Tabellenansicht wechseln.
  - Erwartung: Auswahl, Fortschritt und Sortierung bleiben erhalten.
- [ ] Kapitel nach älteste, neueste und Name sortieren.
  - Erwartung: Natürliche Nummerierung, beispielsweise 9 vor 10; die Sortierung
    verändert weder Lesestand noch ausgewählte Downloads.
- [ ] Gelesene und ungelesene Kapitel auf Desktop und Android vergleichen.
  - Erwartung: Beide Geräte zeigen denselben Zustand verständlich an.

## 3. Lokaler Reader auf macOS (Blocker)

- [ ] Manga über `Öffnen` beziehungsweise `Fortsetzen` starten.
  - Erwartung: Das zuletzt gelesene Kapitel und die genaue Position werden
    geöffnet, nicht das Cover oder pauschal die erste Datei.
- [ ] Einzelseite mit LTR und RTL testen.
- [ ] Doppelseite mit und ohne „Erste Seite ist Cover“ testen.
- [ ] Kontinuierlich vertikal testen.
- [ ] Kontinuierlich horizontal testen.
- [ ] Webtoon/Long-Strip testen.
  - Erwartung für alle Modi: Vorwärts- und Rückwärtsnavigation funktionieren;
    es entstehen keine unbeabsichtigten Zwischenräume.
- [ ] Skalierung auf Bildschirm, Breite, Höhe und Originalgröße testen.
- [ ] Reader-Breite und Seitenabstand ändern.
  - Erwartung: Die sichtbare inhaltliche Position bleibt erhalten.
- [ ] Langsam und schnell nach unten sowie wieder nach oben scrollen.
  - Erwartung: Kein Sprung zum Kapitelanfang und kein Versatz beim Nachladen.
- [ ] Vollbild ein- und ausschalten.
  - Erwartung: Kapitel, Seite, Scrollposition und Reader-Profil bleiben gleich.
- [ ] Pfeiltasten, Mausrad und Trackpad verwenden.
  - Erwartung: Navigation folgt Modus und Leserichtung.
- [ ] Letzte Seite eines Kapitels erreichen.
  - Erwartung: Je nach Einstellung wird der Kapitelwechsel angeboten oder
    automatisch ausgeführt.
- [ ] Vom ersten Bild eines Kapitels rückwärts navigieren.
  - Erwartung: Wechsel zum vorherigen Kapitel funktioniert kontrolliert.

## 4. Lokaler Reader auf Android (Blocker)

- [ ] `Lesen/Fortsetzen` oben in der Detailansicht verwenden.
  - Erwartung: Kein Scrollen zum Ende der Dateiliste erforderlich.
- [ ] Einzelseite, kontinuierlich vertikal und Webtoon testen.
- [ ] Webtoon mit „An Breite anpassen“ testen.
  - Erwartung: Keine Lücken, Sprünge oder unerwartete Größenänderungen.
- [ ] Reader drehen beziehungsweise Fenstergröße ändern, sofern unterstützt.
  - Erwartung: Die semantisch gleiche Seite und Position bleibt sichtbar.
- [ ] Vorwärts-/Rückwärts-Taps, Swipe und Android-Zurück testen.
  - Erwartung: Kein versehentliches Verlassen oder Zurücksetzen des Standes.
- [ ] Vollbild und Bedienelemente ein-/ausblenden.
- [ ] Reader schließen.
  - Erwartung: Rückkehr in genau die Bibliotheksansicht, aus der der Manga
    geöffnet wurde, nicht automatisch in die reine Offline-Ansicht.

## 5. Exaktes Resume und Profiltrennung (Blocker)

Jeden folgenden Test möglichst einmal mit Einzelseite und einmal mit Webtoon
plus „An Breite anpassen“ durchführen.

- [ ] Auf macOS Kapitel und Seite merken, Reader schließen und erneut öffnen.
  - Erwartung: Identisches Kapitel und identische Seite; im kontinuierlichen
    Modus möglichst dieselbe Stelle innerhalb der Seite.
- [ ] Dasselbe auf Android wiederholen.
- [ ] App vollständig beenden und erneut öffnen.
- [ ] Reader-Modus ändern, einige Seiten lesen, schließen und erneut öffnen.
  - Erwartung: Das gewählte Profil wird wiederhergestellt.
- [ ] Auf macOS und Android unterschiedliche Skalierungen für dasselbe Werk
  speichern.
  - Erwartung: Gerätespezifisches Layout bleibt getrennt; der inhaltliche
    Lesestand wird trotzdem korrekt synchronisiert.
- [ ] Während des Lesens auf Seiten mit deutlich unterschiedlichen Höhen
  mehrfach hoch- und herunterscrollen.
  - Erwartung: Kein selbstständiger Sprung durch spätes Bilddekodieren oder
    Neuberechnen des Layouts.
- [ ] Kapitel 5, Seite 2 schließen und wieder öffnen.
  - Erwartung: Nicht Seite 4, 8 oder eine andere geschätzte Position, sondern
    exakt die gespeicherte Seite.

## 6. Remote, Offline und Synchronisation (Blocker)

- [ ] Manga vom Desktop-Server auf Android streamen.
  - Erwartung: Derselbe Reader und dieselben Bedienelemente wie lokal/offline.
- [ ] Im Remote-Reader einige Seiten lesen, schließen und fortsetzen.
  - Erwartung: Exakte Remote-Position und Reader-Profil bleiben erhalten.
- [ ] Danach denselben Manga auf dem Desktop öffnen.
  - Erwartung: Bei relevant abweichendem Stand erscheint der konfigurierbare
    Konfliktdialog mit Kapitel und Seite.
- [ ] Im Konfliktdialog einmal den mobilen und einmal den Desktop-Stand wählen.
  - Erwartung: Die Auswahl wird exakt geöffnet und nicht direkt wieder durch
    den anderen Stand überschrieben.
- [ ] Android offline schalten, weiterlesen, App schließen und neu öffnen.
  - Erwartung: Offline-Stand bleibt erhalten.
- [ ] Server wieder erreichbar machen.
  - Erwartung: Ausstehender Stand wird synchronisiert; bei Konflikt erfolgt eine
    Nachfrage statt einer stillen Überschreibung.
- [ ] Einen teilweise geladenen Manga offline öffnen.
  - Erwartung: Geladene Kapitel funktionieren; fehlende Kapitel werden klar als
    nicht verfügbar angezeigt.
- [ ] Nach dem Offline-Lesen wieder online gehen und denselben Manga streamen.
  - Erwartung: Kein doppeltes Werk und kein Verlust des Offline-Standes.
- [ ] Quelle des Downloads prüfen.
  - Erwartung: Verständlicher Server- und Bibliotheksname statt nur interner ID.

## 7. Kapitel-Downloads und Mehrfachauswahl (vor nächstem Build prüfen)

- [ ] Download-Aktion oben in der mobilen Detailansicht öffnen.
- [ ] `Nächste 100` auswählen.
- [ ] `Ab aktuellem Kapitel` auswählen.
- [ ] Exakten Bereich, beispielsweise Kapitel 101 bis 200, eingeben.
- [ ] Umgekehrte Eingabe, beispielsweise 200 bis 101, testen.
  - Erwartung: Derselbe gültige Bereich wird ausgewählt.
- [ ] Einzelmodus öffnen und nicht zusammenhängende Kapitel wählen.
- [ ] Zwischen Bereichs- und Einzelmodus wechseln.
- [ ] Kapitel sortieren, nachdem eine Auswahl vorbereitet wurde.
  - Erwartung: Auswahl bezieht sich weiterhin auf dieselben Kapitel.
- [ ] Bereits heruntergeladene Kapitel im Bereich kontrollieren.
  - Erwartung: Sie sind markiert und werden nicht erneut übertragen.
- [ ] Bestehenden Teil-Download um einen weiteren Bereich ergänzen.
  - Erwartung: Vorhandene Kapitel bleiben erhalten.
- [ ] Download abbrechen oder Verbindung unterbrechen.
  - Erwartung: Keine defekten Kapitel werden als vollständig heruntergeladen
    angezeigt.
- [ ] App aktualisieren und Teil-Download erneut kontrollieren.

## 8. Kapitel, Fortschritt und Lesezeichen (hohe Priorität)

- [ ] Kapitelübersicht öffnen und ein anderes Kapitel auswählen.
  - Erwartung: Bei vorhandenem Lesestand erfolgt eine verständliche Nachfrage,
    bevor die aktuelle Position verloren geht.
- [ ] Bereits gelesenes Kapitel erneut öffnen.
- [ ] Kapitel als gelesen beziehungsweise ungelesen markieren und Geräte
  synchronisieren.
- [ ] Lesezeichen auf einer Seite erstellen, benennen und mit Notiz versehen.
- [ ] Zu einem Lesezeichen springen.
  - Erwartung: Richtiges Kapitel und richtige Seite; an identischer Position
    keine unnötige Rücksprung-Nachfrage.
- [ ] Lesezeichen löschen und nach einem Scan beziehungsweise Neustart prüfen.
- [ ] Fehlende oder doppelte Kapitelnummern prüfen.
  - Erwartung: Hinweis statt still falscher Reihenfolge.

## 9. Leistung und Robustheit (hohe Priorität)

- [ ] Werk mit mehreren Hundert oder Tausend Kapiteln öffnen.
  - Erwartung: Detailansicht und Auswahlliste bleiben bedienbar.
- [ ] Großes CBZ mit vielen hochauflösenden Bildern öffnen.
  - Erwartung: Kein vollständiges Entpacken in den Arbeitsspeicher und kein
    Absturz.
- [ ] Schnell durch mehrere Seiten und Kapitel navigieren.
- [ ] Remote-Verbindung während des Ladens trennen und wiederherstellen.
- [ ] Beschädigtes oder leeres CBZ öffnen.
  - Erwartung: Verständliche Fehlermeldung; App bleibt stabil.
- [ ] Diagnoseprotokoll kontrollieren.
  - Erwartung: Fehlerklasse und Werk-/Kapitelbezug sind erkennbar; keine Tokens,
    Zertifikate oder unnötigen absoluten Pfade werden protokolliert.

## 10. Komfortfunktionen – dürfen nach Webnovel-Start folgen

Diese Punkte sind Teil des Manga-Zielbilds, blockieren den Beginn des
Webnovel-Readers aber nicht:

- [ ] Erweiterte Filter nach Untertyp, Status, ungelesenen Kapiteln,
  Downloadstatus, Sprache und fehlenden Kapiteln
- [ ] Gespeicherte kombinierte Filter und Sortierungen
- [ ] Manuelle Zuordnung Manga, Comic, Manhwa, Manhua oder Webtoon
- [ ] Vollständiger `ComicInfo.xml`-Import mit manuellen Metadaten-Locks
- [ ] Frei belegbare Desktop-Hotkeys
- [ ] Bildfilter, Sepia, Invertierung und anpassbarer Hintergrund
- [ ] Auto-Scroll und „Bewegung reduzieren“
- [ ] Automatischer Download der nächsten Kapitel
- [ ] Kontrolliertes Löschen bereits gelesener Offline-Kapitel
- [ ] CBR/CB7 und weitere Archivformate
- [ ] Erkennung und Aufteilung breiter Doppelseiten
- [ ] Übersetzergruppen und alternative Kapitelvarianten

## Freigabekriterium für den Webnovel-Meilenstein

Der Webnovel-Reader kann begonnen werden, wenn:

- [ ] Abschnitte 1 bis 6 ohne reproduzierbaren Datenverlust bestehen,
- [ ] Resume in lokal, Remote und offline zuverlässig ist,
- [ ] ein App-Update vorhandene Downloads und Lesestände erhält,
- [ ] keine spontanen Scrollsprünge mehr auftreten und
- [ ] bekannte verbleibende Komfortpunkte als GitHub-Issues dokumentiert sind.
