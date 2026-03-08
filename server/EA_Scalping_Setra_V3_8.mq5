//+------------------------------------------------------------------+
//| EA XAUUSD Scalping v3.8                                          |
//| Adaptive SR + Adaptive Momentum + Debug                           |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUT =================
input string InpSymbol = "XAUUSD";
input ENUM_TIMEFRAMES TF = PERIOD_M15;

//--- Momentum
input double BaseMomentumPip   = 40.0;
input double MomentumATRMult   = 0.45;
input double MinPipFloor       = 25.0;
input double MaxWickRatio      = 0.30;
input bool   UseMomentumWickValidation = true;
input double MomentumOpenWickMaxRatio  = 0.1;
input double MomentumCloseWickMinRatio = 0.0;
input double MomentumCloseWickMaxRatio = 0.30;
input bool   UseMomentumStructureFilter = true;
input int    MomentumStructureLookbackBars = 6;
input bool   UseMomentumExhaustionGuard = true;
input double MomentumMaxBodyATRMult = 1.8;

//--- SL / TP
input int    SL_Buffer_Tick = 3;
input double RR_Normal      = 1.0;
input double FiboTP         = 1.272;

//--- Risk
input bool   UseRiskPercent = true;
input double RiskPercent   = 1.0;
input double FixedLot      = 0.01;
input int    MaxOpenPositions = 3;

//--- SR M5
input bool   SkipTradeNearSR = true;
input int    SR_Lookback        = 20;
input double SR_Pip_Input      = 10.0;
input double SR_ATR_Mult       = 0.5;

//--- HTF SR
input bool   UseHTFSRFilter     = true;
input ENUM_TIMEFRAMES HTF_TF    = PERIOD_H1;
input int    HTF_Lookback       = 12;
input double HTF_SR_Pip         = 10.0;
input double HTF_Bypass_Mult    = 1.2;

// --- Daily Loss Lock
input bool   InpUseDailyLossLock = true;
input double InpMaxDailyLossPercent = 3.0;
input bool   InpUseDailyTradeLimit = true;
input int    InpMaxDailyTrades     = 8;

//--- Debug
input bool   DebugLog           = true;
input int    SkipAfterConsecutiveSL = 2;
input int    SkipDurationMinutes     = 60;
input bool   UseRangingFilter        = true;
input int    RangingLookbackBars     = 20;
input double RangingMaxADX           = 18.0;
input double RangingRangeATRMult     = 1.8;
input int    RangingMinSignals       = 2;
input int    RangingEMAPeriod        = 50;
input int    RangingEMASlopeBars     = 8;
input double RangingMaxEMASlopePip   = 8.0;
input int    RangingBodyAvgBars      = 10;
input double RangingMaxBodyATRMult   = 0.55;
input bool   UseTransitionChopFilter = true;
input double TransitionADXMult       = 1.6;
input double TransitionEMASlopeMult  = 3.0;
input double TransitionSpanRatioMax  = 1.8;

//--- Magic
input int MagicNumber = 20251220;

//=============== GLOBAL =================
datetime lastBarTime=0;
double DayStartBalance = 0;
datetime CurrentDayStart = 0;
int ConsecutiveSLCount = 0;
datetime SkipTradeUntil = 0;

//=============== UTIL ===================
double Pip(){
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);

   // Forex 5/3-digit symbols use fractional pip quotes.
   if(digits == 3 || digits == 5)
      return point * 10.0;

   // Metals/crypto/indices usually use point as practical pip unit.
   return point;
}

double GetATR(ENUM_TIMEFRAMES tf)
{
   static int atrHandle = INVALID_HANDLE;
   static ENUM_TIMEFRAMES atrTF = (ENUM_TIMEFRAMES)-1;

   if(atrHandle == INVALID_HANDLE || atrTF != tf)
   {
      if(atrHandle != INVALID_HANDLE)
         IndicatorRelease(atrHandle);

      atrHandle = iATR(InpSymbol, tf, 14);
      atrTF = tf;
      if(atrHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed create ATR handle");
         return 0.0;
      }
   }

   double atrBuf[];
   if(CopyBuffer(atrHandle, 0, 1, 1, atrBuf) <= 0)
   {
      Print("ERROR: Failed copy ATR buffer");
      return 0.0;
   }

   return atrBuf[0];
}

