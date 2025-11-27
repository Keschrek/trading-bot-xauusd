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
bool IchimokuScore(double &scoreLong,double &scoreShort,string &note)
{
   scoreLong=0.0; scoreShort=0.0; note="";
   if(!InpUseIchimoku || hIKH==INVALID_HANDLE) return false;
   double tenkan[],kijun[],spanA[],spanB[];
   ArraySetAsSeries(tenkan,true); ArraySetAsSeries(kijun,true);
   ArraySetAsSeries(spanA,true);  ArraySetAsSeries(spanB,true);
   bool okTen = CopyBuffer(hIKH,0,0,1,tenkan)>=1;
   bool okKij = CopyBuffer(hIKH,1,0,1,kijun)>=1;
   bool okSa  = CopyBuffer(hIKH,2,0,1,spanA)>=1;
   bool okSb  = CopyBuffer(hIKH,3,0,1,spanB)>=1;
   if(!(okTen && okKij && okSa && okSb)) return false;
   double price = (SymbolInfoTick(g_symbol,g_tick)? g_tick.bid : iClose(g_symbol,InpIKH_Timeframe,0));
   double cloudTop=MathMax(spanA[0],spanB[0]);
   double cloudBottom=MathMin(spanA[0],spanB[0]);
   if(price>cloudTop){ scoreLong+=1.0; note+="IKH_cloud_up "; }
   else if(price<cloudBottom){ scoreShort+=1.0; note+="IKH_cloud_dn "; }
   if(tenkan[0]>kijun[0]){ scoreLong+=1.0; note+="IKH_tk_up "; }
   else if(tenkan[0]<kijun[0]){ scoreShort+=1.0; note+="IKH_tk_dn "; }
   double maxScore = MathMax(0.0,InpIKH_MaxScore);
   scoreLong = Clamp(scoreLong,-maxScore,maxScore);
   scoreShort = Clamp(scoreShort,-maxScore,maxScore);
   return true;
}

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

// PATTERN: definition - muss VOR den Funktionen stehen
enum PatternType
{
   PATTERN_NONE = 0,
   PATTERN_DOUBLE_BOTTOM,
   PATTERN_DOUBLE_TOP,
   PATTERN_W,
   PATTERN_M,
   PATTERN_BULL_ENGULF,
   PATTERN_BEAR_ENGULF,
   PATTERN_HAMMER,
   PATTERN_SHOOTING_STAR
};

struct DetectedPattern
{
   int    type;           // PatternType
   double strength;       // 0..1
   double scoreLong;      // Beitrag zum Long-Score
   double scoreShort;     // Beitrag zum Short-Score
   string name;           // Pattern-Name
};

// PATTERN: forward declarations
bool PatternDetectDoubleBottom(ENUM_TIMEFRAMES tf,int lookback,double &strength);
bool PatternDetectDoubleTop(ENUM_TIMEFRAMES tf,int lookback,double &strength);
bool PatternDetectW(ENUM_TIMEFRAMES tf,int lookback,double &strength);
bool PatternDetectM(ENUM_TIMEFRAMES tf,int lookback,double &strength);
bool PatternDetectEngulfing(ENUM_TIMEFRAMES tf,double &strength,int &direction);
bool PatternDetectHammerShootingStar(ENUM_TIMEFRAMES tf,double &strength,int &direction);
DetectedPattern PatternDetectBest(ENUM_TIMEFRAMES tf);

// REGIME: classification enums
enum RegimeTrendType
{
   REGIME_TREND_DOWN = -1,
   REGIME_TREND_RANGE = 0,
   REGIME_TREND_UP = 1
};

enum RegimeVolType
{
   REGIME_VOL_LOW = 0,
   REGIME_VOL_MID = 1,
   REGIME_VOL_HIGH = 2
};

enum RegimeSessionType
{
   REGIME_SES_ASIA = 0,
   REGIME_SES_LONDON = 1,
   REGIME_SES_NY = 2,
   REGIME_SES_OFF = 3
};

enum RegimeStructureType
{
   REGIME_STR_NEAR_LOW = 0,
   REGIME_STR_MID = 1,
   REGIME_STR_NEAR_HIGH = 2
};

// PHASE-LEARNING: market phase enums
const int TREND_SIDEWAYS = 0;
const int TREND_UP = 1;
const int TREND_DOWN = -1;
const int VOL_LOW = 0;
const int VOL_MEDIUM = 1;
const int VOL_HIGH = 2;
const int SESSION_ASIA = 0;
const int SESSION_EUROPE = 1;
const int SESSION_US = 2;

// INDLEARN: indicator ids (using custom prefix to avoid collision with built-in ENUM_INDICATOR)
enum CustomIndicatorId
{
   CIND_EMA = 1,
   CIND_ADX = 2,
   CIND_RSI = 3,
   CIND_CCI = 4,
   CIND_MACD = 5,
   CIND_MFI = 6,
   CIND_VOLUME = 7,
   CIND_VWAP = 8,
   CIND_PATTERNS = 9,
   CIND_ICHIMOKU = 10,
   CIND_PSAR = 11,
   CIND_CPR = 12,
   CIND_M15ALIGN = 13,
   CIND_ATR_BONUS = 14
};

// REGIME: helper struct to share latest context
struct RegimeContext
{
   int trend;
   int vol;
   int session;
   int structure;
   int regimeId;
};

// INDLEARN: breakdown of indicator contributions
struct IndicatorScoreBreakdown
{
   double ema;
   double adx;
   double rsi;
   double cci;
   double macd;
   double mfi;
   double volume;
   double vwap;
   double patterns;
   double ichimoku;
   double psar;
   double cpr;
   double m15align;
   double atrBonus;
};

// INDLEARN: stats per indicator/regime
struct IndicatorRegimeStat
{
   int      indicatorId;
   int      regimeId;
   int      trades;
   double   weightedPnlSum;
   double   weightedAvgR;
   double   weightShift;
   double   todayAccum;
   datetime lastAdjustDay;
};

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

// PATTERN: detect double bottom
bool PatternDetectDoubleBottom(ENUM_TIMEFRAMES tf,int lookback,double &strength)
{
   strength=0.0;
   if(lookback<4) return false;
   double atr=0; ATR(atr);
   if(atr<=0) return false;
   
   // Suche zwei lokale Tiefpunkte
   int low1Idx=-1, low2Idx=-1;
   double low1=1e10, low2=1e10;
   
   for(int i=2;i<lookback-1;i++)
   {
      double l0=iLow(g_symbol,tf,i);
      double l1=iLow(g_symbol,tf,i-1);
      double l2=iLow(g_symbol,tf,i+1);
      if(l0<l1 && l0<l2) // lokales Tief
      {
         if(low1Idx<0 || l0<low1)
         {
            low2=low1; low2Idx=low1Idx;
            low1=l0; low1Idx=i;
         }
         else if(low2Idx<0 || l0<low2)
         {
            low2=l0; low2Idx=i;
         }
      }
   }
   if(low1Idx<0 || low2Idx<0) return false;
   if(low2Idx>=low1Idx) return false; // low2 muss älter sein
   
   // Prüfe Abstand der Tiefs (max. 1.5 ATR)
   double diff=MathAbs(low1-low2);
   if(diff>1.5*atr) return false;
   
   // Prüfe Zwischenhoch
   double highBetween=0;
   for(int i=low2Idx+1;i<low1Idx;i++)
   {
      double h=iHigh(g_symbol,tf,i);
      if(h>highBetween) highBetween=h;
   }
   if(highBetween<=low1 || highBetween<=low2) return false;
   
   // Strength: je ähnlicher die Tiefs, desto stärker
   strength = 1.0 - (diff / (1.5*atr));
   return (strength>0.3);
}

// PATTERN: detect double top
bool PatternDetectDoubleTop(ENUM_TIMEFRAMES tf,int lookback,double &strength)
{
   strength=0.0;
   if(lookback<4) return false;
   double atr=0; ATR(atr);
   if(atr<=0) return false;
   
   int high1Idx=-1, high2Idx=-1;
   double high1=-1e10, high2=-1e10;
   
   for(int i=2;i<lookback-1;i++)
   {
      double h0=iHigh(g_symbol,tf,i);
      double h1=iHigh(g_symbol,tf,i-1);
      double h2=iHigh(g_symbol,tf,i+1);
      if(h0>h1 && h0>h2) // lokales Hoch
      {
         if(high1Idx<0 || h0>high1)
         {
            high2=high1; high2Idx=high1Idx;
            high1=h0; high1Idx=i;
         }
         else if(high2Idx<0 || h0>high2)
         {
            high2=h0; high2Idx=i;
         }
      }
   }
   if(high1Idx<0 || high2Idx<0) return false;
   if(high2Idx>=high1Idx) return false;
   
   double diff=MathAbs(high1-high2);
   if(diff>1.5*atr) return false;
   
   double lowBetween=1e10;
   for(int i=high2Idx+1;i<high1Idx;i++)
   {
      double l=iLow(g_symbol,tf,i);
      if(l<lowBetween) lowBetween=l;
   }
   if(lowBetween>=high1 || lowBetween>=high2) return false;
   
   strength = 1.0 - (diff / (1.5*atr));
   return (strength>0.3);
}

// PATTERN: detect W-Formation (stärkeres Double Bottom)
bool PatternDetectW(ENUM_TIMEFRAMES tf,int lookback,double &strength)
{
   if(!PatternDetectDoubleBottom(tf,lookback,strength)) return false;
   // W ist im Prinzip ein Double Bottom mit klarerem mittlerem Hoch
   // Erhöhe Strength für W
   strength = MathMin(1.0, strength * 1.2);
   return (strength>0.4);
}

// PATTERN: detect M-Formation (stärkeres Double Top)
bool PatternDetectM(ENUM_TIMEFRAMES tf,int lookback,double &strength)
{
   if(!PatternDetectDoubleTop(tf,lookback,strength)) return false;
   strength = MathMin(1.0, strength * 1.2);
   return (strength>0.4);
}

// PATTERN: detect engulfing
bool PatternDetectEngulfing(ENUM_TIMEFRAMES tf,double &strength,int &direction)
{
   direction=0; strength=0.0;
   double o1=iOpen(g_symbol,tf,1), c1=iClose(g_symbol,tf,1),
          o0=iOpen(g_symbol,tf,0), c0=iClose(g_symbol,tf,0);
   if(o1==0||c1==0||o0==0||c0==0) return false;
   
   double atr=0; ATR(atr);
   if(atr<=0) return false;
   double avgSize = atr;
   double body0 = MathAbs(c0-o0);
   if(body0 < InpPatternMinSizeFactor * avgSize) return false;
   
   bool bull=(c0>o0 && o0<=c1 && c0>=o1 && c1<o1);
   bool bear=(c0<o0 && o0>=c1 && c0<=o1 && c1>o1);
   
   if(bull)
   {
      direction=+1;
      strength = MathMin(1.0, body0 / (avgSize * InpPatternMinSizeFactor));
      return true;
   }
   if(bear)
   {
      direction=-1;
      strength = MathMin(1.0, body0 / (avgSize * InpPatternMinSizeFactor));
      return true;
   }
   return false;
}

// PATTERN: detect hammer/shooting star
bool PatternDetectHammerShootingStar(ENUM_TIMEFRAMES tf,double &strength,int &direction)
{
   direction=0; strength=0.0;
   double o0=iOpen(g_symbol,tf,0), c0=iClose(g_symbol,tf,0),
          h0=iHigh(g_symbol,tf,0), l0=iLow(g_symbol,tf,0);
   if(o0==0||c0==0||h0==0||l0==0) return false;
   
   double body=MathAbs(c0-o0);
   double range=h0-l0;
   if(range<=0 || body/range > InpPatternBodyRatioMax) return false;
   
   double upper=h0-MathMax(o0,c0);
   double lower=MathMin(o0,c0)-l0;
   
   // Hammer (bullish)
   if(lower>=2.0*body && upper<=0.5*body && c0>=o0)
   {
      direction=+1;
      strength = MathMin(1.0, lower / (2.0*body));
      return true;
   }
   // Shooting Star (bearish)
   if(upper>=2.0*body && lower<=0.5*body && c0<=o0)
   {
      direction=-1;
      strength = MathMin(1.0, upper / (2.0*body));
      return true;
   }
   return false;
}

