// file: src/mt5/ea/XAUUSD_MasterEA_v1_0.mq5
#property strict
#property version   "001.000"
#property description "XAU/USD Scalping-Bot – v0.9 (fixes for MQL5 handles, logging, news, trailing)"
#property copyright  "MIT"

#include <Trade/Trade.mqh>
CTrade Trade;

// ======= Inputs / Runtime =======
input string   InpSymbol              = "XAUUSD";
input ENUM_TIMEFRAMES InpTF_Work      = PERIOD_M1;     // Entry-TF
input ENUM_TIMEFRAMES InpTF_HTF       = PERIOD_H1;     // Trend-Bias
input bool     InpHTF_Gate_Strict     = true;          // HTF-Bias als hartes Gate
input string   InpTradeWindow_Start   = "07:00";
input string   InpTradeWindow_End     = "22:00";

input double   InpRisk_PerTrade       = 0.5;           // % Equity
input double   InpDailyLossStopEUR    = 150.0;         // Tagesverlust → Safe-Modus
input double   InpDailyTargetEUR      = 150.0;         // Tagesziel → PostTarget

input bool     InpUseNewsFilter       = true;
input string   InpNewsFile            = "configs\\news_feed.json"; // JSON oder CSV
input int      InpNewsPreBlockMin     = 30;            // vor News blocken
input int      InpNewsPostBlockMin    = 20;            // nach News blocken

input bool     InpUseSmartTrailing    = true;
input int      InpATR_Period          = 14;
input double   InpATR_Mult_SL         = 1.8;
input double   InpATR_Mult_Trail      = 1.2;
input double   InpMinTrailStartEUR    = 10.0;

input double   InpQual_Min_Normal     = 4.0;
input double   InpQual_Min_Safe       = 5.0;
input double   InpQual_Min_PostTarget = 4.5;
input double   InpSplitEntry_Min      = 5.5;           // ab hier bis zu 3 Splits

input double   InpAdjustMaxAbs        = 1.0;           // KI/GPT ±1.0 (intern begrenzt)
input string   InpLogFilePrefix       = "xauusd_meta_"; // MQL5/Files/
input bool     InpDebug               = true;

// ======= Enums / State =======
enum BotMode { MODE_NORMAL=0, MODE_SAFE=1, MODE_POSTTARGET=2, MODE_MANUAL=3 };
BotMode g_mode = MODE_NORMAL;

// Tageszustand
double   g_dayStartEquity = 0.0;
datetime g_dayAnchor      = 0;

// Handles & Cached
MqlTick  g_tick;
int      g_handleATR  = INVALID_HANDLE;
int      g_handleMACD = INVALID_HANDLE;
datetime g_lastM1CloseTime = 0;
int      g_digits = 2;
double   g_point  = 0.01;

// ======= Utils & Logging =======
double Clamp(double v,double lo,double hi){ return MathMax(lo,MathMin(hi,v)); }
string TodayCsv(){ return InpLogFilePrefix + TimeToString(TimeCurrent(),TIME_DATE) + ".csv"; }

void EnsureLogHeader()
{
  string fn=TodayCsv();
  int h = FileOpen(fn,FILE_READ|FILE_CSV|FILE_ANSI,';');
  if(h!=INVALID_HANDLE){ FileClose(h); return; }
  h = FileOpen(fn,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
  if(h==INVALID_HANDLE) return;
  FileWrite(h,"Time","Event","Module","Decision","Mode","Direction","Price","SL","TP",
              "QualBaseL","QualBaseS","DirL","DirS","AdjL","AdjS","QualAppliedL","QualAppliedS",
              "Cats","HTF_OK","Notes");
  FileClose(h);
}
void LogRow(string ev,string mod,string dec,string mode,string dir,double price,double sl,double tp,
            double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,
            int cats,bool htfok,string notes)
{
  string fn=TodayCsv();
  int h=FileOpen(fn,FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI,';'); if(h==INVALID_HANDLE) return;
  FileSeek(h,0,SEEK_END);
  FileWrite(h,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),ev,mod,dec,mode,dir,
            DoubleToString(price,g_digits),DoubleToString(sl,g_digits),DoubleToString(tp,g_digits),
            qL,qS,dL,dS,aL,aS,qaL,qaS,cats,(int)htfok,notes);
  FileClose(h);
}

