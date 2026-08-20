# runtime-analysis.nvim — Ausblick

**Was dieses Plugin ist, in einem Satz:** es misst, was zur Laufzeit
tatsächlich passiert — und ist damit die Gegenprobe zu einem statischen
Analysator, der nur sehen kann, was im Text steht.

Diese Datei war bis 2026-08-20 leer. Was hier fehlte, ist die Richtung; die
Herleitung jeder einzelnen Idee steht seit jeher in
[`IDEAS.md`](IDEAS.md), was gebaut wurde in
[`FEATURES/FINISHED.md`](FEATURES/FINISHED.md).

> **Die Warteschlange steht woanders.** Was als Nächstes gebaut wird — hier
> *und* in `documentation.nvim` und `docmap-desktop` — steht seit
> 2026-08-20 in **einem** Plan:
> [`docmap-desktop/docs/PLAN.md`](https://github.com/StefanBartl/docmap-desktop/blob/main/docs/PLAN.md).

## Wo es hingeht

**Der blinde Fleck der statischen Analyse ist die Aufgabe.** Eine Funktion,
die als Callback-Wert gebunden oder über dynamischen Dispatch erreicht wird,
hat keine Aufrufstelle, die sie nennt — für einen Parser existiert sie
nicht, und die Telemetrie sieht sie laufen. Jede nützliche Kreuzung mit
`documentation.nvim` folgt aus dieser einen Asymmetrie: Churn × Aufrufzahl
trennt „refaktorieren" von „löschen", Coverage × Telemetrie ergibt die
Warteschlange *heiß und ungetestet*, und der Hover sagt, wie oft eine
Funktion in den letzten sieben Tagen wirklich betreten wurde.

**Vom Zählen zum Messen.** Aufrufzahlen sind der Anfang; Zeiten und Formen
sind der Weg zu einem Profiler. Für API-Verkehr ist die Grenze vorab
gezogen und sie ist nicht verhandelbar: **Metadaten und Formen, niemals
Payloads** — weil die Aufzeichnungen committet werden.

**Zwei Browser-Stufen existieren, und keine ist zu Ende benutzt.** Eine
dritte Pipeline wird nicht gebaut. `report_style = "preview-tab"` ist die
browserfreie Stufe und nimmt die Binär-Download-Pause aus dem Standardpfad.

## Drei Grenzen, die nicht verhandelt werden

Sie stehen in [`IDEAS.md`](IDEAS.md) §7 mit voller Begründung; hier stehen
sie, weil sie erklären, warum manches *nicht* kommt.

- **`documentation.nvim` darf niemals hart auf dieses Plugin angewiesen
  sein.** Ein statischer Analysator, der ohne Runtime-Plugin nicht läuft, hat
  genau die Eigenschaft verloren, die ihn im CI nützlich macht.
- **Laufzeitdaten gehören nie ins committete Artefakt.** Sie brechen den
  Byte-Vergleich beim Erzeugen und sind persönliche, schnell veraltende
  Nutzungsdaten beim Committen.
- **Laufzeit-Evidenz darf die Schwere eines Checks nie *erhöhen*.** Eine
  Warnung, die auf einer Maschine erscheint und auf einer anderen nicht, ist
  schlechter als keine Warnung. Als *Unterdrückung* ist sie dagegen richtig,
  und so wird sie auch verwendet.

Und eine, die oft vorgeschlagen wird: **Telemetrie zwischen Maschinen zu
teilen**, damit „auf dieser Maschine kalt" nicht mehr mit „unbenutzt"
verwechselt wird. Die richtige Antwort darauf ist eine ehrliche Formulierung
im Render, kein Aggregationsdienst.
