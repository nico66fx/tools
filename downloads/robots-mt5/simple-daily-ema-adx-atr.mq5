//+------------------------------------------------------------------+
//|                                      EMA_Pullback_ADX_EA.mq5      |
//|              EUR/USD Daily EMA20/EMA200 Pullback + ADX Strategy   |
//|                     Works on any symbol / any timeframe           |
//+------------------------------------------------------------------+
#property copyright "nico66fx"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//================================================================== 
// INPUT PARAMETERS (all optimizer-friendly: input, not sinput)
//================================================================== 
input group "=== General Settings ==="
input ulong           InpMagicNumber   = 20260601;       // Magic Number
input ENUM_TIMEFRAMES InpTimeframe     = PERIOD_D1;       // Signal Timeframe
input double          InpLots          = 0.10;            // Fixed Lot Size
input int             InpMaxTrades     = 1;               // Max Open Trades (this symbol/magic)
input int             InpSlippagePts   = 40;               // Max Slippage (points)

input group "=== Indicator Settings ==="
input int             InpFastEMA       = 25;               // Fast EMA Period
input int             InpTrendEMA      = 200;              // Trend EMA Period
input int             InpADXPeriod     = 14;               // ADX Period
input int             InpADXMin        = 20;             // Minimum ADX Value
input int             InpATRPeriod     = 7;               // ATR Period
input double          InpATRMultiplier = 1.0;              // ATR Multiplier for Stop Loss
input double          InpRiskReward    = 2.0;              // Risk:Reward Ratio (TP = SL * RR)

//================================================================== 
// GLOBALS
//================================================================== 
CTrade         trade;

int            hEmaFast   = INVALID_HANDLE;
int            hEmaTrend  = INVALID_HANDLE;
int            hADX       = INVALID_HANDLE;
int            hATR       = INVALID_HANDLE;

double         gPoint;
int            gDigits;
datetime       gLastBarTime = 0;

