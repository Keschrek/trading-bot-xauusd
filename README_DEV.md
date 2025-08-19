# README_DEV – Laufende Entwickler-Doku
**Pflicht:** Jeder Schritt, jede Entscheidung, jeder Parameterwechsel wird hier kurz dokumentiert.
## Rollen & Ablauf
PO (Patrick) entscheidet; GPT-5 plant/prüft; Gemini analysiert; Cursor AI implementiert.
## Change Log
- (heute) Initiales Repo-Skeleton, Templates, EA-Stub.
## Backlog (Kurz)
- Hauptfilter, Qualitäts-Score, Richtungs-Score, Smart Trailing SL, News-/Pause-Filter.
## 2025-08-19 – v0.2 EA-Skelett erweitert
- Hauptfilter (2/3 Kategorien) implementiert + HTF-Bias-Gate vorbereitet
- ScoreEngine (Qualität) & DirectionEngine (Richtung) mit Basisgewichten
- GPT/KI Adjust hart limitiert (±1.0)
- ATR-basierter Smart Trailing (kein Zurücksetzen)
- CSV-Logger mit erweiterten Feldern (Base/Applied Scores, Mode, Notes)

### Kompilieren & Smoke-Test
1. Datei nach `MQL5/Experts/` spiegeln: `src/mt5/ea/XAUUSD_MasterEA_v1_0.mq5`
2. In MetaEditor öffnen → **Kompilieren** (keine Errors)
3. Strategy Tester (Symbol: XAUUSD, TF: M1, 1 Tag) starten
4. In `MQL5/Files/` sollte eine CSV `xauusd_meta_<YYYY.MM.DD>.csv` mit Header entstehen
