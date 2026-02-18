//+------------------------------------------------------------------+
//| EA Trend Pullback AUTO v5.1 FINAL (MT5)                          |
//+------------------------------------------------------------------+
#property strict
#property version "5.10"

#include <Trade/Trade.mqh>
CTrade trade;

//==================================================================
// ENUM
//==================================================================
enum ENUM_MARKET_MODE
{
   MODE_AUTO = 0,
   MODE_TREND = 1,
   MODE_CORRECTIVE = 2
};

//==================================================================
// INPUT
//==================================================================
input string TradeSymbols = "";   // "" = use _Symbol
input ENUM_MARKET_MODE MarketMode = MODE_AUTO;
input ulong MagicNumber = 20260107;

// ---- Money
input bool   UseRiskPercent = true;
input double RiskPercent    = 0.5;
input double FixedLot       = 0.10;

// ---- Lot Safety (Risk mode only)
input double MinLotRisk = 0.01;
input double MaxLotRisk = 5.0;

// ---- EMA
input int EMA_Fast = 21;
input int EMA_Mid  = 50;

// ---- HTF
input ENUM_TIMEFRAMES HTF_Timeframe = PERIOD_H1;
input int HTF_EMA_Period = 50;

// ---- ATR
input int    ATR_Period  = 14;
input double SL_ATR_Mult = 1.5;

// ---- RR
input bool   UseAutoRR     = true;
input double RR_Trend      = 2.0;
input double RR_Corrective = 0.8;

// ---- Session & Spread
input int    StartHour = 7;
input int    EndHour   = 22;
input double MaxSpread = 30;

// ---- Risk Control
input double DailyLossPercent = 3.0;
input int    MaxOpenPositions = 1;
input int    MaxTradePerDay   = 3;
input int    CooldownMinutes  = 15;

// ---- AUTO Mode
input int    ADX_Period         = 14;
input double ADX_Trend_Min     = 22.0;
input double EMA_Slope_Min_ATR = 0.25;

// ---- Exhaustion Filter
input bool   UseExhaustionFilter = true;
input double MaxBody_ATR         = 1.2;
input double WickRatio_Min       = 0.6;
input double MaxDistEMA_ATR      = 1.0;

// ---- Corrective
input int    RSI_Period  = 14;
input double RSI_Buy_Max = 30.0;
input double RSI_Sell_Min= 70.0;

// ---- Management
input bool   UseBreakEven    = true;
input double BE_ATR          = 1.0;
input bool   UsePartialClose = true;
input double Partial_ATR     = 1.5;
input double Partial_Percent = 50.0;
input bool   UseTrailingStop = true;
input double Trail_ATR_Mult  = 0.7;

//==================================================================
// STRUCT
//==================================================================
struct SymbolState
{
   string   sym;
   datetime lastTradeBar;
   datetime lastTradeTime;
   datetime lastLogBar;
   int      tradesToday;
   bool     entryLock;
};

//==================================================================
// GLOBAL
//==================================================================
SymbolState States[];
double dailyStartBalance;
int lastTradingDay = -1;
ulong partialDoneTickets[];

//==================================================================
// LOGGING
//==================================================================
void LogSkip(SymbolState &st, string reason)
{
   datetime bar = iTime(st.sym, _Period, 1);
   if(bar != st.lastLogBar && TimeCurrent()-st.lastLogBar > 1*60)
   {
      Print("⏭ SKIP | ", st.sym, " | ", reason);
      st.lastLogBar = bar;
   }
}

void LogMode(string sym, string mode, double adx, double slope)
{
   Print("ℹ MODE | ", sym,
         " | ", mode,
         " | ADX=", DoubleToString(adx,1),
         " | Slope=", DoubleToString(slope,2));
}

void LogEntry(string sym, string side, string mode,
              double sl, double tp, double rr, double lot)
{
   Print("✅ ENTRY | ", sym,
         " | ", side,
         " | MODE=", mode,
         " | SL=", DoubleToString(sl,_Digits),
         " | TP=", DoubleToString(tp,_Digits),
         " | RR=", DoubleToString(rr,2),
         " | LOT=", DoubleToString(lot,2));
}

