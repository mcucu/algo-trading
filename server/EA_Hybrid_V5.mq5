//+------------------------------------------------------------------+
//| EA Hybrid V5                                                   |
//| State-Based Day Trading Engine                                   |
//| TREND IMPULSE / TREND PULLBACK / RANGE                            |
//| + HTF Direction Lock + Structure Protection                      |
//| Platform : MetaTrader 5 (MQL5 Native)                            |
//+------------------------------------------------------------------+
#property strict
#property version "5.4"

#include <Trade/Trade.mqh>
CTrade trade;

//========================= INPUT ===================================
// --- Risk
input double RiskPercent = 0.5;
input double RR_TrendImpulse = 1.4;
input double RR_Pullback     = 1.2;

// --- HTF
input ENUM_TIMEFRAMES HTF = PERIOD_H1;
input int ATR_Period = 14;
input int ADX_Period = 14;

// --- EMA
input int EMA_Fast = 20;
input int EMA_Mid  = 50;
input int EMA_Slow = 200;

// --- RSI (PULLBACK ONLY)
input int    RSI_Period = 14;
input double RSI_BuyMin  = 40;
input double RSI_BuyMax  = 50;
input double RSI_SellMin = 50;
input double RSI_SellMax = 60;

// --- Structure / Direction
input bool EnableHTFDirectionLock = true;
input bool EnableStructureFilter  = true;

// --- BE & Partial
input bool   UseBreakEven = true;
input bool   UsePartialTP = true;

// Trend Impulse
input double BE_R_Impulse       = 0.6;
input double Partial_R_Impulse  = 1.0;
input double PartialPct_Impulse = 50;

// Trend Pullback
input double BE_R_Pullback       = 0.4;
input double Partial_R_Pullback  = 0.8;
input double PartialPct_Pullback = 40;

// --- Risk Control
input int    MaxTradesDay = 3;
input double MaxDailyLossPercent = 4.0;
input bool   EnableDailyProfitTargetLock = true;
input double DailyProfitTargetPercent = 3.0;
input int    CooldownMinutes = 15;
input int    MaxOpenPositions = 1;
input bool   EnableSpreadFilter = true;
input double MaxSpreadPoints = 80;

// --- Reversal Protection
input bool   EnablePanicExit = true;
input double PanicATR = 1.5;
input bool   EnableLossStreakLock = true;
input int    LossStreakLimit = 2;
input int    LossLockHours = 8;

// --- HTF Range + LTF Breakout-Retest
input bool   EnableHTFRangeLTFBreakout = true;
input ENUM_TIMEFRAMES HTF_RangeTF1 = PERIOD_D1;
input ENUM_TIMEFRAMES HTF_RangeTF2 = PERIOD_H4;
input bool   RequireBothHTFConsolidating = true;
input int    HTF_RangeLookbackBars = 20;
input double HTF_MaxWidthATR = 6.0;
input double HTF_ADX_Max = 22.0;
input bool   RequireBreakoutRetest = true;

// --- Session
input int StartHour = 7;
input int EndHour   = 22;

// --- Range Mode
input bool   EnableRangeBreakout = true;
input double RangeRiskPercent = 0.2;
input double RR_Range         = 0.5;

// --- Range Breakout
input int    RangeLookbackBars = 15;   // box length
input double RangeBreakBufferATR = 0.25; // breakout buffer

// --- Market State Thresholds
input double ADX_Strong = 25;
input double ADX_Weak   = 18;
input double MinATR_HTF_Points = 20;

// --- Misc
input ulong MagicNumber = 20260115;
input bool VerboseLog = true;

//========================= ENUM ====================================
enum MARKET_STATE
{
   STATE_TREND_IMPULSE = 0,
   STATE_TREND_PULLBACK = 1,
   STATE_RANGE = 2,
   STATE_HTF_RANGE_LTF_BREAKOUT = 3
};

//========================= GLOBAL ==================================
int hATR_H1, hADX_H1;
int hATR_CUR;
int hATR_RTF1, hADX_RTF1;
int hATR_RTF2, hADX_RTF2;
int hEMA_HTF;
int hEMA20, hEMA50, hEMA200;
int hRSI;

