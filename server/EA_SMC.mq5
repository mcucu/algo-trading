//+------------------------------------------------------------------+
//|                                                     EA_SMC.mq5   |
//|                  Smart Money Concept Intraday EA                 |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

enum TrendDirection
{
   TREND_NEUTRAL = 0,
   TREND_BULLISH,
   TREND_BEARISH
};

enum MarketPhase
{
   PHASE_CONSOLIDATION = 0,
   PHASE_TREND,
   PHASE_PULLBACK
};

enum SweepType
{
   SWEEP_NONE = 0,
   SWEEP_BUY_SIDE,
   SWEEP_SELL_SIDE
};

enum FVGDirection
{
   FVG_NONE = 0,
   FVG_BULLISH,
   FVG_BEARISH
};

struct MarketStructureState
{
   TrendDirection trend;
   MarketPhase phase;
   double recentHigh;
   double previousHigh;
   double recentLow;
   double previousLow;
};

struct LiquidityLevels
{
   double nearestBSL;
   double nearestSSL;
   string nearestBSLSource;
   string nearestSSLSource;
};

struct SweepSignal
{
   bool valid;
   SweepType type;
   double liquidityLevel;
   double extremePrice;
   double closePrice;
   datetime candleTime;
};

struct FVGZone
{
   bool valid;
   FVGDirection direction;
   double low;
   double high;
   datetime candleTime;
};

struct TradeSetup
{
   bool valid;
   ENUM_ORDER_TYPE orderType;
   TrendDirection direction;
   double entry;
   double sl;
   double tp1;
   double tp2;
   double volume;
   double targetLiquidity;
   datetime signalTime;
   string comment;
   string bslSource;
   string sslSource;
   string sweepLabel;
   TrendDirection htfPrimaryTrend;
   TrendDirection htfSecondaryTrend;
   TrendDirection ltfPrimaryTrend;
   TrendDirection ltfSecondaryTrend;
   MarketPhase htfPhase;
   MarketPhase ltfPhase;
};

input double RiskPercent = 1.0;
input int MaxDailyTrades = 2;
input double MaxDailyLossPercent = 2.0;
input double MaxDailyLossMoney = 200.0;
input double MaxDailyProfitPercent = 4.0;
input double MaxDailyProfitMoney = 400.0;
input bool UseKillzoneFilter = true;
input int AsiaStart = 0;
input int AsiaEnd = 3;
input int LondonStart = 9;
input int LondonEnd = 12;
input int NYStart = 14;
input int NYEnd = 17;
input int MaxSpread = 30;
input long MagicNumber = 20260310;
input int StructureLookback = 20;
input int LiquidityLookback = 40;
input double EqualLevelTolerancePercent = 0.10;
input double MinFVGPercent = 0.05;
input double DisplacementBodyFactor = 1.5;
input int StopBufferPoints = 30;
input int MinSweepPenetrationPoints = 10;
input double MinSweepWickBodyRatio = 1.2;
input int MaxBarsAfterFVG = 6;
input bool RequireMidpointRetest = false;
input bool RequireRetestRejection = true;
input ENUM_TIMEFRAMES HTFPrimary = PERIOD_D1;
input ENUM_TIMEFRAMES HTFSecondary = PERIOD_H4;
input ENUM_TIMEFRAMES LTFBiasPrimary = PERIOD_H1;
input ENUM_TIMEFRAMES LTFBiasSecondary = PERIOD_M15;
input ENUM_TIMEFRAMES SignalTF = PERIOD_M5;
input double PartialClosePercent = 50.0;

int DailyTradeCount = 0;
double DailyStartBalance = 0.0;
double DailyLossMoney = 0.0;
double DailyProfitMoney = 0.0;
int LastTradeDayKey = 0;
datetime LastSignalBarTime = 0;

void Log(string text)
{
   Print("[SMC_EA] ", text);
}

string TrendToString(TrendDirection trend)
{
   if(trend == TREND_BULLISH)
      return "Bullish";
   if(trend == TREND_BEARISH)
      return "Bearish";
   return "Neutral";
}

string PhaseToString(MarketPhase phase)
{
   if(phase == PHASE_TREND)
      return "Trend";
   if(phase == PHASE_PULLBACK)
      return "Pullback";
   return "Consolidation";
}

