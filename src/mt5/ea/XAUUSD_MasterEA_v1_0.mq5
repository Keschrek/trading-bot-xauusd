// This file contains the full source code for the XAU/USD scalping EA.
// It includes a number of trailing stop and break‑even management features.
// The original code was provided by the user and has been modified to fix
// an issue where the trailing stop loss was not updating correctly.
//
// *** IMPORTANT ***
// MQL5 position property functions (e.g. PositionGetInteger, PositionGetDouble)
// require the position to be pre‑selected using PositionGetSymbol,
// PositionSelect, or PositionSelectByTicket. Without selecting the correct
// position, subsequent calls may return data from a previously selected
// position. According to the MetaTrader documentation, calling
// PositionSelect() immediately before accessing position properties is
// recommended to ensure fresh and accurate data【88776659789476†L75-L79】【88776659789476†L124-L125】.
//
// The modifications in this version ensure that PositionSelectByTicket() is
// called before reading or modifying any position. This guarantees that
// trailing stop calculations always use the correct context, preventing
// mismatches between different positions and allowing the trailing stop to
// function reliably.

// ==============================
// ========== WRAPPERS ==========
// ==============================
bool Buf1(int handle,double &out,int buf=0,int shift=0){
   double b[]; ArraySetAsSeries(b,true);
   int c=CopyBuffer(handle,buf,shift,1,b);
   if(c<1) return false;
   out=b[0]; return true;
}
bool EMA(int handle,double &v,int shift=0){ return Buf1(handle,v,0,shift); }
bool RSI(int handle,double &v,int shift=0){ return Buf1(handle,v,0,shift); }
bool ATR(double &v){ return Buf1(hATR,v,0,0); }
bool MACD_H(double &v){ return Buf1(hMACD,v,2,0); }
bool ADX(double &v){ return Buf1(hADX,v,0,0); }
bool DI_P(double &v){ return Buf1(hADX,v,1,0); }
bool DI_M(double &v){ return Buf1(hADX,v,2,0); }
bool CCI(double &v){ return Buf1(hCCI,v,0,0); }
bool STO(double &k,double &d){
   double kb[],db[]; ArraySetAsSeries(kb,true); ArraySetAsSeries(db,true);
   bool ok1=CopyBuffer(hSTO,0,0,1,kb)>=1;
   bool ok2=CopyBuffer(hSTO,1,0,1,db)>=1;
   if(!(ok1&&ok2)){k=50;d=50;return false;}
   k=kb[0]; d=db[0]; return true;
}
bool SAR(double &v){ return Buf1(hSAR,v,0,0); }
bool MFI(double &v){ return Buf1(hMFI,v,0,0); }

// ==============================
// ====== VWAP (inkrementell) ===
// ==============================
datetime g_vwap_session_start=0;
datetime g_vwap_last_bar_time=0;
double   g_vwap_sumPV=0.0, g_vwap_sumV=0.0, g_vwap=0.0;

datetime SessionStart()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   if(t.hour<InpDayResetHour) t.day-=1;
   t.hour=InpDayResetHour; t.min=0; t.sec=0;
   return StructToTime(t);
}
void VWAP_InitSession()
{
   g_vwap_session_start = SessionStart();
   g_vwap_sumPV=0.0; g_vwap_sumV=0.0; g_vwap=0.0;
   int startIndex = iBarShift(g_symbol,PERIOD_M1,g_vwap_session_start,true);
   if(startIndex<0) return;
   for(int i=startIndex;i>=0;--i){
      double h=iHigh(g_symbol,PERIOD_M1,i),
             l=iLow(g_symbol,PERIOD_M1,i),
             c=iClose(g_symbol,PERIOD_M1,i);
      long   v=(long)iVolume(g_symbol,PERIOD_M1,i);
      double tp=(h+l+c)/3.0;
      g_vwap_sumPV+=tp*(double)v; g_vwap_sumV+=(double)v;
   }
   g_vwap=(g_vwap_sumV>0? g_vwap_sumPV/g_vwap_sumV : 0.0);
   g_vwap_last_bar_time=iTime(g_symbol,PERIOD_M1,0);
}
bool VWAP_Get(double &out)
{
   if(!InpUseVWAP){ out=0.0; return false; }
   datetime ss=SessionStart();
   if(g_vwap_session_start!=ss || g_vwap_sumV<=0.0) VWAP_InitSession();
   datetime curBar=iTime(g_symbol,PERIOD_M1,0);
   if(curBar!=0 && curBar!=g_vwap_last_bar_time){
      double h=iHigh(g_symbol,PERIOD_M1,1),
             l=iLow(g_symbol,PERIOD_M1,1),
             c=iClose(g_symbol,PERIOD_M1,1);
      long   v=(long)iVolume(g_symbol,PERIOD_M1,1);
      double tp=(h+l+c)/3.0;
      g_vwap_sumPV+=tp*(double)v; g_vwap_sumV+=(double)v;
      g_vwap=(g_vwap_sumV>0? g_vwap_sumPV/g_vwap_sumV : 0.0);
      g_vwap_last_bar_time=curBar;
   }
   out=g_vwap; return (g_vwap>0.0);
}

// ==============================
// ============= CPR ============
// ==============================
int CPRSignal(double &P,double &BC,double &TC)
{
   if(!InpUseCPR){ P=BC=TC=0; return 0; }
   double H=iHigh(g_symbol,PERIOD_D1,1),
          L=iLow(g_symbol,PERIOD_D1,1),
          C=iClose(g_symbol,PERIOD_D1,1);
   if(H==0||L==0||C==0){ P=BC=TC=0; return 0; }
   P=(H+L+C)/3.0; BC=(H+L)/2.0; TC=2.0*P-BC;
   double price=(SymbolInfoTick(g_symbol,g_tick)? g_tick.bid : iClose(g_symbol,PERIOD_M1,0));
   if(price>TC) return +1;
   if(price<BC) return -1;
   return 0;
}

// ==============================
// ====== Patterns (M5) =========
// ==============================
int M5_Engulf()
{
   ENUM_TIMEFRAMES tf=PERIOD_M5;
   double o1=iOpen(g_symbol,tf,1), c1=iClose(g_symbol,tf,1),
          o0=iOpen(g_symbol,tf,0), c0=iClose(g_symbol,tf,0);
   if(o1==0||c1==0||o0==0||c0==0) return 0;
   bool bull=(c0>o0 && o0<=c1 && c0>=o1 && c1<o1);
   bool bear=(c0<o0 && o0>=c1 && c0<=o1 && c1>o1);
   if(bull) return +1; if(bear) return -1; return 0;
}
int M5_Pinbar()
{
   ENUM_TIMEFRAMES tf=PERIOD_M5;
   double o0=iOpen(g_symbol,tf,0), c0=iClose(g_symbol,tf,0),
          h0=iHigh(g_symbol,tf,0), l0=iLow(g_symbol,tf,0);
   if(o0==0||c0==0||h0==0||l0==0) return 0;
   double body=MathAbs(c0-o0),
          upper=h0-MathMax(o0,c0),
          lower=MathMin(o0,c0)-l0;
   if(body<=0) return 0;
   bool bull=(lower>=2.0*body)&&(upper<=0.5*body)&&(c0>=o0);
   bool bear=(upper>=2.0*body)&&(lower<=0.5*body)&&(c0<=o0);
   if(bull) return +1; if(bear) return -1; return 0;
}

// ==============================
// ======= Window/Helpers =======
// ==============================
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

