//+------------------------------------------------------------------+
//| EA Hybrid v5.13.1 FINAL                                          |
//| State-Based Day Trading Engine                                   |
//| TREND IMPULSE / TREND PULLBACK / RANGE                            |
//| + BE + Partial + Log Skip                                        |
//| Platform : MetaTrader 5 (MQL5 Native)                            |
//+------------------------------------------------------------------+
#property strict
#property version "5.13"

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
input int    CooldownMinutes = 15;
input int    MaxOpenPositions = 1;

// --- Session
input int StartHour = 7;
input int EndHour   = 22;

// --- Range Mode
input bool   EnableRangeScalp = true;
input double RangeRiskPercent = 0.2;
input double RR_Range         = 0.5;

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
   STATE_RANGE = 2
};

//========================= GLOBAL ==================================
int hATR_H1, hADX_H1;
int hEMA20, hEMA50, hEMA200;
int hRSI;

datetime lastBar=0, lastTradeTime=0;
int tradesToday=0, lastDay=-1;
double dayStartEquity=0;
bool tradingLocked=false;

string GV_BE_PREFIX = "BE_";
string GV_PT_PREFIX = "PT_";
string lastSkipReason = "";

//========================= INIT ====================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   hATR_H1 = iATR(_Symbol, HTF, ATR_Period);
   hADX_H1 = iADX(_Symbol, HTF, ADX_Period);

   hEMA20  = iMA(_Symbol,_Period,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   hEMA50  = iMA(_Symbol,_Period,EMA_Mid ,0,MODE_EMA,PRICE_CLOSE);
   hEMA200 = iMA(_Symbol,_Period,EMA_Slow,0,MODE_EMA,PRICE_CLOSE);

   hRSI = iRSI(_Symbol,_Period,RSI_Period,PRICE_CLOSE);

   if(hATR_H1==INVALID_HANDLE || hADX_H1==INVALID_HANDLE)
      return INIT_FAILED;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   IndicatorRelease(hADX_H1);
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

//========================= MARKET STATE ============================
MARKET_STATE DetectMarketState()
{
   double atr = BUF(hATR_H1,0,1);
   double adx = BUF(hADX_H1,0,1);

   if(atr/_Point < MinATR_HTF_Points || adx < ADX_Weak)
      return STATE_RANGE;

   if(adx >= ADX_Strong)
      return STATE_TREND_IMPULSE;

   return STATE_TREND_PULLBACK;
}

//========================= COMMON ==================================
bool TrendBuy()
{
   return iClose(_Symbol,HTF,1) > iMA(_Symbol,HTF,50,0,MODE_EMA,PRICE_CLOSE);
}
bool TrendSell()
{
   return iClose(_Symbol,HTF,1) < iMA(_Symbol,HTF,50,0,MODE_EMA,PRICE_CLOSE);
}

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
   double pts=MathAbs(entry-sl)/_Point;
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(pts<=0||tick<=0) return 0;

   double lot=risk/(pts*tick);
   double min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   lot=MathFloor(lot/step)*step;
   return MathMax(min,lot);
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
         trade.PositionModify(ticket,entry,tp);
         GlobalVariableSet(beKey,TimeCurrent());
         Print("🟡 BE | Ticket:",ticket);
         return;
      }

      if(UsePartialTP && gainR>=ptR && !GlobalVariableCheck(ptKey))
      {
         double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
         double min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
         double closeVol=MathFloor(vol*ptPct/100.0/step)*step;

         if(closeVol>=min)
         {
            trade.PositionClosePartial(ticket,closeVol);
            GlobalVariableSet(ptKey,TimeCurrent());
            Print("🟢 PARTIAL | Ticket:",ticket);
            return;
         }
      }
   }
}

//========================= STRATEGIES ==============================