int DateKey(datetime value)
{
   MqlDateTime tm;
   TimeToStruct(value, tm);
   return tm.year * 10000 + tm.mon * 100 + tm.day;
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double RelativeDiffPercent(double first, double second)
{
   double midpoint = (MathAbs(first) + MathAbs(second)) / 2.0;
   if(midpoint <= 0.0)
      return 0.0;
   return MathAbs(first - second) / midpoint * 100.0;
}

bool IsNewBar(ENUM_TIMEFRAMES timeframe, datetime &lastBarTime)
{
   datetime currentBarTime = iTime(_Symbol, timeframe, 0);
   if(currentBarTime == 0)
      return false;

   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }

   return false;
}

void ResetDailyStats()
{
   int todayKey = DateKey(TimeCurrent());
   if(todayKey != LastTradeDayKey)
   {
      DailyTradeCount = 0;
      DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      DailyLossMoney = 0.0;
      DailyProfitMoney = 0.0;
      LastTradeDayKey = todayKey;
      Log("Daily stats reset");
   }
}

void UpdateDailyStats()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double pnl = balance - DailyStartBalance;

   DailyLossMoney = 0.0;
   DailyProfitMoney = 0.0;

   if(pnl < 0.0)
      DailyLossMoney = MathAbs(pnl);
   else
      DailyProfitMoney = pnl;
}

bool IsTradingAllowed()
{
   if(DailyStartBalance <= 0.0)
      return false;

   if(DailyTradeCount >= MaxDailyTrades)
   {
      Log("Max daily trades reached");
      return false;
   }

   if(DailyLossMoney >= MaxDailyLossMoney)
   {
      Log("Max daily loss money reached");
      return false;
   }

   double lossPercent = (DailyLossMoney / DailyStartBalance) * 100.0;
   if(lossPercent >= MaxDailyLossPercent)
   {
      Log("Max daily loss percent reached");
      return false;
   }

   if(DailyProfitMoney >= MaxDailyProfitMoney)
   {
      Log("Max daily profit money reached");
      return false;
   }

   double profitPercent = (DailyProfitMoney / DailyStartBalance) * 100.0;
   if(profitPercent >= MaxDailyProfitPercent)
   {
      Log("Max daily profit percent reached");
      return false;
   }

   return true;
}

bool SpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread >= 0 && spread <= MaxSpread);
}

bool IsKillzone()
{
   if(!UseKillzoneFilter)
      return true;

   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);

   if(tm.hour >= AsiaStart && tm.hour < AsiaEnd)
      return true;

   if(tm.hour >= LondonStart && tm.hour < LondonEnd)
      return true;

   if(tm.hour >= NYStart && tm.hour < NYEnd)
      return true;

   return false;
}

double AverageBodySize(ENUM_TIMEFRAMES timeframe, int barsCount, int startShift)
{
   double total = 0.0;
   int samples = 0;

   for(int shift = startShift; shift < startShift + barsCount; shift++)
   {
      double open = iOpen(_Symbol, timeframe, shift);
      double close = iClose(_Symbol, timeframe, shift);
      if(open == 0.0 && close == 0.0)
         continue;

      total += MathAbs(close - open);
      samples++;
   }

   if(samples == 0)
      return 0.0;

   return total / samples;
}

bool AnalyzeStructure(ENUM_TIMEFRAMES timeframe, int lookback, MarketStructureState &state)
{
   state.trend = TREND_NEUTRAL;
   state.phase = PHASE_CONSOLIDATION;
   state.recentHigh = 0.0;
   state.previousHigh = 0.0;
   state.recentLow = 0.0;
   state.previousLow = 0.0;

   int halfWindow = MathMax(5, lookback / 2);
   int previousStart = halfWindow + 1;

   int recentHighIndex = iHighest(_Symbol, timeframe, MODE_HIGH, halfWindow, 1);
   int previousHighIndex = iHighest(_Symbol, timeframe, MODE_HIGH, halfWindow, previousStart);
   int recentLowIndex = iLowest(_Symbol, timeframe, MODE_LOW, halfWindow, 1);
   int previousLowIndex = iLowest(_Symbol, timeframe, MODE_LOW, halfWindow, previousStart);

   if(recentHighIndex < 0 || previousHighIndex < 0 || recentLowIndex < 0 || previousLowIndex < 0)
      return false;

   state.recentHigh = iHigh(_Symbol, timeframe, recentHighIndex);
   state.previousHigh = iHigh(_Symbol, timeframe, previousHighIndex);
   state.recentLow = iLow(_Symbol, timeframe, recentLowIndex);
   state.previousLow = iLow(_Symbol, timeframe, previousLowIndex);

   bool hh = state.recentHigh > state.previousHigh;
   bool hl = state.recentLow > state.previousLow;
   bool lh = state.recentHigh < state.previousHigh;
   bool ll = state.recentLow < state.previousLow;

   if(hh && hl)
   {
      state.trend = TREND_BULLISH;
      state.phase = PHASE_TREND;
   }
   else if(lh && ll)
   {
      state.trend = TREND_BEARISH;
      state.phase = PHASE_TREND;
   }
   else if((hh && ll) || (lh && hl))
   {
      state.trend = TREND_NEUTRAL;
      state.phase = PHASE_PULLBACK;
   }
   else
   {
      state.trend = TREND_NEUTRAL;
      state.phase = PHASE_CONSOLIDATION;
   }

   return true;
}

