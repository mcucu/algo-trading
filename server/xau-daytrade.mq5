//+------------------------------------------------------------------+
//| XAUUSD M15 Day Trader EA - Fixed Version                         |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//--- Input parameters
input int    FastEMA = 14;
input int    SlowEMA = 21;
input int    RSIPeriod = 14;
input double RSI_OB = 70.0;
input double RSI_OS = 30.0;

input double RiskPercent = 1.0;
input double StopLossPips = 2000;    // in points (broker unit)
input double TakeProfitPips = 3000;
input double TrailingStopPips = 1500;

input double FixedLotSize = 0.01;
input bool UseAutoLot = false;

input int    MagicNumber = 1515;

//--- Global handles
int fastEMAHandle = INVALID_HANDLE;
int slowEMAHandle = INVALID_HANDLE;
int rsiHandle     = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create indicator handles on M15 timeframe
   fastEMAHandle = iMA(_Symbol, PERIOD_M15, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowEMAHandle = iMA(_Symbol, PERIOD_M15, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle     = iRSI(_Symbol, PERIOD_M15, RSIPeriod, PRICE_CLOSE);


   if(fastEMAHandle == INVALID_HANDLE || slowEMAHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed!");
      return(INIT_FAILED);
   }

   // set expert magic
   trade.SetExpertMagicNumber((uint)MagicNumber);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Lot Size Calculation based on Risk %                             |
//+------------------------------------------------------------------+
double CalculateLotSizeV2(double stopLossPips)
{
   if(stopLossPips <= 0) return 0.0;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE); // MQL5
   double riskMoney = balance * (RiskPercent / 100.0);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0.0;

   // Try use tick value if available
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double moneyPerLot = 0.0;

   if(tickValue > 0 && tickSize > 0)
   {
      moneyPerLot = (stopLossPips * point / tickSize) * tickValue;
   }
   else
   {
      // fallback approximate using contract size & price
      double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(contractSize > 0 && price > 0)
         moneyPerLot = stopLossPips * point * contractSize * price;
      else
         return 0.0;
   }

   if(moneyPerLot <= 0) return 0.0;

   double lots = riskMoney / moneyPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   // normalize down to nearest lotStep
   double steps = MathFloor(lots / lotStep);
   lots = steps * lotStep;

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   // ensure format suitable for broker (2 decimals typical)
   return NormalizeDouble(lots, 2);
}

double CalculateLotSize(double stopLossPips)
{
   if(stopLossPips <= 0) return 0.0;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE); // MQL5
   double riskMoney = balance * (RiskPercent / 100.0);

   double pipValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double pipSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(pipValue <= 0)
      pipValue = 0.1; // fallback aman

   double lot = riskMoney / (stopLossPips * (pipValue / pipSize));

   // Safety limits
   if(lot < 0.01) lot = 0.01;
   if(lot > 1.00) lot = 1.00;  // BATAS MAKSIMAL!!!

   return NormalizeDouble(lot, 2);
}