// PATTERN: detect best pattern (aggregated)
DetectedPattern PatternDetectBest(ENUM_TIMEFRAMES tf)
{
   DetectedPattern best;
   best.type=PATTERN_NONE;
   best.strength=0.0;
   best.scoreLong=0.0;
   best.scoreShort=0.0;
   best.name="";
   
   if(!InpEnablePatterns) return best;
   
   int patLookback = MathMin(InpPatternLookbackBars, 50);
   double patStrength=0.0;
   int patDir=0;
   
   // Double Bottom / W
   if(PatternDetectDoubleBottom(tf,patLookback,patStrength))
   {
      double score = 1.0 + patStrength; // 1.0 bis 2.0
      if(score > best.strength*2.0)
      {
         best.type=PATTERN_DOUBLE_BOTTOM;
         best.strength=patStrength;
         best.scoreLong=score;
         best.scoreShort=-0.5;
         best.name="DoubleBottom";
      }
   }
   if(PatternDetectW(tf,patLookback,patStrength))
   {
      double score = 1.2 + patStrength*0.8; // 1.2 bis 2.0
      if(score > best.strength*2.0)
      {
         best.type=PATTERN_W;
         best.strength=patStrength;
         best.scoreLong=score;
         best.scoreShort=-0.5;
         best.name="W";
      }
   }
   
   // Double Top / M
   if(PatternDetectDoubleTop(tf,patLookback,patStrength))
   {
      double score = 1.0 + patStrength;
      if(score > best.strength*2.0)
      {
         best.type=PATTERN_DOUBLE_TOP;
         best.strength=patStrength;
         best.scoreLong=-0.5;
         best.scoreShort=score;
         best.name="DoubleTop";
      }
   }
   if(PatternDetectM(tf,patLookback,patStrength))
   {
      double score = 1.2 + patStrength*0.8;
      if(score > best.strength*2.0)
      {
         best.type=PATTERN_M;
         best.strength=patStrength;
         best.scoreLong=-0.5;
         best.scoreShort=score;
         best.name="M";
      }
   }
   
   // Engulfing
   if(PatternDetectEngulfing(tf,patStrength,patDir))
   {
      double score = 1.0 + patStrength;
      if(score > best.strength*2.0)
      {
         best.type=(patDir>0?PATTERN_BULL_ENGULF:PATTERN_BEAR_ENGULF);
         best.strength=patStrength;
         if(patDir>0)
         {
            best.scoreLong=score;
            best.scoreShort=-0.5;
            best.name="BullEngulf";
         }
         else
         {
            best.scoreLong=-0.5;
            best.scoreShort=score;
            best.name="BearEngulf";
         }
      }
   }
   
   // Hammer / Shooting Star
   if(PatternDetectHammerShootingStar(tf,patStrength,patDir))
   {
      double score = 1.0 + patStrength;
      if(score > best.strength*2.0)
      {
         best.type=(patDir>0?PATTERN_HAMMER:PATTERN_SHOOTING_STAR);
         best.strength=patStrength;
         if(patDir>0)
         {
            best.scoreLong=score;
            best.scoreShort=-0.5;
            best.name="Hammer";
         }
         else
         {
            best.scoreLong=-0.5;
            best.scoreShort=score;
            best.name="ShootingStar";
         }
      }
   }
   
   // Clamp scores
   best.scoreLong = Clamp(best.scoreLong, -2.0, 2.0);
   best.scoreShort = Clamp(best.scoreShort, -2.0, 2.0);
   
   return best;
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
    MqlDateTime tm;
    TimeToStruct(TimeCurrent(), tm);

    // Parse Start
    int startH = 0;
    int startM = 0;
    if(StringLen(InpTradeWindow_Start) >= 4)
    {
        startH = (int)StringToInteger(StringSubstr(InpTradeWindow_Start, 0, 2));
        startM = (int)StringToInteger(StringSubstr(InpTradeWindow_Start, 3, 2));
    }

    // Parse End
    int endH = 0;
    int endM = 0;
    if(StringLen(InpTradeWindow_End) >= 4)
    {
        endH = (int)StringToInteger(StringSubstr(InpTradeWindow_End, 0, 2));
        endM = (int)StringToInteger(StringSubstr(InpTradeWindow_End, 3, 2));
    }

    int cur   = tm.hour * 60 + tm.min;
    int start = startH * 60 + startM;
    int end   = endH   * 60 + endM;

    // Normal range (e.g. 07:00–22:00)
    if(start < end)
        return (cur >= start && cur <= end);

    // Overnight range (e.g. 22:00–05:00)
    if(start > end)
        return (cur >= start || cur <= end);

    // Start == End → 24h allowed
    return true;
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
    // ATR M1 (über hATR, da deine ATR() keine TimeFrame-Parameter unterstützt)
    double atrM1 = 0.0;
    if(!ATR(atrM1) || atrM1 <= 0.0)
        return false;

    // ATR D1: eigener Handle für D1
    int hD1 = iATR(g_symbol, PERIOD_D1, InpATR_Period);
    if(hD1 == INVALID_HANDLE)
        return false;

    double d1buf[];
    ArraySetAsSeries(d1buf, true);

    bool ok = (CopyBuffer(hD1, 0, 0, 1, d1buf) >= 1);
    IndicatorRelease(hD1);

    if(!ok || d1buf[0] <= 0.0)
        return false;

    double atrD1 = d1buf[0];
    double ratio = atrM1 / atrD1;

    if(InpDebug)
    {
        Print("[VOL] ATR_M1=", DoubleToString(atrM1, 5),
              " | ATR_D1=", DoubleToString(atrD1, 5),
              " | ratio=", DoubleToString(ratio, 4),
              " >= min=", DoubleToString(InpATR_M1_to_D1_MinRatio,4));
    }

    return (ratio >= InpATR_M1_to_D1_MinRatio);
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
void EvaluateMainFilter(bool &fTrend,bool &fStrength,bool &fMomentum,
                        int &cats,bool &htfok,string &note)
{
    fTrend=false; 
    fStrength=false; 
    fMomentum=false;
    cats=0; 
    htfok=false;
    note="";

    if(!SymbolInfoTick(g_symbol,g_tick))
    {
        note="no tick";
        return;
    }

    // ===== TREND (M1) =====
    double ema5=0, ema10=0, ema50=0, ema200=0;
    bool ok5   = EMA(hEMA_M1_5,ema5,0);
    bool ok10  = EMA(hEMA_M1_10,ema10,0);
    bool ok50  = EMA(hEMA_M1_50,ema50,0);
    bool ok200 = EMA(hEMA_M1_200,ema200,0);

    if(ok5 && ok10 && ok50 && ok200)
    {
        if(ema5 > ema10 && ema10 > ema50) 
        { 
            fTrend = true; 
            cats++; 
            note += "trend "; 
        }
    }

    // ===== STRENGTH (H1 + ADX) =====
    double emaH1_50=0, emaH1_200=0;
    bool h1ok50  = EMA(hEMA_H1_50,emaH1_50,0);
    bool h1ok200 = EMA(hEMA_H1_200,emaH1_200,0);

    double adx = 0;
    bool adxok = ADX(adx);

    if(h1ok50 && h1ok200 && adxok)
    {
        if(emaH1_50 > emaH1_200 && adx >= InpADX_Moderate)
        {
            fStrength = true;
            cats++;
            note += "strength ";
        }
    }

    // ===== MOMENTUM (RSI + MACD) =====
    double rsi=0; 
    double macd=0;
    bool rsiOk  = RSI(hRSI_M1_14, rsi);
    bool macdOk = MACD_H(macd);

    if(rsiOk && macdOk)
    {
        if(rsi > 52 || rsi < 48)  // leicht asymmetrisch = stabiler
        {
            fMomentum = true;
            cats++;
            note += "momentum ";
        }
    }

// ===== High Timeframe OK =====
// H1-Trend darf neutral sein → nicht blockieren
if(h1ok50 && h1ok200)
{
    double dist = MathAbs(emaH1_50 - emaH1_200);

    // nahezu gleich → seitwärts → OK
    if(dist <= (2.0 * g_point))
    {
        htfok = true;
        note += "htf_flat ";
    }
    else
    {
        // echter Trend
        if(emaH1_50 > emaH1_200)
        {
            htfok = true;
            note += "htf_up ";
        }
        else
        {
            htfok = true;
            note += "htf_down ";
        }
    }
}
else
{
    htfok = false;
    note += "htf_fail ";
}

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
bool MajorityDecision(string &bias, double &strength)
{
    bias = "";
    strength = 0.0;

    double score = 0.0;

    // =====================================
    // RSI
    // =====================================
    double rsi = 0.0;
    if(RSI(hRSI_M1_14, rsi))      // <-- KORREKT: nur 2 Parameter
    {
        if(rsi > 55) score += 1.0;
        else if(rsi < 45) score -= 1.0;
    }

    // =====================================
    // MACD
    // =====================================
    double macd = 0.0;
    if(MACD_H(macd))
    {
        if(macd > 0) score += 1.0;
        else if(macd < 0) score -= 1.0;
    }

    // =====================================
    // EMA Cross M1 5/10
    // =====================================
    if(EmaCross_M1_5_10()) score += 1.0;
    else score -= 1.0;

    // =====================================
    // HTF Trend (M1 vs H1)
    // =====================================
    if(EmaBiasOK_TF_M1(hEMA_H1_50, hEMA_H1_200, 1))
        score += 1.0;
    else
        score -= 1.0;

    // =====================================
    // Entscheidung
    // =====================================
    if(score > 0.5)
    {
        bias = "LONG";
        strength = score;
        return true;
    }
    else if(score < -0.5)
    {
        bias = "SHORT";
        strength = MathAbs(score);
        return true;
    }

    bias = "";
    strength = 0.0;
    return false;
}



// ==============================
// ========= SCORE ==============
// ==============================
void ComputeQualityScore(double &longScore,double &shortScore,string &note)
{
   longScore=0.0; shortScore=0.0; note="";
   // REGIME: capture regime for scoring/logging
   RegimeContext ctx = BuildRegimeContext();
   g_lastRegimeCtx = ctx;
   ResetIndicatorBreakdown(g_lastIndicatorScoreLong);
   ResetIndicatorBreakdown(g_lastIndicatorScoreShort);

   // PHASE-LEARNING: detect current market phase for indicator weighting
   int currentTrendPhase = DetectTrendPhase();
   int currentVolLevel = DetectVolatilityLevel();
   int currentSessionBucket = DetectSessionBucket();

   StrategyVariant var = VariantGetById(g_currentVariantId);

   // EMA
   if(EmaCross_M1_5_10())
   {
      double indFactorEMA = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_EMA,ctx.regimeId),0.5,1.5) : 1.0);
      double phaseWeightEMA = GetIndicatorPhaseWeight("EMA",currentTrendPhase,currentVolLevel,currentSessionBucket,1);
      double contrib = 1.5 * indFactorEMA * phaseWeightEMA;
      longScore += contrib;
      shortScore += contrib;
      g_lastIndicatorScoreLong.ema += contrib;
      g_lastIndicatorScoreShort.ema += contrib;
      note+="EMA5/10 ";
   }

   // ADX
   double adx=0.0; ADX(adx);
   double indFactorADX = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_ADX,ctx.regimeId),0.5,1.5) : 1.0);
   double phaseWeightADX_L = GetIndicatorPhaseWeight("ADX",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
   double phaseWeightADX_S = GetIndicatorPhaseWeight("ADX",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
   if(adx>=InpADX_Strong)
   {
      double contribL = 1.0 * indFactorADX * phaseWeightADX_L;
      double contribS = 1.0 * indFactorADX * phaseWeightADX_S;
      longScore+=contribL; shortScore+=contribS;
      g_lastIndicatorScoreLong.adx+=contribL; g_lastIndicatorScoreShort.adx+=contribS;
      note+="ADX_strong ";
   }
   else if(adx>=InpADX_Moderate)
   {
      double contribL = 0.5 * indFactorADX * phaseWeightADX_L;
      double contribS = 0.5 * indFactorADX * phaseWeightADX_S;
      longScore+=contribL; shortScore+=contribS;
      g_lastIndicatorScoreLong.adx+=contribL; g_lastIndicatorScoreShort.adx+=contribS;
      note+="ADX_mod ";
   }

   // Volume
   if(var.useVolumeFilter && VolumeSpike())
   {
      double indFactorVOL = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_VOLUME,ctx.regimeId),0.5,1.5) : 1.0);
      double phaseWeightVOL_L = GetIndicatorPhaseWeight("VOL",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
      double phaseWeightVOL_S = GetIndicatorPhaseWeight("VOL",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
      double contribL = 1.0 * indFactorVOL * phaseWeightVOL_L;
      double contribS = 1.0 * indFactorVOL * phaseWeightVOL_S;
      longScore+=contribL; shortScore+=contribS;
      g_lastIndicatorScoreLong.volume+=contribL; g_lastIndicatorScoreShort.volume+=contribS;
      note+="VOL_spike ";
   }

   // Patterns
   double patternScoreLong=0.0, patternScoreShort=0.0;
   if(InpEnablePatterns && var.usePatterns)
   {
      DetectedPattern p = PatternDetectBest(InpTF_Work);
      patternScoreLong = p.scoreLong;
      patternScoreShort = p.scoreShort;
      if(p.type != PATTERN_NONE)
      {
         double indFactorPAT = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_PATTERNS,ctx.regimeId),0.5,1.5) : 1.0);
         double phaseWeightPAT_L = GetIndicatorPhaseWeight("PATTERN",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
         double phaseWeightPAT_S = GetIndicatorPhaseWeight("PATTERN",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
         double adjLong = patternScoreLong * indFactorPAT * phaseWeightPAT_L;
         double adjShort = patternScoreShort * indFactorPAT * phaseWeightPAT_S;
         longScore += adjLong;
         shortScore += adjShort;
         g_lastIndicatorScoreLong.patterns += adjLong;
         g_lastIndicatorScoreShort.patterns += adjShort;
         note += p.name+"("+DoubleToString(p.strength,2)+") ";
      }
   }

   // RSI
   double rsi=0.0; RSI(hRSI_M1_14,rsi);
   double indFactorRSI = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_RSI,ctx.regimeId),0.5,1.5) : 1.0);
   double phaseWeightRSI_L = GetIndicatorPhaseWeight("RSI",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
   double phaseWeightRSI_S = GetIndicatorPhaseWeight("RSI",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
   if(rsi>55)
   {
      double contrib = 0.5 * indFactorRSI * phaseWeightRSI_L;
      longScore+=contrib;
      g_lastIndicatorScoreLong.rsi+=contrib;
   }
   if(rsi<45)
   {
      double contrib = 0.5 * indFactorRSI * phaseWeightRSI_S;
      shortScore+=contrib;
      g_lastIndicatorScoreShort.rsi+=contrib;
   }

   // CCI
   double cci=0.0; CCI(cci);
   double cciWeight = (var.useCCIWeak ? 0.25 : 0.5);
   double indFactorCCI = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_CCI,ctx.regimeId),0.5,1.5) : 1.0);
   double phaseWeightCCI_L = GetIndicatorPhaseWeight("CCI",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
   double phaseWeightCCI_S = GetIndicatorPhaseWeight("CCI",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
   if(cci>InpCCI_Threshold)
   {
      double contrib = cciWeight * indFactorCCI * phaseWeightCCI_L;
      longScore+=contrib; g_lastIndicatorScoreLong.cci+=contrib;
   }
   if(cci<-InpCCI_Threshold)
   {
      double contrib = cciWeight * indFactorCCI * phaseWeightCCI_S;
      shortScore+=contrib; g_lastIndicatorScoreShort.cci+=contrib;
   }

   // MACD
   double macd=0.0; MACD_H(macd);
   double indFactorMACD = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_MACD,ctx.regimeId),0.5,1.5) : 1.0);
   double phaseWeightMACD_L = GetIndicatorPhaseWeight("MACD",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
   double phaseWeightMACD_S = GetIndicatorPhaseWeight("MACD",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
   if(macd>0)
   {
      double contrib = 0.5*indFactorMACD * phaseWeightMACD_L;
      longScore+=contrib; g_lastIndicatorScoreLong.macd+=contrib;
   }
   if(macd<0)
   {
      double contrib = 0.5*indFactorMACD * phaseWeightMACD_S;
      shortScore+=contrib; g_lastIndicatorScoreShort.macd+=contrib;
   }

   // MFI
   double mfi=0.0; MFI(mfi);
   double indFactorMFI = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_MFI,ctx.regimeId),0.5,1.5) : 1.0);
   double phaseWeightMFI_L = GetIndicatorPhaseWeight("MFI",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
   double phaseWeightMFI_S = GetIndicatorPhaseWeight("MFI",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
   if(mfi>=60)
   {
      double contrib = 0.5*indFactorMFI * phaseWeightMFI_L;
      longScore+=contrib; g_lastIndicatorScoreLong.mfi+=contrib;
   }
   else if(mfi<=40)
   {
      double contrib = 0.5*indFactorMFI * phaseWeightMFI_S;
      shortScore+=contrib; g_lastIndicatorScoreShort.mfi+=contrib;
   }

   // PSAR
   if(InpUsePSARExit)
   {
      double indFactorPSAR = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_PSAR,ctx.regimeId),0.5,1.5) : 1.0);
      if(PSAR_TrendUp())
      {
         double contrib = 0.5*indFactorPSAR;
         longScore+=contrib; g_lastIndicatorScoreLong.psar+=contrib;
      }
      if(PSAR_TrendDown())
      {
         double contrib = 0.5*indFactorPSAR;
         shortScore+=contrib; g_lastIndicatorScoreShort.psar+=contrib;
      }
   }

   // VWAP
   double vwp=0.0;
   if(VWAP_Get(vwp) && SymbolInfoTick(g_symbol,g_tick))
   {
      double indFactorVWAP = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_VWAP,ctx.regimeId),0.5,1.5) : 1.0);
      double contrib = 0.5*indFactorVWAP;
      if(g_tick.bid>vwp)
      {
         longScore+=contrib; g_lastIndicatorScoreLong.vwap+=contrib;
      }
      else
      {
         shortScore+=contrib; g_lastIndicatorScoreShort.vwap+=contrib;
      }
      note+="VWAP="+DoubleToString(vwp,g_digits)+" ";
   }

   // CPR
   double P=0,BC=0,TC=0; int cprs=CPRSignal(P,BC,TC);
   double indFactorCPR = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_CPR,ctx.regimeId),0.5,1.5) : 1.0);
   if(cprs==+1)
   {
      double contrib = 1.0*indFactorCPR;
      longScore+=contrib; g_lastIndicatorScoreLong.cpr+=contrib; note+="CPR_up ";
   }
   else if(cprs==-1)
   {
      double contrib = 1.0*indFactorCPR;
      shortScore+=contrib; g_lastIndicatorScoreShort.cpr+=contrib; note+="CPR_dn ";
   }
   note+="CPR:P="+DoubleToString(P,g_digits)+" BC="+DoubleToString(BC,g_digits)+" TC="+DoubleToString(TC,g_digits)+" ";

   // ATR bonus
   double atrVal=0.0;
   if(ATR(atrVal) && atrVal>0.0)
   {
      double indFactorATR = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_ATR_BONUS,ctx.regimeId),0.5,1.5) : 1.0);
      double contrib = 0.5*indFactorATR;
      longScore+=contrib; shortScore+=contrib;
      g_lastIndicatorScoreLong.atrBonus+=contrib;
      g_lastIndicatorScoreShort.atrBonus+=contrib;
      note+="ATR_bonus ";
   }

   // M15 Align
   if(InpUseM15Align)
   {
      double e5=0.0,e10=0.0;
      bool ok5=EMA(hEMA_M15_5,e5,1);
      bool ok10=EMA(hEMA_M15_10,e10,1);
      if(ok5 && ok10)
      {
         double indFactorM15 = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_M15ALIGN,ctx.regimeId),0.5,1.5) : 1.0);
         if(e5>e10)
         {
            double contrib = 0.5*indFactorM15;
            longScore+=contrib; g_lastIndicatorScoreLong.m15align+=contrib; note+="M15AlignUp ";
         }
         else if(e5<e10)
         {
            double contrib = 0.5*indFactorM15;
            shortScore+=contrib; g_lastIndicatorScoreShort.m15align+=contrib; note+="M15AlignDn ";
         }
      }
   }

   // Ichimoku
   double ikhLong=0.0, ikhShort=0.0; string ikhNote="";
   if(IchimokuScore(ikhLong,ikhShort,ikhNote))
   {
      double ikhMult = (var.useIchimokuBoost ? 1.5 : 1.0);
      double indFactorIKH = (InpEnableIndicatorLearning ? Clamp(1.0+IndGetShift(CIND_ICHIMOKU,ctx.regimeId),0.5,1.5) : 1.0);
      double phaseWeightIKH_L = GetIndicatorPhaseWeight("IKH",currentTrendPhase,currentVolLevel,currentSessionBucket,+1);
      double phaseWeightIKH_S = GetIndicatorPhaseWeight("IKH",currentTrendPhase,currentVolLevel,currentSessionBucket,-1);
      double adjLong = ikhLong * ikhMult * indFactorIKH * phaseWeightIKH_L;
      double adjShort = ikhShort * ikhMult * indFactorIKH * phaseWeightIKH_S;
      longScore+=adjLong; shortScore+=adjShort;
      g_lastIndicatorScoreLong.ichimoku+=adjLong;
      g_lastIndicatorScoreShort.ichimoku+=adjShort;
      note+=ikhNote;
   }
}
void ApplyMetaAdjust(double &adjLong,double &adjShort)
{
    adjLong = 0.0;
    adjShort = 0.0;

    // Falls Meta-Adjust deaktiviert → nichts tun
    if(!InpEnableMetaAdjust)
        return;

    // Falls kein Variant-System existiert → Standardwerte aus Inputs verwenden
    #ifdef USE_VARIANTS
        StrategyVariant var = VariantGetById(g_currentVariantId);
        adjLong  = Clamp(var.metaAdjustLong,  -InpAdjustMaxAbs, InpAdjustMaxAbs);
        adjShort = Clamp(var.metaAdjustShort, -InpAdjustMaxAbs, InpAdjustMaxAbs);
    #else
        // Fallback: Inputs verwenden
        adjLong  = Clamp(InpMetaAdjust_Long,  -InpAdjustMaxAbs, InpAdjustMaxAbs);
        adjShort = Clamp(InpMetaAdjust_Short, -InpAdjustMaxAbs, InpAdjustMaxAbs);
    #endif
}

// Hook
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
input bool     InpUseUnifiedTrail     = true;    // vereinheitlichte Trail-Logik
input int      InpTrailActivationPts  = 150;     // Mindestgewinn in Punkten bis Trail aktiviert
input int      InpTrailStepPts        = 60;      // fixer Mindestabstand in Punkten
input double   InpTrailATRMult        = 1.2;     // ATR-Multiplikator für dynamischen Trail
input int      InpTrailMinStepPts     = 20;      // Mindestverbesserung in Punkten je Anpassung
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
input bool     InpUseIchimoku         = true;
input ENUM_TIMEFRAMES InpIKH_Timeframe = PERIOD_M15;
input int      InpIKH_Tenkan          = 9;
input int      InpIKH_Kijun           = 26;
input int      InpIKH_SenkouB         = 52;
input double   InpIKH_MaxScore        = 2.0;

// Scores & Filter
input double   InpATR_M1_to_D1_MinRatio = 0.003;
input bool     InpUseATRGateHard      = true;
input double   InpMinATRtoPriceRatio  = 0.0010;
input double   InpQual_Min_Normal     = 4.0;
input double   InpQual_Min_Safe       = 5.0;
input double   InpQual_Min_PostTarget = 4.5;
input double   InpSplitEntry_Min      = 5.5;
input double   InpAdjustMaxAbs        = 1.0;

// ===== META ADJUST (fallback wenn Varianten deaktiviert sind) =====
input bool     InpEnableMetaAdjust    = false;
input double   InpMetaAdjust_Long     = 0.0;
input double   InpMetaAdjust_Short    = 0.0;

input double   InpRegimeVolLowRatio   = 0.7;
input double   InpRegimeVolHighRatio  = 1.3;
input int      InpStructureLookbackBars = 60;
input double   InpStructureNearHighPct = 0.8;
input double   InpStructureNearLowPct  = 0.2;
input bool     InpEnableLearningMonitor = true;
input int      InpMonitorMaxSizeKB      = 1024;

// Logging
input string   InpLogFilePrefix       = "xauusd_meta_";
input bool     InpDebug               = true;
input bool     InpEnableLearning        = false;
input int      InpLearningMinTrades     = 50;
input double   InpLearningWinThreshold  = 0.40;
input double   InpLearningUpperTrigger  = 0.60;
input double   InpLearningStep          = 0.02;
input double   InpLearningMaxAdjPerDay  = 0.05;
input double   InpLearningMaxTotalShift = 0.5;
input bool     InpEnableIndicatorLearning    = true;
input int      InpIndLearnMinTrades          = 50;
input double   InpIndLearnStep               = 0.02;
input double   InpIndLearnMaxAdjPerDay       = 0.05;
input double   InpIndLearnMaxTotalShift      = 0.5;
input double   InpIndLearnUpperTriggerR      = 0.10;
input double   InpIndLearnLowerTriggerR      = -0.10;
// PHASE-LEARNING: indicator phase performance inputs
input bool     InpEnablePhaseLearning        = true;
input int      InpIndPhaseMinTrades          = 30;
input double   InpIndPhaseStep               = 0.02;
input double   InpIndPhaseMaxPerDay          = 0.05;
input double   InpIndPhaseMaxTotal           = 0.3;
input double   InpPhaseVolLowThresh          = 0.002;
input double   InpPhaseVolHighThresh         = 0.005;
input double   InpPhaseNearHL_ATR            = 1.0;
input int      InpPhaseHighLowLookback       = 100;

// PATTERN: inputs
input bool     InpEnablePatterns       = true;   // global Patterns AN/AUS
input int      InpPatternLookbackBars  = 20;     // wie viele Bars max. zur Pattern-Suche zurück
input double   InpPatternMinSizeFactor = 0.5;    // Mindestgrößenfaktor relativ zur Durchschnitts-Range
input double   InpPatternBodyRatioMax  = 0.3;    // für Hammer/Pinbar: max. Body relativ zur Gesamtkerze

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
int hIKH=INVALID_HANDLE;

// ==============================
// ========== LOGGING ===========
// ==============================
double Clamp(double v,double lo,double hi){ return MathMax(lo,MathMin(hi,v)); }
const uint CSV_RW_FLAGS = FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI;

string TodayCsv(){ return InpLogFilePrefix + TimeToString(TimeCurrent(),TIME_DATE) + ".csv"; }

