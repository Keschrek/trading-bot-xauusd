// file: src/mt5/ea/XAUUSD_MasterEA_v1_0.mq5
#property strict
#property version   "1.0.0"
#property description "XAU/USD Scalping-Bot (Meta-Strategy Skeleton, Pflichtenheft-konform)"
#property copyright  "MIT"

#include <Trade/Trade.mqh>
CTrade Trade;

// ---------------- Inputs (konservativ, Pflichtenheft-konform) ----------------
input string   InpSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES InpTF_Work      = PERIOD_M1;    // Arbeits-TF (Entry)
input ENUM_TIMEFRAMES InpTF_HTF       = PERIOD_H1;    // HTF-Bias
input double   InpRisk_PerTrade       = 0.5;          // % Equity
input double   InpDailyLossStopEUR    = 150.0;        // Equity Stop (Safe-Modus im Bot)
input bool     InpUseNewsFilter       = true;         // JSON-Bridge (noch Stub)
input bool     InpUseSmartTrailing    = true;         // ATR-basiert
input int      InpATR_Period          = 14;
input double   InpATR_Mult_SL         = 1.8;
input double   InpATR_Mult_Trail      = 1.2;
input double   InpMinTrailStartEUR    = 10.0;         // Trailing erst ab +10€ Gewinn
input double   InpQual_Min_Normal     = 4.0;          // Schwellen gem. Pflichtenheft
input double   InpQual_Min_Safe       = 5.0;
input double   InpQual_Min_PostTarget = 4.5;
input double   InpSplitEntry_Min      = 5.5;
input double   InpAdjustMaxAbs        = 1.0;          // GPT/KI: ±1.0 (limitiert, Gemini)
input string   InpLogFilePrefix       = "xauusd_meta_"; // in MQL5/Files/

/*
  Hinweise:
  - Keine Secrets. News-Filter & GPT-Mode sind vorbereitet, aber noch Stub.
  - Pflichtenheft: Hauptfilter (2/3 Kategorien), ScoreEngine, DirectionEngine,
    Smart Trailing, Equity Stop, Logging.
*/

// ---------------- Globals & Handles ----------------
MqlTick   g_tick;
int       g_handleATR = INVALID_HANDLE;
int       g_handleMACD = INVALID_HANDLE;

datetime  g_lastM1CloseTime = 0;
int       g_digits = 2;
double    g_point  = 0.01;

// ---------------- Utilities ----------------
double Clamp(double v,double lo,double hi){ return MathMax(lo,MathMin(hi,v)); }

string TodayCsvName()
{
  return InpLogFilePrefix + TimeToString(TimeCurrent(), TIME_DATE) + ".csv";
}

void EnsureLogHeader()
{
  string fn = TodayCsvName();
  int h = FileOpen(fn, FILE_READ|FILE_CSV|FILE_ANSI, ';');
  if(h!=INVALID_HANDLE){ FileClose(h); return; }
  h = FileOpen(fn, FILE_WRITE|FILE_CSV|FILE_ANSI, ';');
  if(h==INVALID_HANDLE) return;
  // Header gem. Pflichtenheft-Erweiterung
  FileWrite(h,"Time","Event","Module","Decision","Direction","Price","SL","TP",
               "QualBaseL","QualBaseS","DirL","DirS",
               "AdjL","AdjS","QualAppliedL","QualAppliedS",
               "Mode","Notes");
  FileClose(h);
}

void LogRow(string event,string module,string decision,string dir,double price,double sl,double tp,
            double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,
            string mode,string notes)
{
  string fn = TodayCsvName();
  int h = FileOpen(fn, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI, ';');
  if(h==INVALID_HANDLE) return;
  FileSeek(h, 0, SEEK_END);
  FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
               event, module, decision, dir,
               DoubleToString(price, g_digits),
               DoubleToString(sl, g_digits),
               DoubleToString(tp, g_digits),
               qL, qS, dL, dS, aL, aS, qaL, qaS, mode, notes);
  FileClose(h);
}