// ==============================
// === Trend/Strength/Momentum ==
// ==============================
bool EmaBiasOK_TF_M1(int fast_handle,int slow_handle,int shift=0)
{
   double f=0,s=0; if(!EMA(fast_handle,f,shift) || !EMA(slow_handle,s,shift)) return false;
   return (f>s);
}
bool EmaBiasOK_TF_M1_50_200(int shift=0){ return EmaBiasOK_TF_M1(hEMA_M1_50,hEMA_M1_200,shift); }

bool EmaCross_M1_5_10()
{
   double f0=0,f1=0,s0=0,s1=0;
   if(!EMA(hEMA_M1_5,f0,0) || !EMA(hEMA_M1_5,f1,1) || !EMA(hEMA_M1_10,s0,0) || !EMA(hEMA_M1_10,s1,1)) return false;
   return ( (f1<=s1 && f0>s0) || (f1>=s1 && f0<s0) );
}

bool VolumeSpike()
{
   long v0=(long)iVolume(g_symbol,InpTF_Work,0);
   long sum=0; for(int i=1;i<=50;i++) sum+=(long)iVolume(g_symbol,InpTF_Work,i);
   if(sum<=0) return false; double avg=(double)sum/50.0;
   return (avg>0 && v0>InpVolSpikeFactor*avg);
}
bool StrengthOK_Basic()
{
   double a=0; if(!ATR(a) || !SymbolInfoTick(g_symbol,g_tick)) return false;
   return (a/g_tick.bid > InpMinATRtoPriceRatio);
}
bool EnoughVolatilityDailyRef()
{
   int hD1=iATR(g_symbol,PERIOD_D1,14); if(hD1==INVALID_HANDLE) return true;
   double d1b[]; ArraySetAsSeries(d1b,true);
   bool ok = CopyBuffer(hD1,0,0,1,d1b)>=1; IndicatorRelease(hD1);
   if(!ok) return true;
   double atrD1=d1b[0], atrM1=0; ATR(atrM1);
   if(atrD1<=0 || atrM1<=0) return true;
   return ((atrM1/atrD1)>=InpATR_M1_to_D1_MinRatio);
}
bool StrengthOK_MFI(){ double v=0; if(!MFI(v)) return false; return (v>=60.0 || v<=40.0); }

bool MomentumOK_Composite()
{
   double macd=0; MACD_H(macd);
   double rsi=0; RSI(hRSI_M1_14,rsi);
   double cci=0; CCI(cci);
   double k=50,d=50; STO(k,d);
   bool macdOK=(macd!=0.0);
   bool rsiOK=(rsi>55 || rsi<45);
   bool cciOK=(cci>=InpCCI_Threshold || cci<=-InpCCI_Threshold);
   bool stochOK=(k>=InpStoch_OB || k<=InpStoch_OS);
   return (macdOK||rsiOK||cciOK||stochOK);
}
bool PSAR_TrendUp(){ if(!InpUsePSARExit) return false; double ps=0; SAR(ps); double pr=(SymbolInfoTick(g_symbol,g_tick)? g_tick.bid : iClose(g_symbol,PERIOD_M1,0)); return (pr>ps); }
bool PSAR_TrendDown(){ if(!InpUsePSARExit) return false; double ps=0; SAR(ps); double pr=(SymbolInfoTick(g_symbol,g_tick)? g_tick.bid : iClose(g_symbol,PERIOD_M1,0)); return (pr<ps); }

// ==============================
// ======= MAIN FILTER ==========
// ==============================
void EvaluateMainFilter(bool &fTrend,bool &fStrength,bool &fMomentum,int &cats,bool &htfok,string &note)
{
   fTrend=false; fStrength=false; fMomentum=false; cats=0; htfok=false; note="";
   // Trend
   bool t1=EmaCross_M1_5_10();
   bool t2=EmaBiasOK_TF_M1_50_200();
   double P,BC,TC; int cprS=0; if(InpUseCPR) cprS=CPRSignal(P,BC,TC);
   bool t3=(InpUsePSARExit?(PSAR_TrendUp()||PSAR_TrendDown()):false);
   bool t4=(cprS!=0);
   fTrend=(t1||t2||t3||t4);

   // Strength
   bool s1=StrengthOK_Basic();
   bool s2=VolumeSpike();
   double adx=0; ADX(adx); bool s3=(adx>=InpADX_Moderate);
   bool s4=EnoughVolatilityDailyRef(); if(!s4) note+="VOLREF_LOW ";
   bool s5=StrengthOK_MFI();
   fStrength=(s1||s2||s3||s5);

   // Momentum
   fMomentum=MomentumOK_Composite();

   cats=(int)fTrend+(int)fStrength+(int)fMomentum;
   htfok = EmaBiasOK_TF_M1(hEMA_H1_50,hEMA_H1_200,1);
}

// ==============================
// ======= DIRECTION ============
// ==============================
void AddVote(int v,int &sum,int &lv,int &sv){ if(v>0){lv++;sum++;} else if(v<0){sv++;sum--;}}
void ComputeDirectionVotes(int &sum,int &lv,int &sv)
{
   sum=0; lv=0; sv=0;
   AddVote(EmaBiasOK_TF_M1_50_200()? +1:-1,sum,lv,sv);
   double f0=0,f1=0; EMA(hEMA_M1_5,f0,0); EMA(hEMA_M1_5,f1,1);
   AddVote((f0>f1)?+1:((f0<f1)?-1:0),sum,lv,sv);
   double macd=0; MACD_H(macd); AddVote((macd>0)?+1:((macd<0)?-1:0),sum,lv,sv);
   double rsi=0; RSI(hRSI_M1_14,rsi); AddVote((rsi>50)?+1:((rsi<50)?-1:0),sum,lv,sv);
   double cci=0; CCI(cci); AddVote((cci>+InpCCI_Threshold)?+1:((cci<-InpCCI_Threshold)?-1:0),sum,lv,sv);
   AddVote(EmaBiasOK_TF_M1(hEMA_H1_50,hEMA_H1_200,1)? +1:-1, sum,lv,sv);
   double mfi=0; MFI(mfi); AddVote((mfi>=60)?+1:((mfi<=40)?-1:0),sum,lv,sv);
}
bool MajorityDecision(string &bias,double &dirStrength)
{
   int sum=0,lv=0,sv=0; ComputeDirectionVotes(sum,lv,sv);
   if(sum>=InpMajorityNeed){ bias="LONG"; dirStrength=(double)sum; return true; }
   if(sum<=-InpMajorityNeed){ bias="SHORT"; dirStrength=(double)(-sum); return true; }
   bias=""; dirStrength=0.0; return false;
}