void EnsureLogOpen()
{
   if(g_logHandle!=INVALID_HANDLE) return;
   string fn=TodayCsv();
   // Header anlegen, wenn Datei nicht existiert:
   if(FileIsExist(fn)==false)
   {
      int h=FileOpen(fn,CSV_RW_FLAGS,';');
      if(h!=INVALID_HANDLE)
      {
         FileWrite(h,"Time","Event","Module","Decision","Mode","Direction","Price","SL","TP",
                   "QualBaseL","QualBaseS","DirL","DirS","AdjL","AdjS","QualAppliedL","QualAppliedS",
                   "Cats","HTF_OK","Notes");
         FileClose(h);
      }
   }
   g_logHandle=FileOpen(fn,CSV_RW_FLAGS,';');
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
// ===== LEARNING STATE =========
// ==============================
struct EntrySnapshot
{
   bool     valid;
   string   direction;
   datetime time;
   double   spreadPts;
   double   atr;
   double   qL;
   double   qS;
   double   qaL;
   double   qaS;
   double   dirStrength;
   int      cats;
   bool     htfok;
   int      mode;
   int      timeframe;
   double   rsi;
   double   macd;
   double   cci;
   double   adx;
   double   mfi;
   double   volumeScore;
   double   ichimokuLong;
   double   ichimokuShort;
   double   entryPricePlan;
   double   slPlan;
   double   tpPlan;
   // LEARNING: Filter-Flags
   bool     filterTrendOK;
   bool     filterStrengthOK;
   bool     filterMomentumOK;
   bool     filterVolumeOK;
   bool     filterPatternOK;
   bool     filterSessionOK;
   string   reasonText;
   // PATTERN: context fields
   bool     hasPattern;           // ob irgendein Pattern aktiv war
   string   patternName;          // Name des stärksten Patterns
   double   patternScore;         // Pattern-Score (z.B. -2 bis +2)
   double   patternStrength;      // optionaler Wert 0..1, wie "sauber" das Pattern ist
   // LEARNING: regime context
   int      regimeId;
   int      regimeTrend;
   int      regimeVol;
   int      regimeSession;
   int      regimeStructure;
   // STRUCTURE: swing / range data
   double   lastSwingHigh;
   double   lastSwingLow;
   double   distToSwingHighPts;
   double   distToSwingLowPts;
   double   recentHigh;
   double   recentLow;
   double   distToRecentHighPts;
   double   distToRecentLowPts;
   // INDLEARN: indicator contribution snapshot
   double   indScore_EMA;
   double   indScore_ADX;
   double   indScore_RSI;
   double   indScore_CCI;
   double   indScore_MACD;
   double   indScore_MFI;
   double   indScore_Volume;
   double   indScore_VWAP;
   double   indScore_Patterns;
   double   indScore_Ichimoku;
   double   indScore_PSAR;
   double   indScore_CPR;
   double   indScore_M15Align;
   double   indScore_ATRBonus;
   // PHASE-LEARNING: market phase context
   int      trendPhase;      // -1, 0, +1
   int      volLevel;        // 0,1,2
   int      sessionBucket;  // 0,1,2
   double   distToLastHigh;  // in Punkten
   double   distToLastLow;   // in Punkten
   bool     nearHigh;        // z.B. distToLastHigh < XATR
   bool     nearLow;         // z.B. distToLastLow < XATR
};

struct TradeContextEntry
{
   bool     active;
   ulong    ticket;
   EntrySnapshot snap;
   datetime entryTime;
   double   entryPrice;
   double   plannedSL;
   double   plannedTP;
   double   mfePts;
   double   maePts;
   string   exitReason;
   // VARIANT: context fields
   int      variantId;      // Strategietyp / Variante
   int      paramSetId;     // Parameter-Set (Score- & Trailing-Profil)
};

struct PendingOrderContext
{
   bool     active;
   ulong    orderTicket;
   EntrySnapshot snap;
};

struct ScoreBandStat
{
   double   band;
   int      direction; // +1 long, -1 short
   int      regimeId;
   int      trades;
   int      wins;
   double   sumPnl;
   double   sumPnlPts;
   double   shift;
   double   todayAccum;
   datetime lastAdjustDay;
   // LEARNING: loss penalty & streaks Erweiterung
   int      lossStreak;       // aktuelle Verlust-Serie
   double   weightedPnlSum;   // enthält PnL mit Loss-Penalty
   double   weightedAvg;      // gewichteter Durchschnitt (für Entscheidungsfindung)
   // EXIT-LEARN: efficiency & adjustments
   int      exitTrades;
   double   exitSumEfficiency;
   double   exitAvgEfficiency;
   double   exitShift;
};

// PHASE-LEARNING: indicator phase performance stats
struct IndicatorPhaseStat
{
   string   name;            // "RSI", "MACD", "CCI", "MFI", "IKH", "VOL", "PATTERN", "ADX"
   int      trendPhase;      // -1,0,1
   int      volLevel;        // 0,1,2
   int      sessionBucket;   // 0,1,2
   int      direction;       // +1 long, -1 short
   int      trades;
   int      wins;
   double   sumPnl;          // Summe Profit in Geld
   double   weightedPnl;     // R-basiert
   double   weightedAvg;     // weightedPnl / trades
   double   weightShift;      // Lern-Gewicht (-0.3 .. +0.3)
   double   todayAccum;      // Limit pro Tag
   datetime lastAdjustDay;
};

EntrySnapshot        g_lastDecisionSnapshot = {false};
TradeContextEntry    g_tradeContexts[];
PendingOrderContext  g_pendingOrders[];
ScoreBandStat        g_scoreStats[];
string               g_learningCsv = "";
string               g_learningStatsFile = "";
string               g_indicatorStatsFile = "";
string               g_monitorFile = "XAUUSD_learning_monitor.csv";
datetime             g_lastMonitorWriteTime = 0;
// PHASE-LEARNING: indicator phase stats
IndicatorPhaseStat   g_indPhaseStats[];

// VARIANT: definition
struct StrategyVariant
{
   int   id;
   bool  usePatterns;         // Candle-Patterns (Double Bottom, W-Pattern, etc.) ja/nein
   bool  useVolumeFilter;     // Volumen-/Stärke-Filter ja/nein
   bool  useStrongTrendFilter;// stärkerer Trendfilter ja/nein
   bool  useIchimokuBoost;    // Ichimoku wichtig ja/nein
   bool  useCCIWeak;          // CCI geringer gewichtet ja/nein
   int   trailingSetId;       // 0,1,2 -> wählt Trailing-Profil
   int   scoreProfileId;      // 0,1,2 -> unterschiedliche Score-Schwellen/Profil
};

struct VariantStats
{
   int    variantId;
   int    trades;
   int    wins;
   double pnl;         // Summe Profit in Geld
   double lastReward;
};

struct TrailingSet
{
   int    id;
   double startR;      // ab wie vielen R (Risk-Multiples) Trailing starten
   double stepR;       // wie viel R der SL nachgezogen wird
};

struct ScoreProfile
{
   int    id;
   double offsetLong;  // Offset zum Basiswert für LONG
   double offsetShort; // Offset zum Basiswert für SHORT
};

// VARIANT: presets
StrategyVariant g_variants[];
VariantStats    g_variantStats[];
TrailingSet     g_trailingSets[3];
ScoreProfile    g_scoreProfiles[3];
int             g_currentVariantId = 1;  // aktive Variante
RegimeContext   g_lastRegimeCtx = {REGIME_TREND_RANGE,REGIME_VOL_MID,REGIME_SES_ASIA,REGIME_STR_MID,0};
IndicatorScoreBreakdown g_lastIndicatorScoreLong = {0};
IndicatorScoreBreakdown g_lastIndicatorScoreShort = {0};
IndicatorRegimeStat g_indStats[];

// Forward declarations
void LearningStoreTradeContext(ulong ticket,const EntrySnapshot &snap,double entryPrice,double sl,double tp);
void LearningRegisterPendingOrder(ulong orderTicket,const EntrySnapshot &snap);
void EvaluateClosedTrade(ulong ticket,double exitPrice,double profitPts,double profitMoney,string reason,datetime exitTime);
void ApplyLearningAdjustments();
void ApplyIndicatorLearningAdjustments();
// VARIANT: forward declarations
void VariantInitPresets();
int ChooseVariantForNextTrade();
int VariantEnsureStats(int variantId);
void VariantUpdateStats(int variantId,double profitMoney);
StrategyVariant VariantGetById(int variantId);
TrailingSet TrailingGetSetById(int id);
ScoreProfile ScoreGetProfileById(int id);
// REGIME: helpers
int DetectTrendRegime(double &ema50,double &ema200,double &adxValue);
int DetectVolRegime(double atrWork,double atrDaily,double price);
int DetectSession();
int DetectStructurePosition(double price);
int BuildRegimeId(int trend,int vol,int session,int structure);
RegimeContext BuildRegimeContext(void);
// INDLEARN: helpers
void ResetIndicatorBreakdown(IndicatorScoreBreakdown &out);
int LearningFindScoreStat(double band,int dir,int regimeId);
int LearningEnsureScoreStat(double band,int dir,int regimeId);
int IndStatEnsure(int indicatorId,int regimeId);
double IndGetShift(int indicatorId,int regimeId);
double GetIndicatorPhaseWeight(string name,int trendPhase,int volLevel,int sessionBucket,int direction);
void IndicatorUpdateSingle(int indicatorId,int regimeId,double rMultiple);
void IndicatorUpdateFromTrade(const TradeContextEntry &ctx,double rMultiple);
bool LoadIndicatorStatsFromFile();
bool SaveIndicatorStatsToFile();
// MONITOR: helpers
void MonitorEnsureFile();
void MonitorWriteSnapshot();
string MonitorTrendLabel(int trend);
string MonitorVolLabel(int vol);
string MonitorFormatTimestamp(datetime t);

// ==============================
// ===== LEARNING HELPERS =======
// ==============================
double LearningScoreBand(double qa)
{
   return MathFloor(qa*2.0)/2.0;
}

// REGIME: detection helpers
int DetectTrendRegime(double &ema50,double &ema200,double &adxValue)
{
   ema50=0.0; ema200=0.0; adxValue=0.0;
   bool emaOk50=EMA(hEMA_H1_50,ema50,0);
   bool emaOk200=EMA(hEMA_H1_200,ema200,0);
   bool adxOk=ADX(adxValue);
   if(!(emaOk50 && emaOk200) || !adxOk) return REGIME_TREND_RANGE;
   if(adxValue < InpADX_Moderate) return REGIME_TREND_RANGE;
   if(ema50>ema200) return REGIME_TREND_UP;
   if(ema50<ema200) return REGIME_TREND_DOWN;
   return REGIME_TREND_RANGE;
}

int DetectVolRegime(double atrWork,double atrDaily,double price)
{
   double ratio=0.0;
   if(atrDaily>0.0) ratio = atrWork/atrDaily;
   else if(price>0.0) ratio = atrWork/price;
   if(ratio<=InpRegimeVolLowRatio) return REGIME_VOL_LOW;
   if(ratio>=InpRegimeVolHighRatio) return REGIME_VOL_HIGH;
   return REGIME_VOL_MID;
}

int DetectSession()
{
   MqlDateTime tm; TimeToStruct(TimeCurrent(),tm);
   if(tm.hour>=0 && tm.hour<8)  return REGIME_SES_ASIA;
   if(tm.hour>=8 && tm.hour<16) return REGIME_SES_LONDON;
   if(tm.hour>=16 && tm.hour<22) return REGIME_SES_NY;
   return REGIME_SES_OFF;
}

int DetectStructurePosition(double price)
{
   if(price<=0.0) return REGIME_STR_MID;
   int lookback = MathMax(10,InpStructureLookbackBars);
   double highest=0.0, lowest=0.0;
   bool hasHigh=false, hasLow=false;
   for(int i=1;i<=lookback;i++)
   {
      double h=iHigh(g_symbol,PERIOD_M15,i);
      double l=iLow(g_symbol,PERIOD_M15,i);
      if(h>0.0)
      {
         if(!hasHigh || h>highest){ highest=h; hasHigh=true; }
      }
      if(l>0.0)
      {
         if(!hasLow || l<lowest){ lowest=l; hasLow=true; }
      }
   }
   if(!(hasHigh && hasLow) || highest<=lowest) return REGIME_STR_MID;
   double pos = (price-lowest)/(highest-lowest);
   double hiThresh = Clamp(InpStructureNearHighPct,0.2,0.95);
   double loThresh = Clamp(InpStructureNearLowPct,0.05,0.8);
   if(pos>=hiThresh) return REGIME_STR_NEAR_HIGH;
   if(pos<=loThresh) return REGIME_STR_NEAR_LOW;
   return REGIME_STR_MID;
}

int BuildRegimeId(int trend,int vol,int session,int structure)
{
   int t = (trend==REGIME_TREND_UP?2:(trend==REGIME_TREND_DOWN?0:1));
   return t + (vol*10) + (session*100) + (structure*1000);
}

RegimeContext BuildRegimeContext()
{
   RegimeContext ctx;
   double ema50=0.0, ema200=0.0, adxValue=0.0;
   double atrWork=0.0; ATR(atrWork);
   // STABILITY: iATR returns handle, need to get value via CopyBuffer
   int hD1 = iATR(g_symbol,PERIOD_D1,InpATR_Period);
   double atrDaily = 0.0;
   if(hD1 != INVALID_HANDLE)
   {
      double d1b[]; ArraySetAsSeries(d1b,true);
      if(CopyBuffer(hD1,0,0,1,d1b)>=1) atrDaily = d1b[0];
      IndicatorRelease(hD1);
   }
   double price=(SymbolInfoTick(g_symbol,g_tick)? g_tick.bid : iClose(g_symbol,InpTF_Work,0));
   ctx.trend = DetectTrendRegime(ema50,ema200,adxValue);
   ctx.vol = DetectVolRegime(atrWork,atrDaily,price);
   ctx.session = DetectSession();
   ctx.structure = DetectStructurePosition(price);
   ctx.regimeId = BuildRegimeId(ctx.trend,ctx.vol,ctx.session,ctx.structure);
   return ctx;
}

void ResetIndicatorBreakdown(IndicatorScoreBreakdown &out)
{
   out.ema=0.0; out.adx=0.0; out.rsi=0.0; out.cci=0.0; out.macd=0.0; out.mfi=0.0;
   out.volume=0.0; out.vwap=0.0; out.patterns=0.0; out.ichimoku=0.0;
   out.psar=0.0; out.cpr=0.0; out.m15align=0.0; out.atrBonus=0.0;
}

// STRUCTURE: capture latest swings and broader range context
void ComputeStructureContext(EntrySnapshot &snap)
{
   snap.lastSwingHigh=0.0;
   snap.lastSwingLow=0.0;
   snap.distToSwingHighPts=0.0;
   snap.distToSwingLowPts=0.0;
   snap.recentHigh=0.0;
   snap.recentLow=0.0;
   snap.distToRecentHighPts=0.0;
   snap.distToRecentLowPts=0.0;

   ENUM_TIMEFRAMES tf=InpTF_Work;
   int swingLookback=120;
   for(int i=1;i<swingLookback;i++)
   {
      double h=iHigh(g_symbol,tf,i);
      double prev=iHigh(g_symbol,tf,i+1);
      double next=iHigh(g_symbol,tf,i-1);
      if(h==0.0 || prev==0.0 || next==0.0) continue;
      if(h>prev && h>next){ snap.lastSwingHigh=h; break; }
   }
   for(int i=1;i<swingLookback;i++)
   {
      double l=iLow(g_symbol,tf,i);
      double prev=iLow(g_symbol,tf,i+1);
      double next=iLow(g_symbol,tf,i-1);
      if(l==0.0 || prev==0.0 || next==0.0) continue;
      if(l<prev && l<next){ snap.lastSwingLow=l; break; }
   }

   ENUM_TIMEFRAMES rangeTf=PERIOD_M15;
   int rangeLookback=MathMax(10,InpStructureLookbackBars);
   double maxRecent=0.0, minRecent=0.0;
   bool hasHigh=false,hasLow=false;
   for(int i=1;i<=rangeLookback;i++)
   {
      double h=iHigh(g_symbol,rangeTf,i);
      double l=iLow(g_symbol,rangeTf,i);
      if(h>0.0){ if(!hasHigh || h>maxRecent){ maxRecent=h; hasHigh=true; } }
      if(l>0.0){ if(!hasLow || l<minRecent){ minRecent=l; hasLow=true; } }
   }
   if(hasHigh) snap.recentHigh=maxRecent;
   if(hasLow) snap.recentLow=minRecent;

   double refPrice=0.0;
   if(SymbolInfoTick(g_symbol,g_tick))
      refPrice = (snap.direction=="LONG"? g_tick.ask : g_tick.bid);
   if(refPrice<=0.0) refPrice=iClose(g_symbol,tf,0);
   if(refPrice<=0.0 || g_point<=0.0) return;

   if(snap.lastSwingHigh>0.0)
      snap.distToSwingHighPts = (snap.lastSwingHigh-refPrice)/g_point;
   if(snap.lastSwingLow>0.0)
      snap.distToSwingLowPts = (refPrice-snap.lastSwingLow)/g_point;
   if(snap.recentHigh>0.0)
      snap.distToRecentHighPts = (snap.recentHigh-refPrice)/g_point;
   if(snap.recentLow>0.0)
      snap.distToRecentLowPts = (refPrice-snap.recentLow)/g_point;
}

// PHASE-LEARNING: market phase detection helpers
int DetectTrendPhase()
{
   double ema50=0.0, ema200=0.0;
   if(!EMA(hEMA_H1_50,ema50,0) || !EMA(hEMA_H1_200,ema200,0))
      return TREND_SIDEWAYS;
   double adx=0.0;
   if(!ADX(adx) || adx<InpADX_Moderate)
      return TREND_SIDEWAYS;
   if(ema50 > ema200)
      return TREND_UP;
   if(ema50 < ema200)
      return TREND_DOWN;
   return TREND_SIDEWAYS;
}

int DetectVolatilityLevel()
{
   double atrM1=0.0;
   if(!ATR(atrM1) || atrM1<=0.0)
      return VOL_MEDIUM;
   int hD1=iATR(g_symbol,PERIOD_D1,InpATR_Period);
   if(hD1==INVALID_HANDLE)
      return VOL_MEDIUM;
   double d1b[]; ArraySetAsSeries(d1b,true);
   bool ok = CopyBuffer(hD1,0,0,1,d1b)>=1;
   IndicatorRelease(hD1);
   if(!ok || d1b[0]<=0.0)
      return VOL_MEDIUM;
   double ratio = atrM1 / d1b[0];
   if(ratio < InpPhaseVolLowThresh)
      return VOL_LOW;
   if(ratio > InpPhaseVolHighThresh)
      return VOL_HIGH;
   return VOL_MEDIUM;
}

int DetectSessionBucket()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(),tm);
   int hour = tm.hour;
   if(hour>=0 && hour<=7)
      return SESSION_ASIA;
   if(hour>=8 && hour<=15)
      return SESSION_EUROPE;
   if(hour>=16 && hour<=23)
      return SESSION_US;
   return SESSION_ASIA; // fallback
}

