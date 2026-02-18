//+------------------------------------------------------------------+
//| Consolidation → Breakout → Retest → Fibonacci EA (MT5)          |
//| With Detailed Logging                                            |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//------------------- INPUTS ----------------------------------------
input int    LookbackConsolidation = 10;
input double ATRFactor = 0.5;
input double LotSize = 0.10;
input double RR_Target = 2.0; 
input int    Magic = 12345;
input bool   ShowDebug = true;

// Fibonacci Levels
double fibLevelsBuy[3]  = {0.382, 0.500, 0.618};
double fibLevelsSell[3] = {0.382, 0.500, 0.618};

//------------------- GLOBAL VARIABLES ------------------------------
int atrHandle;

bool breakoutBuy = false;
bool breakoutSell = false;

double breakoutHigh, breakoutLow;
double swingHigh, swingLow;

// Log prefix
string LOG = "[CBRF_EA] ";

//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, PERIOD_M30, 14);
   Print(LOG, "EA initialized. XAUUSD M30 with consolidation + breakout + retest + fibonacci.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar()) return;

   double atrArray[3];
   if(CopyBuffer(atrHandle, 0, 0, 3, atrArray) <= 0) return;

   double ATR = atrArray[0];

   if(PositionsTotal() > 0)
   {
      if(ShowDebug) Print(LOG, "Position active. Waiting until closed...");
      return;
   }

   DetectConsolidationAndBreakout(ATR);

   if(breakoutBuy)  CheckRetestBuy(ATR);
   if(breakoutSell) CheckRetestSell(ATR);
}

//+------------------------------------------------------------------+
//| DETECT CONSOLIDATION + BREAKOUT                                  |
//+------------------------------------------------------------------+
void DetectConsolidationAndBreakout(double ATR)
{
   double highC = -DBL_MAX;
   double lowC  = DBL_MAX;

   for(int i = 1; i <= LookbackConsolidation; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M30, i);
      double l = iLow(_Symbol, PERIOD_M30, i);
      if(h > highC) highC = h;
      if(l < lowC)  lowC = l;
   }

   double range = highC - lowC;

   Print(LOG, "Checking consolidation → range=", DoubleToString(range,_Digits),
                  ", ATR=", DoubleToString(ATR,_Digits));

   if(range > ATR * ATRFactor)
   {
      breakoutBuy = false;
      breakoutSell = false;

      Print(LOG, "NO CONSOLIDATION. Range > ATR factor.");
      return;
   }

   Print(LOG, "Consolidation detected. High=", highC, ", Low=", lowC);

   double prevHigh = iHigh(_Symbol, PERIOD_M30, 1);
   double prevLow  = iLow(_Symbol, PERIOD_M30, 1);

   // BREAKOUT BUY
   if(prevHigh > highC)
   {
      breakoutBuy = true;
      breakoutSell = false;

      breakoutHigh = prevHigh;
      swingLow = lowC;

      Print(LOG, "BREAKOUT BUY detected! breakoutHigh=", breakoutHigh,
            ", swingLow=", swingLow);
   }

   // BREAKOUT SELL
   if(prevLow < lowC)
   {
      breakoutSell = true;
      breakoutBuy = false;

      breakoutLow = prevLow;
      swingHigh = highC;

      Print(LOG, "BREAKOUT SELL detected! breakoutLow=", breakoutLow,
            ", swingHigh=", swingHigh);
   }
}

//+------------------------------------------------------------------+
//| Retest BUY Logic                                                 |
//+------------------------------------------------------------------+
void CheckRetestBuy(double ATR)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double fib382 = swingLow + (breakoutHigh - swingLow) * 0.382;
   double fib500 = swingLow + (breakoutHigh - swingLow) * 0.500;
   double fib618 = swingLow + (breakoutHigh - swingLow) * 0.618;

   Print(LOG, "BUY Retest Check → Bid=", bid,
         " | Fib382=", fib382, ", Fib500=", fib500, ", Fib618=", fib618);

   bool inFibZone =
      (bid <= fib382 && bid >= fib618) ||
      (bid <= fib500 && bid >= fib618) ||
      (bid <= fib382 && bid >= fib500);

   bool retestOK = (bid <= breakoutHigh && bid >= swingLow);

   if(inFibZone)
      Print(LOG, "Price entered Fibonacci BUY zone.");

   if(!inFibZone || !retestOK)
   {
      Print(LOG, "BUY retest NOT confirmed yet...");
      return;
   }

   double SL = swingLow;
   double risk = bid - SL;
   double TP = bid + (risk * RR_Target);

   Print(LOG, "BUY ENTRY TRIGGERED!");
   Print(LOG, "Entry=", bid, ", SL=", SL, ", TP=", TP,
         ", RR=", RR_Target);

   trade.SetExpertMagicNumber(Magic);
   trade.Buy(LotSize, NULL, bid, SL, TP);

   breakoutBuy = false;
}

//+------------------------------------------------------------------+
//| Retest SELL Logic                                                |
//+------------------------------------------------------------------+
void CheckRetestSell(double ATR)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double fib382 = swingHigh - (swingHigh - breakoutLow) * 0.382;
   double fib500 = swingHigh - (swingHigh - breakoutLow) * 0.500;
   double fib618 = swingHigh - (swingHigh - breakoutLow) * 0.618;

   Print(LOG, "SELL Retest Check → Ask=", ask,
         " | Fib382=", fib382, ", Fib500=", fib500, ", Fib618=", fib618);

   bool inFibZone =
      (ask >= fib382 && ask <= fib618) ||
      (ask >= fib500 && ask <= fib618) ||
      (ask >= fib382 && ask <= fib500);

   bool retestOK = (ask >= breakoutLow && ask <= swingHigh);

   if(inFibZone)
      Print(LOG, "Price entered Fibonacci SELL zone.");

   if(!inFibZone || !retestOK)
   {
      Print(LOG, "SELL retest NOT confirmed yet...");
      return;
   }

   double SL = swingHigh;
   double risk = SL - ask;
   double TP = ask - (risk * RR_Target);

   Print(LOG, "SELL ENTRY TRIGGERED!");
   Print(LOG, "Entry=", ask, ", SL=", SL, ", TP=", TP,
         ", RR=", RR_Target);

   trade.SetExpertMagicNumber(Magic);
   trade.Sell(LotSize, NULL, ask, SL, TP);

   breakoutSell = false;
}

//+------------------------------------------------------------------+
//| Detect New Bar                                                   |
//+------------------------------------------------------------------+
datetime lastBarTime = 0;
bool IsNewBar()
{
   datetime ct = iTime(_Symbol, PERIOD_M30, 0);
   if(ct != lastBarTime)
   {
      lastBarTime = ct;
      return true;
   }
   return false;
}