// ==============================
// ========= SCORE ==============
// ==============================
void ComputeQualityScore(double &longScore,double &shortScore,string &note)
{
   longScore=0; shortScore=0; note="";
   if(EmaCross_M1_5_10()){ longScore+=1.5; shortScore+=1.5; note+="EMA5/10 "; }

   double adx=0; ADX(adx);
   if(adx>=InpADX_Strong){ longScore+=1.0; shortScore+=1.0; note+="ADX_strong "; }
   else if(adx>=InpADX_Moderate){ longScore+=0.5; shortScore+=0.5; note+="ADX_mod "; }

   if(VolumeSpike()){ longScore+=1.0; shortScore+=1.0; note+="VOL_spike "; }

   int eng=M5_Engulf(); if(eng==+1){ longScore+=1.5; note+="BullEngulf "; } else if(eng==-1){ shortScore+=1.5; note+="BearEngulf "; }
   int pb=M5_Pinbar();  if(pb==+1){ longScore+=1.5; note+="PinbarBull "; } else if(pb==-1){ shortScore+=1.5; note+="PinbarBear "; }

   double rsi=0; RSI(hRSI_M1_14,rsi); if(rsi>55) longScore+=0.5; if(rsi<45) shortScore+=0.5;
   double cci=0; CCI(cci); if(cci>InpCCI_Threshold) longScore+=0.5; if(cci<-InpCCI_Threshold) shortScore+=0.5;
   double macd=0; MACD_H(macd); if(macd>0) longScore+=0.5; if(macd<0) shortScore+=0.5;

   double mfi=0; MFI(mfi); if(mfi>=60) longScore+=0.5; else if(mfi<=40) shortScore+=0.5;

   if(InpUsePSARExit){ if(PSAR_TrendUp()) longScore+=0.5; if(PSAR_TrendDown()) shortScore+=0.5; }

   double vwp=0; if(VWAP_Get(vwp)){
      if(SymbolInfoTick(g_symbol,g_tick)){
         if(g_tick.bid>vwp) longScore+=0.5; else shortScore+=0.5;
         note+="VWAP="+DoubleToString(vwp,g_digits)+" ";
      }
   }

   double P,BC,TC; int cprs=CPRSignal(P,BC,TC);
   if(cprs==+1){ longScore+=1.0; note+="CPR_up "; } else if(cprs==-1){ shortScore+=1.0; note+="CPR_dn "; }
   note+="CPR:P="+DoubleToString(P,g_digits)+" BC="+DoubleToString(BC,g_digits)+" TC="+DoubleToString(TC,g_digits)+" ";

   double a=0; if(ATR(a) && a>0){ longScore+=0.5; shortScore+=0.5; note+="ATR_bonus "; }
   if(InpUseM15Align){
      double e5=0,e10=0;
      bool ok5=EMA(hEMA_M15_5,e5,1);
      bool ok10=EMA(hEMA_M15_10,e10,1);
      if(ok5 && ok10 && e5>e10){ longScore+=0.5; note+="M15AlignUp "; }
      if(ok5 && ok10 && e5<e10){ shortScore+=0.5; note+="M15AlignDn "; }
   }
}
void ApplyMetaAdjust(double &adjLong,double &adjShort){ adjLong=0.0; adjShort=0.0; } // Hook
// file: XAUUSD_MasterEA_v1_1.mq5
// MIT License
// XAU/USD Scalping EA – stabile v1.1 (kompiliert ohne Phantom-Funktionen)

#property strict
#property description "XAU/USD Scalping-Bot – v1.1"
#property copyright  "MIT"

#include <Trade/Trade.mqh>
CTrade Trade;

// ==============================
// ========= INPUTS =============
// ==============================
input string   InpSymbol              = "";          // leer = aktuelles Symbol
input ulong    InpMagic               = 20251018;
input ENUM_TIMEFRAMES InpTF_Work      = PERIOD_M1;
input ENUM_TIMEFRAMES InpTF_HTF       = PERIOD_H1;
input int      InpDayResetHour        = 7;
input string   InpTradeWindow_Start   = "07:00";
input string   InpTradeWindow_End     = "22:00";
input bool     InpManualOverride      = false;

// Risk & Equity
input double   InpRisk_PerTrade       = 0.5;     // %
input double   InpDailyLossStopEUR    = 150.0;
input double   InpDailyTargetEUR      = 150.0;
input double   InpExtraLossAfterSafe  = 50.0;

// Indicators
input int      InpATR_Period          = 14;
input double   InpATR_Mult_SL         = 1.8;
input double   InpATR_Mult_Trail      = 1.2;
input bool     InpUseSmartTrailing    = true;
input bool     InpUseFixedTrail       = true;   // statt/zusätzlich zu ATR
input int      InpFixedTrailStartPt   = 120;     // Punkte Gewinn bis Trail startet (120 = $1.20)
input int      InpFixedTrailStepPt    = 60;      // fixer Abstand (60 = $0.60)
input bool     InpUsePSARExit         = true;
input double   InpPSAR_Step           = 0.02;
input double   InpPSAR_Max            = 0.2;
input int      InpADX_Period          = 14;
input double   InpADX_Strong          = 25.0;
input double   InpADX_Moderate        = 20.0;
input bool     InpUseDI_Cross         = true;
input int      InpCCI_Period          = 14;
input int      InpCCI_Threshold       = 100;
input int      InpStoch_K             = 14;
input int      InpStoch_D             = 3;
input int      InpStoch_Slow          = 3;
input int      InpStoch_OB            = 80;
input int      InpStoch_OS            = 20;
input int      InpMFI_Period          = 14;
input bool     InpUseCPR              = true;
input bool     InpUseVWAP             = true;
input bool     InpUseM15Align         = true;   // M15 Align via eigene Handles

// Scores & Filter
input double   InpATR_M1_to_D1_MinRatio = 0.003;
input bool     InpUseATRGateHard      = true;
input double   InpMinATRtoPriceRatio  = 0.0010;
input double   InpQual_Min_Normal     = 4.0;
input double   InpQual_Min_Safe       = 5.0;
input double   InpQual_Min_PostTarget = 4.5;
input double   InpSplitEntry_Min      = 5.5;
input double   InpAdjustMaxAbs        = 1.0;

// Logging
input string   InpLogFilePrefix       = "xauusd_meta_";
input bool     InpDebug               = true;

// Spread & Entries
input int      InpMaxSpreadPoints     = 40;
input int      InpOrderRetry          = 2;
input int      InpPendingExpireMin    = 60;

// Staging configurable
input double   InpStage1_Pct          = 60.0;  // %
input double   InpStage2_Pct          = 25.0;  // %
input double   InpStage3_Pct          = 15.0;  // %
input double   InpSplitRetrace1_ATR   = 0.50;
input double   InpSplitRetrace2_ATR   = 1.00;

// Direction/Volume knobs
input int      InpMajorityNeed        = 3;     // Mehrheitsschwelle
input double   InpVolSpikeFactor      = 1.5;   // Volume Spike

// Optional TP/BE (einfach)
input bool     InpUseTP               = true;
input double   InpTP_ATR_Mult         = 1.2;
input bool     InpMoveToBE            = true;
input double   InpBE_RR               = 0.3;

// News Filter
input bool     InpUseNewsFilter       = true;
input string   InpNewsFile            = "configs\\news_feed.json";
input int      InpNewsPreBlockMin     = 30;
input int      InpNewsPostBlockMin    = 20;

// ==============================
// ======= GLOBAL STATE =========
// ==============================
enum BotMode { MODE_NORMAL=0, MODE_SAFE=1, MODE_POSTTARGET=2, MODE_MANUAL=3, MODE_DISABLED_TODAY=4 };
BotMode g_mode = MODE_NORMAL;

MqlTick  g_tick;
int      g_digits = 2;
double   g_point  = 0.01;
string   g_symbol = "";          // laufendes Symbol (nicht Input überschreiben!)
ulong    g_magic  = 0;

datetime g_lastM1CloseTime = 0;
string   g_lastBlockReason = "-";
double   g_dayStartEquity  = 0.0;
datetime g_dayAnchor       = 0;
double   g_safeEnterEquity = 0.0;

// Logging (persistent Handle)
int g_logHandle = INVALID_HANDLE;

// Indicator Handles (einmalig)
int hATR=INVALID_HANDLE, hMACD=INVALID_HANDLE, hADX=INVALID_HANDLE, hSAR=INVALID_HANDLE;
int hCCI=INVALID_HANDLE, hSTO=INVALID_HANDLE, hMFI=INVALID_HANDLE;
int hEMA_M1_5=INVALID_HANDLE, hEMA_M1_10=INVALID_HANDLE, hEMA_M1_50=INVALID_HANDLE, hEMA_M1_200=INVALID_HANDLE;
int hEMA_H1_50=INVALID_HANDLE, hEMA_H1_200=INVALID_HANDLE, hRSI_M1_14=INVALID_HANDLE;
// M15 Align (explizit)
int hEMA_M15_5=INVALID_HANDLE, hEMA_M15_10=INVALID_HANDLE;

