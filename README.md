# XAUUSD Meta-Strategy Bot (MT5)
MT5-Expert Advisor (EA) für XAU/USD mit:
- Hauptfilter (Trend, Stärke/Volumen, Momentum)
- Qualitäts-Score & Richtungs-Score
- Smart Trailing SL (ATR-basiert, nie ins Minus)
- News-/Pause-Filter
- GPT-Mode (JSON-only Meta-Manager)

## Quick Start
1. `src/mt5/ea/` nach `MQL5/Experts/` spiegeln.
2. `configs/example.runtime.json` ? `configs/local.runtime.json` kopieren und anpassen.
3. In MT5 kompilieren, Strategy Tester starten.
Weitere Details: `README_DEV.md`.