void DetectHighLowContext(EntrySnapshot &snap)
{
   snap.distToLastHigh = 0.0;
   snap.distToLastLow = 0.0;
   snap.nearHigh = false;
   snap.nearLow = false;
   
   ENUM_TIMEFRAMES tf = InpTF_Work;
   int lookback = MathMax(10,InpPhaseHighLowLookback);
   double maxHigh = 0.0, minLow = 0.0;
   bool hasHigh = false, hasLow = false;
   
   for(int i=1; i<=lookback; i++)
   {
      double h = iHigh(g_symbol,tf,i);
      double l = iLow(g_symbol,tf,i);
      if(h>0.0)
      {
         if(!hasHigh || h>maxHigh)
         {
            maxHigh = h;
            hasHigh = true;
         }
      }
      if(l>0.0)
      {
         if(!hasLow || l<minLow || minLow==0.0)
         {
            minLow = l;
            hasLow = true;
         }
      }
   }
   
   if(!hasHigh || !hasLow)
      return;
   
   double currentPrice = 0.0;
   if(SymbolInfoTick(g_symbol,g_tick))
      currentPrice = (snap.direction=="LONG"? g_tick.ask : g_tick.bid);
   if(currentPrice<=0.0)
      currentPrice = iClose(g_symbol,tf,0);
   if(currentPrice<=0.0)
      return;
   
   // STABILITY: check g_point before division
   if(g_point>0.0)
   {
      snap.distToLastHigh = MathAbs(maxHigh - currentPrice) / g_point;
      snap.distToLastLow = MathAbs(currentPrice - minLow) / g_point;
      
      double atr=0.0;
      if(ATR(atr) && atr>0.0)
      {
         double threshold = InpPhaseNearHL_ATR * atr / g_point;
         snap.nearHigh = (snap.distToLastHigh < threshold);
         snap.nearLow = (snap.distToLastLow < threshold);
      }
   }
}

string LearningStatsFileName()
{
   // Einheitlicher Dateiname – niemals pro Tag ändern
   if(g_learningStatsFile == "")
   {
      g_learningStatsFile = "xauusd_learning_stats.csv";  
   }
   return g_learningStatsFile;
}


// INDLEARN: persistence helper
string IndicatorStatsFileName()
{
   if(g_indicatorStatsFile=="")
      g_indicatorStatsFile = InpLogFilePrefix + "_ind_stats.csv";
   return g_indicatorStatsFile;
}

void LearningWriteStatsHeader(const int handle)
{
   FileWrite(handle,
             "Direction",
             "ScoreBand",
             "RegimeId",
             "Trades",
             "Wins",
             "SumPnl",
             "Shift",
             "LastAdjustDay",
             "LossStreak",
             "WeightedPnlSum",
             "WeightedAvg",
             "ExitTrades",
             "ExitSumEfficiency",
             "ExitAvgEfficiency",
             "ExitShift");
}

void LearningEnsureStatsFile()
{
   string fn = LearningStatsFileName();
   if(FileIsExist(fn)) return;
   int h = FileOpen(fn,CSV_RW_FLAGS,';');
   if(h==INVALID_HANDLE) return;
   LearningWriteStatsHeader(h);
   FileClose(h);
}

// ROBUSTER CSV READER – kompatibel mit allen Learning-Dateien
int LearningReadCsvRow(int h, string &columns[])
{
   if(h == INVALID_HANDLE)
      return 0;

   string raw = FileReadString(h);
   if(StringLen(raw) < 1)
      return 0;

   // Normalize line breaks
   StringReplace(raw, "\r", "");
   StringReplace(raw, "\n", "");

   // Manual parsing: safer than StringSplit()
   string tmp = "";
   string items[];
   int count = 0;

   for(int i = 0; i < StringLen(raw); i++)
   {
      uchar ch = raw[i];

      if(ch == ';')  // delimiter
      {
         ArrayResize(items, count+1);
         items[count] = tmp;
         count++;
         tmp = "";
      }
      else
      {
         tmp += (string)ch;
      }
   }

   // add last column
   ArrayResize(items, count+1);
   items[count] = tmp;

   // Trim spaces
   for(int n = 0; n < ArraySize(items); n++)
   {
      StringTrimLeft(items[n]);
      StringTrimRight(items[n]);
   }

   // Output
   ArrayResize(columns, ArraySize(items));
   for(int n=0; n<ArraySize(items); n++)
      columns[n] = items[n];

   return ArraySize(columns);
}

// VARIANT: presets initialization
void VariantInitPresets()
{
   // TrailingSets initialisieren
   g_trailingSets[0].id = 0;
   g_trailingSets[0].startR = 1.0;  // konservativ: ab 1.0 R
   g_trailingSets[0].stepR = 0.5;   // Schritt: 0.5 R
   
   g_trailingSets[1].id = 1;
   g_trailingSets[1].startR = 0.7;  // aggressiv: ab 0.7 R
   g_trailingSets[1].stepR = 0.3;   // Schritt: 0.3 R
   
   g_trailingSets[2].id = 2;
   g_trailingSets[2].startR = 1.5;  // spät, aber eng: ab 1.5 R
   g_trailingSets[2].stepR = 0.2;   // Schritt: 0.2 R
   
   // ScoreProfiles initialisieren
   g_scoreProfiles[0].id = 0;
   g_scoreProfiles[0].offsetLong = 0.0;   // Standard: Basiswert
   g_scoreProfiles[0].offsetShort = 0.0;
   
   g_scoreProfiles[1].id = 1;
   g_scoreProfiles[1].offsetLong = 0.3;   // konservativ: +0.3
   g_scoreProfiles[1].offsetShort = 0.3;
   
   g_scoreProfiles[2].id = 2;
   g_scoreProfiles[2].offsetLong = -0.3;  // aggressiv: -0.3
   g_scoreProfiles[2].offsetShort = -0.3;
   
   // StrategyVariants initialisieren
   ArrayResize(g_variants,4);
   
   // Variante 1: Standard-Profil
   g_variants[0].id = 1;
   g_variants[0].usePatterns = false;
   g_variants[0].useVolumeFilter = true;
   g_variants[0].useStrongTrendFilter = false;
   g_variants[0].useIchimokuBoost = false;
   g_variants[0].useCCIWeak = false;
   g_variants[0].trailingSetId = 0;
   g_variants[0].scoreProfileId = 0;
   
   // Variante 2: Stärkerer Trendfilter, weniger CCI
   g_variants[1].id = 2;
   g_variants[1].usePatterns = false;
   g_variants[1].useVolumeFilter = true;
   g_variants[1].useStrongTrendFilter = true;
   g_variants[1].useIchimokuBoost = true;
   g_variants[1].useCCIWeak = true;
   g_variants[1].trailingSetId = 1;
   g_variants[1].scoreProfileId = 1;
   
   // Variante 3: Ohne Volumenfilter, höhere Score-Schwelle
   g_variants[2].id = 3;
   g_variants[2].usePatterns = false;
   g_variants[2].useVolumeFilter = false;
   g_variants[2].useStrongTrendFilter = true;
   g_variants[2].useIchimokuBoost = false;
   g_variants[2].useCCIWeak = false;
   g_variants[2].trailingSetId = 0;
   g_variants[2].scoreProfileId = 2;
   
   // Variante 4: Mit Patterns
   g_variants[3].id = 4;
   g_variants[3].usePatterns = true;
   g_variants[3].useVolumeFilter = true;
   g_variants[3].useStrongTrendFilter = false;
   g_variants[3].useIchimokuBoost = true;
   g_variants[3].useCCIWeak = false;
   g_variants[3].trailingSetId = 2;
   g_variants[3].scoreProfileId = 1;
   
   g_currentVariantId = 1; // Standard starten
}

// VARIANT: helper functions
StrategyVariant VariantGetById(int variantId)
{
   for(int i=0;i<ArraySize(g_variants);i++)
      if(g_variants[i].id==variantId) return g_variants[i];
   return g_variants[0]; // Fallback: Variante 1
}

TrailingSet TrailingGetSetById(int id)
{
   if(id>=0 && id<3) return g_trailingSets[id];
   return g_trailingSets[0]; // Fallback
}

ScoreProfile ScoreGetProfileById(int id)
{
   if(id>=0 && id<3) return g_scoreProfiles[id];
   return g_scoreProfiles[0]; // Fallback
}

int VariantEnsureStats(int variantId)
{
   for(int i=0;i<ArraySize(g_variantStats);i++)
      if(g_variantStats[i].variantId==variantId) return i;
   int idx=ArraySize(g_variantStats);
   ArrayResize(g_variantStats,idx+1);
   g_variantStats[idx].variantId=variantId;
   g_variantStats[idx].trades=0;
   g_variantStats[idx].wins=0;
   g_variantStats[idx].pnl=0.0;
   g_variantStats[idx].lastReward=0.0;
   return idx;
}

// VARIANT: stats update
void VariantUpdateStats(int variantId,double profitMoney)
{
   int idx=VariantEnsureStats(variantId);
   g_variantStats[idx].trades++;
   if(profitMoney>0.0) g_variantStats[idx].wins++;
   g_variantStats[idx].pnl+=profitMoney;
   g_variantStats[idx].lastReward=profitMoney;
}

// VARIANT: selection
int ChooseVariantForNextTrade()
{
   int totalTrades=0;
   for(int i=0;i<ArraySize(g_variantStats);i++)
      totalTrades+=g_variantStats[i].trades;
   
   // Wenn noch wenig Daten: gleichmäßig verteilen
   if(totalTrades<20)
   {
      int variantCount=ArraySize(g_variants);
      if(variantCount==0) return 1;
      int idx = (int)(totalTrades % variantCount);
      return g_variants[idx].id;
   }
   
   // Genug Daten: Exploitation (80-90%) + Exploration (10-20%)
   double rand = MathRand()/(double)32767.0;
   if(rand < 0.15) // 15% Exploration
   {
      int variantCount=ArraySize(g_variants);
      if(variantCount==0) return 1;
      int idx = (int)(MathRand() % variantCount);
      return g_variants[idx].id;
   }
   
   // 85% Exploitation: beste Variante wählen
   int bestVariantId=1;
   double bestScore=-1e10;
   for(int i=0;i<ArraySize(g_variantStats);i++)
   {
      if(g_variantStats[i].trades<5) continue; // Mindestanzahl
      double score = g_variantStats[i].pnl; // oder pnl/trades
      if(score>bestScore)
      {
         bestScore=score;
         bestVariantId=g_variantStats[i].variantId;
      }
   }
   return bestVariantId;
}

int LearningFindTradeContext(ulong ticket)
{
   for(int i=0;i<ArraySize(g_tradeContexts);i++)
      if(g_tradeContexts[i].active && g_tradeContexts[i].ticket==ticket) return i;
   return -1;
}

int LearningFindPendingOrder(ulong orderTicket)
{
   for(int i=0;i<ArraySize(g_pendingOrders);i++)
      if(g_pendingOrders[i].active && g_pendingOrders[i].orderTicket==orderTicket) return i;
   return -1;
}

EntrySnapshot BuildEntrySnapshot(string direction,double qL,double qS,double qaL,double qaS,double dirStrength,int cats,bool htfok)
{
   EntrySnapshot snap;
   ZeroMemory(snap);
   snap.valid = true;
   snap.direction = direction;
   snap.time = TimeCurrent();
   snap.mode = (int)g_mode;
   snap.timeframe = (int)InpTF_Work;
   snap.spreadPts = (SymbolInfoTick(g_symbol,g_tick)? (g_tick.ask-g_tick.bid)/g_point : 0.0);
   double atr=0; ATR(atr); snap.atr=atr;
   snap.qL=qL; snap.qS=qS; snap.qaL=qaL; snap.qaS=qaS;
   snap.dirStrength=dirStrength;
   snap.cats=cats;
   snap.htfok=htfok;
   double rsi=0; RSI(hRSI_M1_14,rsi); snap.rsi=rsi;
   double macd=0; MACD_H(macd); snap.macd=macd;
   double cci=0; CCI(cci); snap.cci=cci;
   double adx=0; ADX(adx); snap.adx=adx;
   double mfi=0; MFI(mfi); snap.mfi=mfi;
   snap.volumeScore = VolumeSpike()?1.0:0.0;
   double ikhLong=0, ikhShort=0; string ikhNote="";
   IchimokuScore(ikhLong,ikhShort,ikhNote);
   snap.ichimokuLong=ikhLong;
   snap.ichimokuShort=ikhShort;
   snap.entryPricePlan=0.0;
   snap.slPlan=0.0;
   snap.tpPlan=0.0;
   // LEARNING: Filter-Flags setzen
   bool fTrend=false, fStrength=false, fMomentum=false; int dummyCats=0; bool dummyHTF=false; string dummyNote="";
   EvaluateMainFilter(fTrend,fStrength,fMomentum,dummyCats,dummyHTF,dummyNote);
   snap.filterTrendOK = fTrend;
   snap.filterStrengthOK = fStrength;
   snap.filterMomentumOK = fMomentum;
   snap.filterVolumeOK = VolumeSpike();
   snap.filterSessionOK = InTradeWindow();
   RegimeContext ctx = g_lastRegimeCtx;
   snap.regimeId = ctx.regimeId;
   snap.regimeTrend = ctx.trend;
   snap.regimeVol = ctx.vol;
   snap.regimeSession = ctx.session;
   snap.regimeStructure = ctx.structure;
   
   // PHASE-LEARNING: market phase context
   snap.trendPhase = DetectTrendPhase();
   snap.volLevel = DetectVolatilityLevel();
   snap.sessionBucket = DetectSessionBucket();
   DetectHighLowContext(snap);
   
   // PATTERN: context fields - Pattern-Infos setzen
   StrategyVariant var = VariantGetById(g_currentVariantId);
   if(InpEnablePatterns && var.usePatterns)
   {
      DetectedPattern p = PatternDetectBest(InpTF_Work);
      snap.hasPattern = (p.type != PATTERN_NONE);
      snap.patternName = p.name;
      snap.patternScore = (direction=="LONG"?p.scoreLong:p.scoreShort);
      snap.patternStrength = p.strength;
      // PATTERN: filterPatternOK basierend auf neuem Pattern-System
      snap.filterPatternOK = snap.hasPattern;
   }
   else
   {
      snap.hasPattern = false;
      snap.patternName = "";
      snap.patternScore = 0.0;
      snap.patternStrength = 0.0;
      snap.filterPatternOK = false;
   }
   
   // LEARNING: Reason-Text zusammenbauen
   snap.reasonText = "";
   if(fTrend) snap.reasonText += "Trend ";
   if(fStrength) snap.reasonText += "Strength ";
   if(fMomentum) snap.reasonText += "Momentum ";
   if(snap.filterVolumeOK) snap.reasonText += "VolSpike ";
   if(snap.hasPattern) snap.reasonText += "Pattern:"+snap.patternName+" ";
   if(direction=="LONG" && ikhLong>0) snap.reasonText += "IKH+"+DoubleToString(ikhLong,1)+" ";
   if(direction=="SHORT" && ikhShort>0) snap.reasonText += "IKH+"+DoubleToString(ikhShort,1)+" ";
   if(rsi>55 && direction=="LONG") snap.reasonText += "RSI>55 ";
   if(rsi<45 && direction=="SHORT") snap.reasonText += "RSI<45 ";
   snap.reasonText += StringFormat(" Regime:%d-%d-%d-%d",snap.regimeTrend,snap.regimeVol,snap.regimeSession,(int)snap.regimeStructure);
   StringTrimRight(snap.reasonText);
   IndicatorScoreBreakdown indSrc = (direction=="LONG"?g_lastIndicatorScoreLong:g_lastIndicatorScoreShort);
   snap.indScore_EMA = indSrc.ema;
   snap.indScore_ADX = indSrc.adx;
   snap.indScore_RSI = indSrc.rsi;
   snap.indScore_CCI = indSrc.cci;
   snap.indScore_MACD = indSrc.macd;
   snap.indScore_MFI = indSrc.mfi;
   snap.indScore_Volume = indSrc.volume;
   snap.indScore_VWAP = indSrc.vwap;
   snap.indScore_Patterns = indSrc.patterns;
   snap.indScore_Ichimoku = indSrc.ichimoku;
   snap.indScore_PSAR = indSrc.psar;
   snap.indScore_CPR = indSrc.cpr;
   snap.indScore_M15Align = indSrc.m15align;
   snap.indScore_ATRBonus = indSrc.atrBonus;
    ComputeStructureContext(snap);
   return snap;
}

void LearningStoreTradeContext(ulong ticket,const EntrySnapshot &snap,double entryPrice,double sl,double tp)
{
   if(ticket==0 || !snap.valid) return;
   int idx=LearningFindTradeContext(ticket);
   if(idx<0){
      idx=ArraySize(g_tradeContexts);
      ArrayResize(g_tradeContexts,idx+1);
   }
   g_tradeContexts[idx].active=true;
   g_tradeContexts[idx].ticket=ticket;
   g_tradeContexts[idx].snap=snap;
   g_tradeContexts[idx].entryTime=TimeCurrent();
   g_tradeContexts[idx].entryPrice=entryPrice;
   g_tradeContexts[idx].plannedSL=sl;
   g_tradeContexts[idx].plannedTP=tp;
   g_tradeContexts[idx].mfePts=0.0;
   g_tradeContexts[idx].maePts=0.0;
   g_tradeContexts[idx].exitReason="";
   // VARIANT + LEARNING: integration - variantId und paramSetId setzen
   g_tradeContexts[idx].variantId = g_currentVariantId;
   StrategyVariant var = VariantGetById(g_currentVariantId);
   g_tradeContexts[idx].paramSetId = var.scoreProfileId * 10 + var.trailingSetId; // Kombination
}

void LearningRegisterPendingOrder(ulong orderTicket,const EntrySnapshot &snap)
{
   if(orderTicket==0 || !snap.valid) return;
   int idx=LearningFindPendingOrder(orderTicket);
   if(idx<0){
      idx=ArraySize(g_pendingOrders);
      ArrayResize(g_pendingOrders,idx+1);
   }
   g_pendingOrders[idx].active=true;
   g_pendingOrders[idx].orderTicket=orderTicket;
   g_pendingOrders[idx].snap=snap;
}

EntrySnapshot LearningConsumePendingOrder(ulong orderTicket,bool &found)
{
   EntrySnapshot snap; snap.valid=false;
   int idx=LearningFindPendingOrder(orderTicket);
   if(idx>=0){
      snap=g_pendingOrders[idx].snap;
      g_pendingOrders[idx].active=false;
      found=true;
   } else {
      found=false;
   }
   return snap;
}