TrendDirection ResolveTrend(TrendDirection primary, TrendDirection secondary)
{
   if(primary == secondary)
      return primary;

   if(primary == TREND_NEUTRAL)
      return secondary;

   if(secondary == TREND_NEUTRAL)
      return primary;

   return TREND_NEUTRAL;
}

void ResetLiquidityLevels(LiquidityLevels &levels)
{
   levels.nearestBSL = 0.0;
   levels.nearestSSL = 0.0;
   levels.nearestBSLSource = "";
   levels.nearestSSLSource = "";
}

void ConsiderBSL(LiquidityLevels &levels, double level, string source, double currentPrice)
{
   if(level <= currentPrice || level <= 0.0)
      return;

   if(levels.nearestBSL == 0.0 || level < levels.nearestBSL)
   {
      levels.nearestBSL = level;
      levels.nearestBSLSource = source;
   }
}

void ConsiderSSL(LiquidityLevels &levels, double level, string source, double currentPrice)
{
   if(level >= currentPrice || level <= 0.0)
      return;

   if(levels.nearestSSL == 0.0 || level > levels.nearestSSL)
   {
      levels.nearestSSL = level;
      levels.nearestSSLSource = source;
   }
}

double FindClusterLevel(ENUM_TIMEFRAMES timeframe,
                        int lookback,
                        bool useHighs,
                        int minCount,
                        double tolerancePercent,
                        double currentPrice,
                        bool wantAboveCurrent)
{
   double bestLevel = 0.0;

   for(int i = 1; i <= lookback; i++)
   {
      double baseLevel = useHighs ? iHigh(_Symbol, timeframe, i) : iLow(_Symbol, timeframe, i);
      if(baseLevel <= 0.0)
         continue;

      int count = 1;
      double sum = baseLevel;

      for(int j = i + 1; j <= lookback; j++)
      {
         double compareLevel = useHighs ? iHigh(_Symbol, timeframe, j) : iLow(_Symbol, timeframe, j);
         if(compareLevel <= 0.0)
            continue;

         if(RelativeDiffPercent(baseLevel, compareLevel) <= tolerancePercent)
         {
            count++;
            sum += compareLevel;
         }
      }

      if(count < minCount)
         continue;

      double candidate = sum / count;
      if(wantAboveCurrent && candidate <= currentPrice)
         continue;
      if(!wantAboveCurrent && candidate >= currentPrice)
         continue;

      if(bestLevel == 0.0)
      {
         bestLevel = candidate;
         continue;
      }

      if(wantAboveCurrent && candidate < bestLevel)
         bestLevel = candidate;
      if(!wantAboveCurrent && candidate > bestLevel)
         bestLevel = candidate;
   }

   return bestLevel;
}

bool DetectLiquidityLevels(LiquidityLevels &levels)
{
   ResetLiquidityLevels(levels);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentPrice = (bid + ask) / 2.0;
   if(currentPrice <= 0.0)
      return false;

   double pdh = iHigh(_Symbol, PERIOD_D1, 1);
   double pdl = iLow(_Symbol, PERIOD_D1, 1);
   double pwh = iHigh(_Symbol, PERIOD_W1, 1);
   double pwl = iLow(_Symbol, PERIOD_W1, 1);

   ConsiderBSL(levels, pdh, "PDH", currentPrice);
   ConsiderSSL(levels, pdl, "PDL", currentPrice);
   ConsiderBSL(levels, pwh, "PWH", currentPrice);
   ConsiderSSL(levels, pwl, "PWL", currentPrice);

   double eqh = FindClusterLevel(LTFBiasSecondary, LiquidityLookback, true, 2, EqualLevelTolerancePercent, currentPrice, true);
   double eql = FindClusterLevel(LTFBiasSecondary, LiquidityLookback, false, 2, EqualLevelTolerancePercent, currentPrice, false);
   double highCluster = FindClusterLevel(LTFBiasSecondary, LiquidityLookback, true, 3, EqualLevelTolerancePercent, currentPrice, true);
   double lowCluster = FindClusterLevel(LTFBiasSecondary, LiquidityLookback, false, 3, EqualLevelTolerancePercent, currentPrice, false);

   ConsiderBSL(levels, eqh, "EQH", currentPrice);
   ConsiderSSL(levels, eql, "EQL", currentPrice);
   ConsiderBSL(levels, highCluster, "SwingHighCluster", currentPrice);
   ConsiderSSL(levels, lowCluster, "SwingLowCluster", currentPrice);

   return (levels.nearestBSL > 0.0 || levels.nearestSSL > 0.0);
}

