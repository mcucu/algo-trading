//+------------------------------------------------------------------+
//| Momentum Scalper: Impulse Candle + Retrace Entry (MT5 / MQL5)    |
//| Fixed version: avoid modifying input, safe position check, fixes |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//--------------------- INPUTS --------------------------------------
input double InpLotSize            = 0.01;   // fixed lot (input, not modified)
input double MaxLot                = 0.02;   // force cap
input double BodyRatioThreshold    = 0.60;   // Body >= 60% of range -> impulse
input int    ATRPeriod             = 14;
input double ATRRangeMultiplier    = 1.5;    // Range >= ATR * multiplier
input double RetracePercent        = 0.38;   // retrace level (0.3 = 30% into candle body)
input int    RetestTimeoutCandles  = 6;      // how many bars to wait for retrace
input double SLBufferPoints        = 10;     // extra points beyond candle low/high
input double RR_Target             = 1.5;    // reward/risk (TP = risk * RR_Target)
input double MaxSpreadPoints       = 200;    // max allowed spread in points (broker-dependent)
input bool   OnlyOneTradeAtTime    = true;   // only 1 active trade per symbol
input bool   ShowDebug             = true;   // enable verbose printing
input int    EA_Magic              = 123456; // magic number for positions

// Logging prefix
string LOG = "[MOMENTUM_SCALP] ";

//--------------------- GLOBAL --------------------------------------
int atrHandle = INVALID_HANDLE;
enum State {ST_IDLE=0, ST_WAIT_RETRACE};
State state = ST_IDLE;

int retestCounter = 0;

// Stored impulse candle data
double impulseOpen=0, impulseHigh=0, impulseLow=0, impulseClose=0;
double impulseBody = 0, impulseRange = 0;
bool impulseIsBuy = false; // true=buy impulse, false=sell impulse

datetime lastBarTime = 0;
double actualLot = 0.0; // runtime lot (may be capped)

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // set actual lot (cap)
   actualLot = InpLotSize;
   if(actualLot > MaxLot)
   {
      Print(LOG, "Input lot > MaxLot. Capping to MaxLot=", DoubleToString(MaxLot,2));
      actualLot = MaxLot;
   }
   // create ATR handle on same timeframe EA is attached to
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print(LOG, "Failed creating ATR handle");
      return(INIT_FAILED);
   }

   // set trade magic
   trade.SetExpertMagicNumber(EA_Magic);
   Print(LOG, "Initialized. TF=", EnumToString(Period()), " Lot=", DoubleToString(actualLot,2));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Utility: print debug                                              |
//+------------------------------------------------------------------+
void dbg(string s)
{
   if(ShowDebug) Print(LOG, s);
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // operate only on new bar open to avoid duplicate detection
   if(!IsNewBar()) return;

   // basic filters: spread
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) point = Point; // fallback
   double spreadPoints = (ask - bid) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      dbg("Spread too high -> skip. spreadPoints=" + DoubleToString(spreadPoints,1));
      // reset state if waiting
      state = ST_IDLE;
      return;
   }

   // only single trade per symbol (if requested)
   if(OnlyOneTradeAtTime && HasActiveTrade()) 
   {
      dbg("Active trade exists -> skipping new setups.");
      state = ST_IDLE;
      return;
   }

   // get current ATR
   double atrArr[];
   if(CopyBuffer(atrHandle, 0, 0, 1, atrArr) <= 0)
   {
      dbg("ATR not ready");
      return;
   }
   double ATR = atrArr[0];

   // State machine
   if(state == ST_IDLE)
   {
      DetectImpulse(ATR);
   }
   else if(state == ST_WAIT_RETRACE)
   {
      WaitForRetraceOrTimeout(ATR);
   }
}