void LearningEnsureCsv()
{
    // Standard-Dateiname setzen
    if (g_learningCsv == "" || StringLen(g_learningCsv) < 4)
        g_learningCsv = InpLogFilePrefix + "learning_full.csv";

    // Wenn Datei existiert → NICHTS machen
    if (FileIsExist(g_learningCsv))
        return;

    // Datei neu anlegen
    int h = FileOpen(g_learningCsv, FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
    if (h == INVALID_HANDLE)
    {
        Print("[Learning] ERROR: Cannot create CSV: ", g_learningCsv);
        return;
    }

    // Header schreiben (einmalig)
    string header =
        "Ticket;EntryTime;ExitTime;Direction;Mode;TF;Spread;ATR;"
        "qaL;qaS;DirStrength;Cats;HTF;RSI;MACD;CCI;ADX;MFI;"
        "VolSpike;IKH_Long;IKH_Short;FilterTrend;FilterStrength;"
        "FilterMomentum;FilterVolume;FilterPattern;FilterSession;"
        "RegimeTrend;RegimeVol;RegimeSession;RegimeStructure;"
        "RegimeId;LastSwingHigh;LastSwingLow;DistSwingHigh;DistSwingLow;"
        "RecentHigh;RecentLow;DistRecentHigh;DistRecentLow;"
        "TrendPhase;VolLevel;SessionBucket;"
        "DistLastHigh;DistLastLow;NearHigh;NearLow;"
        "Ind_EMA;Ind_ADX;Ind_RSI;Ind_CCI;Ind_MACD;Ind_MFI;"
        "Ind_Volume;Ind_VWAP;Ind_Patterns;Ind_Ichimoku;Ind_PSAR;"
        "Ind_CPR;Ind_M15Align;Ind_ATRBonus;"
        "VariantId;ParamSetId;HasPattern;PatternName;PatternScore;"
        "PatternStrength;EntryPrice;ExitPrice;ProfitPts;ProfitMoney;"
        "DurationMin;MFE;MAE;Reason;ReasonText;"
        "LossStreak;WeightedPnlSum;WeightedAvg";

    FileWriteString(h, header + "\n");

    // Datei schließen — WICHTIG!
    FileClose(h);
}


void CsvAppend(string &line,const string value)
{
   if(StringLen(line)>0) line+=";";
   line+=value;
   }
void LearningWriteCsv(const TradeContextEntry &ctx,
                      double exitPrice,
                      double profitPts,
                      double profitMoney,
                      string reason,
                      datetime exitTime,
                      double duration)
{
    // Header sicherstellen
    LearningEnsureCsv();

    // Datei im reinen Append-Mode öffnen (robusteste Variante!)
    int h = FileOpen(g_learningCsv, FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
    if (h == INVALID_HANDLE)
    {
        Print("[Learning] ERROR: Cannot open for append: ", g_learningCsv);
        return;
    }

    // Zum Ende springen (Sicherheit, falls MT5 nicht selbst anhängt)
    FileSeek(h, 0, SEEK_END);

    string line = "";

    // CSV-Daten anhängen
    CsvAppend(line, IntegerToString((long)ctx.ticket));
    CsvAppend(line, TimeToString(ctx.entryTime, TIME_DATE | TIME_MINUTES));
    CsvAppend(line, TimeToString(exitTime, TIME_DATE | TIME_MINUTES));
    CsvAppend(line, ctx.snap.direction);
    CsvAppend(line, IntegerToString(ctx.snap.mode));
    CsvAppend(line, IntegerToString(ctx.snap.timeframe));
    CsvAppend(line, DoubleToString(ctx.snap.spreadPts, 2));
    CsvAppend(line, DoubleToString(ctx.snap.atr, 2));
    CsvAppend(line, DoubleToString(ctx.snap.qaL, 2));
    CsvAppend(line, DoubleToString(ctx.snap.qaS, 2));
    CsvAppend(line, DoubleToString(ctx.snap.dirStrength, 2));
    CsvAppend(line, IntegerToString(ctx.snap.cats));
    CsvAppend(line, IntegerToString((int)ctx.snap.htfok));
    CsvAppend(line, DoubleToString(ctx.snap.rsi, 2));
    CsvAppend(line, DoubleToString(ctx.snap.macd, 2));
    CsvAppend(line, DoubleToString(ctx.snap.cci, 2));
    CsvAppend(line, DoubleToString(ctx.snap.adx, 2));
    CsvAppend(line, DoubleToString(ctx.snap.mfi, 2));
    CsvAppend(line, DoubleToString(ctx.snap.volumeScore, 2));
    CsvAppend(line, DoubleToString(ctx.snap.ichimokuLong, 2));
    CsvAppend(line, DoubleToString(ctx.snap.ichimokuShort, 2));

    CsvAppend(line, IntegerToString((int)ctx.snap.filterTrendOK));
    CsvAppend(line, IntegerToString((int)ctx.snap.filterStrengthOK));
    CsvAppend(line, IntegerToString((int)ctx.snap.filterMomentumOK));
    CsvAppend(line, IntegerToString((int)ctx.snap.filterVolumeOK));
    CsvAppend(line, IntegerToString((int)ctx.snap.filterPatternOK));
    CsvAppend(line, IntegerToString((int)ctx.snap.filterSessionOK));

    CsvAppend(line, IntegerToString(ctx.snap.regimeTrend));
    CsvAppend(line, IntegerToString(ctx.snap.regimeVol));
    CsvAppend(line, IntegerToString(ctx.snap.regimeSession));
    CsvAppend(line, IntegerToString((int)ctx.snap.regimeStructure));
    CsvAppend(line, IntegerToString(ctx.snap.regimeId));

    CsvAppend(line, DoubleToString(ctx.snap.lastSwingHigh, 2));
    CsvAppend(line, DoubleToString(ctx.snap.lastSwingLow, 2));
    CsvAppend(line, DoubleToString(ctx.snap.distToSwingHighPts, 2));
    CsvAppend(line, DoubleToString(ctx.snap.distToSwingLowPts, 2));
    CsvAppend(line, DoubleToString(ctx.snap.recentHigh, 2));
    CsvAppend(line, DoubleToString(ctx.snap.recentLow, 2));
    CsvAppend(line, DoubleToString(ctx.snap.distToRecentHighPts, 2));
    CsvAppend(line, DoubleToString(ctx.snap.distToRecentLowPts, 2));

    CsvAppend(line, IntegerToString(ctx.snap.trendPhase));
    CsvAppend(line, IntegerToString(ctx.snap.volLevel));
    CsvAppend(line, IntegerToString(ctx.snap.sessionBucket));

    CsvAppend(line, DoubleToString(ctx.snap.distToLastHigh, 2));
    CsvAppend(line, DoubleToString(ctx.snap.distToLastLow, 2));
    CsvAppend(line, IntegerToString((int)ctx.snap.nearHigh));
    CsvAppend(line, IntegerToString((int)ctx.snap.nearLow));

    CsvAppend(line, DoubleToString(ctx.snap.indScore_EMA, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_ADX, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_RSI, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_CCI, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_MACD, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_MFI, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_Volume, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_VWAP, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_Patterns, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_Ichimoku, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_PSAR, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_CPR, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_M15Align, 2));
    CsvAppend(line, DoubleToString(ctx.snap.indScore_ATRBonus, 2));

    CsvAppend(line, IntegerToString(ctx.variantId));
    CsvAppend(line, IntegerToString(ctx.paramSetId));
    CsvAppend(line, IntegerToString((int)ctx.snap.hasPattern));
    CsvAppend(line, ctx.snap.patternName);
    CsvAppend(line, DoubleToString(ctx.snap.patternScore, 2));
    CsvAppend(line, DoubleToString(ctx.snap.patternStrength, 2));

    CsvAppend(line, DoubleToString(ctx.entryPrice, 2));
    CsvAppend(line, DoubleToString(exitPrice, 2));
    CsvAppend(line, DoubleToString(profitPts, 2));
    CsvAppend(line, DoubleToString(profitMoney, 2));
    CsvAppend(line, DoubleToString(duration, 2));
    CsvAppend(line, DoubleToString(ctx.mfePts, 2));
    CsvAppend(line, DoubleToString(ctx.maePts, 2));
    CsvAppend(line, reason);
    CsvAppend(line, ctx.snap.reasonText);

    FileWriteString(h, line + "\n");

    FileClose(h);
}




int LearningFindScoreStat(double band, int dir, int regimeId)
{
   int total = ArraySize(g_scoreStats);
   for(int i = 0; i < total; i++)
   {
      if(g_scoreStats[i].direction == dir &&
         g_scoreStats[i].regimeId == regimeId &&
         MathAbs(g_scoreStats[i].band - band) < 0.0001)
      {
         return i;
      }
   }
   return -1;
}


int LearningEnsureScoreStat(double band, int dir, int regimeId)
{
   // Prüfen, ob es den Eintrag bereits gibt
   int found = LearningFindScoreStat(band, dir, regimeId);
   if(found >= 0)
      return found;

   // Neu anlegen
   int idx = ArraySize(g_scoreStats);
   ArrayResize(g_scoreStats, idx + 1);

   // INITIALISIERUNG EINMALIG
   g_scoreStats[idx].band               = band;
   g_scoreStats[idx].direction          = dir;
   g_scoreStats[idx].regimeId           = regimeId;

   g_scoreStats[idx].trades             = 0;
   g_scoreStats[idx].wins               = 0;
   g_scoreStats[idx].sumPnl             = 0.0;
   g_scoreStats[idx].sumPnlPts          = 0.0;

   g_scoreStats[idx].shift              = 0.0;
   g_scoreStats[idx].todayAccum         = 0.0;
   g_scoreStats[idx].lastAdjustDay      = 0;

   g_scoreStats[idx].lossStreak         = 0;
   g_scoreStats[idx].weightedPnlSum     = 0.0;
   g_scoreStats[idx].weightedAvg        = 0.0;

   g_scoreStats[idx].exitTrades         = 0;
   g_scoreStats[idx].exitSumEfficiency  = 0.0;
   g_scoreStats[idx].exitAvgEfficiency  = 0.0;
   g_scoreStats[idx].exitShift          = 0.0;

   return idx;
}


int IndStatEnsure(int indicatorId, int regimeId)
{
   // EXISTIERENDEN EINTRAG SUCHEN
   for(int i = 0; i < ArraySize(g_indStats); i++)
   {
      if(g_indStats[i].indicatorId == indicatorId &&
         g_indStats[i].regimeId == regimeId)
      {
         return i; // bereits vorhanden
      }
   }

   // NEU ANLEGEN
   int idx = ArraySize(g_indStats);
   ArrayResize(g_indStats, idx + 1);

   g_indStats[idx].indicatorId      = indicatorId;
   g_indStats[idx].regimeId         = regimeId;

   g_indStats[idx].trades           = 0;
   g_indStats[idx].weightedPnlSum   = 0.0;
   g_indStats[idx].weightedAvgR     = 0.0;

   g_indStats[idx].weightShift      = 0.0;
   g_indStats[idx].todayAccum       = 0.0;
   g_indStats[idx].lastAdjustDay    = 0;

   return idx;
}

double IndGetShift(int indicatorId, int regimeId)
{
   // Falls RegimeId ungültig, Standardwert 0 zurück
   if(regimeId < 0)
      return 0.0;

   for(int i = 0; i < ArraySize(g_indStats); i++)
   {
      if(g_indStats[i].indicatorId == indicatorId &&
         g_indStats[i].regimeId == regimeId)
      {
         return g_indStats[i].weightShift;
      }
   }

   // NICHT GEFUNDEN → Standard 0
   return 0.0;
}

// INDLEARN: helper function to update indicator stats
void IndicatorUpdateSingle(int indicatorId,int regimeId,double rMultiple)
{
   if(MathAbs(rMultiple)<1e-6) return;
   int idx=IndStatEnsure(indicatorId,regimeId);
   g_indStats[idx].trades++;
   g_indStats[idx].weightedPnlSum+=rMultiple;
   if(g_indStats[idx].trades>0)
      g_indStats[idx].weightedAvgR = g_indStats[idx].weightedPnlSum / (double)g_indStats[idx].trades;
}

void IndicatorUpdateFromTrade(const TradeContextEntry &ctx,double rMultiple)
{
   if(!InpEnableIndicatorLearning) return;
   // INDLEARN: update per indicator/regime stats based on trade outcome
   if(MathAbs(ctx.snap.indScore_EMA)>=1e-6)
      IndicatorUpdateSingle(CIND_EMA,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_RSI)>=1e-6)
      IndicatorUpdateSingle(CIND_RSI,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_CCI)>=1e-6)
      IndicatorUpdateSingle(CIND_CCI,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_MACD)>=1e-6)
      IndicatorUpdateSingle(CIND_MACD,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_MFI)>=1e-6)
      IndicatorUpdateSingle(CIND_MFI,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_Volume)>=1e-6)
      IndicatorUpdateSingle(CIND_VOLUME,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_VWAP)>=1e-6)
      IndicatorUpdateSingle(CIND_VWAP,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_Patterns)>=1e-6)
      IndicatorUpdateSingle(CIND_PATTERNS,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_Ichimoku)>=1e-6)
      IndicatorUpdateSingle(CIND_ICHIMOKU,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_PSAR)>=1e-6)
      IndicatorUpdateSingle(CIND_PSAR,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_CPR)>=1e-6)
      IndicatorUpdateSingle(CIND_CPR,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_M15Align)>=1e-6)
      IndicatorUpdateSingle(CIND_M15ALIGN,ctx.snap.regimeId,rMultiple);
   if(MathAbs(ctx.snap.indScore_ATRBonus)>=1e-6)
      IndicatorUpdateSingle(CIND_ATR_BONUS,ctx.snap.regimeId,rMultiple);
}

// PHASE-LEARNING: find or create indicator phase stat entry
int FindOrCreateIndPhaseStat(string name,int trendPhase,int volLevel,int sessionBucket,int direction)
{
   for(int i=0; i<ArraySize(g_indPhaseStats); i++)
   {
      if(g_indPhaseStats[i].name == name &&
         g_indPhaseStats[i].trendPhase == trendPhase &&
         g_indPhaseStats[i].volLevel == volLevel &&
         g_indPhaseStats[i].sessionBucket == sessionBucket &&
         g_indPhaseStats[i].direction == direction)
         return i;
   }
   int idx = ArraySize(g_indPhaseStats);
   ArrayResize(g_indPhaseStats,idx+1);
   g_indPhaseStats[idx].name = name;
   g_indPhaseStats[idx].trendPhase = trendPhase;
   g_indPhaseStats[idx].volLevel = volLevel;
   g_indPhaseStats[idx].sessionBucket = sessionBucket;
   g_indPhaseStats[idx].direction = direction;
   g_indPhaseStats[idx].trades = 0;
   g_indPhaseStats[idx].wins = 0;
   g_indPhaseStats[idx].sumPnl = 0.0;
   g_indPhaseStats[idx].weightedPnl = 0.0;
   g_indPhaseStats[idx].weightedAvg = 0.0;
   g_indPhaseStats[idx].weightShift = 0.0;
   g_indPhaseStats[idx].todayAccum = 0.0;
   g_indPhaseStats[idx].lastAdjustDay = 0;
   return idx;
}

// PHASE-LEARNING: determine which indicators were active for a trade
bool IsIndicatorActive(const EntrySnapshot &snap,string indName,string direction)
{
   if(indName == "RSI")
   {
      if(direction == "LONG" && snap.rsi > 55) return true;
      if(direction == "SHORT" && snap.rsi < 45) return true;
   }
   else if(indName == "MACD")
   {
      if(direction == "LONG" && snap.macd > 0) return true;
      if(direction == "SHORT" && snap.macd < 0) return true;
   }
   else if(indName == "CCI")
   {
      if(direction == "LONG" && snap.cci > InpCCI_Threshold) return true;
      if(direction == "SHORT" && snap.cci < -InpCCI_Threshold) return true;
   }
   else if(indName == "MFI")
   {
      if(direction == "LONG" && snap.mfi >= 60) return true;
      if(direction == "SHORT" && snap.mfi <= 40) return true;
   }
   else if(indName == "IKH")
   {
      if(direction == "LONG" && snap.ichimokuLong > 0) return true;
      if(direction == "SHORT" && snap.ichimokuShort > 0) return true;
   }
   else if(indName == "VOL")
   {
      if(snap.volumeScore > 0) return true;
   }
   else if(indName == "PATTERN")
   {
      if(snap.hasPattern) return true;
   }
   else if(indName == "ADX")
   {
      if(snap.adx >= InpADX_Moderate) return true;
   }
   return false;
}

// PHASE-LEARNING: update indicator phase stats from trade
void UpdateIndicatorPhaseStats(const TradeContextEntry &ctx,double profitPts,double profitMoney)
{
   if(!InpEnablePhaseLearning) return;
   
   EntrySnapshot snap = ctx.snap;
   int direction = (snap.direction == "LONG" ? +1 : -1);
   
   // Calculate R-multiple (similar to LearningUpdateStats)
   double initialRisk = 0.0;
   // STABILITY: check g_point before division
   if(g_point > 0.0 && snap.slPlan > 0.0 && ctx.entryPrice > 0.0)
   {
      if(snap.direction == "LONG")
         initialRisk = (ctx.entryPrice - snap.slPlan) / g_point;
      else
         initialRisk = (snap.slPlan - ctx.entryPrice) / g_point;
   }
   if(initialRisk <= 0.0 && snap.atr > 0.0 && g_point > 0.0)
      initialRisk = (snap.atr * 2.0) / g_point;
   if(initialRisk <= 0.0)
      initialRisk = MathAbs(profitPts);
   
   double rMultiple = 0.0;
   if(initialRisk > 0.0)
      rMultiple = profitPts / initialRisk;
   else
      rMultiple = (profitMoney > 0.0 ? 1.0 : -1.0);
   
   // List of indicators to check
   string indicators[] = {"RSI","MACD","CCI","MFI","IKH","VOL","PATTERN","ADX"};
   
   for(int i=0; i<ArraySize(indicators); i++)
   {
      if(!IsIndicatorActive(snap,indicators[i],snap.direction))
         continue;
      
      int idx = FindOrCreateIndPhaseStat(indicators[i],snap.trendPhase,snap.volLevel,snap.sessionBucket,direction);
      
      g_indPhaseStats[idx].trades++;
      if(profitMoney > 0.0)
      {
         g_indPhaseStats[idx].wins++;
         g_indPhaseStats[idx].weightedPnl += rMultiple;
      }
      else
      {
         g_indPhaseStats[idx].weightedPnl += (rMultiple * 1.5); // Loss penalty
      }
      g_indPhaseStats[idx].sumPnl += profitMoney;
      if(g_indPhaseStats[idx].trades > 0)
         g_indPhaseStats[idx].weightedAvg = g_indPhaseStats[idx].weightedPnl / (double)g_indPhaseStats[idx].trades;
   }
}

// PHASE-LEARNING: apply indicator phase adjustments
void ApplyIndicatorPhaseAdjustments()
{
   if(!InpEnablePhaseLearning) return;
   
   datetime dayAnchor = g_dayAnchor;
   if(dayAnchor == 0)
   {
      MqlDateTime tm;
      TimeToStruct(TimeCurrent(),tm);
      tm.hour = InpDayResetHour;
      tm.min = 0;
      tm.sec = 0;
      dayAnchor = StructToTime(tm);
   }
   
   for(int i=0; i<ArraySize(g_indPhaseStats); i++)
   {
      if(g_indPhaseStats[i].trades < InpIndPhaseMinTrades)
         continue;
      
      // Day reset check
      if(g_indPhaseStats[i].lastAdjustDay != dayAnchor)
      {
         g_indPhaseStats[i].todayAccum = 0.0;
         g_indPhaseStats[i].lastAdjustDay = dayAnchor;
      }
      
      double delta = 0.0;
      if(g_indPhaseStats[i].weightedAvg > 0.0)
         delta = +InpIndPhaseStep;
      else if(g_indPhaseStats[i].weightedAvg < 0.0)
         delta = -InpIndPhaseStep;
      else
         continue;
      
      // Daily limit check
      double remaining = InpIndPhaseMaxPerDay - MathAbs(g_indPhaseStats[i].todayAccum);
      if(remaining <= 0.0)
         continue;
      if(MathAbs(delta) > remaining)
         delta = (delta > 0.0 ? remaining : -remaining);
      
      // Calculate new shift
      double newShift = g_indPhaseStats[i].weightShift + delta;
      
      // Total limit check
      if(MathAbs(newShift) > InpIndPhaseMaxTotal)
      {
         newShift = (newShift > 0.0 ? InpIndPhaseMaxTotal : -InpIndPhaseMaxTotal);
         delta = newShift - g_indPhaseStats[i].weightShift;
      }
      
      g_indPhaseStats[i].weightShift = newShift;
      g_indPhaseStats[i].todayAccum += delta;
   }
}