bool DetectSweep(TrendDirection direction, const LiquidityLevels &levels, SweepSignal &sweep)
{
   sweep.valid = false;
   sweep.type = SWEEP_NONE;
   sweep.liquidityLevel = 0.0;
   sweep.extremePrice = 0.0;
   sweep.closePrice = 0.0;
   sweep.candleTime = 0;

   double high = iHigh(_Symbol, SignalTF, 2);
   double low = iLow(_Symbol, SignalTF, 2);
   double close = iClose(_Symbol, SignalTF, 2);
   double open = iOpen(_Symbol, SignalTF, 2);

   if(high <= 0.0 || low <= 0.0)
      return false;

   double body = MathAbs(close - open);
   double candleRange = high - low;
   if(body <= 0.0 || candleRange <= 0.0)
      return false;

   double penetration = MinSweepPenetrationPoints * _Point;

   if(direction == TREND_BEARISH && levels.nearestBSL > 0.0)
   {
      double upperWick = high - MathMax(open, close);
      double sweepDistance = high - levels.nearestBSL;
      double candleMidpoint = low + (candleRange / 2.0);
      bool strongReclaim = close < levels.nearestBSL && close <= candleMidpoint;
      bool wickDominant = upperWick >= (body * MinSweepWickBodyRatio);
      bool validPenetration = sweepDistance >= penetration;

      if(high > levels.nearestBSL && strongReclaim && wickDominant && validPenetration)
      {
         sweep.valid = true;
         sweep.type = SWEEP_BUY_SIDE;
         sweep.liquidityLevel = levels.nearestBSL;
         sweep.extremePrice = high;
         sweep.closePrice = close;
         sweep.candleTime = iTime(_Symbol, SignalTF, 2);
         return true;
      }
   }

   if(direction == TREND_BULLISH && levels.nearestSSL > 0.0)
   {
      double lowerWick = MathMin(open, close) - low;
      double sweepDistance = levels.nearestSSL - low;
      double candleMidpoint = low + (candleRange / 2.0);
      bool strongReclaim = close > levels.nearestSSL && close >= candleMidpoint;
      bool wickDominant = lowerWick >= (body * MinSweepWickBodyRatio);
      bool validPenetration = sweepDistance >= penetration;

      if(low < levels.nearestSSL && strongReclaim && wickDominant && validPenetration)
      {
         sweep.valid = true;
         sweep.type = SWEEP_SELL_SIDE;
         sweep.liquidityLevel = levels.nearestSSL;
         sweep.extremePrice = low;
         sweep.closePrice = close;
         sweep.candleTime = iTime(_Symbol, SignalTF, 2);
         return true;
      }
   }

   return false;
}

bool DetectDisplacement(TrendDirection direction)
{
   double open = iOpen(_Symbol, SignalTF, 1);
   double close = iClose(_Symbol, SignalTF, 1);
   double body = MathAbs(close - open);
   double averageBody = AverageBodySize(SignalTF, 5, 2);

   if(body <= 0.0 || averageBody <= 0.0)
      return false;

   int referenceHighIndex = iHighest(_Symbol, SignalTF, MODE_HIGH, 4, 2);
   int referenceLowIndex = iLowest(_Symbol, SignalTF, MODE_LOW, 4, 2);
   if(referenceHighIndex < 0 || referenceLowIndex < 0)
      return false;

   double referenceHigh = iHigh(_Symbol, SignalTF, referenceHighIndex);
   double referenceLow = iLow(_Symbol, SignalTF, referenceLowIndex);

   if(direction == TREND_BULLISH)
      return (close > open && body >= averageBody * DisplacementBodyFactor && close > referenceHigh);

   if(direction == TREND_BEARISH)
      return (close < open && body >= averageBody * DisplacementBodyFactor && close < referenceLow);

   return false;
}