void LogLotCap(string sym, double rawLot, double finalLot)
{
   if(MathAbs(rawLot-finalLot) > 0.0001)
      Print("💰 LOT CAP | ", sym,
            " | raw=", DoubleToString(rawLot,2),
            " -> capped=", DoubleToString(finalLot,2));
}

//==================================================================
// INIT
//==================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);

   string list[];
   if(StringLen(TradeSymbols)==0)
   {
      ArrayResize(list,1);
      list[0]=_Symbol;
   }
   else
   {
      int n=StringSplit(TradeSymbols,',',list);
      if(n<=0) return INIT_FAILED;
   }

   ArrayResize(States,ArraySize(list));
   for(int i=0;i<ArraySize(list);i++)
   {
      string s=list[i];
      StringTrimLeft(s); StringTrimRight(s);
      SymbolSelect(s,true);

      States[i].sym=s;
      States[i].lastTradeBar=0;
      States[i].lastTradeTime=0;
      States[i].lastLogBar=0;
      States[i].tradesToday=0;
      States[i].entryLock=false;
   }

   dailyStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

//==================================================================
// DAILY RESET
//==================================================================
void CheckDailyReset()
{
   MqlDateTime t; TimeToStruct(TimeTradeServer(),t);
   if(t.day!=lastTradingDay)
   {
      lastTradingDay=t.day;
      dailyStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      ArrayResize(partialDoneTickets,0);
      for(int i=0;i<ArraySize(States);i++)
         States[i].tradesToday=0;
   }
}

bool DailyLossExceeded()
{
   double dd=(dailyStartBalance-AccountInfoDouble(ACCOUNT_EQUITY))
             /dailyStartBalance*100.0;
   return (dd>=DailyLossPercent);
}

//==================================================================
// UTIL
//==================================================================
double GetATR(string s)
{
   int h=iATR(s,_Period,ATR_Period);
   double b[];
   if(CopyBuffer(h,0,1,1,b)<=0){IndicatorRelease(h);return 0;}
   IndicatorRelease(h);
   return b[0];
}

double CalcLot(string s,double sl_points)
{
   if(!UseRiskPercent) return FixedLot;
   if(sl_points<=0) return MinLotRisk;

   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)
                     *RiskPercent/100.0;
   double tickVal=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0||tickSize<=0) return MinLotRisk;

   double cost=sl_points*(tickVal/tickSize);
   if(cost<=0) return MinLotRisk;

   double rawLot=riskMoney/cost;
   double lot=rawLot;

   if(lot<MinLotRisk) lot=MinLotRisk;
   if(lot>MaxLotRisk) lot=MaxLotRisk;

   double minLot=SymbolInfoDouble(s,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(s,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(s,SYMBOL_VOLUME_STEP);

   lot=MathMax(lot,minLot);
   lot=MathMin(lot,maxLot);
   lot=NormalizeDouble(lot,(int)MathRound(MathLog10(1.0/step)));

   LogLotCap(s,rawLot,lot);
   return lot;
}

int CountPosition(string s)
{
   int c=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk=PositionGetTicket(i);
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)==MagicNumber &&
         PositionGetString(POSITION_SYMBOL)==s)
         c++;
   }
   return c;
}

//==================================================================
// EXHAUSTION FILTER
//==================================================================
bool IsExhausted(string s,double atr,double ema)
{
   if(!UseExhaustionFilter) return false;

   double o=iOpen(s,_Period,1);
   double c=iClose(s,_Period,1);
   double h=iHigh(s,_Period,1);
   double l=iLow(s,_Period,1);

   double body=MathAbs(c-o);
   double wick=(h-l)-body;

   if(body>atr*MaxBody_ATR) return true;
   if((h-l)>0 && wick/(h-l)>WickRatio_Min) return true;
   if(MathAbs(c-ema)>atr*MaxDistEMA_ATR) return true;

   return false;
}

//==================================================================
// PARTIAL LOCK
//==================================================================
bool PartialDone(ulong ticket)
{
   for(int i=0;i<ArraySize(partialDoneTickets);i++)
      if(partialDoneTickets[i]==ticket) return true;

   int n=ArraySize(partialDoneTickets);
   ArrayResize(partialDoneTickets,n+1);
   partialDoneTickets[n]=ticket;
   return false;
}