// ==============================
// ========== LOGGING ===========
// ==============================
double Clamp(double v,double lo,double hi){ return MathMax(lo,MathMin(hi,v)); }

string TodayCsv(){ return InpLogFilePrefix + TimeToString(TimeCurrent(),TIME_DATE) + ".csv"; }

void EnsureLogOpen()
{
   if(g_logHandle!=INVALID_HANDLE) return;
   string fn=TodayCsv();
   // Header anlegen, wenn Datei nicht existiert:
   if(FileIsExist(fn)==false)
   {
      int h=FileOpen(fn,FILE_WRITE|FILE_CSV|FILE_ANSI,';');
      if(h!=INVALID_HANDLE)
      {
         FileWrite(h,"Time","Event","Module","Decision","Mode","Direction","Price","SL","TP",
                   "QualBaseL","QualBaseS","DirL","DirS","AdjL","AdjS","QualAppliedL","QualAppliedS",
                   "Cats","HTF_OK","Notes");
         FileClose(h);
      }
   }
   g_logHandle=FileOpen(fn,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,';');
   if(g_logHandle!=INVALID_HANDLE) FileSeek(g_logHandle,0,SEEK_END);
}

void LogRow(string ev,string mod,string dec,string mode,string dir,double price,double sl,double tp,
            double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,
            int cats,bool htfok,string notes)
{
   EnsureLogOpen();
   if(g_logHandle==INVALID_HANDLE) return;
   FileWrite(g_logHandle,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS),ev,mod,dec,mode,dir,
             DoubleToString(price,g_digits),DoubleToString(sl,g_digits),DoubleToString(tp,g_digits),
             qL,qS,dL,dS,aL,aS,qaL,qaS,cats,(int)htfok,notes);
}

// Overload ohne cats
void LogRow(string ev,string mod,string dec,string mode,string dir,double price,double sl,double tp,
            double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS,
            bool htfok,string notes)
{
   LogRow(ev,mod,dec,mode,dir,price,sl,tp,qL,qS,dL,dS,aL,aS,qaL,qaS,0,htfok,notes);
}

// ==============================
// ========== NEWS-CACHE ========
// ==============================
struct NewsRow { datetime t; bool high; };
NewsRow g_news[];    // auf Tagesbasis im Speicher

void News_Reset(){ ArrayResize(g_news,0); }

bool News_LoadFile()
{
   News_Reset();
   if(!InpUseNewsFilter) return true;
   int h=FileOpen(InpNewsFile,FILE_READ|FILE_ANSI);
   if(h==INVALID_HANDLE){ LogRow("NEWS_ERR","News","WARN",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"open fail"); return false; }
   string content = FileReadString(h,(int)FileSize(h)); FileClose(h);
   if(StringLen(content)<5){ LogRow("NEWS_ERR","News","WARN",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"empty"); return false; }

   // CSV: time;impact
   string lower=InpNewsFile; StringToLower(lower);
   bool any=false;
   if(StringFind(lower,".csv")>=0)
   {
      string lines[]; int n=StringSplit(content,'\n',lines);
      for(int i=0;i<n;i++){
         string line=lines[i]; StringTrimLeft(line); StringTrimRight(line);
         if(StringLen(line)<10) continue;
         string p[]; int m=StringSplit(line,';',p);
         if(m<1) continue;
         datetime ev=StringToTime(p[0]); if(ev==0) continue;
         bool hi=(m>=2 && StringFind(StringToLower(p[1]),"high")>=0);
         int sz=ArraySize(g_news); ArrayResize(g_news,sz+1); g_news[sz].t=ev; g_news[sz].high=hi; any=true;
      }
   }
   else
   {
      // ganz simpler JSON-Fallback: ..."time":"YYYY.MM.DD HH:MM"...,"impact":"High"...
      int pos=0;
      while(true){
         int tpos=StringFind(content,"\"time\"",pos); if(tpos<0) break;
         int q1=StringFind(content,"\"",tpos+6); int q2=(q1>0?StringFind(content,"\"",q1+1):-1);
         if(q1<0||q2<0) break;
         string ts=StringSubstr(content,q1+1,q2-q1-1);
         datetime ev=StringToTime(ts); pos=q2+1; if(ev==0) continue;
         bool hi=false;
         int ip=StringFind(content,"\"impact\"",pos);
         if(ip>0){ int i1=StringFind(content,"\"",ip+8); int i2=(i1>0?StringFind(content,"\"",i1+1):-1); if(i1>0&&i2>i1){ string imp=StringSubstr(content,i1+1,i2-i1-1); hi=(StringFind(StringToLower(imp),"high")>=0); pos=i2+1;} }
         int sz=ArraySize(g_news); ArrayResize(g_news,sz+1); g_news[sz].t=ev; g_news[sz].high=hi; any=true;
      }
   }
   if(!any) LogRow("NEWS_ERR","News","WARN",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"no rows parsed");
   return any;
}

bool News_IsBlockedWindow()
{
   if(!InpUseNewsFilter) return false;
   datetime now=TimeCurrent();
   for(int i=0;i<ArraySize(g_news);i++){
      int diff=(int)((g_news[i].t-now)/60);
      if(diff>=-InpNewsPostBlockMin && diff<=InpNewsPreBlockMin) return true;
   }
   return false;
}
// ==============================
// ===== MODE / DAY MGMT ========
// ==============================
void SetMode(BotMode m){ g_mode=m; }
string ModeName(){ return g_mode==MODE_SAFE?"Safe":(g_mode==MODE_POSTTARGET?"PostTarget":(g_mode==MODE_MANUAL?"Manual":(g_mode==MODE_DISABLED_TODAY?"DisabledToday":"Normal"))); }
double TodayPnL(){ return AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity; }

void ResetDayIfNeeded()
{
   if(g_dayAnchor==0){
      MqlDateTime z; TimeToStruct(TimeCurrent(),z);
      if(z.hour<InpDayResetHour) z.day-=1;
      z.hour=InpDayResetHour; z.min=0; z.sec=0;
      g_dayAnchor=StructToTime(z);
      g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      g_safeEnterEquity=0.0;
      News_LoadFile();
   } else {
      datetime nextAnchor=g_dayAnchor+24*60*60;
      if(TimeCurrent()>=nextAnchor){
         MqlDateTime z; TimeToStruct(TimeCurrent(),z);
         if(z.hour<InpDayResetHour) z.day-=1;
         z.hour=InpDayResetHour; z.min=0; z.sec=0;
         g_dayAnchor=StructToTime(z);
         g_dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
         g_safeEnterEquity=0.0;
         SetMode(InpManualOverride?MODE_MANUAL:MODE_NORMAL);
         News_LoadFile();
         LogRow("DAY_RESET","ModeManager","RESET",ModeName(),"-",0,0,0, 0,0,0,0,0,0,0,0, 0,true,"new day");
      }
   }
}
void UpdateModeByPnL()
{
   if(g_mode==MODE_DISABLED_TODAY) return;
   if(InpManualOverride){ g_mode=MODE_MANUAL; return; }
   double pnl=TodayPnL();
   if(pnl <= -InpDailyLossStopEUR){ if(g_mode!=MODE_SAFE) g_safeEnterEquity=AccountInfoDouble(ACCOUNT_EQUITY); g_mode=MODE_SAFE; }
   else if(pnl >= InpDailyTargetEUR) g_mode=MODE_POSTTARGET;
   else if(g_mode!=MODE_MANUAL) g_mode=MODE_NORMAL;

   if(g_mode==MODE_SAFE && g_safeEnterEquity>0.0)
      if(AccountInfoDouble(ACCOUNT_EQUITY) <= g_safeEnterEquity - InpExtraLossAfterSafe) g_mode=MODE_DISABLED_TODAY;
}