double AvgBody(int bars)
{
   double sum=0;
   for(int i=1;i<=bars;i++)
      sum+=MathAbs(iClose(InpSymbol,TF,i)-iOpen(InpSymbol,TF,i));
   return sum/bars;
}

double GetHigh(ENUM_TIMEFRAMES tf,int bars,int shift)
{
   double h=-DBL_MAX;
   for(int i=shift;i<shift+bars;i++)
      h=MathMax(h,iHigh(InpSymbol,tf,i));
   return h;
}

double GetLow(ENUM_TIMEFRAMES tf,int bars,int shift)
{
   double l=DBL_MAX;
   for(int i=shift;i<shift+bars;i++)
      l=MathMin(l,iLow(InpSymbol,tf,i));
   return l;
}

int CountPositions()
{
   int buys=0, sells=0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i)))
         continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      long   mg  = PositionGetInteger(POSITION_MAGIC);
      long   type= PositionGetInteger(POSITION_TYPE);

      if(sym == InpSymbol && mg == MagicNumber)
      {
         if(type == POSITION_TYPE_BUY)  buys++;
         if(type == POSITION_TYPE_SELL) sells++;
      }
   }
   return buys + sells;
}

//=============== LOT ====================
double CalculateLot(double entry,double sl)
{
   if(!UseRiskPercent) return FixedLot;

   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double risk=bal*RiskPercent/100.0;
   double tickSize=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(InpSymbol,SYMBOL_TRADE_TICK_VALUE);

   double dist=MathAbs(entry-sl);
   double lossPerLot=(dist/tickSize)*tickValue;
   double lot=risk/lossPerLot;

   double minLot=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_MAX);
   double step  =SymbolInfoDouble(InpSymbol,SYMBOL_VOLUME_STEP);

   lot=MathMax(minLot,MathMin(maxLot,lot));
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(lot,2);
}

//=============== MOMENTUM ===============
bool IsMomentumWickValid(bool bullish,double o,double c,double h,double l)
{
   if(!UseMomentumWickValidation) return true;
   double body=MathAbs(c-o);
   if(body <= 0.0) return false;

   double openWick = bullish ? MathMax(0.0, o-l) : MathMax(0.0, h-o);
   double closeWick = bullish ? MathMax(0.0, h-c) : MathMax(0.0, c-l);

   double noWickMax = body * MathMax(0.0, MomentumOpenWickMaxRatio);
   bool openNoWick = (openWick <= noWickMax);
   bool closeNoWick = (closeWick <= noWickMax);

   bool closeSmallWick = (closeWick >= body * MathMax(0.0, MomentumCloseWickMinRatio)
                          && closeWick <= body * MathMax(MomentumCloseWickMinRatio, MomentumCloseWickMaxRatio));

   // Valid patterns:
   // 1) Open no wick + close wick 20-30%
   // 2) Open and close no wick
   return ((openNoWick && closeSmallWick) || (openNoWick && closeNoWick));
}

bool MomentumBreaksStructure(bool bullish,double closePrice)
{
   if(!UseMomentumStructureFilter) return true;

   int bars = MathMax(2, MomentumStructureLookbackBars);
   double hh = GetHigh(TF, bars, 2);
   double ll = GetLow (TF, bars, 2);

   if(bullish) return (closePrice > hh);
   return (closePrice < ll);
}

bool MomentumNotExhausted(double body,double atr)
{
   if(!UseMomentumExhaustionGuard) return true;
   if(atr <= 0.0) return false;
   return (body <= atr * MomentumMaxBodyATRMult);
}