datetime lastBar=0, lastTradeTime=0;
int tradesToday=0, lastDay=-1;
double dayStartEquity=0;
bool tradingLocked=false;
int consecutiveLosses=0;
datetime lossLockUntil=0;

string GV_BE_PREFIX = "BE_";
string GV_PT_PREFIX = "PT_";
string lastSkipReason = "";

double gRangeHigh = 0;
double gRangeLow  = 0;

//========================= INIT ====================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   hATR_H1 = iATR(_Symbol, HTF, ATR_Period);
   hADX_H1 = iADX(_Symbol, HTF, ADX_Period);
   hATR_CUR = iATR(_Symbol, _Period, ATR_Period);
   hATR_RTF1 = iATR(_Symbol, HTF_RangeTF1, ATR_Period);
   hADX_RTF1 = iADX(_Symbol, HTF_RangeTF1, ADX_Period);
   hATR_RTF2 = iATR(_Symbol, HTF_RangeTF2, ATR_Period);
   hADX_RTF2 = iADX(_Symbol, HTF_RangeTF2, ADX_Period);
   hEMA_HTF = iMA(_Symbol,HTF,EMA_Mid,0,MODE_EMA,PRICE_CLOSE);

   hEMA20  = iMA(_Symbol,_Period,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hEMA50  = iMA(_Symbol,_Period,EMA_Mid ,0,MODE_EMA,PRICE_CLOSE);
   hEMA200 = iMA(_Symbol,_Period,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);

   hRSI = iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);

   if(hATR_H1==INVALID_HANDLE || hADX_H1==INVALID_HANDLE ||
      hATR_CUR==INVALID_HANDLE ||
      hATR_RTF1==INVALID_HANDLE || hADX_RTF1==INVALID_HANDLE ||
      hATR_RTF2==INVALID_HANDLE || hADX_RTF2==INVALID_HANDLE ||
      hEMA_HTF==INVALID_HANDLE ||
      hEMA20==INVALID_HANDLE || hEMA50==INVALID_HANDLE ||
      hEMA200==INVALID_HANDLE || hRSI==INVALID_HANDLE)
   {
      Print("INIT FAILED | Invalid indicator handle");
      return INIT_FAILED;
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   IndicatorRelease(hADX_H1);
   IndicatorRelease(hATR_CUR);
   IndicatorRelease(hATR_RTF1);
   IndicatorRelease(hADX_RTF1);
   IndicatorRelease(hATR_RTF2);
   IndicatorRelease(hADX_RTF2);
   IndicatorRelease(hEMA_HTF);
   IndicatorRelease(hEMA20);
   IndicatorRelease(hEMA50);
   IndicatorRelease(hEMA200);
   IndicatorRelease(hRSI);
}

//========================= UTILS ===================================
double BUF(int h,int b,int s)
{
   double v[];
   if(CopyBuffer(h,b,s,1,v)<=0) return 0;
   return v[0];
}

bool IsNewBar()
{
   datetime t=iTime(_Symbol,_Period,0);
   if(t!=lastBar){ lastBar=t; return true; }
   return false;
}

bool InSession()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   return (t.hour>=StartHour && t.hour<=EndHour);
}

void LogSkip(string reason)
{
   if(!VerboseLog) return;
   if(reason!=lastSkipReason)
   {
      Print("⏭️ SKIP | ",reason);
      lastSkipReason=reason;
   }
}

bool SpreadOK()
{
   if(!EnableSpreadFilter) return true;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0 || bid<=0) return false;
   double spreadPts=(ask-bid)/_Point;
   if(spreadPts>MaxSpreadPoints)
   {
      LogSkip("Spread too high");
      return false;
   }
   return true;
}

bool LossStreakLocked()
{
   if(!EnableLossStreakLock) return false;
   return (TimeCurrent()<lossLockUntil);
}