// ==============================
// ===== RISK & ENTRY GATES =====
// ==============================
double CalcLotByRisk(double stopPts)
{
   if(stopPts<=0) return 0.0;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney=eq*(InpRisk_PerTrade/100.0);
   double tickValue=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize =SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   double moneyPerPoint=(tickSize>0)?(tickValue/(tickSize/g_point)):0.0; if(moneyPerPoint<=0) return 0.0;
   double lots=riskMoney/(stopPts*moneyPerPoint);
   double step=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);
   double minl=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   double maxl=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   lots=MathMax(minl,MathMin(maxl,MathFloor(lots/step)*step));
   return lots;
}
bool GateByScores(double qualApplied,double dir,string &noteOut)
{
   double minQ=(g_mode==MODE_SAFE?InpQual_Min_Safe:(g_mode==MODE_POSTTARGET?InpQual_Min_PostTarget:InpQual_Min_Normal));
   if(qualApplied<minQ){ noteOut="qual<threshold"; return false; }
   if(dir<1.0){ noteOut="dir<1.0"; return false; }
   return true;
}
bool DIConditionOK(string bias)
{
   if(!InpUseDI_Cross) return true;
   double adx=0; if(!ADX(adx) || adx<InpADX_Strong) return false;
   double dip=0, dim=0; DI_P(dip); DI_M(dim);
   if(bias=="LONG")  return (dip>dim);
   if(bias=="SHORT") return (dim>dip);
   return false;
}
bool SpreadOK()
{
   if(!SymbolInfoTick(g_symbol,g_tick)) return false;
   double spr = (g_tick.ask - g_tick.bid)/g_point;
   return (spr <= InpMaxSpreadPoints);
}

// ==============================
// ======= ORDER HELPERS ========
// ==============================
bool OrderBuy(double lots,double slPrice,double tpPrice,string note)
{
   for(int t=0;t<=InpOrderRetry;t++){
      if(Trade.Buy(lots,g_symbol,0.0,slPrice,tpPrice,note)) return true;
      Sleep(50);
   }
   return false;
}
bool OrderSell(double lots,double slPrice,double tpPrice,string note)
{
   for(int t=0;t<=InpOrderRetry;t++){
      if(Trade.Sell(lots,g_symbol,0.0,slPrice,tpPrice,note)) return true;
      Sleep(50);
   }
   return false;
}
bool OrderBuyLimit(double lots,double price,double sl,double tp,datetime exp)
{
   for(int t=0;t<=InpOrderRetry;t++){
      if(Trade.BuyLimit(lots,price,g_symbol,sl,tp,ORDER_TIME_SPECIFIED,exp)) return true;
      Sleep(50);
   }
   return false;
}
bool OrderSellLimit(double lots,double price,double sl,double tp,datetime exp)
{
   for(int t=0;t<=InpOrderRetry;t++){
      if(Trade.SellLimit(lots,price,g_symbol,sl,tp,ORDER_TIME_SPECIFIED,exp)) return true;
      Sleep(50);
   }
   return false;
}

// ==============================
// ====== ENTRIES (staged) ======
// ==============================
void OpenStagedEntries(string bias,double baseLots,double slPts,
                       double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS)
{
   if(!SymbolInfoTick(g_symbol,g_tick)) return;
   double atr=0; ATR(atr);
   double slPrice=0.0;
   double p1=Clamp(InpStage1_Pct,0,100), p2=Clamp(InpStage2_Pct,0,100), p3=Clamp(InpStage3_Pct,0,100);
   double sumPct = MathMax(1.0,(p1+p2+p3));
   double lots1=baseLots*(p1/sumPct), lots2=baseLots*(p2/sumPct), lots3=baseLots*(p3/sumPct);
   datetime exp = TimeCurrent() + InpPendingExpireMin*60;

   if(bias=="LONG"){
slPrice = g_tick.ask - slPts*g_point;

double safe = MathMax((double)MathMax(StopsLevelPts(),FreezeLevelPts())*g_point, 1.0*g_point);
double tpDist = atr * InpTP_ATR_Mult;

double tp1 = (InpUseTP ? SnapToTick(MathMax(g_tick.ask + tpDist, g_tick.ask + safe)) : 0.0);
bool ok1 = OrderBuy(lots1, slPrice, tp1, "LONG mkt");

LogRow(ok1?"ENTRY_OK":"ENTRY_FAIL","Entry","OPEN",ModeName(),"LONG",(double)g_tick.ask,slPrice,tp1,
       qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"market "+DoubleToString(p1,1)+"%");

double price2 = g_tick.bid - (InpSplitRetrace1_ATR*atr);
double price3 = g_tick.bid - (InpSplitRetrace2_ATR*atr);
double sl2 = price2 - slPts*g_point;
double sl3 = price3 - slPts*g_point;

double tp2 = (InpUseTP ? SnapToTick(MathMax(price2 + tpDist, price2 + safe)) : 0.0);
double tp3 = (InpUseTP ? SnapToTick(MathMax(price3 + tpDist, price3 + safe)) : 0.0);

bool ok2 = OrderBuyLimit(lots2, price2, sl2, tp2, exp);
bool ok3 = OrderBuyLimit(lots3, price3, sl3, tp3, exp);

LogRow(ok2?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"LONG",price2,sl2,tp2,
       qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"limit "+DoubleToString(p2,1)+"% @ -"+DoubleToString(InpSplitRetrace1_ATR,2)+"*ATR");
LogRow(ok3?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"LONG",price3,sl3,tp3,
       qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"limit "+DoubleToString(p3,1)+"% @ -"+DoubleToString(InpSplitRetrace2_ATR,2)+"*ATR");
   } else {
slPrice = g_tick.bid + slPts*g_point;

double safe = MathMax((double)MathMax(StopsLevelPts(),FreezeLevelPts())*g_point, 1.0*g_point);
double tpDist = atr * InpTP_ATR_Mult;

double tp1 = (InpUseTP ? SnapToTick(MathMin(g_tick.bid - tpDist, g_tick.bid - safe)) : 0.0);
bool ok1 = OrderSell(lots1, slPrice, tp1, "SHORT mkt");

LogRow(ok1?"ENTRY_OK":"ENTRY_FAIL","Entry","OPEN",ModeName(),"SHORT",(double)g_tick.bid,slPrice,tp1,
       qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"market "+DoubleToString(p1,1)+"%");

double price2 = g_tick.ask + (InpSplitRetrace1_ATR*atr);
double price3 = g_tick.ask + (InpSplitRetrace2_ATR*atr);
double sl2 = price2 + slPts*g_point;
double sl3 = price3 + slPts*g_point;

double tp2 = (InpUseTP ? SnapToTick(MathMin(price2 - tpDist, price2 - safe)) : 0.0);
double tp3 = (InpUseTP ? SnapToTick(MathMin(price3 - tpDist, price3 - safe)) : 0.0);

bool ok2 = OrderSellLimit(lots2, price2, sl2, tp2, exp);
bool ok3 = OrderSellLimit(lots3, price3, sl3, tp3, exp);

LogRow(ok2?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"SHORT",price2,sl2,tp2,
       qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"limit "+DoubleToString(p2,1)+"% @ +"+DoubleToString(InpSplitRetrace1_ATR,2)+"*ATR");
LogRow(ok3?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"SHORT",price3,sl3,tp3,
       qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"limit "+DoubleToString(p3,1)+"% @ +"+DoubleToString(InpSplitRetrace2_ATR,2)+"*ATR");
   }
}

