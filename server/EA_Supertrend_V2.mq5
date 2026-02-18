//+------------------------------------------------------------------+
//| EA_XAUUSD_SuperTrend_M30_v3.mq5                                 |
//| SuperTrend EA v3 – Conservative / Aggressive Mode               |
//| Features:                                                       |
//| 1. Trailing SL SuperTrend                                       |
//| 2. Partial TP + Break Even                                      |
//| 3. Multi-Timeframe Confirmation (M30 + H1)                      |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#include <Trade/Trade.mqh>
CTrade trade;

//==================== MODE ==========================================
input bool   ConservativeMode = true;   // true = conservative, false = aggressive

//==================== LOT & RISK ====================================
input bool     UseRiskPercent     = true;   // true = risk-based lot, false = fixed lot
input double   RiskPercent        = 1.0;    // % risk per trade
input double   FixedLot           = 0.01;   // used if UseRiskPercent=false
input double   MinLot             = 0.01;
input double   MaxLot             = 0.05;
input int      MaxOpenPositions   = 1;

//==================== SUPERTREND ====================================
input int    ST_ATR_Period     = 10;
input double ST_Multiplier     = 3.0;

//==================== RSI ===========================================
input int RSI_Period           = 14;
input int RSI_Buy_Level        = 55;
input int RSI_Sell_Level       = 45;

//==================== EMA ===========================================
input int    EMA_Period        = 50;      // EMA period for trend filter
input double MaxMADistanceATR  = 0.8;     // Max distance from EMA (ATR multiplier)  = 0.8;

//==================== VOLATILITY ====================================
input int ATR_Period           = 14;
input int ATR_MA_Period        = 20;

//==================== TP / SL =======================================
input double RR_Partial        = 1.0;   // RR for partial TP
input double RR_Final          = 2.0;   // Final RR
input double BE_Buffer_Points  = 2;     // BE buffer

//==================== GENERAL =======================================
input int      MagicNumber     = 20251220;
input int      Slippage        = 5;
input int      CooldownMinutes = 15;

//==================== GLOBAL ========================================
datetime lastTradeTime = 0;

//==================== UTIL ==========================================

double CalcLotByRisk(double slPoints)
{
   if(slPoints<=0) return MinLot;
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickValue<=0 || tickSize<=0)
      return MinLot;

   double valuePerPoint = tickValue / tickSize;
   double lot = riskMoney / (slPoints * valuePerPoint);

   lot = MathMax(lot, MinLot);
   lot = MathMin(lot, MaxLot);
   return NormalizeDouble(lot, 2);
}

bool GetATR(double &atr)
{
   int h=iATR(_Symbol,PERIOD_M30,ATR_Period);
   double b[]; if(CopyBuffer(h,0,0,1,b)<=0) return false;
   atr=b[0]; IndicatorRelease(h); return true;
}

bool GetSuperTrend(ENUM_TIMEFRAMES tf,double &st,bool &bull)
{
   double atr; int bars=ST_ATR_Period+2;
   int hATR=iATR(_Symbol,tf,ST_ATR_Period);
   double atrBuf[]; if(CopyBuffer(hATR,0,0,1,atrBuf)<=0) return false;
   atr=atrBuf[0]; IndicatorRelease(hATR);
   double h[],l[],c[];
   if(CopyHigh(_Symbol,tf,1,bars,h)<=0) return false;
   if(CopyLow (_Symbol,tf,1,bars,l)<=0) return false;
   if(CopyClose(_Symbol,tf,1,bars,c)<=0) return false;
   double fu=0,fl=0; bool up=true;
   for(int i=bars-1;i>=0;i--)
   {
      double mid=(h[i]+l[i])/2;
      double ub=mid+ST_Multiplier*atr;
      double lb=mid-ST_Multiplier*atr;
      if(i==bars-1){fu=ub; fl=lb; up=c[i]>=fl;}
      else
      {
         if(ub<fu||c[i+1]>fu) fu=ub;
         if(lb>fl||c[i+1]<fl) fl=lb;
         if(c[i]>fu) up=true;
         else if(c[i]<fl) up=false;
      }
   }
   bull=up; st=up?fl:fu; return true;
}