double TFRangeWidth(ENUM_TIMEFRAMES tf,int lookback,int startShift=1)
{
   if(lookback<1) return 0;
   double hi=iHigh(_Symbol,tf,startShift);
   double lo=iLow(_Symbol,tf,startShift);

   for(int i=startShift+1;i<startShift+lookback;i++)
   {
      double h=iHigh(_Symbol,tf,i);
      double l=iLow(_Symbol,tf,i);
      if(h>hi) hi=h;
      if(l<lo) lo=l;
   }
   return hi-lo;
}

bool IsTFConsolidating(ENUM_TIMEFRAMES tf,int hAtr,int hAdx)
{
   double atr=BUF(hAtr,0,1);
   double adx=BUF(hAdx,0,1);
   if(atr<=0 || adx<=0) return false;

   double width=TFRangeWidth(tf,HTF_RangeLookbackBars,1);
   if(width<=0) return false;

   if(adx>HTF_ADX_Max) return false;
   if(width>HTF_MaxWidthATR*atr) return false;
   return true;
}

bool IsHTFConsolidating()
{
   if(!EnableHTFRangeLTFBreakout) return false;
   bool tf1=IsTFConsolidating(HTF_RangeTF1,hATR_RTF1,hADX_RTF1);
   bool tf2=IsTFConsolidating(HTF_RangeTF2,hATR_RTF2,hADX_RTF2);
   return RequireBothHTFConsolidating ? (tf1 && tf2) : (tf1 || tf2);
}

//========================= HTF & STRUCTURE =========================
bool HTF_Uptrend()
{
   double htfMa = BUF(hEMA_HTF,0,1);
   if(htfMa<=0) return false;
   return iClose(_Symbol,HTF,1) > htfMa;
}
bool HTF_Downtrend()
{
   double htfMa = BUF(hEMA_HTF,0,1);
   if(htfMa<=0) return false;
   return iClose(_Symbol,HTF,1) < htfMa;
}

double LastSwingLow(int lookback=20)
{
   double l=iLow(_Symbol,_Period,1);
   for(int i=2;i<=lookback;i++)
      if(iLow(_Symbol,_Period,i)<l) l=iLow(_Symbol,_Period,i);
   return l;
}

double LastSwingHigh(int lookback=20)
{
   double h=iHigh(_Symbol,_Period,1);
   for(int i=2;i<=lookback;i++)
      if(iHigh(_Symbol,_Period,i)>h) h=iHigh(_Symbol,_Period,i);
   return h;
}

void UpdateRangeBox(int bars)
{
   if(bars<2) bars=2;
   // Exclude bar 1 so breakout check on bar 1 is meaningful.
   gRangeHigh = iHigh(_Symbol,_Period,2);
   gRangeLow  = iLow(_Symbol,_Period,2);

   for(int i=3;i<=bars+1;i++)
   {
      if(iHigh(_Symbol,_Period,i) > gRangeHigh)
         gRangeHigh = iHigh(_Symbol,_Period,i);

      if(iLow(_Symbol,_Period,i) < gRangeLow)
         gRangeLow = iLow(_Symbol,_Period,i);
   }
}

//========================= DAILY LOCK ===============================
void CheckDailyReset()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(),t);
   if(t.day!=lastDay)
   {
      lastDay=t.day;
      tradesToday=0;
      tradingLocked=false;
      dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      Print("🔄 New Day | Equity:",dayStartEquity);
   }
}

bool DailyLossExceeded()
{
   double loss=(dayStartEquity-AccountInfoDouble(ACCOUNT_EQUITY))
                /dayStartEquity*100.0;
   if(loss>=MaxDailyLossPercent)
   {
      tradingLocked=true;
      Print("🛑 DAILY LOCK");
      return true;
   }
   return false;
}

bool DailyProfitTargetReached()
{
   if(!EnableDailyProfitTargetLock) return false;
   if(dayStartEquity<=0) return false;

   double gain=(AccountInfoDouble(ACCOUNT_EQUITY)-dayStartEquity)
               /dayStartEquity*100.0;
   if(gain>=DailyProfitTargetPercent)
   {
      tradingLocked=true;
      Print("🎯 DAILY TARGET LOCK");
      return true;
   }
   return false;
}

