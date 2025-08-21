// file: src/mt5/ea/XAUUSD_MasterEA_v1_0.mq5
#property strict
#property description "XAU/USD Scalping-Bot – v1.0-no-AI (Pflichtenheft ohne KI/ChatGPT/externen News-Pull)"
#property copyright  "MIT"

#include <Trade/Trade.mqh>
CTrade Trade;

// ======= Inputs / Runtime =======
input string   InpSymbol              = "XAUUSD";
// Arbeits-TFs
input ENUM_TIMEFRAMES InpTF_Work      = PERIOD_M1;     // Entry-TF
input ENUM_TIMEFRAMES InpTF_HTF       = PERIOD_H1;     // Trend-Bias (Gate)
// Handelstag / Zeitfenster
input int      InpDayResetHour        = 7;             // Tages-Reset um 07:00
input string   InpTradeWindow_Start   = "07:00";
input string   InpTradeWindow_End     = "22:00";
input bool     InpManualOverride      = false;         // MANUAL-Override Mode

// Risiko & Tagesziele
input double   InpRisk_PerTrade       = 0.5;           // % Equity
input double   InpDailyLossStopEUR    = 150.0;         // -> Safe-Modus
input double   InpDailyTargetEUR      = 150.0;         // -> PostTarget
input double   InpExtraLossAfterSafe  = 50.0;          // Zusatzverlust nach Safe => Handel aus

// News
input bool     InpUseNewsFilter       = true;
input string   InpNewsFile            = "configs\\news_feed.json"; // JSON oder CSV lokal
input int      InpNewsPreBlockMin     = 30;
input int      InpNewsPostBlockMin    = 20;

// Trailing / SL
input bool     InpUseSmartTrailing    = true;
input int      InpATR_Period          = 14;
input double   InpATR_Mult_SL         = 1.8;
input double   InpATR_Mult_Trail      = 1.2;
input double   InpMinTrailStartEUR    = 10.0;

// Parabolic SAR Exit
input bool     InpUsePSARExit         = true;
input double   InpPSAR_Step           = 0.02;
input double   InpPSAR_Max            = 0.2;

// ADX / DI
input int      InpADX_Period          = 14;
input double   InpADX_Strong          = 25.0;
input double   InpADX_Moderate        = 20.0;
input bool     InpUseDI_Cross         = true;          // DI-Kreuz (ADX>25) als Pflicht

// CCI / Stochastic
input int      InpCCI_Period          = 14;
input int      InpCCI_Threshold       = 100;
input int      InpStoch_K             = 14;
input int      InpStoch_D             = 3;
input int      InpStoch_Slow          = 3;
input int      InpStoch_OB            = 80;
input int      InpStoch_OS            = 20;

// Money Flow Index (MFI)
input int      InpMFI_Period          = 14;

// CPR / VWAP / M15-Align / ATR-D1-Ref
input bool     InpUseCPR              = true;
input bool     InpUseVWAP             = true;
input bool     InpUseM15Align         = true;
input double   InpATR_M1_to_D1_MinRatio = 0.003;       // grobe Mindestrelation M1-ATR zu D1-ATR

// Quality-Schwellen & SplitEntry
input double   InpQual_Min_Normal     = 4.0;
input double   InpQual_Min_Safe       = 5.0;
input double   InpQual_Min_PostTarget = 4.5;
input double   InpSplitEntry_Min      = 5.5;           // ab hier bis zu 3 Splits

// Meta-Adjust (ohne ChatGPT-Anbindung)
input double   InpAdjustMaxAbs        = 1.0;           // ±1.0 Hardlimit

// Logging
input string   InpLogFilePrefix       = "xauusd_meta_"; // MQL5/Files/
input bool     InpDebug               = true;

// ======= Enums / State =======
enum BotMode { MODE_NORMAL=0, MODE_SAFE=1, MODE_POSTTARGET=2, MODE_MANUAL=3, MODE_DISABLED_TODAY=4 };
BotMode g_mode = MODE_NORMAL;