void TryEnter(string bias,double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS)
{
   if(!DIConditionOK(bias)){ g_lastBlockReason="DI/ADX"; LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"DI/ADX"); return; }
   if(!SpreadOK()){ g_lastBlockReason="Spread"; LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"spread too high"); return; }

   double a=0; ATR(a);
   double slPts=(a*InpATR_Mult_SL)/g_point;
   double baseLots=CalcLotByRisk(slPts);
   if(baseLots<=0){ g_lastBlockReason="LotCalc"; LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"lot calc failed"); return; }

   OpenStagedEntries(bias,baseLots,slPts,qL,qS,dL,dS,aL,aS,qaL,qaS);
}
// --- Safe SL/TP modify helpers (global) ---
double ND(double p){ return NormalizeDouble(p,g_digits); }

int StopsLevelPts(){
   long lvl=0;
   if(!SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL,lvl)) return 0;
   return (int)lvl;
}

int FreezeLevelPts(){
   long lvl=0;
   if(!SymbolInfoInteger(g_symbol,SYMBOL_TRADE_FREEZE_LEVEL,lvl)) return 0;
   return (int)lvl;
}
double SnapToTick(double price){
   double ts = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts>0.0) price = MathRound(price/ts)*ts;
   return NormalizeDouble(price, g_digits);
}


//
// *** FIXED: ensure the correct position context before modifying stops ***
//
// The original implementation of PositionModifySafe assumed that the context
// (the currently selected position) would remain valid across calls. However,
// MQL5 requires that a position be explicitly selected via PositionSelect() or
// PositionSelectByTicket() before accessing or modifying its properties. If
// the wrong position is selected, the EA may clamp the stop loss on the wrong
// side of the market (for example, treating a BUY position as a SELL) and the
// trailing stop will appear not to work. See the MQL5 documentation for
// PositionGetInteger() – it states that position properties must be pre-selected
// using PositionGetSymbol or PositionSelect【88776659789476†L75-L79】. It also recommends
// calling PositionSelect() just before accessing the data to ensure fresh
// information【88776659789476†L124-L125】. The fix below calls PositionSelectByTicket()
// for the specified ticket before reading any properties. This guarantees that
// the correct position type is used when calculating safety distances and
// applying the trailing stop.

bool PositionModifySafe(ulong ticket,double sl,double tp)
{
   // select the position by ticket; if this fails, we cannot modify
   if(!PositionSelectByTicket(ticket)) return false;
   // determine the position type using the freshly selected context
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   for(int attempt=0; attempt<3; ++attempt)
   {
      // always refresh current market prices
      if(!SymbolInfoTick(g_symbol,g_tick)) return false;

      const double minPts   = (double)MathMax(StopsLevelPts(), FreezeLevelPts());
      const double safeDist = MathMax(minPts*g_point, 1.0*g_point);

      // clamp stop to avoid being too close to current price
      if(ptype==POSITION_TYPE_BUY){
         const double maxSL = g_tick.bid - safeDist;
         if(sl >= maxSL) sl = maxSL;
      } else {
         const double minSL = g_tick.ask + safeDist;
         if(sl <= minSL) sl = minSL;
      }

      // normalize to tick and digits
      sl = SnapToTick(sl);
      if(tp>0.0) tp = SnapToTick(tp);

      // attempt to modify the position
      if(Trade.PositionModify(ticket, sl, tp)) return true;

      // if modification fails, log the error and try again
      int ec = GetLastError(); ResetLastError();
      LogRow("MOD_FAIL","PM","ERR",ModeName(),
             (ptype==POSITION_TYPE_BUY?"LONG":"SHORT"),
             (ptype==POSITION_TYPE_BUY?g_tick.bid:g_tick.ask),
             sl,tp,0,0,0,0,0,0,0,0,true,"ec="+(string)ec);
      Sleep(40);
   }
   return false;
}


// --- end helpers ---