void PanicExit()
{
   if(!EnablePanicExit) return;

   double atr = BUF(hATR_CUR,0,1);
   if(atr<=0) return;

   double candle = MathAbs(iClose(_Symbol,_Period,1)-iOpen(_Symbol,_Period,1));
   if(candle < PanicATR * atr) return;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      if(trade.PositionClose(ticket))
      {
         Print("PANIC EXIT | Ticket:",ticket);
      }
      else
      {
         Print("Panic close failed | Ticket:",ticket,
               " | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
   }
}

//========================= MARKET STATE ============================
MARKET_STATE DetectMarketState()
{
   double atr = BUF(hATR_H1,0,1);
   double adx = BUF(hADX_H1,0,1);

   if(atr/_Point < MinATR_HTF_Points || adx < ADX_Weak)
   {
      if(IsHTFConsolidating())
         return STATE_HTF_RANGE_LTF_BREAKOUT;
      return STATE_RANGE;
   }

   if(adx >= ADX_Strong)
      return STATE_TREND_IMPULSE;

   return STATE_TREND_PULLBACK;
}

//========================= COMMON ==================================
double SwingLow()
{
   double l=iLow(_Symbol,_Period,1);
   for(int i=2;i<=10;i++) if(iLow(_Symbol,_Period,i)<l) l=iLow(_Symbol,_Period,i);
   return l-0.2*BUF(hATR_H1,0,1);
}

double SwingHigh()
{
   double h=iHigh(_Symbol,_Period,1);
   for(int i=2;i<=10;i++) if(iHigh(_Symbol,_Period,i)>h) h=iHigh(_Symbol,_Period,i);
   return h+0.2*BUF(hATR_H1,0,1);
}

double CalcLot(double riskPct,double entry,double sl)
{
   double risk=AccountInfoDouble(ACCOUNT_BALANCE)*riskPct/100.0;
   double dist=MathAbs(entry-sl);
   if(risk<=0 || dist<=0) return 0;

   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickValue<=0 || tickSize<=0) return 0;

   double riskPerLot=(dist/tickSize)*tickValue;
   if(riskPerLot<=0) return 0;

   double lot=risk/riskPerLot;
   double min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double max=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) return 0;

   lot=MathMin(max,lot);
   lot=MathFloor(lot/step)*step;
   if(lot<min) return 0;
   return lot;
}

//========================= MANAGE POSITIONS ========================
void ManagePositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      long type=PositionGetInteger(POSITION_TYPE);

      double price=(type==POSITION_TYPE_BUY)?
         SymbolInfoDouble(_Symbol,SYMBOL_BID):
         SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double R=MathAbs(entry-sl);
      if(R<=0) continue;
      double gainR=MathAbs(price-entry)/R;

      string beKey=GV_BE_PREFIX+(string)ticket;
      string ptKey=GV_PT_PREFIX+(string)ticket;

      double rr=MathAbs(tp-entry)/R;
      double beR=0, ptR=0, ptPct=0;
      bool manage=true;

      if(rr>=RR_TrendImpulse-0.1)
      {
         beR=BE_R_Impulse; ptR=Partial_R_Impulse; ptPct=PartialPct_Impulse;
      }
      else if(rr>=RR_Pullback-0.1)
      {
         beR=BE_R_Pullback; ptR=Partial_R_Pullback; ptPct=PartialPct_Pullback;
      }
      else manage=false;

      if(!manage) continue;

      if(UseBreakEven && gainR>=beR && !GlobalVariableCheck(beKey))
      {
         if(trade.PositionModify(ticket,entry,tp))
         {
            GlobalVariableSet(beKey,TimeCurrent());
            Print("🟡 BE | Ticket:",ticket);
         }
         else
         {
            Print("BE modify failed | Ticket:",ticket,
                  " | Retcode:",trade.ResultRetcode(),
                  " | ",trade.ResultRetcodeDescription());
         }
      }

      if(UsePartialTP && gainR>=ptR && !GlobalVariableCheck(ptKey))
      {
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         double min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double closeVol=MathFloor(vol*ptPct/100.0/step)*step;

         if(closeVol>=min)
         {
            if(trade.PositionClosePartial(ticket,closeVol))
            {
               GlobalVariableSet(ptKey,TimeCurrent());
               Print("🟢 PARTIAL | Ticket:",ticket);
            }
            else
            {
               Print("Partial close failed | Ticket:",ticket,
                     " | Retcode:",trade.ResultRetcode(),
                     " | ",trade.ResultRetcodeDescription());
            }
         }
      }
   }
}