//==================================================================
// MANAGEMENT
//==================================================================
void ManagePosition(string s)
{
   if(!PositionSelect(s)) return;
   if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) return;

   long type=PositionGetInteger(POSITION_TYPE);
   double entry=PositionGetDouble(POSITION_PRICE_OPEN);
   double sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   double vol=PositionGetDouble(POSITION_VOLUME);
   ulong ticket=PositionGetInteger(POSITION_TICKET);

   double price=(type==POSITION_TYPE_BUY)
      ? SymbolInfoDouble(s,SYMBOL_BID)
      : SymbolInfoDouble(s,SYMBOL_ASK);

   double atr=GetATR(s);
   if(atr<=0) return;

   if(UseBreakEven)
   {
      if(type==POSITION_TYPE_BUY && price>=entry+atr*BE_ATR && sl<entry)
         trade.PositionModify(s,entry,tp);
      if(type==POSITION_TYPE_SELL && price<=entry-atr*BE_ATR && sl>entry)
         trade.PositionModify(s,entry,tp);
   }

   if(UsePartialClose && !PartialDone(ticket))
   {
      double tgt=(type==POSITION_TYPE_BUY)
         ? entry+atr*Partial_ATR
         : entry-atr*Partial_ATR;

      bool hit=(type==POSITION_TYPE_BUY && price>=tgt) ||
               (type==POSITION_TYPE_SELL && price<=tgt);

      if(hit)
      {
         double minLot=SymbolInfoDouble(s,SYMBOL_VOLUME_MIN);
         double closeVol=vol*(Partial_Percent/100.0);
         if(closeVol>=minLot)
            trade.PositionClosePartial(s,closeVol);
      }
   }

   if(UseTrailingStop)
   {
      double newSL=sl;
      if(type==POSITION_TYPE_BUY)
      {
         double t=price-atr*Trail_ATR_Mult;
         if(t>sl && t>entry) newSL=t;
      }
      else
      {
         double t=price+atr*Trail_ATR_Mult;
         if((sl==0||t<sl) && t<entry) newSL=t;
      }
      if(newSL!=sl) trade.PositionModify(s,newSL,tp);
   }
}

//==================================================================
// CORRECTIVE ENTRY
//==================================================================
void EntryCorrective(SymbolState &st,string s,double atr,double rr)
{
   int hRSI=iRSI(s,_Period,RSI_Period,PRICE_CLOSE);
   double rsi[]; CopyBuffer(hRSI,0,1,1,rsi); IndicatorRelease(hRSI);

   int hEMA=iMA(s,_Period,EMA_Mid,0,MODE_EMA,PRICE_CLOSE);
   double ema[]; CopyBuffer(hEMA,0,1,1,ema); IndicatorRelease(hEMA);

   double price=iClose(s,_Period,1);

   if(rsi[0]>=RSI_Sell_Min && price>ema[0])
   {
      double sl=price+atr;
      double tp=price-(sl-price)*rr;
      double lot=CalcLot(s,(sl-price)/_Point);
      LogEntry(s,"SELL","CORRECTIVE",sl,tp,rr,lot);
      trade.Sell(lot,s,0,sl,tp);
      st.lastTradeTime=TimeCurrent();
      st.tradesToday++;
   }

   if(rsi[0]<=RSI_Buy_Max && price<ema[0])
   {
      double sl=price-atr;
      double tp=price+(price-sl)*rr;
      double lot=CalcLot(s,(price-sl)/_Point);
      LogEntry(s,"BUY","CORRECTIVE",sl,tp,rr,lot);
      trade.Buy(lot,s,0,sl,tp);
      st.lastTradeTime=TimeCurrent();
      st.tradesToday++;
   }
}

//==================================================================
// MAIN
//==================================================================
void OnTick()
{
   CheckDailyReset();
   if(DailyLossExceeded()) return;

   for(int i=0;i<ArraySize(States);i++)
      ProcessSymbol(States[i]);
}