//==================== ON TICK =======================================
void OnTick()
{
   // === HEARTBEAT LOG (EA alive) ===
   static datetime lastLog=0;
   bool showLog=false;
   if(TimeCurrent()-lastLog>=60)
   {
      Print("[EA v3] Running | Symbol=",_Symbol,
            " TF=",EnumToString(_Period),
            " Time=",TimeToString(TimeCurrent(),TIME_SECONDS));
      lastLog=TimeCurrent();
      showLog=true;
   }

   if(TimeCurrent()-lastTradeTime < CooldownMinutes*60)
   {
      if(showLog) Print("[EA v3] Cooldown active, skip entry");
      return;
   }

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double price = (ask+bid)/2.0;

   //==== Multi TF SuperTrend ====
   double st30=0, stH1=0;
   bool bull30=false, bullH1=false;

   if(!GetSuperTrend(PERIOD_M30,st30,bull30))
   {
      if(showLog) Print("[EA v3] Failed get SuperTrend M30");
      return;
   }
   if(!GetSuperTrend(PERIOD_H1,stH1,bullH1))
   {
      if(showLog) Print("[EA v3] Failed get SuperTrend H1");
      return;
   }

   if(ConservativeMode && bull30!=bullH1)
   {
      if(showLog) Print("[EA v3] Skip: M30/H1 trend mismatch");
      return;
   }

   //==== RSI & EMA ====
   double rsi=0.0, ema=0.0, atr=0.0;
   double buf[];

   int rHandle = iRSI(_Symbol,PERIOD_M30,RSI_Period,PRICE_CLOSE);
   if(rHandle<=0) return;
   if(CopyBuffer(rHandle,0,0,1,buf)>0) rsi=buf[0];
   IndicatorRelease(rHandle);

   int eHandle = iMA(_Symbol,PERIOD_M30,EMA_Period,0,MODE_EMA,PRICE_CLOSE);
   if(eHandle<=0) return;
   if(CopyBuffer(eHandle,0,0,1,buf)>0) ema=buf[0];
   IndicatorRelease(eHandle);

   int aHandle = iATR(_Symbol,PERIOD_M30,ATR_Period);
   if(aHandle<=0) return;
   if(CopyBuffer(aHandle,0,0,1,buf)>0) atr=buf[0];
   IndicatorRelease(aHandle);

   if(MathAbs(price-ema) > atr*MaxMADistanceATR)
   {
      if(showLog) Print("[EA v3] Skip: price too far from EMA");
      return;
   }

   //==== Count positions ====
   int pos=0; bool hasBuy=false, hasSell=false;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC)==MagicNumber && PositionGetString(POSITION_SYMBOL)==_Symbol)
         {
            pos++;
            if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY)  hasBuy=true;
            if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_SELL) hasSell=true;
         }
      }
   }

   if(pos>=MaxOpenPositions)
   {
      if(showLog) Print("[EA v3] Skip: max open positions reached = ",pos);
      return;
   }

   //================ BUY =================
   if(bull30 && bullH1 && !hasSell && rsi>RSI_Buy_Level && price>ema)
   {
      double sl = st30 - 2*_Point;
      double slPoints = (price-sl)/_Point;
      double lot = UseRiskPercent ? CalcLotByRisk(slPoints) : FixedLot;
      double tp = price + (price-sl)*RR_Final;
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(Slippage);
      if(trade.Buy(lot,NULL,ask,sl,tp))
      {
         Print("[EA v3] BUY EXECUTED | lot=",lot, " | ask=", ask, " | sl=", sl, " | tp=", tp);
         lastTradeTime = TimeCurrent();
      }
   }

   //================ SELL =================
   if(!bull30 && !bullH1 && !hasBuy && rsi<RSI_Sell_Level && price<ema)
   {
      double sl = st30 + 2*_Point;
      double slPoints = (sl-price)/_Point;
      double lot = UseRiskPercent ? CalcLotByRisk(slPoints) : FixedLot;
      double tp = price - (sl-price)*RR_Final;
      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(Slippage);
      if(trade.Sell(lot,NULL,bid,sl,tp))
      {
         Print("[EA v3] SELL EXECUTED | lot=",lot, " | bid=", bid, " | sl=", sl, " | tp=", tp);
         lastTradeTime = TimeCurrent();
      }
   }

   //================ MANAGEMENT =================
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double vol  = PositionGetDouble(POSITION_VOLUME);

      //--- Trailing SL by SuperTrend
      double newSL = (type==POSITION_TYPE_BUY) ? st30-2*_Point : st30+2*_Point;
      if((type==POSITION_TYPE_BUY && newSL>sl) || (type==POSITION_TYPE_SELL && newSL<sl))
         trade.PositionModify(ticket,newSL,tp);

      //--- Partial TP + BE
      double rrMove = (type==POSITION_TYPE_BUY) ? (price-open)/(open-sl) : (open-price)/(sl-open);
      if(rrMove>=RR_Partial && vol>FixedLot/2)
      {
         trade.PositionClosePartial(ticket,vol/2);
         double be = (type==POSITION_TYPE_BUY) ? open+BE_Buffer_Points*_Point : open-BE_Buffer_Points*_Point;
         trade.PositionModify(ticket,be,tp);
      }
   }
}

//+------------------------------------------------------------------+

// v3 FEATURES:
// ✔ Conservative / Aggressive mode
// ✔ Trailing SL SuperTrend
// ✔ Partial TP + Break Even
// ✔ Multi TF confirmation (M30 + H1)
// ✔ Best suited for XAUUSD / XAGUSD M30
//+------------------------------------------------------------------+