int BarsSinceTime(ENUM_TIMEFRAMES timeframe, datetime candleTime)
{
   if(candleTime <= 0)
      return -1;

   int shift = iBarShift(_Symbol, timeframe, candleTime, false);
   return shift;
}

bool IsPriceInsideFVG(const FVGZone &zone, double price)
{
   return (price >= zone.low && price <= zone.high);
}

bool ValidateFVGRetest(TrendDirection direction, const FVGZone &zone, double &entryPrice, ENUM_ORDER_TYPE &orderType)
{
   int barsSinceFVG = BarsSinceTime(SignalTF, zone.candleTime);
   if(barsSinceFVG < 1)
      return false;

   if(MaxBarsAfterFVG > 0 && barsSinceFVG > MaxBarsAfterFVG)
      return false;

   double retestHigh = iHigh(_Symbol, SignalTF, 1);
   double retestLow = iLow(_Symbol, SignalTF, 1);
   double retestOpen = iOpen(_Symbol, SignalTF, 1);
   double retestClose = iClose(_Symbol, SignalTF, 1);
   if(retestHigh <= 0.0 || retestLow <= 0.0)
      return false;

   double retestReference = RequireMidpointRetest ? (zone.low + zone.high) / 2.0 : zone.low;
   if(direction == TREND_BEARISH)
      retestReference = RequireMidpointRetest ? (zone.low + zone.high) / 2.0 : zone.high;

   bool touchedZone = (retestHigh >= zone.low && retestLow <= zone.high);
   bool touchedReference = (retestHigh >= retestReference && retestLow <= retestReference);
   if(!touchedZone || !touchedReference)
      return false;

   if(direction == TREND_BULLISH)
   {
      bool bullishReject = (retestClose > retestOpen && retestClose >= zone.high);
      if(RequireRetestRejection && !bullishReject)
         return false;

      entryPrice = NormalizePrice(MathMax(zone.low, MathMin(zone.high, retestClose)));
      orderType = ORDER_TYPE_BUY;
      return true;
   }

   if(direction == TREND_BEARISH)
   {
      bool bearishReject = (retestClose < retestOpen && retestClose <= zone.low);
      if(RequireRetestRejection && !bearishReject)
         return false;

      entryPrice = NormalizePrice(MathMin(zone.high, MathMax(zone.low, retestClose)));
      orderType = ORDER_TYPE_SELL;
      return true;
   }

   return false;
}

bool DetectFVG(TrendDirection direction, FVGZone &zone)
{
   zone.valid = false;
   zone.direction = FVG_NONE;
   zone.low = 0.0;
   zone.high = 0.0;
   zone.candleTime = 0;

   double oldestHigh = iHigh(_Symbol, SignalTF, 3);
   double oldestLow = iLow(_Symbol, SignalTF, 3);
   double newestHigh = iHigh(_Symbol, SignalTF, 1);
   double newestLow = iLow(_Symbol, SignalTF, 1);

   if(oldestHigh <= 0.0 || oldestLow <= 0.0 || newestHigh <= 0.0 || newestLow <= 0.0)
      return false;

   if(direction == TREND_BULLISH && newestLow > oldestHigh)
   {
      zone.valid = true;
      zone.direction = FVG_BULLISH;
      zone.low = oldestHigh;
      zone.high = newestLow;
      zone.candleTime = iTime(_Symbol, SignalTF, 1);
   }
   else if(direction == TREND_BEARISH && newestHigh < oldestLow)
   {
      zone.valid = true;
      zone.direction = FVG_BEARISH;
      zone.low = newestHigh;
      zone.high = oldestLow;
      zone.candleTime = iTime(_Symbol, SignalTF, 1);
   }

   if(!zone.valid)
      return false;

   double midpoint = (zone.low + zone.high) / 2.0;
   double gapPercent = ((zone.high - zone.low) / midpoint) * 100.0;
   if(gapPercent < MinFVGPercent)
   {
      zone.valid = false;
      zone.direction = FVG_NONE;
      return false;
   }

   return true;
}

bool HasOpenExposure()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(symbol == _Symbol && magic == MagicNumber)
         return true;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(!OrderSelect(ticket))
         continue;

      string symbol = OrderGetString(ORDER_SYMBOL);
      long magic = OrderGetInteger(ORDER_MAGIC);
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool pendingType = (type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP);

      if(symbol == _Symbol && magic == MagicNumber && pendingType)
         return true;
   }

   return false;
}

