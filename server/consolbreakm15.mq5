//+------------------------------------------------------------------+
//| Consolidation → Breakout → Retest → Fibonacci EA (MT5 + MTF Trend Filter)
//| Timeframe: M15 | Max Lot: 0.02                                   |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//------------------- INPUTS ----------------------------------------
input int    LookbackConsolidation = 10;
input double ATRFactor = 0.5;

input double LotSize = 0.02;
input double RR_Target = 2.0; 
input int    Magic = 12345;
input bool   ShowDebug = true;

// MTF TREND FILTER
input int FastMA = 20;
input int SlowMA = 50;

//------------------- GLOBAL ----------------------------------------
int atrHandle;
int maFast_H1, maSlow_H1;
int maFast_H4, maSlow_H4;

bool breakoutBuy = false;
bool breakoutSell = false;

double breakoutHigh, breakoutLow;
double swingHigh, swingLow;

string LOG = "[CBRF_M15_MTF] ";
datetime lastBarTime = 0;

//==========================================================
// INIT
//==========================================================
int OnInit()
{
   atrHandle   = iATR(_Symbol, PERIOD_M15, 14);

   // MA H1
   maFast_H1 = iMA(_Symbol, PERIOD_H1, FastMA, 0, MODE_EMA, PRICE_CLOSE);
   maSlow_H1 = iMA(_Symbol, PERIOD_H1, SlowMA, 0, MODE_EMA, PRICE_CLOSE);

   // MA H4
   maFast_H4 = iMA(_Symbol, PERIOD_H4, FastMA, 0, MODE_EMA, PRICE_CLOSE);
   maSlow_H4 = iMA(_Symbol, PERIOD_H4, SlowMA, 0, MODE_EMA, PRICE_CLOSE);

   Print(LOG, "EA Initialized (TF M15 + MTF Trend Filter + Lot Cap 0.02)");

   return(INIT_SUCCEEDED);
}

//==========================================================
// MAIN LOOP
//==========================================================
void OnTick()
{
   if(!IsNewBar()) return;

   double atrArray[3];
   if(CopyBuffer(atrHandle, 0, 0, 3, atrArray) <= 0) return;

   double ATR = atrArray[0];

   // Block jika ada posisi
   if(PositionsTotal() > 0)
   {
      if(ShowDebug) Print(LOG, "Ada posisi berjalan → skip");
      return;
   }

   DetectConsolidationAndBreakout(ATR);

   if(breakoutBuy  && TrendBUY())  CheckRetestBuy(ATR);
   if(breakoutSell && TrendSELL()) CheckRetestSell(ATR);
}

//==========================================================
// Trend Filter Functions
//==========================================================
bool TrendBUY()
{
   double fH1[1], sH1[1], fH4[1], sH4[1];

   CopyBuffer(maFast_H1, 0, 0, 1, fH1);
   CopyBuffer(maSlow_H1, 0, 0, 1, sH1);
   CopyBuffer(maFast_H4, 0, 0, 1, fH4);
   CopyBuffer(maSlow_H4, 0, 0, 1, sH4);

   bool ok = (fH1[0] > sH1[0]) && (fH4[0] > sH4[0]);

   Print(LOG, "Trend BUY Filter → H1:", (string)(fH1[0]>sH1[0]),
         " H4:", (string)(fH4[0]>sH4[0]),
         " → RESULT=", (string)ok);

   return ok;
}

bool TrendSELL()
{
   double fH1[1], sH1[1], fH4[1], sH4[1];

   CopyBuffer(maFast_H1, 0, 0, 1, fH1);
   CopyBuffer(maSlow_H1, 0, 0, 1, sH1);
   CopyBuffer(maFast_H4, 0, 0, 1, fH4);
   CopyBuffer(maSlow_H4, 0, 0, 1, sH4);

   bool ok = (fH1[0] < sH1[0]) && (fH4[0] < sH4[0]);

   Print(LOG, "Trend SELL Filter → H1:", (string)(fH1[0]<sH1[0]),
         " H4:", (string)(fH4[0]<sH4[0]),
         " → RESULT=", (string)ok);

   return ok;
}

//==========================================================
// CONSOLIDATION + BREAKOUT DETECTION
//==========================================================
void DetectConsolidationAndBreakout(double ATR)
{
   double highC = -DBL_MAX;
   double lowC  = DBL_MAX;

   for(int i = 1; i <= LookbackConsolidation; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M15, i);
      double l = iLow(_Symbol, PERIOD_M15, i);

      if(h > highC) highC = h;
      if(l < lowC)  lowC = l;
   }

   double range = highC - lowC;

   Print(LOG, "Checking consolidation → range=", range,
         " ATR=", ATR);

   if(range > ATR * ATRFactor)
   {
      breakoutBuy  = false;
      breakoutSell = false;
      return;
   }

   // Breakout Area Locked
   double prevHigh = iHigh(_Symbol, PERIOD_M15, 1);
   double prevLow  = iLow(_Symbol, PERIOD_M15, 1);

   // BUY breakout
   if(prevHigh > highC)
   {
      breakoutBuy = true;
      breakoutSell = false;
      breakoutHigh = prevHigh;
      swingLow = lowC;

      Print(LOG, "BREAKOUT BUY detected.");
   }

   // SELL breakout
   if(prevLow < lowC)
   {
      breakoutSell = true;
      breakoutBuy = false;
      breakoutLow = prevLow;
      swingHigh = highC;

      Print(LOG, "BREAKOUT SELL detected.");
   }
}

//==========================================================
// RETEST BUY
//==========================================================
void CheckRetestBuy(double ATR)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double fib382 = swingLow + (breakoutHigh - swingLow) * 0.382;
   double fib500 = swingLow + (breakoutHigh - swingLow) * 0.500;
   double fib618 = swingLow + (breakoutHigh - swingLow) * 0.618;

   bool inFib = (bid <= fib382 && bid >= fib618);
   bool retestOK = (bid <= breakoutHigh && bid >= swingLow);

   if(!inFib || !retestOK)
   {
      Print(LOG, "BUY retest belum valid");
      return;
   }

   double SL = swingLow;
   double risk = bid - SL;
   double TP = bid + (risk * RR_Target);

   Print(LOG, "BUY ENTRY READY");

   trade.SetExpertMagicNumber(Magic);
   trade.Buy(LotSize, NULL, bid, SL, TP);

   breakoutBuy = false;
}

//==========================================================
// RETEST SELL
//==========================================================
void CheckRetestSell(double ATR)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double fib382 = swingHigh - (swingHigh - breakoutLow) * 0.382;
   double fib500 = swingHigh - (swingHigh - breakoutLow) * 0.500;
   double fib618 = swingHigh - (swingHigh - breakoutLow) * 0.618;

   bool inFib = (ask >= fib382 && ask <= fib618);
   bool retestOK = (ask >= breakoutLow && ask <= swingHigh);

   if(!inFib || !retestOK)
   {
      Print(LOG, "SELL retest belum valid");
      return;
   }

   double SL = swingHigh;
   double risk = SL - ask;
   double TP = ask - (risk * RR_Target);

   Print(LOG, "SELL ENTRY READY");

   trade.SetExpertMagicNumber(Magic);
   trade.Sell(LotSize, NULL, ask, SL, TP);

   breakoutSell = false;
}

//==========================================================
// NEW BAR DETECTION
//==========================================================
bool IsNewBar()
{
   datetime ct = iTime(_Symbol, PERIOD_M15, 0);
   if(ct != lastBarTime)
   {
      lastBarTime = ct;
      return true;
   }
   return false;
}
