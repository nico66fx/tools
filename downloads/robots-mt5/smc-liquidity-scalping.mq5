//+------------------------------------------------------------------+
//|                              nico66fx_SMC_LiquidityScalping.mq5   |
//|                                        Copyright 2026, nico66fx   |
//|                          https://www.mql5.com/en/users/nico66fx   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, nico66fx"
#property link      "https://www.mql5.com/en/users/nico66fx"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Inputs for Optimizer
input group "=== EMA Settings ==="
input int      EMA_Fast_Period     = 50;           // EMA Fast Period
input int      EMA_Slow_Period     = 200;          // EMA Slow Period
input ENUM_MA_METHOD EMA_Method    = MODE_EMA;     // EMA Method

input group "=== Trading Settings ==="
input double   LotSize             = 0.10;         // Lot Size
input ulong    MagicNumber         = 123456789;    // Magic Number
input int      MaxOpenTrades       = 1;            // Maximum Open Trades
input double   RiskRewardRatio     = 2.0;          // Risk:Reward Ratio (TP)
input double   SL_Buffer_Points    = 150.0;         // SL Buffer (Points beyond sweep)

input group "=== Swing Detection ==="
input int      SwingLookback       = 20;           // Bars to look back for swings
input int      MinSwingBars        = 5;            // Minimum bars between swings

input group "=== Filters ==="
input bool     UseTrendFilter      = true;         // Use EMA Trend Filter
input bool     AllowBuy            = true;         // Allow Buy Trades
input bool     AllowSell           = true;         // Allow Sell Trades

//--- Global variables
CTrade         trade;
CSymbolInfo    sym;
int            handle_ema_fast;
int            handle_ema_slow;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);

   sym.Name(_Symbol);
   sym.Refresh();

   //--- Create indicators
   handle_ema_fast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, EMA_Method, PRICE_CLOSE);
   handle_ema_slow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, EMA_Method, PRICE_CLOSE);

   if(handle_ema_fast == INVALID_HANDLE || handle_ema_slow == INVALID_HANDLE)
     {
      Print("Failed to create EMA indicators");
      return INIT_FAILED;
     }

   Print("nico66fx SMC Liquidity Scalping initialized successfully. Magic: ", MagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handle_ema_fast);
   IndicatorRelease(handle_ema_slow);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
  //Show Equity and Balance
   Comment ( StringFormat ( "nico66fx | Equity is %.2f and Balance is %.2f", AccountInfoDouble (ACCOUNT_EQUITY), AccountInfoDouble(ACCOUNT_BALANCE)));
   if(!IsNewBar()) return;  // Process only on new bar for efficiency

   //--- Check open positions
   if(PositionsTotalByMagic() >= MaxOpenTrades) return;

   //--- Get EMA values
   double ema_fast[2], ema_slow[2];
   if(CopyBuffer(handle_ema_fast, 0, 0, 2, ema_fast) <= 0 ||
      CopyBuffer(handle_ema_slow, 0, 0, 2, ema_slow) <= 0)
      return;

   bool bullish_trend = ema_fast[1] > ema_slow[1];
   bool bearish_trend = ema_fast[1] < ema_slow[1];

   if(UseTrendFilter && !bullish_trend && !bearish_trend) return;

   //--- Detect Liquidity Sweeps
   double sweep_low = 0, sweep_high = 0;
   bool bullish_sweep = DetectBullishLiquiditySweep(sweep_low);
   bool bearish_sweep = DetectBearishLiquiditySweep(sweep_high);

   //--- Buy Setup
   if(AllowBuy && bullish_sweep && (!UseTrendFilter || bullish_trend))
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = sweep_low - SL_Buffer_Points * _Point;
      double risk = entry - sl;
      double tp = entry + risk * RiskRewardRatio;

      if(risk > 0)
        {
         trade.Buy(LotSize, _Symbol, entry, sl, tp, "nico66fx SMC Buy");
        }
     }

   //--- Sell Setup
   if(AllowSell && bearish_sweep && (!UseTrendFilter || bearish_trend))
     {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = sweep_high + SL_Buffer_Points * _Point;
      double risk = sl - entry;
      double tp = entry - risk * RiskRewardRatio;

      if(risk > 0)
        {
         trade.Sell(LotSize, _Symbol, entry, sl, tp, "nico66fx SMC Sell");
        }
     }
  }

//+------------------------------------------------------------------+
//| Detect Bullish Liquidity Sweep                                   |
//+------------------------------------------------------------------+
bool DetectBullishLiquiditySweep(double &sweep_level)
  {
   double low[], close[];
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   if(CopyLow(_Symbol, PERIOD_CURRENT, 1, SwingLookback+10, low) <= 0 ||
      CopyClose(_Symbol, PERIOD_CURRENT, 1, SwingLookback+10, close) <= 0)
      return false;

   // Find most recent swing low
   for(int i = MinSwingBars; i < SwingLookback; i++)
     {
      if(IsSwingLow(i))
        {
         double swing_low = low[i];

         // Check if current candle (index 1) swept below swing low and closed above
         if(low[1] < swing_low && close[1] > swing_low)
           {
            sweep_level = swing_low;
            return true;
           }
         break; // Only check most recent swing
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Detect Bearish Liquidity Sweep                                   |
//+------------------------------------------------------------------+
bool DetectBearishLiquiditySweep(double &sweep_level)
  {
   double high[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(close, true);

   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, SwingLookback+10, high) <= 0 ||
      CopyClose(_Symbol, PERIOD_CURRENT, 1, SwingLookback+10, close) <= 0)
      return false;

   // Find most recent swing high
   for(int i = MinSwingBars; i < SwingLookback; i++)
     {
      if(IsSwingHigh(i))
        {
         double swing_high = high[i];

         // Check if current candle (index 1) swept above swing high and closed below
         if(high[1] > swing_high && close[1] < swing_high)
           {
            sweep_level = swing_high;
            return true;
           }
         break; // Only check most recent swing
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check if bar is a swing low                                      |
//+------------------------------------------------------------------+
bool IsSwingLow(int shift)
  {
   double low[];
   ArraySetAsSeries(low, true);
   if(CopyLow(_Symbol, PERIOD_CURRENT, shift-5, 11, low) <= 0) return false;

   double center_low = low[5];

   for(int i = 0; i < 11; i++)
     {
      if(i == 5) continue;
      if(low[i] <= center_low) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Check if bar is a swing high                                     |
//+------------------------------------------------------------------+
bool IsSwingHigh(int shift)
  {
   double high[];
   ArraySetAsSeries(high, true);
   if(CopyHigh(_Symbol, PERIOD_CURRENT, shift-5, 11, high) <= 0) return false;

   double center_high = high[5];

   for(int i = 0; i < 11; i++)
     {
      if(i == 5) continue;
      if(high[i] >= center_high) return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Count open positions by magic                                    |
//+------------------------------------------------------------------+
int PositionsTotalByMagic()
  {
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
        {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetString(POSITION_SYMBOL) == _Symbol)
            count++;
        }
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Check for new bar                                                |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   static datetime last_bar_time = 0;
   datetime current_bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(current_bar_time != last_bar_time)
     {
      last_bar_time = current_bar_time;
      return true;
     }
   return false;
  }
//+------------------------------------------------------------------+
