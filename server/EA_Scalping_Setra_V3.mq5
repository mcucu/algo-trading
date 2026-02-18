//+------------------------------------------------------------------+
//| EA_Scalping_Setra_V3_2.mq5                                       |
//| Momentum Candle V3 + SR Filter + Retest                          |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>
CTrade trade;

//================ INPUT ============================================
input string InpSymbol = "XAUUSD";

// --- Momentum Candle V3 ---
input double XAU_MinBodyPips_M5   = 40.0;
input double XAU_MinBodyPips_M15  = 50.0;
input double Momentum_WickRatioMax = 0.30;

// --- Support / Resistance ---
input int    SR_LookbackBars   = 20;
input double SR_Distance_Pips  = 10.0;
input bool   SkipTradeNearSR   = false;

// --- SL & TP ---
input int    SL_Buffer_Ticks = 3;
input double RiskReward      = 1.0;

// --- Lot ---
input bool   UseAutoLot  = false;
input double FixedLot    = 0.01;
input double RiskPercent = 1.0;

// --- Magic ---
input int    MagicNumber = 20251217;

//================ GLOBAL ===========================================
datetime lastBarTime = 0;

// Retest state
bool waitBuy=false, waitSell=false;
double pendingBuySL=0, pendingSellSL=0;
datetime waitBarTimeBuy=0, waitBarTimeSell=0;

//================ HELPERS ==========================================
bool IsXAU(const string s)
{
   string sym=s; StringToUpper(sym);
   return StringFind(sym,"XAU")>=0;
}

double PipXAU(){ return 0.1; }

//================ MOMENTUM V3 =====================================
bool MomentumBullV3(const string s, ENUM_TIMEFRAMES tf)
{
   double o=iOpen(s,tf,1), c=iClose(s,tf,1),
          h=iHigh(s,tf,1), l=iLow(s,tf,1);
   if(o<=0||c<=0) return false;

   double minPip=(tf==PERIOD_M5?XAU_MinBodyPips_M5:XAU_MinBodyPips_M15);
   double body=MathAbs(c-o);
   double uw=h-MathMax(o,c), lw=MathMin(o,c)-l;
   double wick=uw+lw;

   if(body < minPip*PipXAU()) return false;
   if(wick/(body+wick) > Momentum_WickRatioMax) return false;
   if(c<=o) return false;

   return true;
}

bool MomentumBearV3(const string s, ENUM_TIMEFRAMES tf)
{
   double o=iOpen(s,tf,1), c=iClose(s,tf,1),
          h=iHigh(s,tf,1), l=iLow(s,tf,1),
          pc=iClose(s,tf,2);
   if(o<=0||c<=0||pc<=0) return false;

   double minPip=(tf==PERIOD_M5?XAU_MinBodyPips_M5:XAU_MinBodyPips_M15);
   double body=MathAbs(c-o);
   double uw=h-MathMax(o,c), lw=MathMin(o,c)-l;
   double wick=uw+lw;

   if(body < minPip*PipXAU()) return false;
   if(wick/(body+wick) > Momentum_WickRatioMax) return false;

   return (c<o)||(c>o && c<pc);
}

//================ SUPPORT / RESISTANCE =============================
double GetResistance(const string s, ENUM_TIMEFRAMES tf)
{
   double r=iHigh(s,tf,2);
   for(int i=3;i<=SR_LookbackBars+1;i++)
      r=MathMax(r,iHigh(s,tf,i));
   return r;
}

double GetSupport(const string s, ENUM_TIMEFRAMES tf)
{
   double sup=iLow(s,tf,2);
   for(int i=3;i<=SR_LookbackBars+1;i++)
      sup=MathMin(sup,iLow(s,tf,i));
   return sup;
}