// Tageszustand
double   g_dayStartEquity = 0.0;
datetime g_dayAnchor      = 0;
double   g_safeEnterEquity= 0.0;

// Handles & Cached
MqlTick  g_tick;
int      g_handleATR   = INVALID_HANDLE;
int      g_handleMACD  = INVALID_HANDLE;
int      g_handleADX   = INVALID_HANDLE;
int      g_handleSAR   = INVALID_HANDLE;
int      g_handleCCI   = INVALID_HANDLE;
int      g_handleSTO   = INVALID_HANDLE;
int      g_handleMFI   = INVALID_HANDLE;

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
// Backward-compat overload (alte 18-Arg-Calls)
void LogRow(string ev,string mod,string dec,string mode,string dir,double price,double sl,double tp,
            double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,
            bool htfok,string notes)
{
  LogRow(ev,mod,dec,mode,dir,price,sl,tp,qL,qS,dL,dS,aL,aS,qaL,qaS,0,htfok,notes);
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
double GetATR(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(g_handleATR,0,0,1,b)<1) return 0.0; return b[0]; }
double GetMACDHist(){ double h[]; ArraySetAsSeries(h,true); if(CopyBuffer(g_handleMACD,2,0,1,h)<1) return 0.0; return h[0]; }
double GetRSI(ENUM_TIMEFRAMES tf,int period=14)
{
  int h=iRSI(InpSymbol,tf,period,PRICE_CLOSE); if(h==INVALID_HANDLE) return 50.0;
  double r[]; ArraySetAsSeries(r,true);
  int copied=CopyBuffer(h,0,0,1,r); IndicatorRelease(h);
  if(copied<1) return 50.0; return r[0];
}
// ADX + DI
double GetADX(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(g_handleADX,0,0,1,b)<1) return 0.0; return b[0]; }
double GetDIPlus(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(g_handleADX,1,0,1,b)<1) return 0.0; return b[0]; }
double GetDIMinus(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(g_handleADX,2,0,1,b)<1) return 0.0; return b[0]; }
// CCI
double GetCCI(){ double b[]; ArraySetAsSeries(b,true); if(CopyBuffer(g_handleCCI,0,0,1,b)<1) return 0.0; return b[0]; }
// Stochastic (Main = %K, Signal = %D)
bool GetStoch(double &k,double &d)
{
  double kb[], db[]; ArraySetAsSeries(kb,true); ArraySetAsSeries(db,true);
  bool ok1 = CopyBuffer(g_handleSTO,0,0,1,kb)>=1;
  bool ok2 = CopyBuffer(g_handleSTO,1,0,1,db)>=1;
  if(!(ok1&&ok2)){ k=50; d=50; return false; }
  k=kb[0]; d=db[0]; return true;
}
// PSAR
double GetPSAR()
{
  double b[]; ArraySetAsSeries(b,true);
  if(CopyBuffer(g_handleSAR,0,0,1,b)<1) return 0.0;
  return b[0];
}
// MFI
double GetMFI()
{
  double b[]; ArraySetAsSeries(b,true);
  if(CopyBuffer(g_handleMFI,0,0,1,b)<1) return 50.0;
  return b[0];
}

// VWAP (Session ab DayResetHour)
datetime SessionStart()
{
  MqlDateTime t; TimeToStruct(TimeCurrent(),t);
  if(t.hour<InpDayResetHour){ // vor Resetstunde: auf Vortag 7:00
    t.day-=1;
  }
  t.hour=InpDayResetHour; t.min=0; t.sec=0;
  return StructToTime(t);
}
bool VWAP(double &vwap)
{
  if(!InpUseVWAP){ vwap=0.0; return false; }
  datetime ss = SessionStart();
  int startIndex = iBarShift(InpSymbol,PERIOD_M1,ss,true);
  if(startIndex<0) { vwap=0.0; return false; }
  int currIndex = 0;
  double sumPV=0.0, sumV=0.0;
  for(int i=startIndex; i>=currIndex; --i)
  {
    double h = iHigh(InpSymbol,PERIOD_M1,i);
    double l = iLow(InpSymbol,PERIOD_M1,i);
    double c = iClose(InpSymbol,PERIOD_M1,i);
    long   v = iVolume(InpSymbol,PERIOD_M1,i);
    double tp = (h+l+c)/3.0;
    sumPV += tp*(double)v;
    sumV  += (double)v;
  }
  if(sumV<=0){ vwap=0.0; return false; }
  vwap = sumPV/sumV; return true;
}