bool MomentumBull(double &body)
{
   double o=iOpen(InpSymbol,TF,1);
   double c=iClose(InpSymbol,TF,1);
   double h=iHigh(InpSymbol,TF,1);
   double l=iLow (InpSymbol,TF,1);

   body=MathAbs(c-o);
   double atr=GetATR(TF);
   double minBody=MathMax(MinPipFloor*Pip(),atr*MomentumATRMult);

   bool dirOk = (c>o);
   bool sizeOk = (body>=minBody);
   bool wickOk = IsMomentumWickValid(true,o,c,h,l);
   bool structureOk = MomentumBreaksStructure(true,c);
   bool exhaustOk = MomentumNotExhausted(body,atr);
   bool pass = (dirOk && sizeOk && wickOk && structureOk && exhaustOk);

   if(DebugLog)
   {
      double bodyPip = (Pip() > 0.0 ? body / Pip() : 0.0);
      double minBodyPip = (Pip() > 0.0 ? minBody / Pip() : 0.0);
      Print("[MOMO BULL] pass=", (pass ? "Y" : "N"),
            " dir=", (dirOk ? "Y" : "N"),
            " size=", (sizeOk ? "Y" : "N"),
            " wick=", (wickOk ? "Y" : "N"),
            " bos=", (structureOk ? "Y" : "N"),
            " exh=", (exhaustOk ? "Y" : "N"),
            " bodyPip=", bodyPip,
            " minBodyPip=", minBodyPip,
            " atr=", atr);
   }

   return pass;
}

bool MomentumBear(double &body)
{
   double o=iOpen(InpSymbol,TF,1);
   double c=iClose(InpSymbol,TF,1);
   double h=iHigh(InpSymbol,TF,1);
   double l=iLow (InpSymbol,TF,1);

   body=MathAbs(o-c);
   double atr=GetATR(TF);
   double minBody=MathMax(MinPipFloor*Pip(),atr*MomentumATRMult);

   bool dirOk = (c<o);
   bool sizeOk = (body>=minBody);
   bool wickOk = IsMomentumWickValid(false,o,c,h,l);
   bool structureOk = MomentumBreaksStructure(false,c);
   bool exhaustOk = MomentumNotExhausted(body,atr);
   bool pass = (dirOk && sizeOk && wickOk && structureOk && exhaustOk);

   if(DebugLog)
   {
      double bodyPip = (Pip() > 0.0 ? body / Pip() : 0.0);
      double minBodyPip = (Pip() > 0.0 ? minBody / Pip() : 0.0);
      Print("[MOMO BEAR] pass=", (pass ? "Y" : "N"),
            " dir=", (dirOk ? "Y" : "N"),
            " size=", (sizeOk ? "Y" : "N"),
            " wick=", (wickOk ? "Y" : "N"),
            " bos=", (structureOk ? "Y" : "N"),
            " exh=", (exhaustOk ? "Y" : "N"),
            " bodyPip=", bodyPip,
            " minBodyPip=", minBodyPip,
            " atr=", atr);
   }

   return pass;
}

double GetADX()
{
   static int adxHandle = INVALID_HANDLE;
   static ENUM_TIMEFRAMES adxTF = (ENUM_TIMEFRAMES)-1;

   if(adxHandle == INVALID_HANDLE || adxTF != TF)
   {
      if(adxHandle != INVALID_HANDLE)
         IndicatorRelease(adxHandle);

      adxHandle = iADX(InpSymbol, TF, 14);
      adxTF = TF;
      if(adxHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed create ADX handle");
         return 0.0;
      }
   }

   double adxBuf[];
   if(CopyBuffer(adxHandle, 0, 1, 1, adxBuf) <= 0)
   {
      Print("ERROR: Failed copy ADX buffer");
      return 0.0;
   }

   return adxBuf[0];
}