enum ENUM_SIGNAL
  {
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1,
   SIGNAL_SELL = 2
  };

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpFastEMA <= 0 || InpTrendEMA <= 0 || InpADXPeriod <= 0 || InpATRPeriod <= 0)
     {
      Print("EA Init Error: Indicator periods must be positive.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpFastEMA >= InpTrendEMA)
     {
      Print("EA Init Error: Fast EMA period must be smaller than Trend EMA period.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpLots <= 0.0 || InpMaxTrades <= 0 || InpATRMultiplier <= 0.0 || InpRiskReward <= 0.0)
     {
      Print("EA Init Error: Lots / MaxTrades / ATRMultiplier / RiskReward must be positive.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   hEmaFast  = iMA(_Symbol, InpTimeframe, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hEmaTrend = iMA(_Symbol, InpTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX      = iADX(_Symbol, InpTimeframe, InpADXPeriod);
   hATR      = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(hEmaFast == INVALID_HANDLE || hEmaTrend == INVALID_HANDLE ||
      hADX == INVALID_HANDLE || hATR == INVALID_HANDLE)
     {
      Print("EA Init Error: Failed to create one or more indicator handles. Error: ", GetLastError());
      return(INIT_FAILED);
     }

   gPoint  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   gDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   gLastBarTime = 0;

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEmaFast  != INVALID_HANDLE) IndicatorRelease(hEmaFast);
   if(hEmaTrend != INVALID_HANDLE) IndicatorRelease(hEmaTrend);
   if(hADX      != INVALID_HANDLE) IndicatorRelease(hADX);
   if(hATR      != INVALID_HANDLE) IndicatorRelease(hATR);
  }

//+------------------------------------------------------------------+
//| Check if a new bar has formed on the signal timeframe             |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t0 = iTime(_Symbol, InpTimeframe, 0);
   if(t0 == 0) return(false);
   if(t0 != gLastBarTime)
     {
      gLastBarTime = t0;
      return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Count open positions for this symbol & magic number                |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Retrieve indicator values needed for the signal (shift 1 & 2)     |
//+------------------------------------------------------------------+
bool GetIndicatorData(double &emaFast[], double &emaTrend[], double &adxMain[], double &atr[],
                      double &openArr[], double &closeArr[], double &highArr[], double &lowArr[])
  {
   const int needed = 3; // shifts 0,1,2

   if(CopyBuffer(hEmaFast,  0, 0, needed, emaFast)  != needed) return(false);
   if(CopyBuffer(hEmaTrend, 0, 0, needed, emaTrend) != needed) return(false);
   if(CopyBuffer(hADX,      0, 0, needed, adxMain)  != needed) return(false);
   if(CopyBuffer(hATR,      0, 0, needed, atr)      != needed) return(false);

   if(CopyOpen (_Symbol, InpTimeframe, 0, needed, openArr)  != needed) return(false);
   if(CopyClose(_Symbol, InpTimeframe, 0, needed, closeArr) != needed) return(false);
   if(CopyHigh (_Symbol, InpTimeframe, 0, needed, highArr)  != needed) return(false);
   if(CopyLow  (_Symbol, InpTimeframe, 0, needed, lowArr)   != needed) return(false);

   ArraySetAsSeries(emaFast,  true);
   ArraySetAsSeries(emaTrend, true);
   ArraySetAsSeries(adxMain,  true);
   ArraySetAsSeries(atr,      true);
   ArraySetAsSeries(openArr,  true);
   ArraySetAsSeries(closeArr, true);
   ArraySetAsSeries(highArr,  true);
   ArraySetAsSeries(lowArr,   true);

   return(true);
  }

//+------------------------------------------------------------------+
//| Evaluate entry signal using the last CLOSED bar (shift 1)         |
//| Pullback logic: price touched EMA20 on bar[1] or bar[2],          |
//| then bar[1] closes as a bullish/bearish candle beyond EMA20       |
//+------------------------------------------------------------------+
ENUM_SIGNAL CheckSignal()
  {
   double emaFast[], emaTrend[], adxMain[], atr[];
   double o[], c[], h[], l[];

   if(!GetIndicatorData(emaFast, emaTrend, adxMain, atr, o, c, h, l))
      return(SIGNAL_NONE);

   // Use shift 1 = last fully closed bar, shift 2 = bar before it
   double close1 = c[1], open1 = o[1], high1 = h[1], low1 = l[1];
   double low2   = l[2], high2 = h[2];

   double fastEma1  = emaFast[1];
   double fastEma2  = emaFast[2];
   double trendEma1 = emaTrend[1];
   double adx1      = adxMain[1];

   bool bullishCandle = (close1 > open1);
   bool bearishCandle = (close1 < open1);

   // --- BUY CONDITIONS ---
   bool buyTrend      = (close1 > trendEma1) && (fastEma1 > trendEma1);
   bool buyMomentum    = (adx1 > InpADXMin);
   bool buyPullback    = (low1 <= fastEma1) || (low2 <= fastEma2);
   bool buyTrigger     = bullishCandle && (close1 > fastEma1);

   if(buyTrend && buyMomentum && buyPullback && buyTrigger)
      return(SIGNAL_BUY);

   // --- SELL CONDITIONS ---
   bool sellTrend      = (close1 < trendEma1) && (fastEma1 < trendEma1);
   bool sellMomentum   = (adx1 > InpADXMin);
   bool sellPullback   = (high1 >= fastEma1) || (high2 >= fastEma2);
   bool sellTrigger    = bearishCandle && (close1 < fastEma1);

   if(sellTrend && sellMomentum && sellPullback && sellTrigger)
      return(SIGNAL_SELL);

   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| Get current ATR value (shift 1, last closed bar) for SL sizing    |
//+------------------------------------------------------------------+
bool GetATRValue(double &atrValue)
  {
   double buf[];
   if(CopyBuffer(hATR, 0, 1, 1, buf) != 1) return(false);
   atrValue = buf[0];
   return(atrValue > 0.0);
  }

//+------------------------------------------------------------------+
//| Normalize lot size to broker constraints                           |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0) stepLot = 0.01;

   double normalized = MathRound(lots / stepLot) * stepLot;
   normalized = MathMax(minLot, MathMin(maxLot, normalized));
   return(normalized);
  }

//+------------------------------------------------------------------+
//| Open a trade based on the signal                                   |
//+------------------------------------------------------------------+
void ExecuteSignal(ENUM_SIGNAL signal)
  {
   double atrValue;
   if(!GetATRValue(atrValue))
     {
      Print("Warning: ATR value unavailable, skipping entry.");
      return;
     }

   double slDistance = atrValue * InpATRMultiplier;
   if(slDistance <= 0.0) return;

   double tpDistance = slDistance * InpRiskReward;

   double lots = NormalizeLots(InpLots);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
     {
      Print("Warning: Unable to retrieve current tick.");
      return;
     }

   int stopsLevelPts = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = stopsLevelPts * gPoint;

   if(signal == SIGNAL_BUY)
     {
      double price = tick.ask;
      double sl    = price - slDistance;
      double tp    = price + tpDistance;

      if(minStopDist > 0.0 && (price - sl) < minStopDist)
         sl = price - minStopDist;

      sl = NormalizeDouble(sl, gDigits);
      tp = NormalizeDouble(tp, gDigits);

      if(!trade.Buy(lots, _Symbol, price, sl, tp, "EMA Pullback Buy"))
         Print("Buy order failed. Error: ", GetLastError(), " Retcode: ", trade.ResultRetcode());
     }
   else
   if(signal == SIGNAL_SELL)
     {
      double price = tick.bid;
      double sl    = price + slDistance;
      double tp    = price - tpDistance;

      if(minStopDist > 0.0 && (sl - price) < minStopDist)
         sl = price + minStopDist;

      sl = NormalizeDouble(sl, gDigits);
      tp = NormalizeDouble(tp, gDigits);

      if(!trade.Sell(lots, _Symbol, price, sl, tp, "EMA Pullback Sell"))
         Print("Sell order failed. Error: ", GetLastError(), " Retcode: ", trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
  {
  //Show Equity and Balance
   Comment ( StringFormat ( "Equity is %.2f and Balance is %.2f", AccountInfoDouble (ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE)));
   // Entry evaluated strictly on candle close (new bar event)
   if(!IsNewBar())
      return;

   if(CountOpenPositions() >= InpMaxTrades)
      return;

   ENUM_SIGNAL signal = CheckSignal();
   if(signal == SIGNAL_NONE)
      return;

   ExecuteSignal(signal);
  }
//+------------------------------------------------------------------+