// ==============================
// ===== POSITION MANAGEMENT ====
// ==============================
void ManagePositions()
{
   if(!SymbolInfoTick(g_symbol,g_tick)) return;

   double a = 0.0; ATR(a);

   // Positions robust durchgehen (kein Phantom-API)
   int cnt=(int)PositionsTotal();
   while(cnt>0)
   {
      cnt--; // rückwärts

      // select context by symbol index
      string sym = PositionGetSymbol(cnt);        // selektiert automatisch
      if(sym=="" || sym!=g_symbol) continue;

      long pmagic = PositionGetInteger(POSITION_MAGIC);
      if((ulong)pmagic!=(ulong)InpMagic) continue;

      // obtain the ticket and ensure we select the correct position
      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;

      long   ptype  = PositionGetInteger(POSITION_TYPE);
      double oldSL  = PositionGetDouble(POSITION_SL);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);

      // PSAR-Exit
      if(InpUsePSARExit)
      {
         double ps=0.0;
         if(SAR(ps))
         {
            double cur=(ptype==POSITION_TYPE_BUY? g_tick.bid: g_tick.ask);
            if( (ptype==POSITION_TYPE_BUY && cur<ps) || (ptype==POSITION_TYPE_SELL && cur>ps) )
            {
               if(!PositionSelectByTicket(ticket)) continue;
               double currentTP = PositionGetDouble(POSITION_TP);
               bool closed=Trade.PositionClose(ticket);
               LogRow(closed?"EXIT_OK":"EXIT_FAIL","Exit","PSAR",ModeName(),
                      (ptype==POSITION_TYPE_BUY?"LONG":"SHORT"),
                      cur,oldSL,currentTP,
                      0,0,0,0,0,0,0,0,true,"psar exit");
               continue;
            }
         }
      }

// Move to BE (robust: Floor >= Entry ± 1 Tick + Broker-Abstände)
if(InpMoveToBE && a>0.0)
{
   double slPts = (a*InpATR_Mult_SL)/g_point;
   double rr = (ptype==POSITION_TYPE_BUY ?
               (g_tick.bid - entry)/g_point :
               (entry - g_tick.ask)/g_point) / slPts;

   if(rr >= InpBE_RR)
   {
      const double minPts   = (double)MathMax(StopsLevelPts(), FreezeLevelPts());
      const double safeDist = MathMax(minPts*g_point, 1.0*g_point);

      // harter Entry-Floor
      double beFloor = (ptype==POSITION_TYPE_BUY ? entry + 1.0*g_point : entry - 1.0*g_point);
      // wegen Freeze/Stops ggf. näher am Markt:
      double marketBound = (ptype==POSITION_TYPE_BUY ? g_tick.bid - safeDist : g_tick.ask + safeDist);

      double beSL = (ptype==POSITION_TYPE_BUY ? MathMax(beFloor, marketBound)
                                              : MathMin(beFloor, marketBound));
      beSL = SnapToTick(beSL);

      bool better = (oldSL<=0.0) ||
                    (ptype==POSITION_TYPE_BUY && beSL>oldSL) ||
                    (ptype==POSITION_TYPE_SELL && beSL<oldSL);

      if(better)
      {
         if(!PositionSelectByTicket(ticket)) continue;
         double currentTP = PositionGetDouble(POSITION_TP);
         bool mod = PositionModifySafe(ticket, beSL, currentTP);
         LogRow(mod?"MOD_OK":"MOD_FAIL","PM","MOVE_BE",ModeName(),
                (ptype==POSITION_TYPE_BUY?"LONG":"SHORT"),
                (ptype==POSITION_TYPE_BUY?g_tick.bid:g_tick.ask),
                beSL,currentTP,
                0,0,0,0,0,0,0,0,true,"move to BE");
         if(mod){ oldSL = beSL; continue; }
      }
   }
}

// --- FIXED TRAIL (optional) ---------------------------------------
if(InpUseFixedTrail)
{
   double cur = (ptype==POSITION_TYPE_BUY ? g_tick.bid : g_tick.ask);
   double profitPts = (ptype==POSITION_TYPE_BUY ? (cur - entry)/g_point : (entry - cur)/g_point);

   if(profitPts >= InpFixedTrailStartPt)
   {
      double step = (double)InpFixedTrailStepPt * g_point;
      double wantSL = (ptype==POSITION_TYPE_BUY ? (cur - step) : (cur + step));

      // nur enger, nie lockern
      double newSL = oldSL;
      if(ptype==POSITION_TYPE_BUY)
      {
         if(oldSL<=0.0 || wantSL>oldSL) newSL = wantSL;
         if(newSL >= cur) newSL = cur - 1.0*g_point;
      }
      else
      {
         if(oldSL<=0.0 || wantSL<oldSL) newSL = wantSL;
         if(newSL <= cur) newSL = cur + 1.0*g_point;
      }

      // Mindestbewegung & Broker-StopsLevel
      double minDist = StopsLevelPts()*g_point;
      if(ptype==POSITION_TYPE_BUY && (cur - newSL) < MathMax(minDist,1.0*g_point)) newSL = cur - MathMax(minDist,1.0*g_point);
      if(ptype==POSITION_TYPE_SELL && (newSL - cur) < MathMax(minDist,1.0*g_point)) newSL = cur + MathMax(minDist,1.0*g_point);

      double minStep = MathMax(1.0*g_point, 0.01 * a); // wie beim ATR-Trail: nicht zu häufig
      if(newSL>0.0 && (oldSL<=0.0 || MathAbs(newSL-oldSL) >= minStep))
      {
         if(!PositionSelectByTicket(ticket)) continue;
         double currentTP = PositionGetDouble(POSITION_TP);
         bool mod = PositionModifySafe(ticket, newSL, currentTP);
         LogRow(mod?"MOD_OK":"MOD_FAIL","PM","TRAIL_FIXED",ModeName(),
                (ptype==POSITION_TYPE_BUY?"LONG":"SHORT"),
                cur,newSL,currentTP,
                0,0,0,0,0,0,0,0,true,"fixed trail");
         if(mod) continue; // erfolgreich nachgezogen -> nächstes Position-Objekt
      }
   }
}
// --- ENDE FIXED TRAIL ----------------------------------------------

// --- ATR TRAIL: nur NACH BE, nie lockern, mit Entry-Floor & Broker-Abstand ----
if(InpUseSmartTrailing && a>0.0)
{
   // erst trailen, wenn BE aktiv (SL bereits >=/< = Entry)
   bool beActive = (oldSL>0.0 && ((ptype==POSITION_TYPE_BUY && oldSL>=entry) ||
                                  (ptype==POSITION_TYPE_SELL && oldSL<=entry)));
   if(!beActive) { continue; }

   const double cur     = (ptype==POSITION_TYPE_BUY ? g_tick.bid : g_tick.ask);
   const double trailPx = a * InpATR_Mult_Trail;

   // Wunsch-SL
   double want = (ptype==POSITION_TYPE_BUY ? cur - trailPx : cur + trailPx);

   // nie lockern
   if(oldSL>0.0)
      want = (ptype==POSITION_TYPE_BUY ? MathMax(want, oldSL)
                                       : MathMin(want, oldSL));

   // Floor über/unter Entry halten
   if(ptype==POSITION_TYPE_BUY) want = MathMax(want, entry + 1.0*g_point);
   else                         want = MathMin(want, entry - 1.0*g_point);

   // Broker-Abstände
   const double minPts   = (double)MathMax(StopsLevelPts(), FreezeLevelPts());
   const double safeDist = MathMax(minPts*g_point, 1.0*g_point);
   if(ptype==POSITION_TYPE_BUY) want = MathMin(want, cur - safeDist);
   else                         want = MathMax(want, cur + safeDist);

   double newSL = SnapToTick(want);

   const double minStep = MathMax(1.0*g_point, 0.05 * a);
   if(newSL>0.0 && (oldSL<=0.0 || MathAbs(newSL-oldSL) >= minStep))
   {
      if(!PositionSelectByTicket(ticket)) continue;
      double currentTP = PositionGetDouble(POSITION_TP);
      bool mod = PositionModifySafe(ticket, newSL, currentTP);
      LogRow(mod?"MOD_OK":"MOD_FAIL","PM","TRAIL_ATR",ModeName(),
             (ptype==POSITION_TYPE_BUY?"LONG":"SHORT"),
             cur,newSL,currentTP,
             0,0,0,0,0,0,0,0,true,"atr trail after BE");
      if(mod){ oldSL = newSL; continue; }
   }
}

// --- END ATR TRAIL ----------------------------------------------------------

   }
}