//+------------------------------------------------------------------+
//| Check if there's already position for this symbol by magic       |
//+------------------------------------------------------------------+
bool HasActiveTrade()
{
   // Use PositionSelect to check there is a position for this symbol and our magic
   if(PositionSelect(_Symbol))
   {
      long posMagic = (long)PositionGetInteger(POSITION_MAGIC);
      // Only consider positions opened by this EA
      if(posMagic == EA_Magic) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect impulse candle (on closed candle index 1)                 |
//+------------------------------------------------------------------+
void DetectImpulse(double ATR)
{
   // read candle index 1
   double op = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double hi = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lo = iLow(_Symbol, PERIOD_CURRENT, 1);
   double cl = iClose(_Symbol, PERIOD_CURRENT, 1);

   double body = MathAbs(cl - op);
   double range = hi - lo;

   // safety: require ATR positive
   if(ATR <= 0.0) 
   {
      dbg("ATR <= 0. skip");
      return;
   }

   // checks
   double bodyRatio = 0.0;
   if(range > 0.0) bodyRatio = body / range;

   dbg("Checking impulse candle -> O=" + DoubleToString(op,Digits()) +
       " H=" + DoubleToString(hi,Digits()) +
       " L=" + DoubleToString(lo,Digits()) +
       " C=" + DoubleToString(cl,Digits()) +
       " body=" + DoubleToString(body,Digits()) +
       " range=" + DoubleToString(range,Digits()) +
       " bodyRatio=" + DoubleToString(bodyRatio,2) +
       " ATR=" + DoubleToString(ATR,2));

   // Impulse criteria
   bool condBody = (bodyRatio >= BodyRatioThreshold);
   bool condRange = (range >= ATR * ATRRangeMultiplier);

   if(condBody && condRange)
   {
      impulseOpen = op; impulseHigh = hi; impulseLow = lo; impulseClose = cl;
      impulseBody = body; impulseRange = range;
      impulseIsBuy = (cl > op);

      // set state to waiting retrace
      state = ST_WAIT_RETRACE;
      retestCounter = 0;

      dbg("IMPULSE detected -> isBuy=" + (impulseIsBuy ? "YES" : "NO") +
          " bodyRatio=" + DoubleToString(bodyRatio,2) +
          " setting WAIT_RETRACE (timeout " + IntegerToString(RetestTimeoutCandles) + " bars)");
   }
   else
   {
      dbg("No impulse (criteria not met)");
   }
}

//+------------------------------------------------------------------+
//| Wait for retrace into RetracePercent of impulse body             |
//+------------------------------------------------------------------+
void WaitForRetraceOrTimeout(double ATR)
{
   retestCounter++;
   dbg("Waiting retrace... attempt " + IntegerToString(retestCounter) + "/" + IntegerToString(RetestTimeoutCandles));

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = impulseIsBuy ? bid : ask;

   // compute retrace target price
   double target = 0.0;
   if(impulseIsBuy)
      target = impulseHigh - (impulseBody * RetracePercent);
   else
      target = impulseLow + (impulseBody * RetracePercent);

   // small tolerance in price (use ATR*0.10)
   double tol = ATR * 0.10;

   dbg("Retrace target=" + DoubleToString(target,Digits()) + " current=" + DoubleToString(price,Digits()) + " tol=" + DoubleToString(tol,Digits()));

   bool hitRetrace = false;
   if(impulseIsBuy)
   {
      if(price <= target + tol && price >= target - tol) hitRetrace = true;
   }
   else
   {
      if(price >= target - tol && price <= target + tol) hitRetrace = true;
   }

   if(hitRetrace)
   {
      dbg("Retrace HIT -> executing entry");
      ExecuteEntry(ATR);
      state = ST_IDLE;
      return;
   }

   if(retestCounter >= RetestTimeoutCandles)
   {
      dbg("Retrace TIMEOUT -> abandoning setup");
      state = ST_IDLE;
      return;
   }
}

//+------------------------------------------------------------------+
//| Execute market entry with SL based on impulse candle             |
//+------------------------------------------------------------------+
void ExecuteEntry(double ATR)
{
   double entryPrice = 0.0;
   double sl = 0.0;
   double tp = 0.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(point <= 0) point = Point;

   if(impulseIsBuy)
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sl = impulseLow - SLBufferPoints * point;
      double risk = entryPrice - sl;
      if(risk <= point*1.0)
      {
         dbg("Risk too small -> abort");
         return;
      }
      tp = entryPrice + risk * RR_Target;

      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
   }
   else
   {
      entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      sl = impulseHigh + SLBufferPoints * point;
      double risk = sl - entryPrice;
      if(risk <= point*1.0)
      {
         dbg("Risk too small -> abort");
         return;
      }
      tp = entryPrice - risk * RR_Target;

      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
   }

   // Final checks: spread again
   double spreadPoints = (SymbolInfoDouble(_Symbol,SYMBOL_ASK) - SymbolInfoDouble(_Symbol,SYMBOL_BID)) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      dbg("Spread grew too high before entry -> abort");
      return;
   }

   // Place market order: use trade object, supply symbol as NULL to default to current symbol
   trade.SetExpertMagicNumber(EA_Magic);
   trade.SetDeviationInPoints(200);

   bool ok = false;
   if(impulseIsBuy)
   {
      dbg("Placing BUY market -> Entry=" + DoubleToString(entryPrice,Digits()) +
          " SL=" + DoubleToString(sl,Digits()) +
          " TP=" + DoubleToString(tp,Digits()) +
          " Lot=" + DoubleToString(actualLot,2));
      ok = trade.Buy(actualLot, NULL, 0, sl, tp, "ImpulseRetraceBuy");
   }
   else
   {
      dbg("Placing SELL market -> Entry=" + DoubleToString(entryPrice,Digits()) +
          " SL=" + DoubleToString(sl,Digits()) +
          " TP=" + DoubleToString(tp,Digits()) +
          " Lot=" + DoubleToString(actualLot,2));
      ok = trade.Sell(actualLot, NULL, 0, sl, tp, "ImpulseRetraceSell");
   }

   if(ok)
      dbg("Order placed successfully. ticket=" + (string)trade.ResultOrder());
   else
      dbg("Order failed: " + trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| New bar detection                                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}