double CalculateLot(double slDistance)
{
   if(slDistance <= 0.0)
      return 0.0;

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(riskMoney <= 0.0 || tickSize <= 0.0 || tickValue <= 0.0 || minLot <= 0.0 || maxLot <= 0.0)
      return 0.0;

   if(step <= 0.0)
      step = 0.01;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   double rawLot = riskMoney / lossPerLot;
   if(rawLot < minLot)
      return 0.0;

   double volume = MathFloor(rawLot / step) * step;
   if(volume > maxLot)
      volume = maxLot;

   int volumeDigits = 2;
   if(step == 1.0)
      volumeDigits = 0;
   else if(step == 0.1)
      volumeDigits = 1;
   else if(step == 0.01)
      volumeDigits = 2;
   else if(step == 0.001)
      volumeDigits = 3;

   return NormalizeDouble(volume, volumeDigits);
}

bool ValidateStops(double entry, double sl, double tp)
{
   double minStopDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(minStopDistance <= 0.0)
      minStopDistance = _Point;

   if(MathAbs(entry - sl) < minStopDistance)
      return false;

   if(MathAbs(tp - entry) < minStopDistance)
      return false;

   return true;
}

string SweepToString(SweepType sweepType)
{
   if(sweepType == SWEEP_BUY_SIDE)
      return "BuySideSweep";
   if(sweepType == SWEEP_SELL_SIDE)
      return "SellSideSweep";
   return "None";
}

string PartialStateKey(ulong ticket)
{
   return StringFormat("SMC_PARTIAL_%I64u", ticket);
}

bool IsPartialDone(ulong ticket)
{
   return GlobalVariableCheck(PartialStateKey(ticket));
}

void MarkPartialDone(ulong ticket)
{
   GlobalVariableSet(PartialStateKey(ticket), (double)TimeCurrent());
}

double NormalizeVolume(double volume)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step <= 0.0)
      step = 0.01;

   int volumeDigits = 2;
   if(step == 1.0)
      volumeDigits = 0;
   else if(step == 0.1)
      volumeDigits = 1;
   else if(step == 0.01)
      volumeDigits = 2;
   else if(step == 0.001)
      volumeDigits = 3;

   double normalized = MathFloor(volume / step) * step;
   if(normalized > maxLot)
      normalized = maxLot;
   if(normalized < minLot)
      return 0.0;

   return NormalizeDouble(normalized, volumeDigits);
}

void LogTradePlan(const TradeSetup &setup)
{
   Log("MARKET STRUCTURE | HTF: " + TrendToString(setup.htfPrimaryTrend) + "/" + TrendToString(setup.htfSecondaryTrend) +
       " | LTF: " + TrendToString(setup.ltfPrimaryTrend) + "/" + TrendToString(setup.ltfSecondaryTrend) +
       " | Phase: " + PhaseToString(setup.htfPhase) + "/" + PhaseToString(setup.ltfPhase));
   Log("LIQUIDITY | BSL: " + setup.bslSource + " | SSL: " + setup.sslSource);
   Log(StringFormat("SWEEP/FVG | Sweep=%s | Entry=%.5f | SL=%.5f | TP1=%.5f | TP2=%.5f | Retest=%s",
                    setup.sweepLabel,
                    setup.entry,
                    setup.sl,
                    setup.tp1,
                    setup.tp2,
                    (setup.orderType == ORDER_TYPE_BUY || setup.orderType == ORDER_TYPE_SELL ? "Confirmed" : "Pending")));
}

void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      if(IsPartialDone(ticket))
         continue;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);
      double priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(volume <= 0.0 || priceOpen <= 0.0 || sl <= 0.0)
         continue;

      double risk = 0.0;
      double tp1 = 0.0;
      bool hitTp1 = false;

      if(type == POSITION_TYPE_BUY)
      {
         risk = priceOpen - sl;
         if(risk <= 0.0)
            continue;
         tp1 = priceOpen + (risk * 2.0);
         hitTp1 = (currentBid >= tp1);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         risk = sl - priceOpen;
         if(risk <= 0.0)
            continue;
         tp1 = priceOpen - (risk * 2.0);
         hitTp1 = (currentAsk <= tp1);
      }
      else
      {
         continue;
      }

      if(!hitTp1)
         continue;

      double closeVolume = NormalizeVolume(volume * PartialClosePercent / 100.0);
      double remainder = NormalizeVolume(volume - closeVolume);
      if(closeVolume < minLot || remainder < minLot)
      {
         MarkPartialDone(ticket);
         continue;
      }

      if(!trade.PositionClosePartial(_Symbol, closeVolume))
      {
         Log("Partial close failed: " + trade.ResultRetcodeDescription());
         continue;
      }

      if(!trade.PositionModify(_Symbol, NormalizePrice(priceOpen), tp))
         Log("Break-even modify failed: " + trade.ResultRetcodeDescription());

      MarkPartialDone(ticket);
      Log(StringFormat("Partial close executed | Ticket=%I64u | CloseVol=%.2f | TP1=%.5f",
                       ticket,
                       closeVolume,
                       tp1));
   }
}