// ==============================
// ===== INIT / DEINIT ==========
// ==============================
void OnInitCommon()
{
   g_symbol = (InpSymbol=="" ? _Symbol : InpSymbol);
   g_magic  = InpMagic;

   if(!SymbolSelect(g_symbol,true)) Print("SymbolSelect failed");
   g_digits = (int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   g_point  = SymbolInfoDouble(g_symbol,SYMBOL_POINT);

   // Indicator Handles (einmalig)
   hATR  = iATR(g_symbol, InpTF_Work, InpATR_Period);
   hMACD = iMACD(g_symbol, InpTF_Work, 12,26,9, PRICE_CLOSE);
   hADX  = iADX(g_symbol, InpTF_Work, InpADX_Period);
   hSAR  = iSAR(g_symbol, InpTF_Work, InpPSAR_Step, InpPSAR_Max);
   hCCI  = iCCI(g_symbol, InpTF_Work, InpCCI_Period, PRICE_TYPICAL);
   hSTO  = iStochastic(g_symbol, InpTF_Work, InpStoch_K, InpStoch_D, InpStoch_Slow, MODE_SMA, STO_LOWHIGH);
   hMFI  = iMFI(g_symbol, InpTF_Work, InpMFI_Period, VOLUME_TICK);

   hEMA_M1_5   = iMA(g_symbol,PERIOD_M1,5,0,MODE_EMA,PRICE_CLOSE);
   hEMA_M1_10  = iMA(g_symbol,PERIOD_M1,10,0,MODE_EMA,PRICE_CLOSE);
   hEMA_M1_50  = iMA(g_symbol,PERIOD_M1,50,0,MODE_EMA,PRICE_CLOSE);
   hEMA_M1_200 = iMA(g_symbol,PERIOD_M1,200,0,MODE_EMA,PRICE_CLOSE);
   hEMA_H1_50  = iMA(g_symbol,PERIOD_H1,50,0,MODE_EMA,PRICE_CLOSE);
   hEMA_H1_200  = iMA(g_symbol,PERIOD_H1,200,0,MODE_EMA,PRICE_CLOSE);
   hRSI_M1_14  = iRSI(g_symbol,PERIOD_M1,14,PRICE_CLOSE);

   // M15 Align
   hEMA_M15_5  = iMA(g_symbol,PERIOD_M15,5,0,MODE_EMA,PRICE_CLOSE);
   hEMA_M15_10 = iMA(g_symbol,PERIOD_M15,10,0,MODE_EMA,PRICE_CLOSE);

   EnsureLogOpen();
   News_LoadFile();

   // Day anchor
   MqlDateTime z; TimeToStruct(TimeCurrent(),z); if(z.hour<InpDayResetHour) z.day-=1;
   z.hour=InpDayResetHour; z.min=0; z.sec=0;
   g_dayAnchor = StructToTime(z);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_safeEnterEquity=0.0;

   g_mode=InpManualOverride?MODE_MANUAL:MODE_NORMAL;

   if(InpUseVWAP) VWAP_InitSession();
   Print("[EA] Init OK v1.1 | Symbol=",g_symbol);
}

int OnInit()
{
   OnInitCommon();
   if(hATR==INVALID_HANDLE || hMACD==INVALID_HANDLE || hADX==INVALID_HANDLE ||
      hSAR==INVALID_HANDLE || hCCI==INVALID_HANDLE || hSTO==INVALID_HANDLE ||
      hMFI==INVALID_HANDLE || hEMA_M1_5==INVALID_HANDLE || hEMA_M1_10==INVALID_HANDLE ||
      hEMA_M1_50==INVALID_HANDLE || hEMA_M1_200==INVALID_HANDLE || hEMA_H1_50==INVALID_HANDLE ||
      hEMA_H1_200==INVALID_HANDLE || hRSI_M1_14==INVALID_HANDLE || hEMA_M15_5==INVALID_HANDLE || hEMA_M15_10==INVALID_HANDLE)
      return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_logHandle!=INVALID_HANDLE){ FileClose(g_logHandle); g_logHandle=INVALID_HANDLE; }

   if(hATR!=INVALID_HANDLE)       IndicatorRelease(hATR);
   if(hMACD!=INVALID_HANDLE)      IndicatorRelease(hMACD);
   if(hADX!=INVALID_HANDLE)       IndicatorRelease(hADX);
   if(hSAR!=INVALID_HANDLE)       IndicatorRelease(hSAR);
   if(hCCI!=INVALID_HANDLE)       IndicatorRelease(hCCI);
   if(hSTO!=INVALID_HANDLE)       IndicatorRelease(hSTO);
   if(hMFI!=INVALID_HANDLE)       IndicatorRelease(hMFI);
   if(hEMA_M1_5!=INVALID_HANDLE)  IndicatorRelease(hEMA_M1_5);
   if(hEMA_M1_10!=INVALID_HANDLE) IndicatorRelease(hEMA_M1_10);
   if(hEMA_M1_50!=INVALID_HANDLE) IndicatorRelease(hEMA_M1_50);
   if(hEMA_M1_200!=INVALID_HANDLE)IndicatorRelease(hEMA_M1_200);
   if(hEMA_H1_50!=INVALID_HANDLE) IndicatorRelease(hEMA_H1_50);
   if(hEMA_H1_200!=INVALID_HANDLE)IndicatorRelease(hEMA_H1_200);
   if(hRSI_M1_14!=INVALID_HANDLE) IndicatorRelease(hRSI_M1_14);
   if(hEMA_M15_5!=INVALID_HANDLE) IndicatorRelease(hEMA_M15_5);
   if(hEMA_M15_10!=INVALID_HANDLE) IndicatorRelease(hEMA_M15_10);
}
// ==============================
// ============ TICK ============
// ==============================
void OnTick()
{
   if(!SymbolInfoTick(g_symbol,g_tick)) return;

   // HUD
   double spreadPts=(g_tick.ask-g_tick.bid)/g_point;
   string hud = "Mode:"+ModeName()+" | PnL:"+DoubleToString(TodayPnL(),2)+"€ | Spread:"+DoubleToString(spreadPts,1)+"pt | LastBlock:"+g_lastBlockReason;
   Comment(hud);

   // nur M1 neu (Positionspflege immer)
   datetime m1Close = iTime(g_symbol, InpTF_Work, 0);
   if(m1Close==0){ ManagePositions(); return; }
   bool isNewBar = (m1Close!=g_lastM1CloseTime);

   ResetDayIfNeeded();
   UpdateModeByPnL();

   if(g_mode==MODE_DISABLED_TODAY){
      g_lastBlockReason="DisabledToday";
      LogRow("DISABLED_TODAY","Mode","BLOCK","DisabledToday","-",0,0,0,0,0,0,0,0,0,0,0,0,true,"extra loss after safe");
      return;
   }
   if(InpManualOverride){
      g_lastBlockReason="Manual";
      LogRow("MANUAL_OVERRIDE","Mode","BLOCK","Manual","-",0,0,0,0,0,0,0,0,0,0,0,0,true,"manual mode");
      ManagePositions(); return;
   }
   if(!InTradeWindow()){
      g_lastBlockReason="Window";
      LogRow("WINDOW_BLOCK","Mode","BLOCK",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"outside window");
      ManagePositions(); return;
   }
   if(News_IsBlockedWindow()){
      SetMode(MODE_SAFE);
      g_lastBlockReason="News";
      LogRow("NEWS_BLOCK","News","BLOCK",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"news window");
      ManagePositions(); return;
   }
   if(TodayPnL() <= -InpDailyLossStopEUR){
      SetMode(MODE_SAFE);
      g_lastBlockReason="DailyLoss";
      LogRow("SAFE_MODE","Risk","BLOCK","Safe","-",0,0,0,0,0,0,0,0,0,0,0,0,true,"daily loss");
      ManagePositions(); return;
   }

   string volReason="";
   if(InpUseATRGateHard){
      double a=0; if(!ATR(a) || !SymbolInfoTick(g_symbol,g_tick)){ volReason="atr_missing"; }
      else{
         double ratio = a / g_tick.bid;
         if(ratio < InpMinATRtoPriceRatio) volReason="atr/price low";
         else if(!EnoughVolatilityDailyRef()) volReason="m1_vs_d1 low";
      }
      if(StringLen(volReason)>0){
         g_lastBlockReason="Vol:"+volReason;
         LogRow("VOL_BLOCK","Vol","BLOCK",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"atr gate: "+volReason);
         ManagePositions(); return;
      }
   }

   if(!isNewBar){ ManagePositions(); return; }
   g_lastM1CloseTime = m1Close;

   // Main Filter
   bool fTrend=false,fStrength=false,fMomentum=false; int cats=0; bool htfok=false; string nfNote="";
   EvaluateMainFilter(fTrend,fStrength,fMomentum,cats,htfok,nfNote);
   if(!(cats>=2 && htfok)){
      g_lastBlockReason="MainFilter";
      LogRow("FILTER_BLOCK","MainFilter","BLOCK",ModeName(),"-",0,0,0, 0,0, 0,0, 0,0, 0,0, cats, htfok, "main filter "+nfNote);
      ManagePositions(); return;
   }

   // Scores
   double qL=0,qS=0; string qNote=""; ComputeQualityScore(qL,qS,qNote);
   double aL=0,aS=0; ApplyMetaAdjust(aL,aS);
   aL=Clamp(aL,-InpAdjustMaxAbs,InpAdjustMaxAbs);
   aS=Clamp(aS,-InpAdjustMaxAbs,InpAdjustMaxAbs);
   double qaL=qL+aL, qaS=qS+aS;

   // Direction
   string bias=""; double dirStrength=0.0;
   bool hasMaj=MajorityDecision(bias,dirStrength);
   if(!hasMaj){
      g_lastBlockReason="NoMajority";
      LogRow("DIR_BLOCK","Direction","BLOCK",ModeName(),"-",0,0,0,qL,qS,0,0,aL,aS,qaL,qaS,0,true,"no majority");
      ManagePositions(); return;
   }

   // Gate & Entry
   string gateNote="";
   if(bias=="LONG"){ bool ok=GateByScores(qaL,dirStrength,gateNote); if(ok) TryEnter("LONG",qL,qS,dirStrength,0,aL,aS,qaL,qaS); else g_lastBlockReason="Gate"; }
   else if(bias=="SHORT"){ bool ok=GateByScores(qaS,dirStrength,gateNote); if(ok) TryEnter("SHORT",qL,qS,0,dirStrength,aL,aS,qaL,qaS); else g_lastBlockReason="Gate"; }

   ManagePositions();
}