// PHASE-LEARNING: get indicator phase weight
double GetIndicatorPhaseWeight(string name,int trendPhase,int volLevel,int sessionBucket,int direction)
{
   if(!InpEnablePhaseLearning)
      return 1.0;
   
   for(int i=0; i<ArraySize(g_indPhaseStats); i++)
   {
      if(g_indPhaseStats[i].name == name &&
         g_indPhaseStats[i].trendPhase == trendPhase &&
         g_indPhaseStats[i].volLevel == volLevel &&
         g_indPhaseStats[i].sessionBucket == sessionBucket &&
         g_indPhaseStats[i].direction == direction)
      {
         double factor = 1.0 + g_indPhaseStats[i].weightShift;
         return Clamp(factor,0.7,1.3);
      }
   }
   return 1.0;
}

double ComputeExitEfficiency(const TradeContextEntry &ctx,double profitPts)
{
   double mfe = ctx.mfePts;
   if(mfe < 0.1) mfe = 0.1;
   double eff = profitPts / (mfe + 1.0);
   if(profitPts < 0.0)
      eff = -MathAbs(eff);
   else
      eff = MathAbs(eff);
   return eff;
}

void LearningApplyExitStats(int idx,double exitEfficiency)
{
   if(idx<0) return;
   g_scoreStats[idx].exitTrades++;
   g_scoreStats[idx].exitSumEfficiency += exitEfficiency;
   if(g_scoreStats[idx].exitTrades>0)
      g_scoreStats[idx].exitAvgEfficiency = g_scoreStats[idx].exitSumEfficiency / (double)g_scoreStats[idx].exitTrades;
   if(g_scoreStats[idx].exitTrades >= 40 && g_scoreStats[idx].exitAvgEfficiency < 0.25)
      g_scoreStats[idx].exitShift -= 0.01;
   else if(g_scoreStats[idx].exitAvgEfficiency > 0.5)
      g_scoreStats[idx].exitShift += 0.01;
   g_scoreStats[idx].exitShift = Clamp(g_scoreStats[idx].exitShift,-0.1,0.1);
}

void LearningUpdateStats(const TradeContextEntry &ctx,double profitPts,double profitMoney)
{
   double qa = (ctx.snap.direction=="LONG"?ctx.snap.qaL:ctx.snap.qaS);
   double band = LearningScoreBand(qa);
   int dir = (ctx.snap.direction=="LONG"?+1:-1);
   int idx = LearningEnsureScoreStat(band,dir,ctx.snap.regimeId);
   g_scoreStats[idx].trades++;
   
   // LEARNING: loss penalty applied - Berechne R-Multiple basierend auf initialRisk
   double initialRisk = 0.0;
   // STABILITY: check g_point before division
   if(g_point > 0.0 && ctx.snap.slPlan > 0.0 && ctx.entryPrice > 0.0)
   {
      // Berechne initialRisk in Punkten (Entry-SL Abstand)
      if(ctx.snap.direction == "LONG")
         initialRisk = (ctx.entryPrice - ctx.snap.slPlan) / g_point;
      else
         initialRisk = (ctx.snap.slPlan - ctx.entryPrice) / g_point;
   }
   
   // Fallback: Wenn kein SL vorhanden, verwende ATR-basierten Schätzwert
   if(initialRisk <= 0.0 && ctx.snap.atr > 0.0 && g_point > 0.0)
      initialRisk = (ctx.snap.atr * 2.0) / g_point; // Schätzung: 2x ATR
   
   // Fallback: Wenn auch kein ATR, verwende profitPts als Basis (relativ)
   if(initialRisk <= 0.0)
      initialRisk = MathAbs(profitPts); // Relative Bewertung
   
   // Berechne R-Multiple (normalisiertes Profit/Loss)
   double rMultiple = 0.0;
   if(initialRisk > 0.0)
      rMultiple = profitPts / initialRisk;
   else
      rMultiple = (profitMoney > 0.0 ? 1.0 : -1.0); // Fallback
   
   // LEARNING: loss penalty applied - Anwenden der Loss-Penalty
   if(profitMoney > 0.0)
   {
      // Gewinn: normal zählen, Loss-Streak zurücksetzen
      g_scoreStats[idx].wins++;
      g_scoreStats[idx].lossStreak = 0;
      g_scoreStats[idx].weightedPnlSum += rMultiple; // +1R → +1
   }
   else
   {
      // Verlust: 50% stärker negativ gewichten
      g_scoreStats[idx].lossStreak++;
      g_scoreStats[idx].weightedPnlSum += (rMultiple * 1.5); // -1R → -1.5
   }
   
   // Standard-Statistiken aktualisieren
   g_scoreStats[idx].sumPnl += profitMoney;
   g_scoreStats[idx].sumPnlPts += profitPts;
   
   // LEARNING: loss penalty applied - Gewichteten Durchschnitt aktualisieren
   if(g_scoreStats[idx].trades > 0)
      g_scoreStats[idx].weightedAvg = g_scoreStats[idx].weightedPnlSum / (double)g_scoreStats[idx].trades;

   IndicatorUpdateFromTrade(ctx,rMultiple);
   // PHASE-LEARNING: update indicator phase stats
   UpdateIndicatorPhaseStats(ctx,profitPts,profitMoney);
   double exitEfficiency = ComputeExitEfficiency(ctx,profitPts);
   LearningApplyExitStats(idx,exitEfficiency);
}

void EvaluateClosedTrade(ulong ticket,double exitPrice,double profitPts,double profitMoney,string reason,datetime exitTime)
{
   int idx=LearningFindTradeContext(ticket);
   if(idx<0) return;
   TradeContextEntry ctx = g_tradeContexts[idx];
   double durationMin = (double)(exitTime - ctx.entryTime)/60.0;
   if(durationMin<0.0) durationMin=0.0;
   // LEARNING: Stats VOR CSV-Schreiben aktualisieren, damit CSV korrekte Werte enthält
   LearningUpdateStats(ctx,profitPts,profitMoney);
   LearningWriteCsv(ctx,exitPrice,profitPts,profitMoney,reason,exitTime,durationMin);
   // VARIANT + LEARNING: integration - VariantStats aktualisieren
   VariantUpdateStats(ctx.variantId,profitMoney);
   g_tradeContexts[idx].active=false;
}

double LearningGetShift(double qa,string direction,int regimeId)
{
   if(regimeId<0)
   {
      RegimeContext ctx = BuildRegimeContext();
      regimeId = ctx.regimeId;
   }
   int dir=(direction=="LONG"?+1:-1);
   double band=LearningScoreBand(qa);
   int idx=LearningFindScoreStat(band,dir,regimeId);
   if(idx>=0) return g_scoreStats[idx].shift;
   int fallbackIdx=LearningFindScoreStat(band,dir,0);
   if(fallbackIdx>=0) return g_scoreStats[fallbackIdx].shift;
   for(int i=0;i<ArraySize(g_scoreStats);i++)
      if(g_scoreStats[i].direction==dir && MathAbs(g_scoreStats[i].band-band)<0.0001)
         return g_scoreStats[i].shift;
   return 0.0;
}

// LEARNING: Adjustment
void ApplyLearningAdjustments()
{
   if(!InpEnableLearning) return;
   datetime today=TimeCurrent();
   MqlDateTime dt; TimeToStruct(today,dt);
   if(dt.hour<InpDayResetHour) dt.day-=1;
   dt.hour=InpDayResetHour; dt.min=0; dt.sec=0;
   datetime dayAnchor = StructToTime(dt);
   
   for(int i=0;i<ArraySize(g_scoreStats);i++)
   {
      if(g_scoreStats[i].trades < InpLearningMinTrades) continue;
      if(g_scoreStats[i].lastAdjustDay!=dayAnchor){
         g_scoreStats[i].todayAccum=0.0;
         g_scoreStats[i].lastAdjustDay=dayAnchor;
      }
      
      // LEARNING: weighted decision metrics - Berechne Metriken
      double winRate = (g_scoreStats[i].trades>0? (double)g_scoreStats[i].wins/(double)g_scoreStats[i].trades : 0.0);
      double avgPnl = (g_scoreStats[i].trades>0? g_scoreStats[i].sumPnl/(double)g_scoreStats[i].trades : 0.0);
      double weightedAvg = g_scoreStats[i].weightedAvg;
      int lossStreak = g_scoreStats[i].lossStreak;
      
      // LEARNING: weighted decision metrics - Entscheidungslogik basierend auf gewichteten Metriken
      double delta=0.0;
      bool shouldStricter = (weightedAvg < 0.0) || (avgPnl < 0.0) || (winRate < InpLearningWinThreshold);
      bool shouldRelax = (weightedAvg > 0.0) && (avgPnl > 0.0) && (winRate > InpLearningUpperTrigger);
      
      if(shouldStricter)
         delta = +InpLearningStep; // Entry-Threshold STRENGER machen
      else if(shouldRelax)
         delta = -InpLearningStep; // Entry-Threshold LOCKERN
      
      // LEARNING: loss streak reaction - Verstärke Reaktion bei Loss-Streaks
      if(shouldStricter && lossStreak >= 8)
      {
         // Sehr starke Verlustserie: 3x stärker reagieren
         delta = InpLearningStep * 3.0;
      }
      else if(shouldStricter && lossStreak >= 5)
      {
         // Mittlere Verlustserie: 2x stärker reagieren
         delta = InpLearningStep * 2.0;
      }
      
      if(delta==0.0) continue;
      
      // LEARNING: shift clamping - Tageslimit prüfen
      double remaining = InpLearningMaxAdjPerDay - MathAbs(g_scoreStats[i].todayAccum);
      if(remaining<=0.0) continue;
      if(MathAbs(delta)>remaining) delta = (delta>0?remaining:-remaining);
      
      // LEARNING: shift clamping - Gesamtlimit prüfen
      double newShift = g_scoreStats[i].shift + delta;
      if(MathAbs(newShift) > InpLearningMaxTotalShift){
         newShift = (newShift>0?InpLearningMaxTotalShift:-InpLearningMaxTotalShift);
         delta = newShift - g_scoreStats[i].shift;
      }
      
      // LEARNING: shift clamping - Finale Anwendung
      g_scoreStats[i].shift = newShift;
      g_scoreStats[i].todayAccum += delta;
   }
}

// INDLEARN: daily adjustments
void ApplyIndicatorLearningAdjustments()
{
   if(!InpEnableIndicatorLearning) return;
   datetime today=TimeCurrent();
   MqlDateTime dt; TimeToStruct(today,dt);
   if(dt.hour<InpDayResetHour) dt.day-=1;
   dt.hour=InpDayResetHour; dt.min=0; dt.sec=0;
   datetime dayAnchor = StructToTime(dt);

   for(int i=0;i<ArraySize(g_indStats);i++)
   {
      if(g_indStats[i].lastAdjustDay!=dayAnchor)
      {
         g_indStats[i].todayAccum=0.0;
         g_indStats[i].lastAdjustDay=dayAnchor;
      }
      if(g_indStats[i].trades < InpIndLearnMinTrades) continue;
      double delta=0.0;
      if(g_indStats[i].weightedAvgR > InpIndLearnUpperTriggerR) delta = +InpIndLearnStep;
      else if(g_indStats[i].weightedAvgR < InpIndLearnLowerTriggerR) delta = -InpIndLearnStep;
      if(delta==0.0) continue;
      double remaining = InpIndLearnMaxAdjPerDay - MathAbs(g_indStats[i].todayAccum);
      if(remaining<=0.0) continue;
      if(MathAbs(delta)>remaining) delta = (delta>0?remaining:-remaining);
      double newShift = g_indStats[i].weightShift + delta;
      if(MathAbs(newShift) > InpIndLearnMaxTotalShift)
      {
         newShift = (newShift>0?InpIndLearnMaxTotalShift:-InpIndLearnMaxTotalShift);
         delta = newShift - g_indStats[i].weightShift;
      }
      g_indStats[i].weightShift = newShift;
      g_indStats[i].todayAccum += delta;
   }
}

// LEARNING: Persistence
bool LoadLearningStatsFromFile()
{
    LearningEnsureStatsFile();
    string fn = LearningStatsFileName();

    if (!FileIsExist(fn))
        return false;

    // Datei NUR im READ-Modus öffnen (stabilste Variante!)
    int h = FileOpen(fn, FILE_READ | FILE_CSV | FILE_ANSI, ';');
    if (h == INVALID_HANDLE)
    {
        Print("[Learning] ERROR: Cannot open learning stats file: ", fn);
        return false;
    }

    string cols[];

    // Header einlesen (und ignorieren)
    if (LearningReadCsvRow(h, cols) <= 0)
    {
        FileClose(h);
        return false;
    }

    ArrayResize(g_scoreStats, 0);

    // Einträge einlesen
    while (LearningReadCsvRow(h, cols) > 0)
    {
        int n = ArraySize(cols);
        if (n < 7)  // Mindestspalten prüfen
            continue;

        string dirStr = cols[0];
        double band   = StringToDouble(cols[1]);
        int regimeId  = (int)StringToInteger(cols[2]);
        int dir       = (dirStr=="LONG" ? +1 : -1);

        int idx = LearningEnsureScoreStat(band, dir, regimeId);

        g_scoreStats[idx].trades            = (int)StringToInteger(cols[3]);
        g_scoreStats[idx].wins              = (int)StringToInteger(cols[4]);
        g_scoreStats[idx].sumPnl            = StringToDouble(cols[5]);
        g_scoreStats[idx].shift             = StringToDouble(cols[6]);
        g_scoreStats[idx].lastAdjustDay     = StringToTime(cols[7]);
        g_scoreStats[idx].lossStreak        = StringToInteger(cols[8]);
        g_scoreStats[idx].weightedPnlSum    = StringToDouble(cols[9]);
        g_scoreStats[idx].weightedAvg       = StringToDouble(cols[10]);
        g_scoreStats[idx].exitTrades        = StringToInteger(cols[11]);
        g_scoreStats[idx].exitSumEfficiency = StringToDouble(cols[12]);
        g_scoreStats[idx].exitAvgEfficiency = StringToDouble(cols[13]);
        g_scoreStats[idx].exitShift         = StringToDouble(cols[14]);

        // interne Werte zurücksetzen
        g_scoreStats[idx].todayAccum = 0.0;
        g_scoreStats[idx].sumPnlPts  = 0.0;
    }

    FileClose(h);
    return true;
}