double GetEMA(int period,int shift)
{
   static int emaHandle = INVALID_HANDLE;
   static int emaPeriod = -1;
   static ENUM_TIMEFRAMES emaTF = (ENUM_TIMEFRAMES)-1;

   if(emaHandle == INVALID_HANDLE || emaPeriod != period || emaTF != TF)
   {
      if(emaHandle != INVALID_HANDLE)
         IndicatorRelease(emaHandle);

      emaHandle = iMA(InpSymbol, TF, period, 0, MODE_EMA, PRICE_CLOSE);
      emaPeriod = period;
      emaTF = TF;
      if(emaHandle == INVALID_HANDLE)
      {
         Print("ERROR: Failed create EMA handle");
         return 0.0;
      }
   }

   double emaBuf[];
   if(CopyBuffer(emaHandle, 0, shift, 1, emaBuf) <= 0)
   {
      Print("ERROR: Failed copy EMA buffer");
      return 0.0;
   }

   return emaBuf[0];
}

bool IsRangingMarket()
{
   if(!UseRangingFilter) return false;

   double atr = GetATR(TF);
   if(atr <= 0.0) return false;

   int bars = MathMax(5, RangingLookbackBars);
   double hh = GetHigh(TF, bars, 1);
   double ll = GetLow (TF, bars, 1);
   double span = hh - ll;

   double spanMax = atr * RangingRangeATRMult;
   bool rangeCompressed = (span <= spanMax);
   double spanRatio = (spanMax > 0.0 ? span / spanMax : 0.0);

   double adx = GetADX();
   bool weakTrend = (adx > 0.0 && adx <= RangingMaxADX);

   int emaSlopeBars = MathMax(2, RangingEMASlopeBars);
   double emaNow = GetEMA(MathMax(5, RangingEMAPeriod), 1);
   double emaPast = GetEMA(MathMax(5, RangingEMAPeriod), 1 + emaSlopeBars);
   double emaSlopePip = 0.0;
   bool flatEMA = false;
   if(emaNow > 0.0 && emaPast > 0.0)
   {
      emaSlopePip = MathAbs(emaNow - emaPast) / Pip();
      flatEMA = (emaSlopePip <= RangingMaxEMASlopePip);
   }

   int bodyBars = MathMax(5, RangingBodyAvgBars);
   double avgBody = AvgBody(bodyBars);
   double bodyMax = atr * RangingMaxBodyATRMult;
   bool smallBody = (avgBody <= bodyMax);

   double softADXMax = RangingMaxADX * MathMax(1.0, TransitionADXMult);
   double softEMAMax = RangingMaxEMASlopePip * MathMax(1.0, TransitionEMASlopeMult);
   bool transitionChop = false;
   if(UseTransitionChopFilter)
   {
      bool softTrend = (adx > 0.0 && adx <= softADXMax);
      bool softEMA = (emaSlopePip <= softEMAMax);
      bool nearCompression = (spanRatio <= MathMax(1.0, TransitionSpanRatioMax));

      // Transitional chop can appear before bodies shrink.
      transitionChop = ((smallBody && softTrend && softEMA)
                        || (nearCompression && softTrend));
   }

   int signals = 0;
   if(rangeCompressed) signals++;
   if(weakTrend) signals++;
   if(flatEMA) signals++;
   if(smallBody) signals++;
   if(transitionChop) signals++;

   int minSignals = MathMax(1, MathMin(5, RangingMinSignals));
   bool transitionOverride = (UseTransitionChopFilter && transitionChop && !smallBody && adx > 0.0 && adx <= softADXMax);
   bool ranging = (signals >= minSignals) || transitionOverride;

   if(DebugLog)
   {
      Print("[RANGING CHECK] ranging=", (ranging ? "YES" : "NO"),
            " signals=", signals, "/", minSignals,
            " rc=", (rangeCompressed ? "Y" : "N"),
            " wt=", (weakTrend ? "Y" : "N"),
            " fe=", (flatEMA ? "Y" : "N"),
            " sb=", (smallBody ? "Y" : "N"),
            " tc=", (transitionChop ? "Y" : "N"),
            " tov=", (transitionOverride ? "Y" : "N"),
            " span=", span,
            " spanMax=", spanMax,
            " spanRatio=", spanRatio,
            " adx=", adx,
            " adxMax=", RangingMaxADX,
            " softADXMax=", softADXMax,
            " emaSlopePip=", emaSlopePip,
            " emaSlopeMax=", RangingMaxEMASlopePip,
            " softEMAMax=", softEMAMax,
            " avgBody=", avgBody,
            " bodyMax=", bodyMax);
   }

   return ranging;
}