bool BuildTradeSetup(TradeSetup &setup)
{
   setup.valid = false;
   setup.orderType = ORDER_TYPE_BUY_LIMIT;
   setup.direction = TREND_NEUTRAL;
   setup.entry = 0.0;
   setup.sl = 0.0;
   setup.tp1 = 0.0;
   setup.tp2 = 0.0;
   setup.volume = 0.0;
   setup.targetLiquidity = 0.0;
   setup.signalTime = 0;
   setup.comment = "";
   setup.bslSource = "";
   setup.sslSource = "";
   setup.sweepLabel = "";
   setup.htfPrimaryTrend = TREND_NEUTRAL;
   setup.htfSecondaryTrend = TREND_NEUTRAL;
   setup.ltfPrimaryTrend = TREND_NEUTRAL;
   setup.ltfSecondaryTrend = TREND_NEUTRAL;
   setup.htfPhase = PHASE_CONSOLIDATION;
   setup.ltfPhase = PHASE_CONSOLIDATION;

   MarketStructureState htfPrimaryState;
   MarketStructureState htfSecondaryState;
   MarketStructureState ltfPrimaryState;
   MarketStructureState ltfSecondaryState;

   if(!AnalyzeStructure(HTFPrimary, StructureLookback, htfPrimaryState))
      return false;
   if(!AnalyzeStructure(HTFSecondary, StructureLookback, htfSecondaryState))
      return false;
   if(!AnalyzeStructure(LTFBiasPrimary, StructureLookback, ltfPrimaryState))
      return false;
   if(!AnalyzeStructure(LTFBiasSecondary, StructureLookback, ltfSecondaryState))
      return false;

   TrendDirection htfBias = ResolveTrend(htfPrimaryState.trend, htfSecondaryState.trend);
   TrendDirection ltfBias = ResolveTrend(ltfPrimaryState.trend, ltfSecondaryState.trend);

   if(htfBias == TREND_NEUTRAL)
      return false;

   if(ltfBias != htfBias)
      return false;

   LiquidityLevels liquidity;
   if(!DetectLiquidityLevels(liquidity))
      return false;

   SweepSignal sweep;
   if(!DetectSweep(htfBias, liquidity, sweep))
      return false;

   if(!DetectDisplacement(htfBias))
      return false;

   FVGZone fvg;
   if(!DetectFVG(htfBias, fvg))
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return false;

   double entry = NormalizePrice((fvg.low + fvg.high) / 2.0);
   double slBuffer = StopBufferPoints * _Point;
   double sl = 0.0;
   double targetLiquidity = 0.0;

   if(htfBias == TREND_BULLISH)
   {
      sl = NormalizePrice(MathMin(sweep.extremePrice, fvg.low) - slBuffer);
      targetLiquidity = liquidity.nearestBSL;
   }
   else if(htfBias == TREND_BEARISH)
   {
      sl = NormalizePrice(MathMax(sweep.extremePrice, fvg.high) + slBuffer);
      targetLiquidity = liquidity.nearestSSL;
   }

   if(targetLiquidity <= 0.0)
      return false;

   ENUM_ORDER_TYPE orderType = ORDER_TYPE_BUY_LIMIT;
   double retestEntry = 0.0;
   ENUM_ORDER_TYPE retestOrderType = ORDER_TYPE_BUY;
   bool hasValidatedRetest = ValidateFVGRetest(htfBias, fvg, retestEntry, retestOrderType);

   if(hasValidatedRetest)
   {
      orderType = retestOrderType;
      entry = retestEntry;
   }
   else
   {
      if(MaxBarsAfterFVG > 0 && BarsSinceTime(SignalTF, fvg.candleTime) > MaxBarsAfterFVG)
         return false;

      if(htfBias == TREND_BULLISH)
      {
         if(entry >= ask)
            return false;
         orderType = ORDER_TYPE_BUY_LIMIT;
      }
      else
      {
         if(entry <= bid)
            return false;
         orderType = ORDER_TYPE_SELL_LIMIT;
      }
   }

   double risk = 0.0;
   double reward = 0.0;

   if(htfBias == TREND_BULLISH)
   {
      risk = entry - sl;
      reward = targetLiquidity - entry;
   }
   else
   {
      risk = sl - entry;
      reward = entry - targetLiquidity;
   }

   if(risk <= 0.0 || reward <= 0.0)
      return false;

   double rr = reward / risk;
   if(rr < 2.0 || reward < risk)
      return false;

   double volume = CalculateLot(risk);
   if(volume <= 0.0)
      return false;

   double tp1 = 0.0;
   double tp2 = NormalizePrice(targetLiquidity);

   if(htfBias == TREND_BULLISH)
      tp1 = NormalizePrice(entry + (risk * 2.0));
   else
      tp1 = NormalizePrice(entry - (risk * 2.0));

   if(!ValidateStops(entry, sl, tp2))
      return false;

   setup.valid = true;
   setup.orderType = orderType;
   setup.direction = htfBias;
   setup.entry = entry;
   setup.sl = sl;
   setup.tp1 = tp1;
   setup.tp2 = tp2;
   setup.volume = volume;
   setup.targetLiquidity = targetLiquidity;
   setup.signalTime = iTime(_Symbol, SignalTF, 1);
   setup.comment = StringFormat("SMC %s %s",
                                TrendToString(htfBias),
                                (sweep.type == SWEEP_BUY_SIDE ? "BSL" : "SSL"));
   setup.bslSource = liquidity.nearestBSLSource;
   setup.sslSource = liquidity.nearestSSLSource;
   setup.sweepLabel = SweepToString(sweep.type);
   setup.htfPrimaryTrend = htfPrimaryState.trend;
   setup.htfSecondaryTrend = htfSecondaryState.trend;
   setup.ltfPrimaryTrend = ltfPrimaryState.trend;
   setup.ltfSecondaryTrend = ltfSecondaryState.trend;
   setup.htfPhase = htfPrimaryState.phase;
   setup.ltfPhase = ltfSecondaryState.phase;

   LogTradePlan(setup);
   return true;
}