//========================= STRATEGIES ==============================

void TradeTrendImpulse()
{
   double ema20=BUF(hEMA20,0,1);
   double ema50=BUF(hEMA50,0,1);
   double ema200=BUF(hEMA200,0,1);

   bool bullishStack=(ema20>ema50 && ema50>ema200);
   bool bearishStack=(ema20<ema50 && ema50<ema200);

   bool allowBuy = (!EnableHTFDirectionLock || HTF_Uptrend());
   bool allowSell = (!EnableHTFDirectionLock || HTF_Downtrend());

   if(!bullishStack && !bearishStack)
   {
      LogSkip("Impulse EMA stack invalid");
      return;
   }

   if(bullishStack && allowBuy)
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl=SwingLow();
      double tp=entry+(entry-sl)*RR_TrendImpulse;
      double lot=CalcLot(RiskPercent,entry,sl);
      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🚀 IMPULSE BUY");
      }
      else if(lot>0)
      {
         Print("Impulse BUY failed | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
   }
   else if(bearishStack && allowSell)
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl=SwingHigh();
      double tp=entry-(sl-entry)*RR_TrendImpulse;
      double lot=CalcLot(RiskPercent,entry,sl);
      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🚀 IMPULSE SELL");
      }
      else if(lot>0)
      {
         Print("Impulse SELL failed | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
   }
   else
   {
      LogSkip("Impulse blocked by direction lock or EMA side");
   }
}

void TradeTrendPullback()
{
   double rsi=BUF(hRSI,0,1);
   bool allowBuy = EnableHTFDirectionLock ? HTF_Uptrend() : (BUF(hEMA20,0,1)>=BUF(hEMA50,0,1));
   bool allowSell = EnableHTFDirectionLock ? HTF_Downtrend() : (BUF(hEMA20,0,1)<=BUF(hEMA50,0,1));

   // === BUY SIDE ===
   if(allowBuy)
   {
      if(rsi>=RSI_BuyMin && rsi<=RSI_BuyMax &&
         iLow(_Symbol,_Period,1)<=BUF(hEMA20,0,1) &&
         iClose(_Symbol,_Period,1)>BUF(hEMA20,0,1))
      {
         if(EnableStructureFilter)
         {
            if(iLow(_Symbol,_Period,1) < LastSwingLow())
            {
               LogSkip("Pullback BUY skipped (HL broken)");
               return;
            }
         }

         double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double sl=SwingLow();
         double tp=entry+(entry-sl)*RR_Pullback;
         double lot=CalcLot(RiskPercent,entry,sl);
         if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
         {
            tradesToday++; lastTradeTime=TimeCurrent();
            Print("🟡 PULLBACK BUY");
         }
         else if(lot>0)
         {
            Print("Pullback BUY failed | Retcode:",trade.ResultRetcode(),
                  " | ",trade.ResultRetcodeDescription());
         }
      }
   }

   // === SELL SIDE ===
   if(allowSell)
   {
      if(rsi>=RSI_SellMin && rsi<=RSI_SellMax &&
         iHigh(_Symbol,_Period,1)>=BUF(hEMA20,0,1) &&
         iClose(_Symbol,_Period,1)<BUF(hEMA20,0,1))
      {
         if(EnableStructureFilter)
         {
            if(iHigh(_Symbol,_Period,1) > LastSwingHigh())
            {
               LogSkip("Pullback SELL skipped (LH broken)");
               return;
            }
         }

         double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double sl=SwingHigh();
         double tp=entry-(sl-entry)*RR_Pullback;
         double lot=CalcLot(RiskPercent,entry,sl);
         if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
         {
            tradesToday++; lastTradeTime=TimeCurrent();
            Print("🟡 PULLBACK SELL");
         }
         else if(lot>0)
         {
            Print("Pullback SELL failed | Retcode:",trade.ResultRetcode(),
                  " | ",trade.ResultRetcodeDescription());
         }
      }
   }
}

