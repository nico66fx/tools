//+------------------------------------------------------------------+
//|                                           200_EMA_Breakout_EA.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "200 EMA Breakout Strategy EA"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== EMA Settings ==="
input int InpEmaPeriod = 200;                    // EMA Period
input ENUM_MA_METHOD InpEmaMethod = MODE_EMA;    // EMA Method
input ENUM_APPLIED_PRICE InpEmaPrice = PRICE_CLOSE; // EMA Applied Price

input group "=== Risk Management ==="
input double InpLotSize = 0.05;                  // Lot Size
input int InpStopLoss = 250;                     // Stop Loss (pips)
input int InpTakeProfit = 550;                   // Take Profit (pips)

input group "=== Swing Detection ==="
input int InpSwingBars = 400;                     // Bars for swing detection

input group "=== EA Settings ==="
input int InpMagicNumber = 123456;              // Magic Number
input string InpTradeComment = "EMA_Breakout";   // Trade Comment
input bool InpAllowBuy = true;                  // Allow Buy Orders
input bool InpAllowSell = true;                 // Allow Sell Orders

//--- Global Variables
CTrade trade;
int emaHandle;
double emaBuffer[];
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Initialize trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   
   //--- Create EMA indicator handle
   emaHandle = iMA(_Symbol, _Period, InpEmaPeriod, 0, InpEmaMethod, InpEmaPrice);
   if(emaHandle == INVALID_HANDLE)
   {
      Print("Failed to create EMA indicator handle");
      return(INIT_FAILED);
   }
   
   //--- Set array as series
   ArraySetAsSeries(emaBuffer, true);
   
   Print("200 EMA Breakout EA initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release indicator handle
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
//Show Equity and Balance
Comment ( StringFormat ( "Equity is %.2f and Balance is %.2f", AccountInfoDouble (ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE)));
   //--- Check for new bar
   if(!IsNewBar())
      return;
   
   //--- Check if we have enough bars
   if(Bars(_Symbol, _Period) < InpEmaPeriod + InpSwingBars + 10)
      return;
   
   //--- Get EMA values
   if(CopyBuffer(emaHandle, 0, 0, 10, emaBuffer) <= 0)
   {
      Print("Failed to get EMA values");
      return;
   }
   
   //--- Check for existing positions
   bool hasPosition = PositionSelect(_Symbol);
   
   if(!hasPosition)
   {
      //--- Look for entry signals
      CheckForEntry();
   }
}

//+------------------------------------------------------------------+
//| Check for new bar                                               |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime != lastBarTime)
   {
      lastBarTime = currentBarTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check for entry conditions                                      |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   //--- Get current and previous candle data
   double currentClose = iClose(_Symbol, _Period, 1);  // Previous completed candle
   double currentOpen = iOpen(_Symbol, _Period, 1);
   double prevClose = iClose(_Symbol, _Period, 2);
   double prevOpen = iOpen(_Symbol, _Period, 2);
   
   //--- Get current EMA value
   double currentEma = emaBuffer[1];  // EMA at previous completed candle
   
   //--- Find swing high and low
   double swingHigh = GetSwingHigh();
   double swingLow = GetSwingLow();
   
   //--- Check Buy Conditions
   if(InpAllowBuy && CheckBuyConditions(currentClose, currentOpen, currentEma, swingHigh))
   {
      OpenBuyTrade();
   }
   
   //--- Check Sell Conditions
   if(InpAllowSell && CheckSellConditions(currentClose, currentOpen, currentEma, swingLow))
   {
      OpenSellTrade();
   }
}

//+------------------------------------------------------------------+
//| Check buy conditions                                             |
//+------------------------------------------------------------------+
bool CheckBuyConditions(double close, double open, double ema, double swingHigh)
{
   //--- Price must be above 200 EMA
   if(close <= ema)
      return false;
   
   //--- Must be a bullish candle
   if(close <= open)
      return false;
   
   //--- Candle must close above previous swing high
   if(swingHigh > 0 && close > swingHigh)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Check sell conditions                                            |
//+------------------------------------------------------------------+
bool CheckSellConditions(double close, double open, double ema, double swingLow)
{
   //--- Price must be below 200 EMA
   if(close >= ema)
      return false;
   
   //--- Must be a bearish candle
   if(close >= open)
      return false;
   
   //--- Candle must close below previous swing low
   if(swingLow > 0 && close < swingLow)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| Find swing high                                                  |
//+------------------------------------------------------------------+
double GetSwingHigh()
{
   double swingHigh = 0;
   int lookback = InpSwingBars * 3; // Look back more bars to find swing
   
   for(int i = InpSwingBars; i < lookback; i++)
   {
      double high = iHigh(_Symbol, _Period, i);
      bool isSwingHigh = true;
      
      //--- Check if this high is higher than surrounding bars
      for(int j = i - InpSwingBars; j <= i + InpSwingBars; j++)
      {
         if(j == i) continue;
         if(j < 0) continue;
         
         double compareHigh = iHigh(_Symbol, _Period, j);
         if(compareHigh >= high)
         {
            isSwingHigh = false;
            break;
         }
      }
      
      if(isSwingHigh)
      {
         swingHigh = high;
         break;
      }
   }
   
   return swingHigh;
}

//+------------------------------------------------------------------+
//| Find swing low                                                   |
//+------------------------------------------------------------------+
double GetSwingLow()
{
   double swingLow = 0;
   int lookback = InpSwingBars * 3; // Look back more bars to find swing
   
   for(int i = InpSwingBars; i < lookback; i++)
   {
      double low = iLow(_Symbol, _Period, i);
      bool isSwingLow = true;
      
      //--- Check if this low is lower than surrounding bars
      for(int j = i - InpSwingBars; j <= i + InpSwingBars; j++)
      {
         if(j == i) continue;
         if(j < 0) continue;
         
         double compareLow = iLow(_Symbol, _Period, j);
         if(compareLow <= low)
         {
            isSwingLow = false;
            break;
         }
      }
      
      if(isSwingLow)
      {
         swingLow = low;
         break;
      }
   }
   
   return swingLow;
}

//+------------------------------------------------------------------+
//| Open buy trade                                                   |
//+------------------------------------------------------------------+
void OpenBuyTrade()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   //--- Calculate SL and TP
   double sl = ask - (InpStopLoss * point * 10);
   double tp = ask + (InpTakeProfit * point * 10);
   
   //--- Normalize prices
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   //--- Open buy trade
   if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp, InpTradeComment))
   {
      Print("Buy trade opened successfully at: ", ask, " SL: ", sl, " TP: ", tp);
   }
   else
   {
      Print("Failed to open buy trade. Error: ", trade.ResultRetcode());
   }
}

//+------------------------------------------------------------------+
//| Open sell trade                                                  |
//+------------------------------------------------------------------+
void OpenSellTrade()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   //--- Calculate SL and TP
   double sl = bid + (InpStopLoss * point * 10);
   double tp = bid - (InpTakeProfit * point * 10);
   
   //--- Normalize prices
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   //--- Open sell trade
   if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp, InpTradeComment))
   {
      Print("Sell trade opened successfully at: ", bid, " SL: ", sl, " TP: ", tp);
   }
   else
   {
      Print("Failed to open sell trade. Error: ", trade.ResultRetcode());
   }
}