bool PlaceTrade(const TradeSetup &setup)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);

   bool result = false;

   if(setup.orderType == ORDER_TYPE_BUY)
      result = trade.Buy(setup.volume, _Symbol, 0.0, setup.sl, setup.tp2, setup.comment);
   else if(setup.orderType == ORDER_TYPE_SELL)
      result = trade.Sell(setup.volume, _Symbol, 0.0, setup.sl, setup.tp2, setup.comment);
   else if(setup.orderType == ORDER_TYPE_BUY_LIMIT)
      result = trade.BuyLimit(setup.volume, setup.entry, _Symbol, setup.sl, setup.tp2, ORDER_TIME_GTC, 0, setup.comment);
   else if(setup.orderType == ORDER_TYPE_SELL_LIMIT)
      result = trade.SellLimit(setup.volume, setup.entry, _Symbol, setup.sl, setup.tp2, ORDER_TIME_GTC, 0, setup.comment);

   if(!result)
   {
      Log("Order rejected: " + trade.ResultRetcodeDescription());
      return false;
   }

   DailyTradeCount++;
   Log(StringFormat("Order placed | Dir=%s | Entry=%.5f | SL=%.5f | TP1=%.5f | TP2=%.5f | Vol=%.2f",
                    TrendToString(setup.direction),
                    setup.entry,
                    setup.sl,
                    setup.tp1,
                    setup.tp2,
                    setup.volume));
   return true;
}

int OnInit()
{
   DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   LastTradeDayKey = DateKey(TimeCurrent());
   trade.SetExpertMagicNumber(MagicNumber);
   Log("EA Initialized");
   return INIT_SUCCEEDED;
}

void OnTick()
{
   ResetDailyStats();
   UpdateDailyStats();
   ManageOpenPositions();

   if(!IsTradingAllowed())
      return;

   if(!IsKillzone())
      return;

   if(!SpreadOK())
      return;

   if(HasOpenExposure())
      return;

   if(!IsNewBar(SignalTF, LastSignalBarTime))
      return;

   TradeSetup setup;
   if(!BuildTradeSetup(setup))
      return;

   if(setup.signalTime == 0)
      return;

   PlaceTrade(setup);
}
