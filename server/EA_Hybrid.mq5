//+------------------------------------------------------------------+
//| EA Hybrid v5 FINAL                                               |
//| SuperTrend HTF (H1) + EMA20 Pullback LTF (M15)                    |
//| Anti-Crash | Daily Lock | BE | Partial | Verbose Log             |
//| Platform : MetaTrader 5 (MQL5 Native)                            |
//+------------------------------------------------------------------+
#property strict
#property version "5.10"

#include <Trade/Trade.mqh>
CTrade trade;

//========================= INPUT ===================================
input double RiskPercent = 0.5;
input double RR          = 1.2;

// --- HTF (H1)
input ENUM_TIMEFRAMES HTF = PERIOD_H1;
input int    ATR_Period   = 14;
input double ExhaustionATR = 2.0;

input int    BB_Period = 20;
input double BB_Dev    = 2.0;

// --- LTF EMA (chart TF = M15)
input int EMA_Fast = 20;
input int EMA_Mid  = 50;
input int EMA_Slow = 200;

// --- Risk control
input int    MaxTradesDay        = 3;
input double MaxDailyLossPercent = 5.0;

// --- BE & Partial
input bool   UseBreakEven = true;
input double BE_R = 0.5;

input bool   UsePartialTP = true;
input double PartialClosePercent = 50;

// --- Session
input int StartHour = 6;
input int EndHour   = 23;

// --- Log
input bool VerboseSkipLog = true;

input ulong MagicNumber = 20260115;

//========================= GLOBAL ==================================
int hATR_H1, hEMA50_H1, hBB_H1;
int hEMA20_M15, hEMA50_M15, hEMA200_M15;

datetime lastBar = 0;
int tradesToday = 0;
int lastDay = -1;

double dayStartEquity = 0;
bool   tradingLocked  = false;

// --- Flags
string GV_BE_PREFIX      = "BE_DONE_";
string GV_PARTIAL_PREFIX = "PARTIAL_DONE_";
string lastSkipReason    = "";

//========================= INIT ====================================
int OnInit()
{
   hATR_H1   = iATR(_Symbol, HTF, ATR_Period);
   hEMA50_H1 = iMA(_Symbol, HTF, 50, 0, MODE_EMA, PRICE_CLOSE);
   hBB_H1    = iBands(_Symbol, HTF, BB_Period, 0, BB_Dev, PRICE_CLOSE);

   hEMA20_M15  = iMA(_Symbol, _Period, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA50_M15  = iMA(_Symbol, _Period, EMA_Mid , 0, MODE_EMA, PRICE_CLOSE);
   hEMA200_M15 = iMA(_Symbol, _Period, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(hATR_H1==INVALID_HANDLE || hEMA50_H1==INVALID_HANDLE || hBB_H1==INVALID_HANDLE)
      return INIT_FAILED;

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR_H1);
   IndicatorRelease(hEMA50_H1);
   IndicatorRelease(hBB_H1);
   IndicatorRelease(hEMA20_M15);
   IndicatorRelease(hEMA50_M15);
   IndicatorRelease(hEMA200_M15);
}

//========================= UTILS ===================================
double BUF(int handle,int buffer,int shift)
{
   double v[];
   if(CopyBuffer(handle,buffer,shift,1,v)<=0) return 0;
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
   MqlDateTime t;
   TimeToStruct(TimeCurrent(),t);
   return (t.hour>=StartHour && t.hour<=EndHour);
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
      dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      tradingLocked=false;
      Print("🔄 New day | Equity reset:",dayStartEquity);
   }
}

bool DailyLossExceeded()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double loss=(dayStartEquity-eq)/dayStartEquity*100.0;
   if(loss>=MaxDailyLossPercent)
   {
      tradingLocked=true;
      Print("🛑 DAILY LOCK | Loss:",DoubleToString(loss,2),"%");
      return true;
   }
   return false;
}

//========================= LOG =====================================
void LogSkip(string reason)
{
   if(!VerboseSkipLog) return;
   if(reason!=lastSkipReason)
   {
      Print("⏭️ SKIP: ",reason);
      lastSkipReason=reason;
   }
}

//========================= HTF FILTER ===============================
bool SuperTrendBuyHTF()
{
   return iClose(_Symbol,HTF,1) > BUF(hEMA50_H1,0,1);
}

bool SuperTrendSellHTF()
{
   return iClose(_Symbol,HTF,1) < BUF(hEMA50_H1,0,1);
}

bool ExhaustionOK_HTF()
{
   double atr=BUF(hATR_H1,0,1);
   double ema=BUF(hEMA50_H1,0,1);
   return MathAbs(iClose(_Symbol,HTF,1)-ema)<=ExhaustionATR*atr;
}

bool BBExpansionOK_HTF(bool buy)
{
   double u1=BUF(hBB_H1,1,1), l1=BUF(hBB_H1,2,1);
   double u2=BUF(hBB_H1,1,3), l2=BUF(hBB_H1,2,3);
   if((u1-l1)<=(u2-l2)) return true;
   if(buy && iClose(_Symbol,HTF,1)>u1) return false;
   if(!buy && iClose(_Symbol,HTF,1)<l1) return false;
   return true;
}

//========================= LTF ENTRY ===============================
bool TrendBuyLTF()
{
   return BUF(hEMA20_M15,0,1)>BUF(hEMA50_M15,0,1) &&
          BUF(hEMA50_M15,0,1)>BUF(hEMA200_M15,0,1);
}

bool TrendSellLTF()
{
   return BUF(hEMA20_M15,0,1)<BUF(hEMA50_M15,0,1) &&
          BUF(hEMA50_M15,0,1)<BUF(hEMA200_M15,0,1);
}