bool ParseHHMM(string s,int &hh,int &mm)
{
  int p=StringFind(s,":"); if(p<0) return false;
  hh=(int)StringToInteger(StringSubstr(s,0,p));
  mm=(int)StringToInteger(StringSubstr(s,p+1));
  return (hh>=0 && hh<24 && mm>=0 && mm<60);
}
bool InTradeWindow()
{
  int sh=7, sm=0, eh=22, em=0;
  ParseHHMM(InpTradeWindow_Start,sh,sm);
  ParseHHMM(InpTradeWindow_End,eh,em);
  MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
  int nowMin = dt.hour*60+dt.min;
  int sMin   = sh*60+sm;
  int eMin   = eh*60+em;
  return (nowMin>=sMin && nowMin<=eMin);
}

// ======= Series Helpers (MQL5: CopyBuffer) =======
double MaValue(ENUM_TIMEFRAMES tf,int period,ENUM_MA_METHOD method=MODE_EMA,int price_type=PRICE_CLOSE,int shift=0)
{
  int h=iMA(InpSymbol,tf,period,0,method,price_type);
  if(h==INVALID_HANDLE) return 0.0;
  double b[]; ArraySetAsSeries(b,true);
  int copied=CopyBuffer(h,0,shift,1,b);
  IndicatorRelease(h);
  if(copied<1) return 0.0;
  return b[0];
}
double GetATR()
{
  double b[]; ArraySetAsSeries(b,true);
  if(CopyBuffer(g_handleATR,0,0,1,b)<1) return 0.0;
  return b[0];
}
double GetMACDHist()
{
  double h[]; ArraySetAsSeries(h,true);
  if(CopyBuffer(g_handleMACD,2,0,1,h)<1) return 0.0;
  return h[0];
}
double GetRSI(ENUM_TIMEFRAMES tf,int period=14)
{
  int h=iRSI(InpSymbol,tf,period,PRICE_CLOSE); if(h==INVALID_HANDLE) return 50.0;
  double r[]; ArraySetAsSeries(r,true);
  int copied=CopyBuffer(h,0,0,1,r); IndicatorRelease(h);
  if(copied<1) return 50.0;
  return r[0];
}

// ======= Trend/Momentum Helpers =======
bool EmaBiasOK_TF(ENUM_TIMEFRAMES tf,int fast,int slow)
{
  double f=MaValue(tf,fast,MODE_EMA,PRICE_CLOSE,0);
  double s=MaValue(tf,slow,MODE_EMA,PRICE_CLOSE,0);
  if(f==0 || s==0) return false;
  return (f>s);
}
bool EmaCross_TF(ENUM_TIMEFRAMES tf,int fast,int slow)
{
  double f0=MaValue(tf,fast,MODE_EMA,PRICE_CLOSE,0);
  double s0=MaValue(tf,slow,MODE_EMA,PRICE_CLOSE,0);
  double f1=MaValue(tf,fast,MODE_EMA,PRICE_CLOSE,1);
  double s1=MaValue(tf,slow,MODE_EMA,PRICE_CLOSE,1);
  return ( (f1<=s1 && f0>s0) || (f1>=s1 && f0<s0) );
}
bool VolumeSpike()
{
  long v0=(long)iVolume(InpSymbol,InpTF_Work,0);
  long sum=0; for(int i=1;i<=50;i++) sum+=(long)iVolume(InpSymbol,InpTF_Work,i);
  if(sum<=0) return false; double avg=(double)sum/50.0;
  return (avg>0 && v0>1.5*avg);
}
bool StrengthOK()
{
  double atr=GetATR(); if(atr<=0 || !SymbolInfoTick(InpSymbol,g_tick)) return false;
  return (atr/g_tick.bid > 0.0010);
}

// ======= Main Filter & Scores =======
void EvaluateMainFilter(bool &trend, bool &strength, bool &momentum)
{
  trend    = EmaBiasOK_TF(InpTF_Work,50,200) || EmaCross_TF(InpTF_Work,5,10);
  strength = StrengthOK() || VolumeSpike();
  double macd = GetMACDHist(); double rsi = GetRSI(InpTF_Work,14);
  momentum = (macd!=0.0) || (rsi>55 || rsi<45);
}
bool EvaluateHTFBias()
{
  bool ok = EmaBiasOK_TF(InpTF_HTF,50,200);
  return InpHTF_Gate_Strict ? ok : (ok || true);
}
void ComputeQualityScore(double &longScore,double &shortScore)
{
  longScore=0; shortScore=0;
  if(EmaCross_TF(InpTF_Work,5,10)) { longScore+=1.5; shortScore+=1.5; }
  if(StrengthOK())                 { longScore+=0.5; shortScore+=0.5; }
  if(VolumeSpike())                { longScore+=1.0; shortScore+=1.0; }
  double atr=GetATR(); if(atr>0)   { longScore+=0.5; shortScore+=0.5; } // Volatilitätsbonus
}
void ComputeDirectionScore(double &longScore,double &shortScore)
{
  longScore=0; shortScore=0;
  if(EmaBiasOK_TF(InpTF_Work,50,200)) longScore+=1.0; else shortScore+=1.0;
  double macd = GetMACDHist(); if(macd>0) longScore+=1.0; if(macd<0) shortScore+=1.0;
  double rsi = GetRSI(InpTF_Work,14); if(rsi>50) longScore+=0.5; else if(rsi<50) shortScore+=0.5;
}
void ApplyMetaAdjust(double &adjLong,double &adjShort){ adjLong=0.0; adjShort=0.0; } // externe KI noch nicht angebunden