//================ LOT ==============================================
double CalcLot(const string s,double entry,double sl)
{
   if(!UseAutoLot) return FixedLot;

   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
   double point=SymbolInfoDouble(s,SYMBOL_POINT);
   double tickV=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_VALUE);
   double tickS=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_SIZE);

   double distPoints=MathAbs(entry-sl)/point;
   double lossLot=(distPoints*point/tickS)*tickV;
   if(lossLot<=0) return FixedLot;

   double lot=riskMoney/lossLot;
   double minLot=SymbolInfoDouble(s,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(s,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(s,SYMBOL_VOLUME_STEP);

   lot=MathMax(minLot,MathMin(maxLot,lot));
   lot=MathFloor(lot/step)*step;

   return NormalizeDouble(lot,2);
}

//================ ENTRY ============================================
void OpenBuy(const string s,double slMomentum)
{
   double ask=SymbolInfoDouble(s,SYMBOL_ASK);
   double tick=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_SIZE);
   int digits=(int)SymbolInfoInteger(s,SYMBOL_DIGITS);

   double sl=slMomentum-(SL_Buffer_Ticks*tick);
   if(sl>=ask) return;

   double lot=CalcLot(s,ask,sl);
   if(lot<=0) return;

   double tp=ask+(ask-sl)*RiskReward;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.Buy(lot,s,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"BUY v3.2");
}

void OpenSell(const string s,double slMomentum)
{
   double bid=SymbolInfoDouble(s,SYMBOL_BID);
   double tick=SymbolInfoDouble(s,SYMBOL_TRADE_TICK_SIZE);
   int digits=(int)SymbolInfoInteger(s,SYMBOL_DIGITS);

   double sl=slMomentum+(SL_Buffer_Ticks*tick);
   if(sl<=bid) return;

   double lot=CalcLot(s,bid,sl);
   if(lot<=0) return;

   double tp=bid-(sl-bid)*RiskReward;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.Sell(lot,s,0,NormalizeDouble(sl,digits),NormalizeDouble(tp,digits),"SELL v3.2");
}

//================ MAIN =============================================
void OnTick()
{
   string s=InpSymbol;
   ENUM_TIMEFRAMES tf=(ENUM_TIMEFRAMES)_Period;

   datetime bt=iTime(s,tf,0);
   if(bt==lastBarTime) return;
   lastBarTime=bt;

   double srDist = SR_Distance_Pips * PipXAU();

   // === BUY ===
   if(MomentumBullV3(s,tf))
   {
      double sup=GetSupport(s,tf);
      double lowMom=iLow(s,tf,1);

      if(MathAbs(lowMom-sup)<=srDist)
      {
         if(SkipTradeNearSR) return;
         waitBuy=true;
         pendingBuySL=lowMom;
         waitBarTimeBuy=bt;
      }
      else
         OpenBuy(s,lowMom);
   }

   // Retest BUY
   if(waitBuy && bt>waitBarTimeBuy)
   {
      double body=MathAbs(iClose(s,tf,1)-iOpen(s,tf,1));
      if(body < (XAU_MinBodyPips_M5*PipXAU()*0.4))
      {
         if(iClose(s,tf,0)>iClose(s,tf,1))
            OpenBuy(s,pendingBuySL);
      }
      waitBuy=false;
   }

   // === SELL ===
   if(MomentumBearV3(s,tf))
   {
      double res=GetResistance(s,tf);
      double highMom=iHigh(s,tf,1);

      if(MathAbs(highMom-res)<=srDist)
      {
         if(SkipTradeNearSR) return;
         waitSell=true;
         pendingSellSL=highMom;
         waitBarTimeSell=bt;
      }
      else
         OpenSell(s,highMom);
   }

   // Retest SELL
   if(waitSell && bt>waitBarTimeSell)
   {
      double body=MathAbs(iClose(s,tf,1)-iOpen(s,tf,1));
      if(body < (XAU_MinBodyPips_M5*PipXAU()*0.4))
      {
         if(iClose(s,tf,0)<iClose(s,tf,1))
            OpenSell(s,pendingSellSL);
      }
      waitSell=false;
   }
}