void TradeRangeBreakout()
{
   if(!EnableRangeBreakout)
   {
      LogSkip("Range breakout disabled");
      return;
   }

   UpdateRangeBox(RangeLookbackBars);

   double atr = BUF(hATR_H1,0,1);
   if(atr<=0)
   {
      LogSkip("ATR not ready");
      return;
   }
   double buffer = atr * RangeBreakBufferATR;

   double close = iClose(_Symbol,_Period,1);

   // ================= BUY BREAKOUT =================
   if(close > gRangeHigh + buffer)
   {
      if(EnableHTFDirectionLock && HTF_Downtrend())
      {
         LogSkip("Buy breakout skipped (HTF down)");
         return;
      }

      double entry = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl = gRangeLow - buffer;
      double tp = entry + (entry - sl) * RR_Range;
      double lot = CalcLot(RangeRiskPercent,entry,sl);

      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++;
         lastTradeTime = TimeCurrent();
         Print("🟦 RANGE BREAKOUT BUY");
      }
      else if(lot>0)
      {
         Print("Range BUY failed | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
      return;
   }

   // ================= SELL BREAKOUT =================
   if(close < gRangeLow - buffer)
   {
      if(EnableHTFDirectionLock && HTF_Uptrend())
      {
         LogSkip("Sell breakout skipped (HTF up)");
         return;
      }

      double entry = SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl = gRangeHigh + buffer;
      double tp = entry - (sl - entry) * RR_Range;
      double lot = CalcLot(RangeRiskPercent,entry,sl);

      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++;
         lastTradeTime = TimeCurrent();
         Print("🟥 RANGE BREAKOUT SELL");
      }
      else if(lot>0)
      {
         Print("Range SELL failed | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
      return;
   }

   LogSkip("Waiting for range breakout");
}

void GetRangeBoxFromShift(int bars,int firstShift,double &hi,double &lo)
{
   if(bars<1) bars=1;
   hi=iHigh(_Symbol,_Period,firstShift);
   lo=iLow(_Symbol,_Period,firstShift);
   for(int i=firstShift+1;i<firstShift+bars;i++)
   {
      double h=iHigh(_Symbol,_Period,i);
      double l=iLow(_Symbol,_Period,i);
      if(h>hi) hi=h;
      if(l<lo) lo=l;
   }
}

void TradeHTFRangeLTFBreakoutRetest()
{
   if(!EnableHTFRangeLTFBreakout)
   {
      LogSkip("HTF range breakout mode disabled");
      return;
   }

   if(!IsHTFConsolidating())
   {
      LogSkip("HTF not consolidating");
      return;
   }

   double atr=BUF(hATR_CUR,0,1);
   if(atr<=0)
   {
      LogSkip("ATR current TF not ready");
      return;
   }

   double boxHigh=0, boxLow=0;
   // Range source excludes bars 1-2 to validate breakout then retest.
   GetRangeBoxFromShift(RangeLookbackBars,3,boxHigh,boxLow);

   double buffer=atr*RangeBreakBufferATR;
   double c2=iClose(_Symbol,_Period,2);
   double c1=iClose(_Symbol,_Period,1);
   double l1=iLow(_Symbol,_Period,1);
   double h1=iHigh(_Symbol,_Period,1);

   bool breakoutBuy=c2>(boxHigh+buffer);
   bool breakoutSell=c2<(boxLow-buffer);

   bool retestBuy=true;
   bool retestSell=true;
   if(RequireBreakoutRetest)
   {
      retestBuy=(l1<=(boxHigh+buffer) && c1>(boxHigh+buffer));
      retestSell=(h1>=(boxLow-buffer) && c1<(boxLow-buffer));
   }

   if(breakoutBuy && retestBuy)
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl=boxLow-buffer;
      double tp=entry+(entry-sl)*RR_Range;
      double lot=CalcLot(RangeRiskPercent,entry,sl);
      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++;
         lastTradeTime=TimeCurrent();
         Print("HTF RANGE LTF BREAKOUT BUY");
      }
      else if(lot>0)
      {
         Print("HTF range BUY failed | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
      return;
   }

   if(breakoutSell && retestSell)
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl=boxHigh+buffer;
      double tp=entry-(sl-entry)*RR_Range;
      double lot=CalcLot(RangeRiskPercent,entry,sl);
      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++;
         lastTradeTime=TimeCurrent();
         Print("HTF RANGE LTF BREAKOUT SELL");
      }
      else if(lot>0)
      {
         Print("HTF range SELL failed | Retcode:",trade.ResultRetcode(),
               " | ",trade.ResultRetcodeDescription());
      }
      return;
   }

   LogSkip("Waiting HTF-range breakout-retest");
}