// ======= ModeManager / Day Handling =======
void ResetDayIfNeeded()
{
  MqlDateTime t; TimeToStruct(TimeCurrent(),t);
  MqlDateTime d; TimeToStruct(g_dayAnchor,d);
  if(t.day!=d.day || t.mon!=d.mon || t.year!=d.year || g_dayAnchor==0)
  {
    MqlDateTime z=t; z.hour=0; z.min=0; z.sec=0;
    g_dayAnchor = StructToTime(z);
    g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    g_mode = MODE_NORMAL; // Tagesreset
    LogRow("DAY_RESET","ModeManager","RESET","Normal","-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "new day");
  }
}
double TodayPnL(){ return AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity; }
void UpdateModeByPnL()
{
  double pnl = TodayPnL();
  if(pnl <= -InpDailyLossStopEUR) g_mode = MODE_SAFE;
  else if(pnl >= InpDailyTargetEUR) g_mode = MODE_POSTTARGET;
  else if(g_mode!=MODE_MANUAL) g_mode = MODE_NORMAL;
}
string ModeName(){ return g_mode==MODE_SAFE?"Safe":(g_mode==MODE_POSTTARGET?"PostTarget":(g_mode==MODE_MANUAL?"Manual":"Normal")); }
double QualMinByMode()
{
  if(g_mode==MODE_SAFE) return InpQual_Min_Safe;
  if(g_mode==MODE_POSTTARGET) return InpQual_Min_PostTarget;
  return InpQual_Min_Normal;
}

// ======= News Filter (JSON/CSV – einfache Parser) =======
bool ParseNextEventMinutes(int &mins_to_event,bool &window,bool &highimpact)
{
  mins_to_event = 9999; window=false; highimpact=false;
  if(!InpUseNewsFilter) return false;

  string f=InpNewsFile;
  int h=FileOpen(f,FILE_READ|FILE_ANSI); if(h==INVALID_HANDLE) return false;
  string content = FileReadString(h,(int)FileSize(h)); FileClose(h);

  string lower = StringToLower(f);
  // CSV: lines "YYYY-MM-DD HH:MM;impact"
  if(StringFind(lower,".csv")>=0)
  {
    string lines[]; int n=StringSplit(content,'\n',lines);
    for(int i=0;i<n;i++)
    {
      string line=lines[i]; StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line)<10) continue;
      string parts[]; int m=StringSplit(line,';',parts); if(m<1) continue;
      string ts=parts[0]; string imp=(m>=2?parts[1]:"");
      datetime ev=StringToTime(ts);
      int diff=(int)((ev-TimeCurrent())/60);
      if(diff<mins_to_event) mins_to_event=diff;
      if(diff>=-InpNewsPostBlockMin && diff<=InpNewsPreBlockMin) window=true;
      if(StringFind(StringToLower(imp),"high")>=0) highimpact=true;
    }
    return true;
  }

  // JSON (sehr simpel): find occurrences of "time":"...","impact":"..."
  int pos=0; bool any=false;
  while(true)
  {
    int tpos=StringFind(content,"\"time\"",pos); if(tpos<0) break;
    int q1 = StringFind(content,"\"", tpos+6); if(q1<0) break;
    int q2 = StringFind(content,"\"", q1+1); if(q2<0) break;
    string ts = StringSubstr(content,q1+1,q2-q1-1);

    int ipos=StringFind(content,"\"impact\"",q2); if(ipos<0) { pos=q2+1; any=true; continue; }
    int i1 = StringFind(content,"\"", ipos+8); if(i1<0) { pos=q2+1; any=true; continue; }
    int i2 = StringFind(content,"\"", i1+1); if(i2<0) { pos=q2+1; any=true; continue; }
    string imp=StringSubstr(content,i1+1,i2-i1-1);

    datetime ev=StringToTime(ts);
    int diff=(int)((ev-TimeCurrent())/60);
    if(diff<mins_to_event) mins_to_event=diff;
    if(diff>=-InpNewsPostBlockMin && diff<=InpNewsPreBlockMin) window=true;
    if(StringFind(StringToLower(imp),"high")>=0) highimpact=true;

    pos=i2+1; any=true;
  }
  return any;
}
bool IsTradingPausedByNews()
{
  if(!InpUseNewsFilter) return false;
  int mins=9999; bool window=false, hi=false;
  if(!ParseNextEventMinutes(mins,window,hi)) return false;
  return window; // blocke im Fenster (pre/post)
}