bool DailyLossExceeded()
{
   if(!InpUseDailyLossLock) return false;
   if(DayStartBalance <= 0.0) return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dd = (DayStartBalance - equity) / DayStartBalance * 100.0;
   return (dd >= InpMaxDailyLossPercent);
}

datetime GetDayStart(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

void RefreshDailyBaseline()
{
   datetime dayStart = GetDayStart(TimeCurrent());
   if(CurrentDayStart != dayStart)
   {
      CurrentDayStart = dayStart;
      DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(DebugLog)
         Print("[DAILY RESET] dayStart=", TimeToString(CurrentDayStart, TIME_DATE),
               " balance=", DayStartBalance);
   }
}


int CountTodayTrades()
{
   datetime now = TimeCurrent();
   datetime dayStart = GetDayStart(now);

   if(!HistorySelect(dayStart, now))
      return 0;

   int trades = 0;
   int deals = HistoryDealsTotal();
   for(int i=0; i<deals; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
      long magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);

      if(sym == InpSymbol && magic == MagicNumber && entry == DEAL_ENTRY_IN)
         trades++;
   }
   return trades;
}

bool DailyTradeLimitReached()
{
   if(!InpUseDailyTradeLimit) return false;
   if(InpMaxDailyTrades <= 0) return false;

   int todayTrades = CountTodayTrades();
   if(todayTrades >= InpMaxDailyTrades)
   {
      if(DebugLog) Print("[LOCKED] Max daily trades reached: ", todayTrades, "/", InpMaxDailyTrades);
      return true;
   }
   return false;
}

bool NearSR()
{
   double h=-DBL_MAX,l=DBL_MAX;
   for(int i=1;i<=SR_Lookback;i++)
   {
      h=MathMax(h,iHigh(InpSymbol,TF,i));
      l=MathMin(l,iLow(InpSymbol,TF,i));
   }
   double price=iClose(InpSymbol,TF,1);
   double buf=SR_Pip_Input*Pip();
   return (MathAbs(price-h)<=buf || MathAbs(price-l)<=buf);
}