// CPR (aus Vortag H/L/C)
int CPRSignal(double &P,double &BC,double &TC)
{
  if(!InpUseCPR){ P=BC=TC=0; return 0; }
  double H = iHigh(InpSymbol,PERIOD_D1,1);
  double L = iLow (InpSymbol,PERIOD_D1,1);
  double C = iClose(InpSymbol,PERIOD_D1,1);
  if(H==0 || L==0 || C==0) { P=BC=TC=0; return 0; }
  P  = (H+L+C)/3.0;
  BC = (H+L)/2.0;
  TC = 2.0*P - BC;
  double price = (SymbolInfoTick(InpSymbol,g_tick)? g_tick.bid : iClose(InpSymbol,PERIOD_M1,0));
  if(price>TC) return +1; // Breakout oben
  if(price<BC) return -1; // Breakout unten
  return 0;                // innerhalb CPR
}

// ======= Trend/Momentum/Strength Helpers =======
bool EmaBiasOK_TF(ENUM_TIMEFRAMES tf,int fast,int slow,int shift=0)
{
  double f=MaValue(tf,fast,MODE_EMA,PRICE_CLOSE,shift);
  double s=MaValue(tf,slow,MODE_EMA,PRICE_CLOSE,shift);
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
bool StrengthOK_Basic()
{
  double atr=GetATR(); 
  if(atr<=0 || !SymbolInfoTick(InpSymbol,g_tick)) return false;
  return (atr/g_tick.bid > 0.0010);
}

bool StrengthOK_ADX()
{
  double adx=GetADX(); 
  return (adx>=InpADX_Moderate);
}

// grobe Relation M1-ATR zu D1-ATR (punkte-basiert)
bool EnoughVolatilityDailyRef()
{
  int hD1 = iATR(InpSymbol,PERIOD_D1,14);
  if(hD1==INVALID_HANDLE) return true;

  double d1b[]; ArraySetAsSeries(d1b,true);
  if(CopyBuffer(hD1,0,0,1,d1b)<1){ IndicatorRelease(hD1); return true; }
  double atrD1 = d1b[0];
  IndicatorRelease(hD1);

  double atrM1 = GetATR();
  if(atrD1<=0 || atrM1<=0) return true;

  return ( (atrM1/atrD1) >= InpATR_M1_to_D1_MinRatio );
}

// **NEU separat (nicht in EnoughVolatilityDailyRef!)**
bool StrengthOK_MFI()
{
  double mfi = GetMFI();
  return (mfi>=60.0 || mfi<=40.0); // starker Kauf-/Verkaufsdruck
}

bool MomentumOK_Composite()
{
  double macd = GetMACDHist();
  double rsi  = GetRSI(InpTF_Work,14);
  double cci  = GetCCI();
  double k=50,d=50; GetStoch(k,d);
  bool macdOK = (macd!=0.0);
  bool rsiOK  = (rsi>55 || rsi<45);
  bool cciOK  = (cci>=InpCCI_Threshold || cci<=-InpCCI_Threshold);
  bool stochOK= (k>=InpStoch_OB || k<=InpStoch_OS);
  return (macdOK || rsiOK || cciOK || stochOK);
}
bool PSAR_TrendUp()
{
  if(!InpUsePSARExit) return false;
  double ps = GetPSAR();
  double price = (SymbolInfoTick(InpSymbol,g_tick)? g_tick.bid : iClose(InpSymbol,PERIOD_M1,0));
  return (price>ps);
}
bool PSAR_TrendDown()
{
  if(!InpUsePSARExit) return false;
  double ps = GetPSAR();
  double price = (SymbolInfoTick(InpSymbol,g_tick)? g_tick.bid : iClose(InpSymbol,PERIOD_M1,0));
  return (price<ps);
}

// ======= Candlestick (M5) – simple Engulfing =======
int M5_Engulf() // +1 bullisch, -1 bärisch, 0 neutral
{
ENUM_TIMEFRAMES tf = PERIOD_M5;
  double o1=iOpen(InpSymbol,tf,1), c1=iClose(InpSymbol,tf,1);
  double o0=iOpen(InpSymbol,tf,0), c0=iClose(InpSymbol,tf,0);
  if(o1==0 || c1==0 || o0==0 || c0==0) return 0;
  bool bull = (c0>o0 && o0<=c1 && c0>=o1 && c1<o1); // grob: aktuelle bull Kerze umhüllt vorherige bear
  bool bear = (c0<o0 && o0>=c1 && c0<=o1 && c1>o1);
  if(bull) return +1;
  if(bear) return -1;
  return 0;
}

// ======= Main Filter & Scores =======
void EvaluateMainFilter(bool &trend, bool &strength, bool &momentum, int &catsOut, bool &htfokOut, string &notes)
{
  trend=false; strength=false; momentum=false; catsOut=0; htfokOut=false; notes="";
  // Trend: EMA5/10 Cross oder EMA50/200 Bias oder PSAR-Richtung oder CPR-Breakout
  bool t1 = EmaCross_TF(InpTF_Work,5,10);
  bool t2 = EmaBiasOK_TF(InpTF_Work,50,200);
  int  cprS=0; double P,BC,TC; if(InpUseCPR) cprS = CPRSignal(P,BC,TC);
  bool t3 = (InpUsePSARExit? (PSAR_TrendUp()||PSAR_TrendDown()) : false);
  bool t4 = (cprS!=0);
  trend = (t1 || t2 || t3 || t4);

  // Stärke: ATR-Bewegung, Volumen-Spike, ADX
  bool s1 = StrengthOK_Basic();
  bool s2 = VolumeSpike();
  bool s3 = StrengthOK_ADX();
  bool s4 = EnoughVolatilityDailyRef();
  bool s5 = StrengthOK_MFI();
  strength = ( (s1||s2||s3||s5) && s4 );


  // Momentum: MACD/RSI/CCI/Stoch Composite
  momentum = MomentumOK_Composite();

  catsOut = (int)trend + (int)strength + (int)momentum;
  htfokOut= EmaBiasOK_TF(InpTF_HTF,50,200,1); // H1-Bias mit Kerze [1]
}

void ComputeQualityScore(double &longScore,double &shortScore, string &note)
{
  longScore=0; shortScore=0; note="";

  // EMA 5/10 Cross
  if(EmaCross_TF(InpTF_Work,5,10)){ longScore+=1.5; shortScore+=1.5; note+="EMA5/10 "; }

  // ADX
  double adx=GetADX(); 
  if(adx>=InpADX_Strong){ longScore+=1.0; shortScore+=1.0; note+="ADX_strong "; }
  else if(adx>=InpADX_Moderate){ longScore+=0.5; shortScore+=0.5; note+="ADX_mod "; }

  // Volumen
  if(VolumeSpike()){ longScore+=1.0; shortScore+=1.0; note+="VOL_spike "; }

  // Candlestick M5
  int eng=M5_Engulf(); 
  if(eng==+1){ longScore+=1.5; note+="BullEngulf "; } 
  else if(eng==-1){ shortScore+=1.5; note+="BearEngulf "; }

  // RSI/CCI/MACD-Stütze
  double rsi=GetRSI(InpTF_Work,14); if(rsi>55) longScore+=0.5; if(rsi<45) shortScore+=0.5;
  double cci=GetCCI(); if(cci>InpCCI_Threshold) longScore+=0.5; if(cci<-InpCCI_Threshold) shortScore+=0.5;
  double macd=GetMACDHist(); if(macd>0) longScore+=0.5; if(macd<0) shortScore+=0.5;

  // **NEU: MFI-Beitrag**
  double mfi = GetMFI();
  if(mfi>=60) { longScore+=0.5; note+="MFI "; }
  else if(mfi<=40) { shortScore+=0.5; note+="MFI "; }

  // **NEU: PSAR Score-Bonus (+0.5)**
  if(InpUsePSARExit){
    if(PSAR_TrendUp())   { longScore+=0.5;  note+="PSAR "; }
    if(PSAR_TrendDown()) { shortScore+=0.5; note+="PSAR "; }
  }

  // VWAP: Preis vs VWAP  (**mit Zahl im Note**)
  double vwap; 
  if(VWAP(vwap)){
    if(SymbolInfoTick(InpSymbol,g_tick)){
      if(g_tick.bid>vwap) longScore+=0.5; else shortScore+=0.5;
      note+="VWAP="+DoubleToString(vwap,g_digits)+" ";
    }
  }

  // CPR: Breakout/Bounce  (**mit Zahlen im Note**)
  double P,BC,TC; int cprs=CPRSignal(P,BC,TC);
  if(cprs==+1){ longScore+=1.0; note+="CPR_up "; }
  else if(cprs==-1){ shortScore+=1.0; note+="CPR_dn "; }
  note+="CPR:P="+DoubleToString(P,g_digits)+" BC="+DoubleToString(BC,g_digits)+" TC="+DoubleToString(TC,g_digits)+" ";

  // Volatilitätsbonus via ATR
  double atr=GetATR(); if(atr>0){ longScore+=0.5; shortScore+=0.5; note+="ATR_bonus "; }

  // M15 Align Bonus
  if(InpUseM15Align && EmaBiasOK_TF(PERIOD_M15,5,10,1)){ longScore+=0.5; note+="M15Align "; }
}


void ComputeDirectionScore(double &longScore,double &shortScore)
{
  longScore=0; shortScore=0;

  // EMA 50/200 Bias
  if(EmaBiasOK_TF(InpTF_Work,50,200)) longScore+=1.0; else shortScore+=1.0;

  // EMA 5/10 slope (naiv via f0>f1)
  double f0=MaValue(InpTF_Work,5), f1=MaValue(InpTF_Work,5,MODE_EMA,PRICE_CLOSE,1);
  if(f0>f1) longScore+=0.5; else if(f0<f1) shortScore+=0.5;

  // MACD
  double macd=GetMACDHist(); if(macd>0) longScore+=1.0; if(macd<0) shortScore+=1.0;

  // RSI
  double rsi=GetRSI(InpTF_Work,14); if(rsi>50) longScore+=0.5; else if(rsi<50) shortScore+=0.5;

  // CCI
  double cci=GetCCI(); if(cci>+InpCCI_Threshold) longScore+=0.5; if(cci<-InpCCI_Threshold) shortScore+=0.5;

  // HTF Bias (H1 EMA50 Lage, Kerze [1]) als Gategewicht
  if(EmaBiasOK_TF(InpTF_HTF,50,200,1)) longScore+=0.5; else shortScore+=0.5;

  // MFI (optional als Richtungsgewicht)
  double mfi=GetMFI();
  if(mfi>=60)      longScore+=0.5;
  else if(mfi<=40) shortScore+=0.5;
}

void ApplyMetaAdjust(double &adjLong,double &adjShort){ adjLong=0.0; adjShort=0.0; } // externe KI-Adjust später

// ======= ModeManager / Day Handling =======
void SetMode(BotMode m){ g_mode=m; }
string ModeName(){ return g_mode==MODE_SAFE?"Safe":(g_mode==MODE_POSTTARGET?"PostTarget":(g_mode==MODE_MANUAL?"Manual":(g_mode==MODE_DISABLED_TODAY?"DisabledToday":"Normal"))); }
double TodayPnL(){ return AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity; }

void ResetDayIfNeeded()
{
  MqlDateTime t; TimeToStruct(TimeCurrent(),t);
  MqlDateTime a; TimeToStruct(g_dayAnchor,a);
  bool needReset=false;
  if(g_dayAnchor==0) needReset=true;
  else{
    // Wenn seit Anker >24h ODER Stunde < ResetHour und Anker != heute @ ResetHour → Reset
    datetime nextAnchor = g_dayAnchor + 24*60*60;
    if(TimeCurrent()>=nextAnchor) needReset=true;
  }
  if(needReset)
  {
    MqlDateTime z; TimeToStruct(TimeCurrent(),z);
    if(z.hour<InpDayResetHour){ z.day-=1; }  // Anker auf heutigen Resetpunkt
    z.hour=InpDayResetHour; z.min=0; z.sec=0;
    g_dayAnchor = StructToTime(z);
    g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    g_safeEnterEquity = 0.0;
    if(InpManualOverride) g_mode=MODE_MANUAL; else g_mode=MODE_NORMAL;
    LogRow("DAY_RESET","ModeManager","RESET",ModeName()," - ",0,0,0, 0,0,0,0, 0,0, 0,0, 0,true,"new day at reset hour");
  }
}
void UpdateModeByPnL()
{
  if(g_mode==MODE_DISABLED_TODAY) return;
  if(InpManualOverride){ g_mode=MODE_MANUAL; return; }

  double pnl = TodayPnL();
  if(pnl <= -InpDailyLossStopEUR)
  {
    if(g_mode!=MODE_SAFE){ g_safeEnterEquity=AccountInfoDouble(ACCOUNT_EQUITY); }
    g_mode = MODE_SAFE;
  }
  else if(pnl >= InpDailyTargetEUR) g_mode = MODE_POSTTARGET;
  else if(g_mode!=MODE_MANUAL) g_mode = MODE_NORMAL;

  // Extra-Schutz: nach Safe weiterer Verlust X => Aus für den Tag
  if(g_mode==MODE_SAFE && g_safeEnterEquity>0.0)
  {
    if( AccountInfoDouble(ACCOUNT_EQUITY) <= g_safeEnterEquity - InpExtraLossAfterSafe )
      g_mode = MODE_DISABLED_TODAY;
  }
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

  // sehr einfache JSON-Suche: "time":"...","impact":"..."
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
  double minQ = (g_mode==MODE_SAFE? InpQual_Min_Safe : (g_mode==MODE_POSTTARGET? InpQual_Min_PostTarget : InpQual_Min_Normal));
  if(qualApplied<minQ){ noteOut="qual<threshold"; return false; }
  if(dir<1.0){ noteOut="dir<1.0"; return false; }
  return true;
}

bool DIConditionOK(string bias)
{
  if(!InpUseDI_Cross) return true;
  double adx = GetADX(); if(adx<InpADX_Strong) return false;
  double dip = GetDIPlus(), dim = GetDIMinus();
  if(bias=="LONG")  return (dip>dim);
  if(bias=="SHORT") return (dim>dip);
  return false;
}

void OpenSplit(ENUM_ORDER_TYPE type,double baseLots,double slPts,double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,string note,int splitIndex)
{
  if(baseLots<=0) return;
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  // simple scale-in: 1st 60%, 2nd 25%, 3rd 15%
  double lots = baseLots;
  if(splitIndex==1) lots*=0.60;
  if(splitIndex==2) lots*=0.25;
  if(splitIndex==3) lots*=0.15;

  double slPrice=0.0;
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
  if(!DIConditionOK(bias)){
    LogRow("ENTRY_BLOCK","EntryManager","BLOCK",ModeName(),bias,0,0,0,qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"DI/ADX condition");
    return;
  }

  double atr = GetATR();
  double slPts = MathMax((atr*InpATR_Mult_SL)/g_point, 100.0);
  double baseLots = CalcLotByRisk(slPts);
  if(baseLots<=0){
    LogRow("ENTRY_BLOCK","EntryManager","BLOCK",ModeName(),bias,0,0,0,qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"lot calc failed");
    return;
  }
  bool split = (qaL>=InpSplitEntry_Min || qaS>=InpSplitEntry_Min) && (g_mode==MODE_NORMAL || g_mode==MODE_POSTTARGET);

  if(bias=="LONG"){
    OpenSplit(ORDER_TYPE_BUY, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "LONG", 1);
    if(split){ OpenSplit(ORDER_TYPE_BUY, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "LONG", 2);
               OpenSplit(ORDER_TYPE_BUY, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "LONG", 3); }
  } else if(bias=="SHORT"){
    OpenSplit(ORDER_TYPE_SELL, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "SHORT", 1);
    if(split){ OpenSplit(ORDER_TYPE_SELL, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "SHORT", 2);
               OpenSplit(ORDER_TYPE_SELL, baseLots, slPts, qL,qS,dL,dS,aL,aS,qaL,qaS, "SHORT", 3); }
  }
}

void ManagePositions()
{
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  for(int i=PositionsTotal()-1;i>=0;--i)
  {
    ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
    if(PositionGetString(POSITION_SYMBOL)!=InpSymbol) continue;

    // optional PSAR Exit
    if(InpUsePSARExit)
    {
      double ps = GetPSAR();
      double priceCur = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)? g_tick.bid : g_tick.ask;
      if( (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY && priceCur<ps) ||
          (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL && priceCur>ps) )
      {
        Trade.PositionClose(t);
        continue;
      }
    }

    if(!InpUseSmartTrailing) continue;
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

// ======= Main Loop =======
void OnInitCommon()
{
  if(!SymbolSelect(InpSymbol,true)) { Print("SymbolSelect failed"); }
  g_digits = (int)SymbolInfoInteger(InpSymbol,SYMBOL_DIGITS);
  g_point  = SymbolInfoDouble(InpSymbol,SYMBOL_POINT);

  g_handleATR  = iATR(InpSymbol, InpTF_Work, InpATR_Period);
  g_handleMACD = iMACD(InpSymbol, InpTF_Work, 12,26,9, PRICE_CLOSE);
  g_handleADX  = iADX(InpSymbol, InpTF_Work, InpADX_Period);
  g_handleSAR  = iSAR(InpSymbol, InpTF_Work, InpPSAR_Step, InpPSAR_Max);
  g_handleCCI  = iCCI(InpSymbol, InpTF_Work, InpCCI_Period, PRICE_TYPICAL);
  g_handleSTO  = iStochastic(InpSymbol, InpTF_Work, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
  g_handleMFI  = iMFI(InpSymbol, InpTF_Work, InpMFI_Period, VOLUME_TICK);

  EnsureLogHeader();

  // Tagesanker/Equity bei Resetstunde
  MqlDateTime z; TimeToStruct(TimeCurrent(),z);
  if(z.hour<InpDayResetHour){ z.day-=1; }
  z.hour=InpDayResetHour; z.min=0; z.sec=0;
  g_dayAnchor = StructToTime(z);
  g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  g_safeEnterEquity=0.0;

  if(InpManualOverride) g_mode=MODE_MANUAL; else g_mode=MODE_NORMAL;

  Print("[EA] Init OK v1.0-no-AI | Symbol=",InpSymbol);
}
int OnInit()
{
  OnInitCommon();
  if(g_handleATR==INVALID_HANDLE || g_handleMACD==INVALID_HANDLE || g_handleADX==INVALID_HANDLE ||
     g_handleSAR==INVALID_HANDLE || g_handleCCI==INVALID_HANDLE || g_handleSTO==INVALID_HANDLE ||
     g_handleMFI==INVALID_HANDLE)
     return(INIT_FAILED);

  return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
  if(g_handleATR!=INVALID_HANDLE)  IndicatorRelease(g_handleATR);
  if(g_handleMACD!=INVALID_HANDLE) IndicatorRelease(g_handleMACD);
  if(g_handleADX!=INVALID_HANDLE)  IndicatorRelease(g_handleADX);
  if(g_handleSAR!=INVALID_HANDLE)  IndicatorRelease(g_handleSAR);
  if(g_handleCCI!=INVALID_HANDLE)  IndicatorRelease(g_handleCCI);
  if(g_handleSTO!=INVALID_HANDLE)  IndicatorRelease(g_handleSTO);
  if(g_handleMFI!=INVALID_HANDLE)  IndicatorRelease(g_handleMFI);
}


void OnTick()
{
  if(!SymbolInfoTick(InpSymbol,g_tick)) return;

  // Nur bei neuer M1-Kerze rechnen
  datetime m1Close = iTime(InpSymbol, InpTF_Work, 0);
  if(m1Close==0 || m1Close==g_lastM1CloseTime){ ManagePositions(); return; }
  g_lastM1CloseTime = m1Close;

  // Day reset & mode updates
  ResetDayIfNeeded();
  UpdateModeByPnL();

  if(g_mode==MODE_DISABLED_TODAY){ LogRow("DISABLED_TODAY","ModeManager","BLOCK","DisabledToday","-",0,0,0,0,0,0,0,0,0,0,0,0,true,"extra loss after safe"); return; }
  if(InpManualOverride){ LogRow("MANUAL_OVERRIDE","ModeManager","BLOCK","Manual","-",0,0,0,0,0,0,0,0,0,0,0,0,true,"manual mode"); return; }

  // Fenster / News / Safe
  if(!InTradeWindow())
  { LogRow("WINDOW_BLOCK","ModeManager","BLOCK",ModeName(),"-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "outside window"); ManagePositions(); return; }

  if(IsTradingPausedByNews())
  { SetMode(MODE_SAFE); LogRow("NEWS_BLOCK","NewsFilter","BLOCK",ModeName(),"-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "news window"); ManagePositions(); return; }

  if(TodayPnL() <= -InpDailyLossStopEUR)
  { SetMode(MODE_SAFE); LogRow("SAFE_MODE","RiskControl","BLOCK","Safe","-",0,0,0, 0,0,0,0, 0,0, 0,0, 0, true, "daily loss"); ManagePositions(); return; }

  // Hauptfilter
  bool fTrend=false,fStrength=false,fMomentum=false; int cats=0; bool htfok=false; string nfNote="";
  EvaluateMainFilter(fTrend,fStrength,fMomentum,cats,htfok,nfNote);
  if(!(cats>=2 && htfok))
  { LogRow("FILTER_BLOCK","MainFilter","BLOCK",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,cats,htfok,"main filter "+nfNote); ManagePositions(); return; }

  // Scores
  double qL=0,qS=0,dL=0,dS=0; string qNote="";
  ComputeQualityScore(qL,qS,qNote);
  ComputeDirectionScore(dL,dS);
  double aL=0,aS=0; ApplyMetaAdjust(aL,aS); aL=Clamp(aL,-InpAdjustMaxAbs,InpAdjustMaxAbs); aS=Clamp(aS,-InpAdjustMaxAbs,InpAdjustMaxAbs);
  double qaL = qL + aL, qaS = qS + aS;

  // Entscheidung Long/Short
  string note="";
  bool gateLong  = GateByScores(qaL, dL, note);
  bool gateShort = GateByScores(qaS, dS, note);

  if(gateLong && dL>=1.0 && dL>=dS)        TryEnter("LONG",  qL,qS,dL,dS,aL,aS,qaL,qaS);
  else if(gateShort && dS>=1.0 && dS>dL)   TryEnter("SHORT", qL,qS,dL,dS,aL,aS,qaL,qaS);

  // Offene Positionen managen (Trailing/PSAR)
  ManagePositions();
}