int CountPosition()
{
   int pos=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
            PositionGetString(POSITION_SYMBOL)==_Symbol)
         {
            pos++;
         }
      }
   }
   return pos;
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   // Keep parameters explicitly used for MQL5 compiler compatibility.
   long _reqAction=(long)request.action;
   uint _resRetcode=(uint)result.retcode;
   if(_reqAction==-1 && _resRetcode==0xFFFFFFFF) return;

   if(!EnableLossStreakLock) return;
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0) return;
   if(!HistorySelect(TimeCurrent()-86400*30,TimeCurrent())) return;

   ulong deal=trans.deal;
   if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)!=MagicNumber) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) return;

   long entryType=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(entryType!=DEAL_ENTRY_OUT && entryType!=DEAL_ENTRY_OUT_BY) return;

   double net=HistoryDealGetDouble(deal,DEAL_PROFIT)+
              HistoryDealGetDouble(deal,DEAL_SWAP)+
              HistoryDealGetDouble(deal,DEAL_COMMISSION);

   if(net<0)
   {
      consecutiveLosses++;
      Print("Loss streak | count=",consecutiveLosses,
            " | net=",DoubleToString(net,2));
   }
   else if(net>0)
   {
      if(consecutiveLosses>0)
         Print("Loss streak reset by winning trade | net=",DoubleToString(net,2));
      consecutiveLosses=0;
   }

   if(consecutiveLosses>=LossStreakLimit)
   {
      lossLockUntil=TimeCurrent()+LossLockHours*3600;
      Print("LOSS STREAK LOCK | until ",
            TimeToString(lossLockUntil,TIME_DATE|TIME_MINUTES));
      consecutiveLosses=0;
   }
}

//========================= ONTICK ================================
void OnTick()
{
   CheckDailyReset();
   PanicExit();
   if(tradingLocked || DailyLossExceeded() || DailyProfitTargetReached())
   {
      LogSkip("Daily lock");
      return;
   }

   ManagePositions();

   if(!IsNewBar()){ LogSkip("Not new bar"); return; }
   if(!InSession()){ LogSkip("Out of session"); return; }
   if(LossStreakLocked()){ LogSkip("Loss streak lock"); return; }
   if(tradesToday>=MaxTradesDay){ LogSkip("Max trades"); return; }
   if(TimeCurrent()-lastTradeTime < CooldownMinutes*60)
   {
      LogSkip("Cooldown");
      return;
   }
   if(CountPosition()>=MaxOpenPositions)
   {
      LogSkip("Position limit");
      return;
   }
   if(!SpreadOK()) return;

   MARKET_STATE state = DetectMarketState();

   if(state==STATE_TREND_IMPULSE)            TradeTrendImpulse();
   else if(state==STATE_TREND_PULLBACK)      TradeTrendPullback();
   else if(state==STATE_HTF_RANGE_LTF_BREAKOUT) TradeHTFRangeLTFBreakoutRetest();
   else                                      TradeRangeBreakout();
}