void TradeTrendImpulse()
{
   if(!(BUF(hEMA20,0,1)>BUF(hEMA50,0,1) &&
        BUF(hEMA50,0,1)>BUF(hEMA200,0,1))) { LogSkip("Impulse EMA invalid"); return; }

   if(TrendBuy())
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl=SwingLow();
      double tp=entry+(entry-sl)*RR_TrendImpulse;
      double lot=CalcLot(RiskPercent,entry,sl);
      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🚀 IMPULSE BUY");
         return;
      }
      else
      {
         Print("ℹ SKIP : TrendImpulse Buy | ", _Symbol);
      }
   }

   if(TrendSell())
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl=SwingHigh();
      double tp=entry-(sl-entry)*RR_TrendImpulse;
      double lot=CalcLot(RiskPercent,entry,sl);
      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🚀 IMPULSE SELL");
         return;
      }
      else
      {
         Print("ℹ SKIP : TrendImpulse Sell | ", _Symbol);
      }
   }
}

void TradeTrendPullback()
{
   double rsi=BUF(hRSI,0,1);

   if(TrendBuy() &&
      rsi>=RSI_BuyMin && rsi<=RSI_BuyMax &&
      iLow(_Symbol,_Period,1)<=BUF(hEMA20,0,1) &&
      iClose(_Symbol,_Period,1)>BUF(hEMA20,0,1))
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl=SwingLow();
      double tp=entry+(entry-sl)*RR_Pullback;
      double lot=CalcLot(RiskPercent,entry,sl);
      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🟡 PULLBACK BUY");
         return;
      }
      else
      {
         Print("ℹ SKIP : TrendPullback Sell | ", _Symbol);
      }
   }

   if(TrendSell() &&
      rsi>=RSI_SellMin && rsi<=RSI_SellMax &&
      iHigh(_Symbol,_Period,1)>=BUF(hEMA20,0,1) &&
      iClose(_Symbol,_Period,1)<BUF(hEMA20,0,1))
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl=SwingHigh();
      double tp=entry-(sl-entry)*RR_Pullback;
      double lot=CalcLot(RiskPercent,entry,sl);
      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🟡 PULLBACK SELL");
         return;
      }
      else
      {
         Print("ℹ SKIP : TrendPullback Buy | ", _Symbol);
      }
   }
}

void TradeRange()
{
   if(!EnableRangeScalp){ LogSkip("Range disabled"); return; }

   double atr=BUF(hATR_H1,0,1);

   if(iLow(_Symbol,_Period,1)<iLow(_Symbol,_Period,5))
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double sl=entry-0.3*atr;
      double tp=entry+(entry-sl)*RR_Range;
      double lot=CalcLot(RangeRiskPercent,entry,sl);
      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🔵 RANGE BUY");
         return;
      }
      else
      {
         Print("ℹ SKIP : Range Buy | ", _Symbol);
      }
   }

   if(iHigh(_Symbol,_Period,1)>iHigh(_Symbol,_Period,5))
   {
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double sl=entry+0.3*atr;
      double tp=entry-(sl-entry)*RR_Range;
      double lot=CalcLot(RangeRiskPercent,entry,sl);
      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++; lastTradeTime=TimeCurrent();
         Print("🔵 RANGE SELL");
         return;
      }
      else
      {
         Print("ℹ SKIP : Range Sell | ", _Symbol);
      }
   }
}

//========================= ONTICK ================================
void OnTick()
{
   CheckDailyReset();
   if(tradingLocked || DailyLossExceeded()){ LogSkip("Daily lock"); return; }

   ManagePositions();

   if(!IsNewBar()){ LogSkip("Not new bar"); return; }
   if(!InSession()){ LogSkip("Out of session"); return; }
   if(tradesToday>=MaxTradesDay){ LogSkip("Max trades"); return; }
   if(TimeCurrent()-lastTradeTime < CooldownMinutes*60)
   {
      LogSkip("Cooldown");
      return;
   }
   if(PositionsTotal()>=MaxOpenPositions){ LogSkip("Position limit"); return; }

   MARKET_STATE state = DetectMarketState();

   if(state==STATE_TREND_IMPULSE) TradeTrendImpulse();
   else if(state==STATE_TREND_PULLBACK) TradeTrendPullback();
   else TradeRange();
}

void LogMode(string mode, double adx)
{
   Print("ℹ MODE | ", _Symbol, " | ", mode, " | ADX=", DoubleToString(adx,1));
}