//==================================================================
// PROCESS SYMBOL
//==================================================================
void ProcessSymbol(SymbolState &st)
{
   string s=st.sym;
   ManagePosition(s);

   MqlDateTime t; TimeToStruct(TimeCurrent(),t);
   if(t.hour<StartHour||t.hour>EndHour)
   { LogSkip(st,"Outside trading hour"); return; }

   double spread=(SymbolInfoDouble(s,SYMBOL_ASK)
                 -SymbolInfoDouble(s,SYMBOL_BID))/_Point;
   if(spread>MaxSpread)
   { LogSkip(st,"Spread too high"); return; }

   datetime bar=iTime(s,_Period,1);
   if(bar==st.lastTradeBar)
   { LogSkip(st,"Already processed candle"); return; }

   if(TimeCurrent()-st.lastTradeTime < CooldownMinutes*60)
   { LogSkip(st,"Cooldown"); return; }

   if(st.tradesToday>=MaxTradePerDay)
   { LogSkip(st,"Max trade per day"); return; }

   if(CountPosition(s)>=MaxOpenPositions)
   { LogSkip(st,"Position exists"); return; }

   int hADX=iADX(s,HTF_Timeframe,ADX_Period);
   double adx[]; CopyBuffer(hADX,0,1,1,adx); IndicatorRelease(hADX);

   int hEMA=iMA(s,HTF_Timeframe,HTF_EMA_Period,0,MODE_EMA,PRICE_CLOSE);
   double ema50[]; CopyBuffer(hEMA,0,1,3,ema50); IndicatorRelease(hEMA);

   double atr=GetATR(s);
   if(atr<=0) return;

   double slope=MathAbs(ema50[0]-ema50[2])/atr;

   ENUM_MARKET_MODE mode=
      (MarketMode==MODE_AUTO)
      ? ((adx[0]>=ADX_Trend_Min && slope>=EMA_Slope_Min_ATR)
         ? MODE_TREND : MODE_CORRECTIVE)
      : MarketMode;

   string modeStr=(mode==MODE_TREND?"TREND":"CORRECTIVE");
   LogMode(s,modeStr,adx[0],slope);

   double rr=UseAutoRR
      ? (mode==MODE_TREND?RR_Trend:RR_Corrective)
      : 1.0;

   st.entryLock=true;

   if(mode==MODE_TREND)
   {
      int h21=iMA(s,_Period,EMA_Fast,0,MODE_EMA,PRICE_CLOSE);
      int h50=iMA(s,_Period,EMA_Mid ,0,MODE_EMA,PRICE_CLOSE);
      double e21[],e50l[];
      CopyBuffer(h21,0,1,3,e21);
      CopyBuffer(h50,0,1,3,e50l);
      IndicatorRelease(h21); IndicatorRelease(h50);

      double c0=iClose(s,_Period,1);
      double c1=iClose(s,_Period,2);

      if(IsExhausted(s,atr,e21[0]))
      {
         LogSkip(st,"Exhausted / rejection candle");
         st.entryLock=false;
         return;
      }

      if(e21[0]>e50l[0] && c1<e21[1] && c0>e21[0])
      {
         double sl=c0-atr*SL_ATR_Mult;
         double tp=c0+(c0-sl)*rr;
         double lot=CalcLot(s,(c0-sl)/_Point);
         LogEntry(s,"BUY","TREND",sl,tp,rr,lot);
         trade.Buy(lot,s,0,sl,tp);
         st.lastTradeBar=bar;
         st.lastTradeTime=TimeCurrent();
         st.tradesToday++;
      }

      if(e21[0]<e50l[0] && c1>e21[1] && c0<e21[0])
      {
         double sl=c0+atr*SL_ATR_Mult;
         double tp=c0-(sl-c0)*rr;
         double lot=CalcLot(s,(sl-c0)/_Point);
         LogEntry(s,"SELL","TREND",sl,tp,rr,lot);
         trade.Sell(lot,s,0,sl,tp);
         st.lastTradeBar=bar;
         st.lastTradeTime=TimeCurrent();
         st.tradesToday++;
      }
   }
   else
   {
      EntryCorrective(st,s,atr,rr);
   }

   st.entryLock=false;
}