// ======= Entry / Risk / Trailing =======
double CalcLotByRisk(double stopPts)
{
  if(stopPts<=0) return 0.0;
  double eq = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = eq * (InpRisk_PerTrade/100.0);
  double tickValue = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);
  double tickSize  = SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
  double moneyPerPoint = (tickSize>0)? (tickValue/(tickSize/g_point)) : 0.0;
  if(moneyPerPoint<=0) return 0.0;
  double lots = riskMoney / (stopPts * moneyPerPoint);
  double step = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);
  double minl = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
  double maxl = SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
  if(step<=0) step=0.01;
  lots = MathMax(minl, MathMin(maxl, MathFloor(lots/step)*step));
  return lots;
}

bool GateByScores(double qualApplied,double dir,string &noteOut)
{
  double minQ = QualMinByMode();
  if(qualApplied<minQ){ noteOut="qual<threshold"; return false; }
  if(dir<1.0){ noteOut="dir<1.0"; return false; }
  return true;
}

void OpenSplit(ENUM_ORDER_TYPE type,double baseLots,double slPts,double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,string note,int splitIndex)
{
  if(baseLots<=0) return;

  double slPrice=0.0;
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  // simple scale-in: 1st 60%, 2nd 25%, 3rd 15%
  double lots = baseLots;
  if(splitIndex==1) lots*=0.60;
  if(splitIndex==2) lots*=0.25;
  if(splitIndex==3) lots*=0.15;

  if(type==ORDER_TYPE_BUY){
    slPrice = g_tick.ask - slPts*g_point;
    bool ok = Trade.Buy(lots,InpSymbol,0.0,slPrice,0.0,note);
    LogRow(ok?"ENTRY_OK":"ENTRY_FAIL","EntryManager", ok?"OPEN":"FAIL", ModeName(),
           "LONG", (double)g_tick.ask, slPrice, 0.0,
           qL,qS,dL,dS,aL,aS,qaL,qaS, 0,true, note + " split="+IntegerToString(splitIndex));
  } else {
    slPrice = g_tick.bid + slPts*g_point;
    bool ok = Trade.Sell(lots,InpSymbol,0.0,slPrice,0.0,note);
    LogRow(ok?"ENTRY_OK":"ENTRY_FAIL","EntryManager", ok?"OPEN":"FAIL", ModeName(),
           "SHORT", (double)g_tick.bid, slPrice, 0.0,
           qL,qS,dL,dS,aL,aS,qaL,qaS, 0,true, note + " split="+IntegerToString(splitIndex));
  }
}

void TryEnter(string bias, double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS)
{
  double atr = GetATR();
  double slPts = MathMax((atr*InpATR_Mult_SL)/g_point, 100.0);
  double baseLots = CalcLotByRisk(slPts);

  if(baseLots<=0){
    LogRow("ENTRY_BLOCK","EntryManager","BLOCK",ModeName(),bias,0,0,0,qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"lot calc failed");
    return;
  }

  bool split = (qaL>=InpSplitEntry_Min || qaS>=InpSplitEntry_Min) && (g_mode==MODE_NORMAL || g_mode==MODE_POSTTARGET);

  if(bias=="LONG")
  {
    OpenSplit(ORDER_TYPE_BUY, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "LONG", 1);
    if(split){ OpenSplit(ORDER_TYPE_BUY, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "LONG", 2);
               OpenSplit(ORDER_TYPE_BUY, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "LONG", 3); }
  }
  else if(bias=="SHORT")
  {
    OpenSplit(ORDER_TYPE_SELL, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "SHORT", 1);
    if(split){ OpenSplit(ORDER_TYPE_SELL, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "SHORT", 2);
               OpenSplit(ORDER_TYPE_SELL, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "SHORT", 3); }
  }
}