//=============== ENTRY ==================
void CheckEntry()
{
   if(TimeCurrent() < SkipTradeUntil)
   {
      if(DebugLog)
      {
         int secLeft = (int)(SkipTradeUntil - TimeCurrent());
         int minLeft = (secLeft + 59) / 60;
         Print("[NO TRADE] Cooldown after consecutive SL, remaining ", minLeft, " min");
      }
      return;
   }
   RefreshDailyBaseline();

   if(DailyLossExceeded())
   {
      if(DebugLog) Print("[LOCKED] Daily loss exceeded");
      return;
   }

   if(DailyTradeLimitReached())
   {
      if(DebugLog) Print("[LOCKED] Daily trade limit reached");
      return;
   }

   if(CountPositions() >= MaxOpenPositions)
   {
     if(DebugLog) Print("[NO TRADE] Reached max position");
     return; 
   }

   if(IsRangingMarket())
   {
      if(DebugLog) Print("[NO TRADE] RangingMarket");
      return;
   }

   double body=0;
   bool bull=MomentumBull(body);
   bool bear=MomentumBear(body);

   if(!bull && !bear)
   {
      if(DebugLog) Print("[NO TRADE] Momentum invalid");
      return;
   }

   double atr=GetATR(TF);
   double srDist=MathMin(SR_Pip_Input*Pip(),atr*SR_ATR_Mult);

   //bool nearSR=false;
   bool nearSR = NearSR();
   if(SkipTradeNearSR && nearSR)
   {
      if(DebugLog) Print("[NO TRADE] Near SnR");
      return;
   }

   double srH=GetHigh(TF,SR_Lookback,2);
   double srL=GetLow (TF,SR_Lookback,2);

   double ask=SymbolInfoDouble(InpSymbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(InpSymbol,SYMBOL_BID);

   if(bull && MathAbs(ask-srH)<=srDist) nearSR=true;
   if(bear && MathAbs(bid-srL)<=srDist) nearSR=true;

   if(UseHTFSRFilter)
   {
      double avgBody=AvgBody(20);
      double htfH=GetHigh(HTF_TF,HTF_Lookback,1);
      double htfL=GetLow (HTF_TF,HTF_Lookback,1);

      if(body<avgBody*HTF_Bypass_Mult)
      {
         if(bull && MathAbs(ask-htfH)<=HTF_SR_Pip*Pip()) nearSR=true;
         if(bear && MathAbs(bid-htfL)<=HTF_SR_Pip*Pip()) nearSR=true;
      }
   }

   double high=iHigh(InpSymbol,TF,1);
   double low =iLow (InpSymbol,TF,1);
   double buffer=SL_Buffer_Tick*SymbolInfoDouble(InpSymbol,SYMBOL_POINT);

   if(bull)
   {
      double sl=low-buffer;
      double tp=nearSR ? low+(high-low)*FiboTP : ask+(ask-sl)*RR_Normal;
      double lot=CalculateLot(ask,sl);

      if(lot>0)
      {
         trade.SetExpertMagicNumber(MagicNumber);
         trade.Buy(lot,InpSymbol,ask,sl,tp);
         if(DebugLog) Print("[TRADE BUY] Mode=",nearSR?"NearSR":"Normal");
      }
   }

   if(bear)
   {
      double sl=high+buffer;
      double tp=nearSR ? high-(high-low)*FiboTP : bid-(sl-bid)*RR_Normal;
      double lot=CalculateLot(bid,sl);

      if(lot>0)
      {
         trade.SetExpertMagicNumber(MagicNumber);
         trade.Sell(lot,InpSymbol,bid,sl,tp);
         if(DebugLog) Print("[TRADE SELL] Mode=",nearSR?"NearSR":"Normal");
      }
   }
}

//=============== EVENTS =================
int OnInit()
{
   CurrentDayStart = GetDayStart(TimeCurrent());
   DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(DebugLog)
      Print("[INIT] dayStart=", TimeToString(CurrentDayStart, TIME_DATE),
            " balance=", DayStartBalance);

   trade.SetExpertMagicNumber(MagicNumber);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   datetime t=iTime(InpSymbol,TF,0);
   if(t!=lastBarTime)
   {
      lastBarTime=t;
      CheckEntry();
   }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;

   string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   long magic    = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   long entry    = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   long reason   = HistoryDealGetInteger(dealTicket, DEAL_REASON);

   if(symbol != InpSymbol || magic != MagicNumber || entry != DEAL_ENTRY_OUT)
      return;

   if(reason == DEAL_REASON_SL)
   {
      ConsecutiveSLCount++;
      if(DebugLog) Print("[SL TRACK] Consecutive SL = ", ConsecutiveSLCount);

      if(ConsecutiveSLCount >= SkipAfterConsecutiveSL)
      {
         SkipTradeUntil = TimeCurrent() + (SkipDurationMinutes * 60);
         if(DebugLog) Print("[COOLDOWN] Triggered for ", SkipDurationMinutes, " minutes until ", TimeToString(SkipTradeUntil, TIME_DATE|TIME_SECONDS));
         ConsecutiveSLCount = 0;
      }
   }
   else
   {
      ConsecutiveSLCount = 0;
      if(DebugLog) Print("[SL TRACK] Reset, close reason = ", reason);
   }
}
