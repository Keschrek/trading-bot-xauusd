// file: src/mt5/ea/XAUUSD_MasterEA_v1_0.mq5
#property strict
#include <Trade/Trade.mqh>
CTrade Trade;

// --- Inputs (Beispiele, später aus configs lesen) ---
input double   RiskPerTrade = 0.5;
input double   ATR_Mult_SL  = 1.8;
input double   TP_RR        = 1.6;

int OnInit(){
   Print("XAUUSD_MasterEA_v1_0 init");
   return(INIT_SUCCEEDED);
}

void OnTick(){
   // TODO:
   // 1) RunMainFilter();   // Trend/Stärke/Momentum (mind. 2/3)
   // 2) ScoreQuality();    // Spread/Volatilität/Session etc.
   // 3) ScoreDirection();  // Long/Short/Flat
   // 4) PositionSizing();  // Equity-basiert
   // 5) Place/Manage Orders + Smart Trailing (ATR-Schritte, nie ins Minus)
}

void OnDeinit(const int reason){
   Print("EA deinit: ", reason);
}