void ManagePositions()
{
  if(!InpUseSmartTrailing) return;
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  for(int i=PositionsTotal()-1;i>=0;--i)
  {
    ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=InpSymbol) continue;
    double priceCur = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)? g_tick.bid : g_tick.ask;
    double profitEUR= PositionGetDouble(POSITION_PROFIT);
    if(profitEUR < InpMinTrailStartEUR) continue;

    double atr=GetATR();
    double trailPts=MathMax((atr*InpATR_Mult_Trail)/g_point, 50.0);
    double oldSL=PositionGetDouble(POSITION_SL), newSL=oldSL;

    if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)
      newSL=MathMax(oldSL, priceCur - trailPts*g_point);
    else
      newSL=MathMin(oldSL, priceCur + trailPts*g_point);

    if(newSL!=oldSL) Trade.PositionModify(t,newSL,PositionGetDouble(POSITION_TP));
  }
}

// ======= Safety =======
bool DailyLossExceeded(){ return TodayPnL() <= -InpDailyLossStopEUR; }

// ======= Main Loop =======
void OnInitCommon()
{
  if(!SymbolSelect(InpSymbol,true)) { Print("SymbolSelect failed"); }
  g_digits = (int)SymbolInfoInteger(InpSymbol,SYMBOL_DIGITS);
  g_point  = SymbolInfoDouble(InpSymbol,SYMBOL_POINT);

  g_handleATR  = iATR(InpSymbol, InpTF_Work, InpATR_Period);
  g_handleMACD = iMACD(InpSymbol, InpTF_Work, 12,26,9, PRICE_CLOSE);

  EnsureLogHeader();

  // Tagesanker/Equity merken
  MqlDateTime t; TimeToStruct(TimeCurrent(),t);
  MqlDateTime z=t; z.hour=0; z.min=0; z.sec=0; g_dayAnchor = StructToTime(z);
  g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

  Print("[EA] Init OK v0.9 | Symbol=",InpSymbol);
}
int OnInit()
{
  OnInitCommon();
  if(g_handleATR==INVALID_HANDLE || g_handleMACD==INVALID_HANDLE) return(INIT_FAILED);
  return(INIT_SUCCEEDED);
}
void OnDeinit(const int reason)
{
  if(g_handleATR!=INVALID_HANDLE)  IndicatorRelease(g_handleATR);
  if(g_handleMACD!=INVALID_HANDLE) IndicatorRelease(g_handleMACD);
}

void OnTick()
{
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  // Nur bei neuer M1-Kerze arbeiten
  datetime m1Close = iTime(InpSymbol, InpTF_Work, 0);
  if(m1Close==0 || m1Close==g_lastM1CloseTime) { ManagePositions(); return; }
  g_lastM1CloseTime = m1Close;

  // Day reset & mode updates
  ResetDayIfNeeded();
  UpdateModeByPnL();

  // Fenster / News / Safe
  if(!InTradeWindow())
  { LogRow("WINDOW_BLOCK","ModeManager","BLOCK",ModeName(),"-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "outside window"); ManagePositions(); return; }

  if(IsTradingPausedByNews())
  { g_mode = MODE_SAFE; LogRow("NEWS_BLOCK","NewsFilter","BLOCK",ModeName(),"-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "news window"); ManagePositions(); return; }

  if(DailyLossExceeded())
  { g_mode = MODE_SAFE; LogRow("SAFE_MODE","RiskControl","BLOCK","Safe","-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "daily loss"); ManagePositions(); return; }

  // Hauptfilter
  bool fTrend=false,fStrength=false,fMomentum=false;
  EvaluateMainFilter(fTrend,fStrength,fMomentum);
  int cats=(int)fTrend+(int)fStrength+(int)fMomentum;
  bool htfok = EvaluateHTFBias();
  if(!(cats>=2 && (InpHTF_Gate_Strict? htfok:true)))
  { LogRow("FILTER_BLOCK","MainFilter","BLOCK",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,cats,htfok,"main filter"); ManagePositions(); return; }

  // Scores
  double qL=0,qS=0,dL=0,dS=0; ComputeQualityScore(qL,qS); ComputeDirectionScore(dL,dS);
  double aL=0,aS=0; ApplyMetaAdjust(aL,aS); aL=Clamp(aL,-InpAdjustMaxAbs,InpAdjustMaxAbs); aS=Clamp(aS,-InpAdjustMaxAbs,InpAdjustMaxAbs);
  double qaL = qL + aL, qaS = qS + aS;

  // Entscheidung Long/Short
  string note="";
  bool gateLong  = GateByScores(qaL, dL, note);
  bool gateShort = GateByScores(qaS, dS, note);

  if(gateLong && dL>=1.0 && dL>=dS)        TryEnter("LONG",  qL,qS,dL,dS,aL,aS,qaL,qaS);
  else if(gateShort && dS>=1.0 && dS>dL)   TryEnter("SHORT", qL,qS,dL,dS,aL,aS,qaL,qaS);

  // Offene Positionen managen
  ManagePositions();
}