bool SaveLearningStatsToFile()
{
    LearningEnsureStatsFile();
    string fn = LearningStatsFileName();

    // Datei vollständig NEU schreiben – WRITE ist korrekt
    int h = FileOpen(fn, FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
    if (h == INVALID_HANDLE)
    {
        Print("[Learning] ERROR: Cannot save learning stats: ", fn);
        return false;
    }

    // Header exakt passend zum Loader
    FileWrite(h,
        "Direction","Band","RegimeId","Trades","Wins","SumPnL","Shift",
        "LastAdjustDay","LossStreak","WeightedPnlSum","WeightedAvg",
        "ExitTrades","ExitSumEfficiency","ExitAvgEfficiency","ExitShift"
    );

    // Einträge schreiben
    for (int i = 0; i < ArraySize(g_scoreStats); i++)
    {
        if (g_scoreStats[i].trades <= 0)
            continue;

        string dirStr = (g_scoreStats[i].direction > 0 ? "LONG" : "SHORT");

        FileWrite(h,
            dirStr,
            DoubleToString(g_scoreStats[i].band, 4),
            (long)g_scoreStats[i].regimeId,
            (long)g_scoreStats[i].trades,
            (long)g_scoreStats[i].wins,
            DoubleToString(g_scoreStats[i].sumPnl, 6),
            DoubleToString(g_scoreStats[i].shift, 6),
            TimeToString(g_scoreStats[i].lastAdjustDay, TIME_DATE),
            (long)g_scoreStats[i].lossStreak,
            DoubleToString(g_scoreStats[i].weightedPnlSum, 6),
            DoubleToString(g_scoreStats[i].weightedAvg, 6),
            (long)g_scoreStats[i].exitTrades,
            DoubleToString(g_scoreStats[i].exitSumEfficiency, 6),
            DoubleToString(g_scoreStats[i].exitAvgEfficiency, 6),
            DoubleToString(g_scoreStats[i].exitShift, 6)
        );
    }

    FileClose(h);
    return true;
}



bool LoadIndicatorStatsFromFile()
{
    string fn = IndicatorStatsFileName();
    if (!FileIsExist(fn))
        return false;

    // WICHTIG: Nur READ – niemals WRITE beim Laden
    int h = FileOpen(fn, FILE_READ | FILE_CSV | FILE_ANSI, ';');
    if (h == INVALID_HANDLE)
        return false;

    string columns[];

    // Header einlesen
    bool headerOk = (LearningReadCsvRow(h, columns) > 0);

    ArrayResize(g_indStats, 0);

    // Jede weitere Zeile einlesen
    while (LearningReadCsvRow(h, columns) > 0)
    {
        int n = ArraySize(columns);
        if (n < 2)
            continue;

        int indId = (int)StringToInteger(columns[0]);
        int regId = (int)StringToInteger(columns[1]);

        // Ungültige Datensätze ignorieren
        if (indId <= 0 || regId < 0)
            continue;

        int idx = ArraySize(g_indStats);
        ArrayResize(g_indStats, idx + 1);

        g_indStats[idx].indicatorId    = indId;
        g_indStats[idx].regimeId       = regId;

        g_indStats[idx].trades         = (n >= 3 ? (int)StringToInteger(columns[2]) : 0);
        g_indStats[idx].weightedPnlSum = (n >= 4 ? StringToDouble(columns[3]) : 0.0);
        g_indStats[idx].weightedAvgR   = (n >= 5 ? StringToDouble(columns[4]) : 0.0);
        g_indStats[idx].weightShift    = (n >= 6 ? StringToDouble(columns[5]) : 0.0);
        g_indStats[idx].lastAdjustDay  = (n >= 7 ? StringToTime(columns[6]) : 0);
        g_indStats[idx].todayAccum     = (n >= 8 ? StringToDouble(columns[7]) : 0.0);
    }

    FileClose(h);
    return headerOk;
}


bool SaveIndicatorStatsToFile()
{
    string fn = IndicatorStatsFileName();

    // Datei IMMER komplett neu erstellen (FILE_WRITE)
    int h = FileOpen(fn, FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
    if (h == INVALID_HANDLE)
    {
        Print("[IndicatorStats] ERROR: Cannot open indicator stats file for writing: ", fn);
        return false;
    }

    // Header schreiben
    FileWrite(h,
        "IndicatorId","RegimeId","Trades",
        "WeightedPnlSum","WeightedAvgR","WeightShift",
        "LastAdjustDay","TodayAccum"
    );

    // Datenzeilen schreiben
    for (int i = 0; i < ArraySize(g_indStats); i++)
    {
        FileWrite(h,
            (long)g_indStats[i].indicatorId,
            (long)g_indStats[i].regimeId,
            (long)g_indStats[i].trades,
            DoubleToString(g_indStats[i].weightedPnlSum, 6),
            DoubleToString(g_indStats[i].weightedAvgR, 6),
            DoubleToString(g_indStats[i].weightShift, 6),
            TimeToString(g_indStats[i].lastAdjustDay, TIME_DATE),
            DoubleToString(g_indStats[i].todayAccum, 6)
        );
    }

    FileClose(h);
    return true;
}


string MonitorTrendLabel(int trend)
{
   if(trend==REGIME_TREND_UP) return "Up";
   if(trend==REGIME_TREND_DOWN) return "Down";
   return "Range";
}

string MonitorVolLabel(int vol)
{
   if(vol==REGIME_VOL_HIGH) return "High";
   if(vol==REGIME_VOL_LOW) return "Low";
   return "Medium";
}

string MonitorFormatTimestamp(datetime t)
{
   string ts = TimeToString(t,TIME_DATE|TIME_SECONDS);
   StringReplace(ts,".","-");
   StringReplace(ts,":","-");
   return ts;
}

void MonitorEnsureFile()
{
    if (!InpEnableLearningMonitor)
        return;

    string fn = g_monitorFile;
    ulong maxBytes = (ulong)MathMax(0, InpMonitorMaxSizeKB) * 1024;

    // ------------------------------------------------------
    // 1) Rotation prüfen – Datei zu groß?
    // ------------------------------------------------------
    if (FileIsExist(fn) && maxBytes > 0)
    {
        int hRead = FileOpen(fn, FILE_READ | FILE_BIN);
        if (hRead != INVALID_HANDLE)
        {
            ulong size = FileSize(hRead);
            FileClose(hRead);

            if (size > maxBytes)
            {
                // Backup-Dateiname erstellen
                string backup =
                    "XAUUSD_learning_monitor_" +
                    MonitorFormatTimestamp(TimeCurrent()) +
                    ".csv";

                // Falls Backup existiert → löschen
                if (FileIsExist(backup))
                    FileDelete(backup);

                // Wichtig: 4-Parameter-Version von FileMove()
                bool ok = FileMove(fn, 0, backup, 0);
                if (!ok)
                    Print("[Monitor] ERROR: File rotation failed: ", fn);
            }
        }
    }

    // ------------------------------------------------------
    // 2) Datei existiert nicht → neu erstellen + Header
    // ------------------------------------------------------
    if (!FileIsExist(fn))
    {
        int h = FileOpen(fn, FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
        if (h != INVALID_HANDLE)
        {
            FileWrite(h,
                "Timestamp","TrendPhase","VolatilityLevel","RecordType","Direction",
                "RangeStart","RangeEnd","Trades","Wins","Winrate","WeightedAvg","LossPenalty",
                "ShiftValue","ExitTrades","ExitAvgEfficiency","ExitShift",
                "VariantId","VariantTrades","VariantWins","VariantWinrate","VariantPnL","VariantLastReward"
            );
            FileClose(h);
        }
        else
        {
            Print("[Monitor] ERROR: Cannot create monitor file: ", fn);
        }
    }
}


void MonitorWriteSnapshot()
{
    if(!InpEnableLearningMonitor)
        return;

    // Datei sicherstellen
    MonitorEnsureFile();

    int h = FileOpen(g_monitorFile, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
    if(h == INVALID_HANDLE)
        return;

    // an das Ende schreiben
    FileSeek(h, 0, SEEK_END);

    datetime now = TimeCurrent();
    string ts = TimeToString(now, TIME_DATE | TIME_SECONDS);

    // aktueller Regime-Context
    RegimeContext ctx = BuildRegimeContext();
    g_lastRegimeCtx = ctx;

    string trendStr = MonitorTrendLabel(ctx.trend);
    string volStr   = MonitorVolLabel(ctx.vol);

    bool wrote = false;

    // ============================
    //   SCORE STATS (BANDS)
    // ============================
    for(int i = 0; i < ArraySize(g_scoreStats); i++)
    {
        double winrate = (g_scoreStats[i].trades > 0 ?
                          (double)g_scoreStats[i].wins / (double)g_scoreStats[i].trades : 0.0);

        double rangeStart = g_scoreStats[i].band;
        double rangeEnd   = rangeStart + 0.5;

        FileWrite(h,
            ts,
            trendStr,
            volStr,
            "BAND",
            (g_scoreStats[i].direction > 0 ? "LONG" : "SHORT"),
            DoubleToString(rangeStart,2),
            DoubleToString(rangeEnd,2),
            (long)g_scoreStats[i].trades,
            (long)g_scoreStats[i].wins,
            DoubleToString(winrate,4),
            DoubleToString(g_scoreStats[i].weightedAvg,4),
            (long)g_scoreStats[i].lossStreak,
            DoubleToString(g_scoreStats[i].shift,4),
            (long)g_scoreStats[i].exitTrades,
            DoubleToString(g_scoreStats[i].exitAvgEfficiency,4),
            DoubleToString(g_scoreStats[i].exitShift,4),
            "", "", "", "", "", ""
        );

        wrote = true;
    }

    // ============================
    //   VARIANT STATS
    // ============================
    for(int i = 0; i < ArraySize(g_variantStats); i++)
    {
        double winrate = (g_variantStats[i].trades > 0 ?
                          (double)g_variantStats[i].wins / (double)g_variantStats[i].trades : 0.0);

        FileWrite(h,
            ts,
            trendStr,
            volStr,
            "VARIANT",
            "",
            "",
            "",
            (long)g_variantStats[i].trades,
            (long)g_variantStats[i].wins,
            DoubleToString(winrate,4),
            "",
            "",
            "",
            "",
            "",
            "",
            (long)g_variantStats[i].variantId,
            (long)g_variantStats[i].trades,
            (long)g_variantStats[i].wins,
            DoubleToString(winrate,4),
            DoubleToString(g_variantStats[i].pnl,2),
            DoubleToString(g_variantStats[i].lastReward,2)
        );

        wrote = true;
    }

    // ============================
    //   PHASE LEARNING STATS
    // ============================
    for(int i = 0; i < ArraySize(g_indPhaseStats); i++)
    {
        if(g_indPhaseStats[i].trades < InpIndPhaseMinTrades)
            continue;

        double winrate = (g_indPhaseStats[i].trades > 0 ?
                          (double)g_indPhaseStats[i].wins / (double)g_indPhaseStats[i].trades : 0.0);

        string trendPhaseStr =
            (g_indPhaseStats[i].trendPhase == TREND_UP     ? "UP" :
             g_indPhaseStats[i].trendPhase == TREND_DOWN   ? "DOWN" :
                                                             "SIDEWAYS");

        string volLevelStr =
            (g_indPhaseStats[i].volLevel == VOL_LOW  ? "LOW" :
             g_indPhaseStats[i].volLevel == VOL_HIGH ? "HIGH" :
                                                       "MEDIUM");

        string sessionStr =
            (g_indPhaseStats[i].sessionBucket == SESSION_ASIA   ? "ASIA" :
             g_indPhaseStats[i].sessionBucket == SESSION_EUROPE ? "EUROPE" :
                                                                  "US");

        FileWrite(h,
            ts,
            trendStr,
            volStr,
            "INDPHASE",
            (g_indPhaseStats[i].direction > 0 ? "LONG" : "SHORT"),
            "",
            "",
            (long)g_indPhaseStats[i].trades,
            (long)g_indPhaseStats[i].wins,
            DoubleToString(winrate,4),
            DoubleToString(g_indPhaseStats[i].weightedAvg,4),
            "",
            DoubleToString(g_indPhaseStats[i].weightShift,4),
            "", "", "",
            g_indPhaseStats[i].name,
            trendPhaseStr,
            volLevelStr,
            sessionStr,
            ""
        );

        wrote = true;
    }

    // Fallback, falls nichts geschrieben wurde
    if(!wrote)
    {
        FileWrite(h,
            ts,
            trendStr,
            volStr,
            "SUMMARY",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "", "", "", "", "", ""
        );
    }

    FileClose(h);
    g_lastMonitorWriteTime = now;
}



string DealReasonText(ENUM_DEAL_REASON reason)
{
    switch (reason)
    {
        case DEAL_REASON_SL:      return "SL";
        case DEAL_REASON_TP:      return "TP";
        case DEAL_REASON_SO:      return "StopOut";
        case DEAL_REASON_CLIENT:  return "Manual";
        case DEAL_REASON_EXPERT:  return "EA";

        // Fallback für unbekannte oder broker-spezifische Gründe
        default:                  return "Other";
    }
}




// ==============================
// ========== NEWS-CACHE ========
// ==============================
struct NewsRow
{
    datetime t;
    bool high;
};
NewsRow g_news[];


void News_Reset()
{
    ArrayResize(g_news,0);
}


bool News_LoadFile()
{
    News_Reset();
    if(!InpUseNewsFilter) return true;

    int h = FileOpen(InpNewsFile, FILE_READ | FILE_ANSI);
    if(h == INVALID_HANDLE)
    {
        LogRow("NEWS_ERR","News","WARN",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"open fail");
        return false;
    }

    ulong fileSize = FileSize(h);
    string content = FileReadString(h, (int)fileSize);
    FileClose(h);

    if(StringLen(content) < 5)
    {
        LogRow("NEWS_ERR","News","WARN",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"empty");
        return false;
    }

    bool any = false;
    string lower = InpNewsFile;
    StringToLower(lower);

    // =========================
    // CSV parsing
    // =========================
    if(StringFind(lower, ".csv") >= 0)
    {
        string lines[];
        int n = StringSplit(content, '\n', lines);

        for(int i=0; i<n; i++)
        {
            string line = lines[i];
            StringTrimLeft(line);
            StringTrimRight(line);
            if(StringLen(line) < 10) continue;

            string p[];
            int m = StringSplit(line, ';', p);
            if(m < 1) continue;

            datetime ev = StringToTime(p[0]);
            if(ev == 0) continue;

            bool hi = false;
            if(m >= 2)
                hi = (StringFind(StringToLower(p[1]), "high") >= 0);

            int sz = ArraySize(g_news);
            ArrayResize(g_news, sz+1);
            g_news[sz].t = ev;
            g_news[sz].high = hi;
            any = true;
        }
    }
    else
    {
        // =========================
        // JSON parsing fallback
        // =========================
        int pos = 0;
        while(true)
        {
            int tpos = StringFind(content, "\"time\"", pos);
            if(tpos < 0) break;

            int q1 = StringFind(content, "\"", tpos+6);
            int q2 = (q1 > 0 ? StringFind(content, "\"", q1+1) : -1);
            if(q1 < 0 || q2 < 0) break;

            string ts = StringSubstr(content, q1+1, q2-q1-1);
            datetime ev = StringToTime(ts);
            pos = q2 + 1;
            if(ev == 0) continue;

            bool hi = false;

            int ip = StringFind(content, "\"impact\"", pos);
            if(ip > 0)
            {
                int i1 = StringFind(content, "\"", ip+8);
                int i2 = (i1 > 0 ? StringFind(content, "\"", i1+1) : -1);

                if(i1 > 0 && i2 > i1)
                {
                    string imp = StringSubstr(content, i1+1, i2-i1-1);
                    hi = (StringFind(StringToLower(imp), "high") >= 0);
                    pos = i2 + 1;
                }
            }

            int sz = ArraySize(g_news);
            ArrayResize(g_news, sz+1);
            g_news[sz].t = ev;
            g_news[sz].high = hi;
            any = true;
        }
    }

    if(!any)
        LogRow("NEWS_ERR","News","WARN",ModeName(),"-",0,0,0,0,0,0,0,0,0,0,0,0,true,"no rows parsed");

    return any;
}


bool News_IsBlockedWindow()
{
    if(!InpUseNewsFilter) return false;

    datetime now = TimeCurrent();

    for(int i=0; i < ArraySize(g_news); i++)
    {
        int diff = (int)((g_news[i].t - now) / 60);

        if(diff >= -InpNewsPostBlockMin &&
           diff <=  InpNewsPreBlockMin)
            return true;
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
    datetime now = TimeCurrent();
    MqlDateTime tmNow; 
    TimeToStruct(now, tmNow);

    // Zielzeit für den täglichen Reset
    tmNow.hour = InpDayResetHour;
    tmNow.min  = 0;
    tmNow.sec  = 0;
    datetime todayReset = StructToTime(tmNow);

    // Wenn die Reset-Zeit heute noch nicht erreicht ist → gestern
    if(now < todayReset)
        todayReset -= 24*60*60;

    // Wenn wir den Anchor noch nie gesetzt haben → einmalig initialisieren
    if(g_dayAnchor == 0)
    {
        g_dayAnchor       = todayReset;
        g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
        g_safeEnterEquity = 0.0;

        News_LoadFile();

        // Kein daily delete! File bleibt bestehen.
        // g_learningCsv NICHT löschen!

        return;
    }

    // --- Tageswechsel ---
    if(now >= g_dayAnchor + 24*60*60)
    {
        g_dayAnchor       = todayReset;
        g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
        g_safeEnterEquity = 0.0;

        // Normaler Mode-Rücksprung (Manual unverändert)
        if(!InpManualOverride)
            g_mode = MODE_NORMAL;

        News_LoadFile();

        LogRow("DAY_RESET","ModeManager","RESET",ModeName(),"-",
               0,0,0,0,0,0,0,0,0,0,0,true,"new day");

        // Learning-Datei wird NICHT gelöscht!
        // g_learningCsv bleibt wie es ist

        return;
    }
}

void UpdateModeByPnL()
{
    // 1. Absolute Prioritäten
    if(g_mode == MODE_DISABLED_TODAY)
        return;

    if(InpManualOverride)
    {
        g_mode = MODE_MANUAL;
        return;
    }

    double pnl = TodayPnL();
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);

    // 2. Daily Loss Stop → sofortiger SAFE Mode, aber NICHT Disabled
    if(pnl <= -InpDailyLossStopEUR)
    {
        if(g_mode != MODE_SAFE)
            g_safeEnterEquity = equity;

        g_mode = MODE_SAFE;
        return;
    }

    // 3. Wechsel in DisabledToday NUR wenn Safe weiter fällt
    if(g_mode == MODE_SAFE)
    {
        if(equity <= g_safeEnterEquity - InpExtraLossAfterSafe)
        {
            g_mode = MODE_DISABLED_TODAY;
            return;
        }
    }

    // 4. PostTarget → Gewinnziel erreicht
    if(pnl >= InpDailyTargetEUR)
    {
        g_mode = MODE_POSTTARGET;
        return;
    }

    // 5. Normale Phase
    if(g_mode != MODE_MANUAL)
        g_mode = MODE_NORMAL;
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

// SPLIT: normalize staged lot sizes to broker constraints
double NormalizeSplitLots(double lots)
{
   if(lots <= 0.0) return 0.0;
   double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   double minl = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double maxl = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;

   double v = MathFloor(lots / step) * step;
   if(v < minl) return 0.0;
   if(v > maxl) v = maxl;
   return NormalizeDouble(v,2);
}
bool GateByScores(
    double baseScore,           // qL oder qS
    double dirStrength,
    string bias,
    double qaValue,             // qaL oder qaS
    string &noteOut,
    int regimeId
)
{
    noteOut = "";

    // 1) Mindestscore abhängig vom Modus
    double minQ =
        (g_mode == MODE_SAFE       ? InpQual_Min_Safe :
        (g_mode == MODE_POSTTARGET ? InpQual_Min_PostTarget :
                                     InpQual_Min_Normal));

    // 2) Variante – ScoreProfile Offset
    StrategyVariant var = VariantGetById(g_currentVariantId);
    ScoreProfile prof = ScoreGetProfileById(var.scoreProfileId);

    double profileOffset = (bias == "LONG" ? prof.offsetLong : prof.offsetShort);
    minQ += profileOffset;

    // 3) Grundscore
    double effQ = baseScore;

    // 4) Learning-Shift (indikatorbasiert)
    double learnShift = 0.0;
    if(InpEnableLearning)
        learnShift = LearningGetShift(qaValue, bias, regimeId);
    effQ += learnShift;

    // 5) Regime-Struktur – leichtes tightening
    if(g_lastRegimeCtx.structure == REGIME_STR_NEAR_HIGH && bias == "LONG")
        minQ += 0.3;
    if(g_lastRegimeCtx.structure == REGIME_STR_NEAR_LOW && bias == "SHORT")
        minQ += 0.3;

    // 6) Exit-Shift aus Lernstatistik
    double band = LearningScoreBand(qaValue);
    int dir = (bias == "LONG" ? +1 : -1);

    int idx = LearningFindScoreStat(band, dir, regimeId);
    if(idx >= 0)
    {
        double exitShift = g_scoreStats[idx].exitShift;
        effQ += exitShift;

        if(MathAbs(exitShift) > 0.0001)
            noteOut += " exitShift=" + DoubleToString(exitShift,2);
    }

    // 7) Validierung Score
    if(!MathIsValidNumber(effQ))
        effQ = 0.0;

    // 8) Floor gegen negative Fehlinterpretationen
    if(effQ < -5.0)
        effQ = -5.0;

    // 9) Reject wenn Score < Mindestscore
    if(effQ < minQ)
    {
        noteOut = "score<thresh"
                  + (MathAbs(learnShift)>0.001 ? " learn="+DoubleToString(learnShift,2) : "")
                  + (MathAbs(profileOffset)>0.001 ? " prof="+DoubleToString(profileOffset,2) : "");
        return false;
    }

    // 10) Direction Strength muss > 0.8 sein (fix)
    if(dirStrength < 0.8)
    {
        noteOut = "dir<0.8";
        return false;
    }

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
void OpenStagedEntries(const EntrySnapshot &snap,string bias,double baseLots,double slPts,
                       double qL,double qS,double dL,double dS,double aL,double aS,double qaL,double qaS)
{
   if(!SymbolInfoTick(g_symbol,g_tick)) return;
   double atr=0; ATR(atr);
   double slPrice=0.0;
   double p1=Clamp(InpStage1_Pct,0,100), p2=Clamp(InpStage2_Pct,0,100), p3=Clamp(InpStage3_Pct,0,100);
   double sumPct = MathMax(1.0,(p1+p2+p3));
   double lots1=baseLots*(p1/sumPct), lots2=baseLots*(p2/sumPct), lots3=baseLots*(p3/sumPct);
   lots1 = NormalizeSplitLots(lots1);
   lots2 = NormalizeSplitLots(lots2);
   lots3 = NormalizeSplitLots(lots3);
   if(lots1<=0.0 && lots2<=0.0 && lots3<=0.0)
   {
      LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,
             qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,"split lots zero");
      return;
   }
   datetime exp = TimeCurrent() + InpPendingExpireMin*60;

   if(bias=="LONG"){
slPrice = g_tick.ask - slPts*g_point;

double safe = MathMax((double)MathMax(StopsLevelPts(),FreezeLevelPts())*g_point, 1.0*g_point);
double tpDist = atr * InpTP_ATR_Mult;

double tp1 = (InpUseTP ? SnapToTick(MathMax(g_tick.ask + tpDist, g_tick.ask + safe)) : 0.0);
      if(lots1>0.0)
      {
         bool ok1 = OrderBuy(lots1, slPrice, tp1, "LONG mkt");
         LogRow(ok1?"ENTRY_OK":"ENTRY_FAIL","Entry","OPEN",ModeName(),"LONG",(double)g_tick.ask,slPrice,tp1,
                qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,
                "market "+DoubleToString(p1,1)+"% lots="+DoubleToString(lots1,2));
      }
      // Marktfüller werden über OnTradeTransaction mit snap verknüpft

double price2 = g_tick.bid - (InpSplitRetrace1_ATR*atr);
double price3 = g_tick.bid - (InpSplitRetrace2_ATR*atr);
double sl2 = price2 - slPts*g_point;
double sl3 = price3 - slPts*g_point;

double tp2 = (InpUseTP ? SnapToTick(MathMax(price2 + tpDist, price2 + safe)) : 0.0);
double tp3 = (InpUseTP ? SnapToTick(MathMax(price3 + tpDist, price3 + safe)) : 0.0);

      if(lots2>0.0)
      {
         bool ok2 = OrderBuyLimit(lots2, price2, sl2, tp2, exp);
         LogRow(ok2?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"LONG",price2,sl2,tp2,
                qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,
                "limit "+DoubleToString(p2,1)+"% @ -"+DoubleToString(InpSplitRetrace1_ATR,2)+"*ATR lots="+DoubleToString(lots2,2));
         EntrySnapshot snap2=snap;
         snap2.entryPricePlan=price2;
         snap2.slPlan=sl2;
         snap2.tpPlan=tp2;
         if(ok2)
            LearningRegisterPendingOrder(Trade.ResultOrder(),snap2);
      }
      if(lots3>0.0)
      {
         bool ok3 = OrderBuyLimit(lots3, price3, sl3, tp3, exp);
         LogRow(ok3?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"LONG",price3,sl3,tp3,
                qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,
                "limit "+DoubleToString(p3,1)+"% @ -"+DoubleToString(InpSplitRetrace2_ATR,2)+"*ATR lots="+DoubleToString(lots3,2));
         EntrySnapshot snap3=snap;
         snap3.entryPricePlan=price3;
         snap3.slPlan=sl3;
         snap3.tpPlan=tp3;
         if(ok3)
            LearningRegisterPendingOrder(Trade.ResultOrder(),snap3);
      }
   } else {
slPrice = g_tick.bid + slPts*g_point;

double safe = MathMax((double)MathMax(StopsLevelPts(),FreezeLevelPts())*g_point, 1.0*g_point);
double tpDist = atr * InpTP_ATR_Mult;

double tp1 = (InpUseTP ? SnapToTick(MathMin(g_tick.bid - tpDist, g_tick.bid - safe)) : 0.0);
      if(lots1>0.0)
      {
         bool ok1 = OrderSell(lots1, slPrice, tp1, "SHORT mkt");
         LogRow(ok1?"ENTRY_OK":"ENTRY_FAIL","Entry","OPEN",ModeName(),"SHORT",(double)g_tick.bid,slPrice,tp1,
                qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,
                "market "+DoubleToString(p1,1)+"% lots="+DoubleToString(lots1,2));
      }
      // Marktfüller werden über OnTradeTransaction mit snap verknüpft

double price2 = g_tick.ask + (InpSplitRetrace1_ATR*atr);
double price3 = g_tick.ask + (InpSplitRetrace2_ATR*atr);
double sl2 = price2 + slPts*g_point;
double sl3 = price3 + slPts*g_point;

double tp2 = (InpUseTP ? SnapToTick(MathMin(price2 - tpDist, price2 - safe)) : 0.0);
double tp3 = (InpUseTP ? SnapToTick(MathMin(price3 - tpDist, price3 - safe)) : 0.0);

      if(lots2>0.0)
      {
         bool ok2 = OrderSellLimit(lots2, price2, sl2, tp2, exp);
         LogRow(ok2?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"SHORT",price2,sl2,tp2,
                qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,
                "limit "+DoubleToString(p2,1)+"% @ +"+DoubleToString(InpSplitRetrace1_ATR,2)+"*ATR lots="+DoubleToString(lots2,2));
         EntrySnapshot snap2=snap;
         snap2.entryPricePlan=price2;
         snap2.slPlan=sl2;
         snap2.tpPlan=tp2;
         if(ok2)
            LearningRegisterPendingOrder(Trade.ResultOrder(),snap2);
      }
      if(lots3>0.0)
      {
         bool ok3 = OrderSellLimit(lots3, price3, sl3, tp3, exp);
         LogRow(ok3?"ENTRY_OK":"ENTRY_FAIL","Entry","PENDING",ModeName(),"SHORT",price3,sl3,tp3,
                qL,qS,dL,dS,aL,aS,qaL,qaS,0,true,
                "limit "+DoubleToString(p3,1)+"% @ +"+DoubleToString(InpSplitRetrace2_ATR,2)+"*ATR lots="+DoubleToString(lots3,2));
         EntrySnapshot snap3=snap;
         snap3.entryPricePlan=price3;
         snap3.slPlan=sl3;
         snap3.tpPlan=tp3;
         if(ok3)
            LearningRegisterPendingOrder(Trade.ResultOrder(),snap3);
      }
   }
}

void TryEnter(
    const EntrySnapshot &snap,
    string bias,
    double qL, double qS,
    double dirStrength,
    double aL, double aS,
    double qaL, double qaS
)

{
    // --- 1) DI/ADX-Filter ---
    if(!DIConditionOK(bias))
    {
        g_lastBlockReason = "DI/ADX";
        LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,
               qL,qS,dirStrength,0,aL,aS,qaL,qaS,0,true,"DI/ADX");
        return;
    }

    // --- 2) Spread Check ---
    if(!SpreadOK())
    {
        g_lastBlockReason="Spread";
        LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,
               qL,qS,dirStrength,0,aL,aS,qaL,qaS,0,true,"spread too high");
        return;
    }

    // --- 3) ATR / Stop Distance ---
    double atr=0;
    if(!ATR(atr) || atr<=0.0 || g_point<=0.0)
    {
        g_lastBlockReason="ATR/Point";
        LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,
               qL,qS,dirStrength,0,aL,aS,qaL,qaS,0,true,"ATR missing");
        return;
    }

    double slPts = (atr * InpATR_Mult_SL) / g_point;
    if(slPts <= 0.0)
    {
        g_lastBlockReason="SLPts";
        LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,
               qL,qS,dirStrength,0,aL,aS,qaL,qaS,0,true,"slPts invalid");
        return;
    }

    // --- 4) Lot Calculation ---
    double baseLots = CalcLotByRisk(slPts);
    if(baseLots <= 0.0)
    {
        g_lastBlockReason = "LotCalc";
        LogRow("ENTRY_BLOCK","Entry","BLOCK",ModeName(),bias,0,0,0,
               qL,qS,dirStrength,0,aL,aS,qaL,qaS,0,true,"lot calc failed");
        return;
    }

    // --- 5) Entry ---
    OpenStagedEntries(
        snap,
        bias,
        baseLots,
        slPts,
        qL, qS,
        dirStrength, dirStrength,      // symmetric dirStrength!
        aL, aS,
        qaL, qaS
    );
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

bool ApplyUnifiedTrail(ulong ticket,long ptype,double entry,double oldSL,double atr)
{
   if(!InpUseUnifiedTrail) return false;
   if(!SymbolInfoTick(g_symbol,g_tick)) return false;

   // TRAILING: use trailingSet - Hole aktive Variante und TrailingSet
   int ctxIdx = LearningFindTradeContext(ticket);
   int variantId = (ctxIdx>=0 ? g_tradeContexts[ctxIdx].variantId : g_currentVariantId);
   StrategyVariant var = VariantGetById(variantId);
   TrailingSet trailSet = TrailingGetSetById(var.trailingSetId);
   
   // Berechne initialRisk (Entry-SL Abstand in Punkten)
   double initialRiskPts = 0.0;
   if(oldSL>0.0)
      initialRiskPts = (ptype==POSITION_TYPE_BUY ? (entry-oldSL)/g_point : (oldSL-entry)/g_point);
   else
   {
      // Fallback: ATR-basiert
      if(atr>0.0) initialRiskPts = (atr*InpATR_Mult_SL)/g_point;
      else initialRiskPts = InpTrailActivationPts; // Fallback
   }
   if(initialRiskPts<=0.0) return false;

   double cur = (ptype==POSITION_TYPE_BUY ? g_tick.bid : g_tick.ask);
   // STABILITY: check g_point before division
   if(g_point<=0.0) return false;
   double profitPts = (ptype==POSITION_TYPE_BUY ? (cur - entry)/g_point : (entry - cur)/g_point);
   
   // TRAILING: use trailingSet - Aktivierung basierend auf R (Risk-Multiples)
   // STABILITY: prevent division by zero
   if(initialRiskPts<=0.0) return false;
   double profitR = profitPts / initialRiskPts;
   if(profitR < trailSet.startR) return false; // Noch nicht genug Profit in R

   const double minPts   = (double)MathMax(StopsLevelPts(), FreezeLevelPts());
   const double safeDist = MathMax(minPts*g_point, 1.0*g_point);

   // TRAILING: use trailingSet - Schritt basierend auf R
   double stepDistR = trailSet.stepR * initialRiskPts * g_point;
   double stepDist = MathMax(stepDistR, (double)InpTrailStepPts*g_point);
   double atrDist  = (atr>0.0 && InpTrailATRMult>0.0 ? atr*InpTrailATRMult : 0.0);
   double targetDist = MathMax(stepDist, atrDist);
   if(targetDist<=0.0) targetDist = safeDist*1.5;

   double desired = (ptype==POSITION_TYPE_BUY ? cur - targetDist : cur + targetDist);
   if(ptype==POSITION_TYPE_BUY){
      desired = MathMin(desired, cur - safeDist);
      desired = MathMax(desired, entry + 1.0*g_point);
      if(oldSL>0.0) desired = MathMax(desired, oldSL);
   } else {
      desired = MathMax(desired, cur + safeDist);
      desired = MathMin(desired, entry - 1.0*g_point);
      if(oldSL>0.0) desired = MathMin(desired, oldSL);
   }

   double minStepMove = MathMax((double)InpTrailMinStepPts*g_point, 0.02*MathMax(atr,safeDist));
   desired = SnapToTick(desired);
   if(oldSL>0.0 && MathAbs(desired-oldSL) < minStepMove) return false;
   if(desired<=0.0) return false;

   if(!PositionSelectByTicket(ticket)) return false;
   double currentTP = PositionGetDouble(POSITION_TP);
   bool mod = PositionModifySafe(ticket, desired, currentTP);
   LogRow(mod?"MOD_OK":"MOD_FAIL","PM","TRAIL_UNIFIED",ModeName(),
          (ptype==POSITION_TYPE_BUY?"LONG":"SHORT"),
          cur,desired,currentTP,
          0,0,0,0,0,0,0,0,true,"unified trail R="+DoubleToString(profitR,2));
   return mod;
}

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
      int ctxIdx = LearningFindTradeContext(ticket);
      if(ctxIdx>=0){
         // STABILITY: check g_point before division
      if(g_point>0.0)
      {
         double signedPts = (ptype==POSITION_TYPE_BUY ? (g_tick.bid - entry)/g_point : (entry - g_tick.ask)/g_point);
         if(signedPts > g_tradeContexts[ctxIdx].mfePts) g_tradeContexts[ctxIdx].mfePts = signedPts;
         if(signedPts < g_tradeContexts[ctxIdx].maePts) g_tradeContexts[ctxIdx].maePts = signedPts;
      }
      }

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
if(InpMoveToBE && a>0.0 && g_point>0.0)
{
   double slPts = (a*InpATR_Mult_SL)/g_point;
   // STABILITY: prevent division by zero
   if(slPts<=0.0) { /* skip BE logic if slPts invalid */ }
   else
   {
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
}

if(InpUseUnifiedTrail)
{
   if(ApplyUnifiedTrail(ticket,ptype,entry,oldSL,a)) continue;
}
else
{
// --- FIXED TRAIL (optional) ---------------------------------------
if(InpUseFixedTrail && g_point>0.0)
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
   // STABILITY: defensive check for g_point
   if(g_point<=0.0)
   {
      Print("[EA] ERROR: SYMBOL_POINT is invalid (",g_point,"), using 0.01");
      g_point = 0.01;
   }

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
   if(InpUseIchimoku)
      hIKH = iIchimoku(g_symbol,InpIKH_Timeframe,InpIKH_Tenkan,InpIKH_Kijun,InpIKH_SenkouB);
   else
      hIKH = INVALID_HANDLE;

   EnsureLogOpen();
   if(InpEnableLearningMonitor) MonitorEnsureFile();
   LearningEnsureStatsFile();
   News_LoadFile();

   // Day anchor
   MqlDateTime z; TimeToStruct(TimeCurrent(),z); if(z.hour<InpDayResetHour) z.day-=1;
   z.hour=InpDayResetHour; z.min=0; z.sec=0;
   g_dayAnchor = StructToTime(z);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_safeEnterEquity=0.0;

   g_mode=InpManualOverride?MODE_MANUAL:MODE_NORMAL;

   if(InpUseVWAP) VWAP_InitSession();
   // VARIANT: presets - Initialisierung
   VariantInitPresets();
   Print("[EA] Init OK v1.1 | Symbol=",g_symbol);
}

int OnInit()
{
   OnInitCommon();
   if(hATR==INVALID_HANDLE || hMACD==INVALID_HANDLE || hADX==INVALID_HANDLE ||
      hSAR==INVALID_HANDLE || hCCI==INVALID_HANDLE || hSTO==INVALID_HANDLE ||
      hMFI==INVALID_HANDLE || hEMA_M1_5==INVALID_HANDLE || hEMA_M1_10==INVALID_HANDLE ||
      hEMA_M1_50==INVALID_HANDLE || hEMA_M1_200==INVALID_HANDLE || hEMA_H1_50==INVALID_HANDLE ||
      hEMA_H1_200==INVALID_HANDLE || hRSI_M1_14==INVALID_HANDLE || hEMA_M15_5==INVALID_HANDLE || hEMA_M15_10==INVALID_HANDLE ||
      (InpUseIchimoku && hIKH==INVALID_HANDLE))
      return(INIT_FAILED);
   // LEARNING: Persistence - Stats beim Start laden
   if(!LoadLearningStatsFromFile() && InpDebug)
      Print("[EA] learning stats file could not be loaded, starting fresh");
   if(InpEnableIndicatorLearning && !LoadIndicatorStatsFromFile() && InpDebug)
      Print("[EA] indicator stats file could not be loaded, starting fresh");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_logHandle!=INVALID_HANDLE){ FileClose(g_logHandle); g_logHandle=INVALID_HANDLE; }

   // LEARNING: Persistence - Stats beim Beenden speichern
   // STABILITY: only save if learning is enabled
 if(InpEnableLearning)
      SaveLearningStatsToFile();
   if(InpEnableIndicatorLearning)
      SaveIndicatorStatsToFile();

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
   if(hIKH!=INVALID_HANDLE)        IndicatorRelease(hIKH);
}

void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.symbol!=g_symbol) return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD) return;
   HistorySelect(TimeCurrent()-7*24*60*60,TimeCurrent()+60);
   ulong dealMagic=(ulong)HistoryDealGetInteger(trans.deal,DEAL_MAGIC);
   if(dealMagic!=g_magic) return;
   ENUM_DEAL_ENTRY entry=(ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_IN)
   {
      bool found=false;
      EntrySnapshot snap=LearningConsumePendingOrder(trans.order,found);
      if(!found) snap=g_lastDecisionSnapshot;
      if(!snap.valid) return;
      double entryPrice=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
      if(entryPrice<=0.0) entryPrice=trans.price;
      snap.entryPricePlan=entryPrice;
      ulong positionId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
      LearningStoreTradeContext(positionId,snap,entryPrice,snap.slPlan,snap.tpPlan);
   }
   else if(entry==DEAL_ENTRY_OUT)
   {
      ulong positionId=(ulong)HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
      int idx=LearningFindTradeContext(positionId);
      if(idx<0) return;
      double exitPrice=HistoryDealGetDouble(trans.deal,DEAL_PRICE);
      double profitMoney=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_SWAP);
      TradeContextEntry ctx=g_tradeContexts[idx];
      // STABILITY: check g_point before division
      double profitPts=0.0;
      if(g_point>0.0)
         profitPts=(ctx.snap.direction=="LONG"? (exitPrice-ctx.entryPrice)/g_point : (ctx.entryPrice-exitPrice)/g_point);
      ENUM_DEAL_REASON reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal,DEAL_REASON);
      datetime exitTime=(datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);
      string reasonText=DealReasonText(reason);
      EvaluateClosedTrade(positionId,exitPrice,profitPts,profitMoney,reasonText,exitTime);
   }
}
// ==============================
// ============ TICK ============
// ==============================
void OnTick()
{
   if(!SymbolInfoTick(g_symbol,g_tick)) return;

   // HUD
   double spreadPts=0.0;
   if(g_point>0.0) spreadPts=(g_tick.ask-g_tick.bid)/g_point;
   string hud = "Mode:"+ModeName()+" | PnL:"+DoubleToString(TodayPnL(),2)+"€ | Spread:"+DoubleToString(spreadPts,1)+"pt | LastBlock:"+g_lastBlockReason;
   Comment(hud);

   // nur M1 neu (Positionspflege immer)
   datetime m1Close = iTime(g_symbol, InpTF_Work, 0);
   if(m1Close==0){ ManagePositions(); return; }
   bool isNewBar = (m1Close!=g_lastM1CloseTime);
   bool shouldMonitor = false;
   if(isNewBar) shouldMonitor=true;
   if((TimeCurrent()-g_lastMonitorWriteTime)>=3600) shouldMonitor=true;
   if(shouldMonitor && InpEnableLearningMonitor) MonitorWriteSnapshot();

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

// ===============================
// ======== SCORE-PROCESSING =====
// ===============================

// 1) Quality Score berechnen
double qL = 0.0, qS = 0.0;
string qNote = "";
ComputeQualityScore(qL, qS, qNote);

// 2) Meta-Adjust anwenden (falls aktiv)
double aL = 0.0, aS = 0.0;
ApplyMetaAdjust(aL, aS);

// 3) Clamping der Adjustments
aL = Clamp(aL, -InpAdjustMaxAbs, InpAdjustMaxAbs);
aS = Clamp(aS, -InpAdjustMaxAbs, InpAdjustMaxAbs);

// 4) Kombinierte Scores
double qaL = qL + aL;
double qaS = qS + aS;

// 5) Sicherstellen, dass keine NaN-Werte auftreten
if(!MathIsValidNumber(qaL)) qaL = 0.0;
if(!MathIsValidNumber(qaS)) qaS = 0.0;

// 6) Negativ-Floor (verhindert anti-Signale)
const double minFloor = -5.0;
qaL = MathMax(minFloor, qaL);
qaS = MathMax(minFloor, qaS);

// 7) Richtung & Stärke bestimmen (nur EINMAL!)
string bias = "";
double dirStrength = 0.0;
bool hasMaj = MajorityDecision(bias, dirStrength);

// 8) dirStrength absichern und ggf. blocken
if(!MathIsValidNumber(dirStrength))
    dirStrength = 0.0;

if(!hasMaj){
    g_lastBlockReason = "NoMajority";
    LogRow("DIR_BLOCK","Direction","BLOCK",ModeName(),"-",0,0,0,
           qL,qS,0,0,aL,aS,qaL,qaS,0,true,"no majority");
    ManagePositions();
    return;
}


   // VARIANT: selection - Variante für nächsten Trade wählen
   g_currentVariantId = ChooseVariantForNextTrade();

   // Gate & Entry
   string gateNote="";
   EntrySnapshot snap = BuildEntrySnapshot(bias,qL,qS,qaL,qaS,dirStrength,cats,htfok);
   g_lastDecisionSnapshot = snap;
 if(bias=="LONG")
{
    bool ok = GateByScores(qaL, dirStrength, "LONG", qaL, gateNote, snap.regimeId);
    if(ok)
        TryEnter(snap, "LONG", qL, qS, dirStrength, aL, aS, qaL, qaS);
    else
        g_lastBlockReason="Gate";
}

else if(bias=="SHORT")
{
    bool ok = GateByScores(qaS, dirStrength, "SHORT", qaS, gateNote, snap.regimeId);
    if(ok)
        TryEnter(snap, "SHORT", qL, qS, dirStrength, aL, aS, qaL, qaS);
    else
        g_lastBlockReason="Gate";
}


   ManagePositions();
}