// ---------------- Init/Deinit ----------------
int OnInit()
{
  if(!SymbolSelect(InpSymbol,true)) return(INIT_FAILED);
  g_digits = (int)SymbolInfoInteger(InpSymbol,SYMBOL_DIGITS);
  g_point  = SymbolInfoDouble(InpSymbol,SYMBOL_POINT);

  g_handleATR  = iATR(InpSymbol, InpTF_Work, InpATR_Period);
  if(g_handleATR==INVALID_HANDLE) { Print("ATR handle failed"); return(INIT_FAILED); }

  // MACD (12,26,9) Histogram
  g_handleMACD = iMACD(InpSymbol, InpTF_Work, 12, 26, 9, PRICE_CLOSE);
  if(g_handleMACD==INVALID_HANDLE) { Print("MACD handle failed"); return(INIT_FAILED); }

  EnsureLogHeader();
  Print("[EA] Init OK | Symbol=",InpSymbol," TF=",IntegerToString((int)InpTF_Work));
  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  if(g_handleATR!=INVALID_HANDLE)  IndicatorRelease(g_handleATR);
  if(g_handleMACD!=INVALID_HANDLE) IndicatorRelease(g_handleMACD);
}

// ---------------- Main Loop ----------------
void OnTick()
{
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  // Nur bei neu geschlossener M1-Kerze arbeiten
  datetime m1Close = iTime(InpSymbol, InpTF_Work, 0);
  if(m1Close==0 || m1Close==g_lastM1CloseTime) return;
  g_lastM1CloseTime = m1Close;

  // Safety Gates
  if(IsTradingPausedByNews())
  {
    LogRow("NEWS_BLOCK","NewsFilter","BLOCK","-",0,0,0,0,0,0,0,0,0,0,"Safe","News active");
    return;
  }
  if(DailyLossExceeded())
  {
    LogRow("SAFE_MODE","RiskControl","BLOCK","-",0,0,0,0,0,0,0,0,0,0,"Safe","Daily loss stop");
    return;
  }

  // Hauptfilter (Vorfilter)
  bool fTrend=false, fStrength=false, fMomentum=false;
  EvaluateMainFilter(fTrend,fStrength,fMomentum);
  int cats = (int)fTrend + (int)fStrength + (int)fMomentum;

  bool htfBias = EvaluateHTFBias(); // Gate (vorbereitet streng; kann konfigurierbar werden)
  if(!(cats>=2 && htfBias))
  {
    LogRow("FILTER_BLOCK","MainFilter","BLOCK","-",0,0,0,0,0,0,0,0,0,0,"Normal","cats="+IntegerToString(cats));
    return;
  }

  // Scores
  double qualLong=0, qualShort=0;
  double dirLong=0,  dirShort=0;
  ComputeQualityScore(qualLong,qualShort);
  ComputeDirectionScore(dirLong,dirShort);

  // GPT/KI Adjust (limitiert)
  double adjL=0.0, adjS=0.0;
  ApplyMetaAdjust(adjL,adjS);
  adjL = Clamp(adjL, -InpAdjustMaxAbs, InpAdjustMaxAbs);
  adjS = Clamp(adjS, -InpAdjustMaxAbs, InpAdjustMaxAbs);

  double appliedL = qualLong  + adjL;
  double appliedS = qualShort + adjS;

  // Entry Decision (konservativ)
  string reason="";
  if(ShouldEnterLong(appliedL, dirLong, reason))
     TryOpenPosition(ORDER_TYPE_BUY, reason, qualLong, qualShort, dirLong, dirShort, adjL, adjS, appliedL, appliedS);
  else if(ShouldEnterShort(appliedS, dirShort, reason))
     TryOpenPosition(ORDER_TYPE_SELL, reason, qualLong, qualShort, dirLong, dirShort, adjL, adjS, appliedL, appliedS);

  // Positionen managen (Trailing)
  ManagePositions();
}

// ---------------- Filter & Scores ----------------
bool EmaBiasOK_TF(ENUM_TIMEFRAMES tf, int fast,int slow)
{
  double f=iMA(InpSymbol,tf,fast,0,MODE_EMA,PRICE_CLOSE,0);
  double s=iMA(InpSymbol,tf,slow,0,MODE_EMA,PRICE_CLOSE,0);
  if(f==0 || s==0) return false;
  return (f>s);
}