//+------------------------------------------------------------------+
//| Check if position exists by type (uses MagicNumber)              |
//+------------------------------------------------------------------+
bool PositionExists(ENUM_POSITION_TYPE type)
{
   int total = PositionsTotal();
   for(int idx = 0; idx < total; idx++)
   {
      ulong ticket = PositionGetTicket(idx);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long pm = PositionGetInteger(POSITION_MAGIC);
      long pt = PositionGetInteger(POSITION_TYPE);
      if(pm == MagicNumber && pt == type) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage trailing stops for positions opened by this EA            |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int total = PositionsTotal();

   for(int idx = 0; idx < total; idx++)
   {
      ulong ticket = PositionGetTicket(idx);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      long pm = PositionGetInteger(POSITION_MAGIC);
      if(pm != MagicNumber) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curPrice = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double curSL = PositionGetDouble(POSITION_SL);

      double trailDistance = TrailingStopPips * point;

      if(ptype == POSITION_TYPE_BUY)
      {
         double profitPts = (curPrice - openPrice) / point;
         if(profitPts >= (TrailingStopPips)) // only start trailing after some profit (using same value here)
         {
            double newSL = NormalizeDouble(curPrice - trailDistance, digits);
            if(curSL == 0.0 || newSL > curSL)
            {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - curPrice) / point;
         if(profitPts >= (TrailingStopPips))
         {
            double newSL = NormalizeDouble(curPrice + trailDistance, digits);
            if(curSL == 0.0 || newSL < curSL)
            {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // Use bar time to avoid multiple signals inside same forming bar
   static datetime last_bar_time = 0;
   MqlRates rates[2];
   if(CopyRates(_Symbol, PERIOD_M15, 0, 2, rates) <= 0) return;
   if(rates[0].time == last_bar_time) return;
   last_bar_time = rates[0].time;
   
   if(rates[0].time == last_bar_time)
   {
      Print("DEBUG | New bar detected at: ", TimeToString(rates[0].time, TIME_DATE|TIME_SECONDS));
   }

   // Ensure indicator handles valid
   if(fastEMAHandle == INVALID_HANDLE || slowEMAHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE)
   {
      // try re-init
      OnInit();
      return;
   }

   // Copy buffers (most recent values at index 0)
   double fastBuf[3], slowBuf[3], rsiBuf[3];

   if(CopyBuffer(fastEMAHandle, 0, 0, 2, fastBuf) <= 0) return;
   if(CopyBuffer(slowEMAHandle, 0, 0, 2, slowBuf) <= 0) return;
   if(CopyBuffer(rsiHandle,     0, 0, 1, rsiBuf) <= 0) return;

   double fastNow = fastBuf[0];
   double fastPrev= fastBuf[1];
   double slowNow = slowBuf[0];
   double slowPrev= slowBuf[1];
   double currRSI = rsiBuf[0];
   
   Print("DEBUG | fastNow=", DoubleToString(fastNow,5),
      " slowNow=", DoubleToString(slowNow,5),
      " RSI=", DoubleToString(currRSI,2));

   // Manage trailing stops first
   ManageTrailingStop();

   // Calculate lot based on configured StopLossPips
   double lots = CalculateLotSize(StopLossPips);
   if(lots <= 0.0) { /* cannot trade due to lot calc */ }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Signals
   bool buySignal  = (fastPrev < slowPrev) && (fastNow > slowNow) && (currRSI > RSI_OS);
   bool sellSignal = (fastPrev > slowPrev) && (fastNow < slowNow) && (currRSI < RSI_OB);

   // BUY
   if(buySignal && !PositionExists(POSITION_TYPE_BUY))
   {
      Print("DEBUG | BUY SIGNAL DETECTED");
      double sl = NormalizeDouble(ask - StopLossPips * point, digits);
      double tp = NormalizeDouble(ask + TakeProfitPips * point, digits);
      if(lots > 0.0)
      {
         if(!trade.Buy(lots, _Symbol, 0.0, sl, tp))
            Print("Buy failed: ", GetLastError());
         else
            Print("Buy opened: lots=", DoubleToString(lots,2), " SL=", DoubleToString(sl,digits), " TP=", DoubleToString(tp,digits));
      }
   }
   else
   {
      Print("DEBUG | Buy conditions not met");
   }

   // SELL
   if(sellSignal && !PositionExists(POSITION_TYPE_SELL))
   {
      Print("DEBUG | SELL SIGNAL DETECTED");
      double sl = NormalizeDouble(bid + StopLossPips * point, digits);
      double tp = NormalizeDouble(bid - TakeProfitPips * point, digits);
      if(lots > 0.0)
      {
         if(!trade.Sell(lots, _Symbol, 0.0, sl, tp))
            Print("Sell failed: ", GetLastError());
         else
            Print("Sell opened: lots=", DoubleToString(lots,2), " SL=", DoubleToString(sl,digits), " TP=", DoubleToString(tp,digits));
      }
   }
   else
   {
      Print("DEBUG | Sell conditions not met");
   }
}
//+------------------------------------------------------------------+
