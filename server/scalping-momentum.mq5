//+------------------------------------------------------------------+
//| Impulse Candle Momentum Scalping EA (MT5)                        |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//-------------------- INPUTS ---------------------------------------
input double FixedLot        = 0.01;
input bool   UseAutoLot      = false;
input double RiskPercent     = 1.0;
input int    ATRPeriod       = 14;
input double ImpulseFactor   = 2.0;
input double RR_Target       = 2.0;
input int    LookbackBars    = 20;
input int    MagicNumber     = 98765;
input int    MaxOpenPositions = 3;

//-------------------- FUNCTION PROTOTYPES --------------------------
double GetLotSize(double sl_pips);
double GetATR();
bool   IsImpulseCandle(int shift);
double GetSwingHigh(int bars);
double GetSwingLow(int bars);
int    CountOpenPositions();     // <<< NEW
void   Log(string txt);

//====================================================================
// ON TICK
//====================================================================
void OnTick()
{
   if(Bars(_Symbol, _Period) < LookbackBars + 5) return;
   
   if(HasActiveTrade()) {
      Log("Max open position reached - skip entry");
      return;
   }

   // block multi-position by magic number
   if(PositionsTotal() >= MaxOpenPositions)
   {
      Log("Max open position reached - skip entry");
      return;
   }

   // detect momentum bar
   if(!IsImpulseCandle(1))
   {
      Log("NO impulse candle");
      return;
   }

   double prev_open  = iOpen(_Symbol,_Period,1);
   double prev_close = iClose(_Symbol,_Period,1);
   double prev_high  = iHigh(_Symbol,_Period,1);
   double prev_low   = iLow(_Symbol,_Period,1);

   double curr_close = iClose(_Symbol,_Period,0);

   bool bullish = (prev_close > prev_open);
   bool bearish = (prev_close < prev_open);

   if(bullish && curr_close <= prev_close)
   {
      Log("Bull impulse but no follow-through");
      return;
   }

   if(bearish && curr_close >= prev_close)
   {
      Log("Bear impulse but no follow-through");
      return;
   }

   double SL, TP, entry;

   //---------------------------------------------
   // BUY SETUP
   //---------------------------------------------
   if(bullish)
   {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      SL = prev_low;

      double sl_pips = MathAbs(entry - SL) / _Point;
      double lot = GetLotSize(sl_pips);

      double fibTarget = prev_high + (prev_close - prev_open) * 1.272;

      double tpHigh  = prev_high;
      TP = MathMax(tpHigh, fibTarget);

      trade.Buy(lot, _Symbol, entry, SL, TP);
      Log(StringFormat("BUY executed, SL=%.2f TP=%.2f", SL, TP));
      return;
   }

   //---------------------------------------------
   // SELL SETUP
   //---------------------------------------------
   if(bearish)
   {
      entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      SL = prev_high;

      double sl_pips = MathAbs(entry - SL) / _Point;
      double lot = GetLotSize(sl_pips);

      double fibTarget = prev_low - (prev_open - prev_close) * 1.272;

      double tpLow = prev_low;
      TP = MathMin(tpLow, fibTarget);

      trade.Sell(lot, _Symbol, entry, SL, TP);
      Log(StringFormat("SELL executed, SL=%.2f TP=%.2f", SL, TP));
      return;
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
      if(posMagic == MagicNumber) return true;
   }
   return false;
}

//====================================================================
// COUNT OPEN POSITIONS (Magic Number Based)
//====================================================================
int CountOpenPositions()
{
   int count = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            count++;
         }
      }
   }
   return count;
}

//====================================================================
// LOT SIZE
//====================================================================
double GetLotSize(double sl_pips)
{
   if(!UseAutoLot) return FixedLot;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0);
   double pipValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(pipValue <= 0) pipValue = 1;

   double lot = riskMoney / (sl_pips * pipValue);
   return NormalizeDouble(lot, 2);
}

//====================================================================
// ATR
//====================================================================
double GetATR()
{
   int handle = iATR(_Symbol, _Period, ATRPeriod);
   if(handle == INVALID_HANDLE) return 0;

   double atr[];
   if(CopyBuffer(handle, 0, 0, 1, atr) < 1) return 0;

   return atr[0];
}

//====================================================================
// IMPULSE CANDLE CHECK
//====================================================================
bool IsImpulseCandle(int shift)
{
   double body = MathAbs(iClose(_Symbol,_Period,shift) - iOpen(_Symbol,_Period,shift));

   double sum = 0.0;
   for(int idx = shift+1; idx <= shift+LookbackBars; idx++)
   {
      double b = MathAbs(iClose(_Symbol,_Period,idx) - iOpen(_Symbol,_Period,idx));
      sum += b;
   }

   double avgBody = sum / LookbackBars;

   return (body >= avgBody * ImpulseFactor);
}

//====================================================================
// SWING HIGH / LOW
//====================================================================
double GetSwingHigh(int bars)
{
   double maxH = iHigh(_Symbol,_Period,1);
   for(int i=2; i <= bars; i++)
   {
      double h = iHigh(_Symbol,_Period,i);
      if(h > maxH) maxH = h;
   }
   return maxH;
}

double GetSwingLow(int bars)
{
   double minL = iLow(_Symbol,_Period,1);
   for(int i=2; i <= bars; i++)
   {
      double l = iLow(_Symbol,_Period,i);
      if(l < minL) minL = l;
   }
   return minL;
}

//====================================================================
// LOGGER
//====================================================================
void Log(string txt)
{
   Print("[SCALPING_MOM] ", txt);
}