bool EmaCross_TF(ENUM_TIMEFRAMES tf, int fast,int slow)
{
  double f0=iMA(InpSymbol,tf,fast,0,MODE_EMA,PRICE_CLOSE,0);
  double s0=iMA(InpSymbol,tf,slow,0,MODE_EMA,PRICE_CLOSE,0);
  double f1=iMA(InpSymbol,tf,fast,0,MODE_EMA,PRICE_CLOSE,1);
  double s1=iMA(InpSymbol,tf,slow,0,MODE_EMA,PRICE_CLOSE,1);
  return ( (f1<=s1 && f0>s0) || (f1>=s1 && f0<s0) );
}

double GetATR()
{
  double buf[]; ArraySetAsSeries(buf,true);
  if(CopyBuffer(g_handleATR,0,0,2,buf)<2) return 0.0;
  return buf[0];
}

double GetMACDHist()
{
  // iMACD returns: 0 main, 1 signal, 2 hist
  double hist[]; ArraySetAsSeries(hist,true);
  if(CopyBuffer(g_handleMACD,2,0,2,hist)<2) return 0.0;
  return hist[0];
}

double GetRSI_TF(ENUM_TIMEFRAMES tf,int period=14)
{
  int h = iRSI(InpSymbol, tf, period, PRICE_CLOSE);
  if(h==INVALID_HANDLE) return 50.0;
  double r[]; ArraySetAsSeries(r,true);
  if(CopyBuffer(h,0,0,2,r)<2) { IndicatorRelease(h); return 50.0; }
  double v = r[0];
  IndicatorRelease(h);
  return v;
}

bool VolumeSpike()
{
  // Einfacher Spike-Check vs. 50er Durchschnitt auf Work-TF
  long v0 = (long)iVolume(InpSymbol, InpTF_Work, 0);
  long sum = 0;
  for(int i=1;i<=50;i++) sum += (long)iVolume(InpSymbol, InpTF_Work, i);
  if(sum<=0) return false;
  double avg = (double)sum/50.0;
  return (avg>0 && v0 > 1.5*avg);
}

bool StrengthOK()
{
  // Platzhalter: ATR/Preis-Verhältnis als Proxy für "Stärke"
  double atr = GetATR();
  if(atr<=0 || g_tick.bid<=0) return false;
  double ratio = atr / g_tick.bid;
  return (ratio > 0.0010);
}

void EvaluateMainFilter(bool &trend, bool &strength, bool &momentum)
{
  trend    = EmaBiasOK_TF(InpTF_Work,50,200) || EmaCross_TF(InpTF_Work,5,10);
  strength = StrengthOK() || VolumeSpike();
  // Momentum: MACD-Hist Richtung oder RSI aus der Mitte
  double macd = GetMACDHist();
  double rsi  = GetRSI_TF(InpTF_Work,14);
  momentum = (macd!=0.0) || (rsi>55 || rsi<45);
}

bool EvaluateHTFBias()
{
  // H1 EMA50>EMA200 als Gate (konfigurabel streng in Folge-PR)
  return EmaBiasOK_TF(InpTF_HTF,50,200) || true; // aktuell „weich“ zugelassen
}

void ComputeQualityScore(double &longScore, double &shortScore)
{
  longScore=0; shortScore=0;

  // Beispiele (Gewichte gem. Pflichtenheft grob angenähert)
  if(EmaCross_TF(InpTF_Work,5,10)) { longScore+=1.5; shortScore+=1.5; }
  if(StrengthOK())                 { longScore+=0.5; shortScore+=0.5; }
  if(VolumeSpike())                { longScore+=1.0; shortScore+=1.0; }

  // ATR-Volatilitätsbonus
  double atr = GetATR();
  if(atr>0) { longScore+=0.5; shortScore+=0.5; }
}

void ComputeDirectionScore(double &longScore, double &shortScore)
{
  longScore=0; shortScore=0;

  if(EmaBiasOK_TF(InpTF_Work,50,200)) longScore+=1.0; else shortScore+=1.0;

  double macd = GetMACDHist();
  if(macd>0) longScore+=1.0;
  if(macd<0) shortScore+=1.0;

  double rsi = GetRSI_TF(InpTF_Work,14);
  if(rsi>50) longScore+=0.5; else if(rsi<50) shortScore+=0.5;
}