bool PullbackBuy()
{
   return iLow(_Symbol,_Period,1)<=BUF(hEMA20_M15,0,1) &&
          iClose(_Symbol,_Period,1)>=BUF(hEMA20_M15,0,1);
}

bool PullbackSell()
{
   return iHigh(_Symbol,_Period,1)>=BUF(hEMA20_M15,0,1) &&
          iClose(_Symbol,_Period,1)<=BUF(hEMA20_M15,0,1);
}

bool BullPin()
{
   double h=iHigh(_Symbol,_Period,1), l=iLow(_Symbol,_Period,1);
   double o=iOpen(_Symbol,_Period,1), c=iClose(_Symbol,_Period,1);
   return MathAbs(c-o)<=0.3*(h-l) && (MathMin(o,c)-l)>=2*MathAbs(c-o);
}

bool BearPin()
{
   double h=iHigh(_Symbol,_Period,1), l=iLow(_Symbol,_Period,1);
   double o=iOpen(_Symbol,_Period,1), c=iClose(_Symbol,_Period,1);
   return MathAbs(c-o)<=0.3*(h-l) && (h-MathMax(o,c))>=2*MathAbs(c-o);
}

//========================= SL & LOT ================================
double SwingLow()
{
   double l=iLow(_Symbol,_Period,1);
   for(int i=2;i<=10;i++) if(iLow(_Symbol,_Period,i)<l) l=iLow(_Symbol,_Period,i);
   return l;
}

double SwingHigh()
{
   double h=iHigh(_Symbol,_Period,1);
   for(int i=2;i<=10;i++) if(iHigh(_Symbol,_Period,i)>h) h=iHigh(_Symbol,_Period,i);
   return h;
}

double CalcLot(double sl)
{
   double risk=AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
   double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double pts=MathAbs(entry-sl)/_Point;
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(pts<=0||tick<=0) return 0;
   double lot=risk/(pts*tick);
   double min=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   return MathMax(min,NormalizeDouble(lot/step,0)*step);
}

//========================= FLAGS ===================================
bool IsFlagSet(string key){ return GlobalVariableCheck(key); }
void SetFlag(string key){ GlobalVariableSet(key,TimeCurrent()); }

//========================= MANAGE POSITIONS ========================
void ManagePositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber)continue;

      double entry=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      long type=PositionGetInteger(POSITION_TYPE);

      double price=(type==POSITION_TYPE_BUY)?
         SymbolInfoDouble(_Symbol,SYMBOL_BID):
         SymbolInfoDouble(_Symbol,SYMBOL_ASK);

      double R=MathAbs(entry-sl);
      if(R<=0)continue;
      double gain=MathAbs(price-entry)/R;

      string beKey=GV_BE_PREFIX+(string)ticket;
      string ptKey=GV_PARTIAL_PREFIX+(string)ticket;

      if(UseBreakEven && gain>=BE_R && !IsFlagSet(beKey))
      {
         if((type==POSITION_TYPE_BUY && sl<entry) ||
            (type==POSITION_TYPE_SELL && sl>entry))
         {
            trade.PositionModify(ticket,entry,tp);
            SetFlag(beKey);
            Print("🟡 BE | Ticket:",ticket," R:",DoubleToString(gain,2));
         }
      }

      if(UsePartialTP && gain>=1.0 && !IsFlagSet(ptKey))
      {
         double closeVol=vol*PartialClosePercent/100.0;
         if(closeVol>=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))
         {
            trade.PositionClosePartial(ticket,closeVol);
            SetFlag(ptKey);
            Print("🟢 PARTIAL | Ticket:",ticket," R:",DoubleToString(gain,2));
         }
      }
   }
}

//========================= ONTICK ================================
void OnTick()
{
   CheckDailyReset();
   if(tradingLocked || DailyLossExceeded()){ LogSkip("Daily loss lock"); return; }

   ManagePositions();

   if(!IsNewBar()) return;
   if(!InSession()) return;
   if(tradesToday>=MaxTradesDay){ LogSkip("Max trades reached"); return; }

   trade.SetExpertMagicNumber(MagicNumber);

   // ================= BUY =================
   if(!SuperTrendBuyHTF()) LogSkip("HTF not BUY");
   else if(!ExhaustionOK_HTF()) LogSkip("HTF Exhaustion");
   else if(!BBExpansionOK_HTF(true)) LogSkip("HTF BB Expansion");
   else if(!TrendBuyLTF()) LogSkip("LTF EMA invalid");
   else if(!PullbackBuy()) LogSkip("No EMA20 pullback");
   else if(!BullPin()) LogSkip("No bullish PA");
   else
   {
      double sl=SwingLow();
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double tp=entry+(entry-sl)*RR;
      double lot=CalcLot(sl);
      if(lot>0 && trade.Buy(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++;
         Print("✅ BUY Hybrid v5");
      }
   }

   // ================= SELL =================
   if(!SuperTrendSellHTF()) LogSkip("HTF not SELL");
   else if(!ExhaustionOK_HTF()) LogSkip("HTF Exhaustion");
   else if(!BBExpansionOK_HTF(false)) LogSkip("HTF BB Expansion");
   else if(!TrendSellLTF()) LogSkip("LTF EMA invalid");
   else if(!PullbackSell()) LogSkip("No EMA20 pullback");
   else if(!BearPin()) LogSkip("No bearish PA");
   else
   {
      double sl=SwingHigh();
      double entry=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double tp=entry-(sl-entry)*RR;
      double lot=CalcLot(sl);
      if(lot>0 && trade.Sell(lot,_Symbol,entry,sl,tp))
      {
         tradesToday++;
         Print("✅ SELL Hybrid v5");
      }
   }
}