void ApplyMetaAdjust(double &adjLong, double &adjShort)
{
  // Stub: externe KI noch nicht verdrahtet
  adjLong  = 0.0;
  adjShort = 0.0;
}

bool ShouldEnterLong(double qualApplied, double dirScore, string &reason)
{
  if(qualApplied>=InpQual_Min_Normal && dirScore>=1.0)
  { reason="QUAL>=min & DIR>=1"; return true; }
  return false;
}
bool ShouldEnterShort(double qualApplied, double dirScore, string &reason)
{
  if(qualApplied>=InpQual_Min_Normal && dirScore>=1.0)
  { reason="QUAL>=min & DIR>=1"; return true; }
  return false;
}

// ---------------- Risk, Entry & Trailing ----------------
double CalcLotByRisk(double stopPts)
{
  if(stopPts<=0) return(0.0);
  double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = equity * (InpRisk_PerTrade/100.0);

  double tickValue = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);
  double tickSize  = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
  double moneyPerPoint = (tickSize>0) ? (tickValue / (tickSize / g_point)) : 0.0;
  if(moneyPerPoint<=0) return 0.0;

  double lots = riskMoney / (stopPts * moneyPerPoint);
  double step = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
  double minl = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
  double maxl = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
  if(step<=0) step=0.01;
  lots = MathMax(minl, MathMin(maxl, MathFloor(lots/step)*step));
  return(lots);
}

void TryOpenPosition(ENUM_ORDER_TYPE type, string reason,
                     double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS)
{
  double atr = GetATR();
  double slPts = MathMax((atr*InpATR_Mult_SL)/g_point, 100.0); // Floor
  double price = (type==ORDER_TYPE_BUY)? g_tick.ask : g_tick.bid;
  double sl    = (type==ORDER_TYPE_BUY)? price - slPts*g_point : price + slPts*g_point;
  double tp    = 0.0; // dynamisch in späteren PRs

  double lots  = CalcLotByRisk(slPts);
  if(lots<=0)
  {
    LogRow("ENTRY_BLOCK","EntryManager","BLOCK",(type==ORDER_TYPE_BUY?"LONG":"SHORT"),
           price, sl, tp, qL,qS,dL,dS,aL,aS,qaL,qaS, "Normal","lot calc failed");
    return;
  }

  Trade.SetStopLossPrice(sl);
  Trade.SetTakeProfitPrice(tp);
  bool ok = (type==ORDER_TYPE_BUY)
              ? Trade.Buy(lots, InpSymbol, price, sl, tp, reason)
              : Trade.Sell(lots, InpSymbol, price, sl, tp, reason);

  LogRow(ok? "ENTRY_OK":"ENTRY_FAIL","EntryManager", ok? "OPEN":"FAIL",
         (type==ORDER_TYPE_BUY?"LONG":"SHORT"), price, sl, tp,
         qL,qS,dL,dS,aL,aS,qaL,qaS, "Normal", reason);
}

void ManagePositions()
{
  if(!InpUseSmartTrailing) return;

  for(int i=PositionsTotal()-1;i>=0;--i)
  {
    ulong ticket = PositionGetTicket(i);
    if(!PositionSelectByTicket(ticket)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=InpSymbol) continue;

    double priceCur  = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)? g_tick.bid : g_tick.ask;
    double profitEUR = PositionGetDouble(POSITION_PROFIT);
    if(profitEUR < InpMinTrailStartEUR) continue;

    double atr = GetATR();
    double trailPts = MathMax((atr*InpATR_Mult_Trail)/g_point, 50.0);
    double newSL, oldSL = PositionGetDouble(POSITION_SL);

    if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
      newSL = MathMax(oldSL, priceCur - trailPts*g_point);
    else
      newSL = MathMin(oldSL, priceCur + trailPts*g_point);

    if(newSL!=oldSL)
      Trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
  }
}

// ---------------- Safety Stubs ----------------
bool IsTradingPausedByNews()
{
  if(!InpUseNewsFilter) return false;
  // TODO: JSON/CSV Bridge (Python) anbinden
  return false;
}

bool DailyLossExceeded()
{
  // TODO: Tages-PnL/EQUITY beobachten und Safe-Modus setzen
  return false;
}