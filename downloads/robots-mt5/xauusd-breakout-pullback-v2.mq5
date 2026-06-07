//+------------------------------------------------------------------+
//|  XAUUSD Breakout + Pullback EA — MT5  v2.0                       |
//|  Símbolo: XAUUSD  |  TF recomendado: H1 o H4                     |
//|  Correcciones v2: swing excluye vela actual, zona pullback        |
//|  en puntos absolutos, filtro rango calibrado, invalidación suave  |
//+------------------------------------------------------------------+
#property copyright "2025"
#property version   "2.00"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

CTrade        trade;
CPositionInfo posInfo;

//--- ================================================================
input group   "=== SWING ==="
input int     SwingLookback     = 50;    // velas hacia atrás para swing (excluye vela actual)
input int     BodyAvgPeriod     = 10;    // velas para promedio de cuerpo
input double  BodyMultiplier    = 1.4;   // ruptura válida = cuerpo >= X * promedio

input group   "=== TENDENCIA Y FILTROS ==="
input int     MAPeriod          = 100;   // EMA de tendencia
input int     RangeLookback     = 20;    // velas para detectar lateral
input double  RangeMinPoints    = 150;   // rango mínimo en puntos para no ser lateral
                                         // XAUUSD H1: 150 pts = 15 pips = ~$1.5 movimiento mínimo

input group   "=== ENTRADAS ==="
input double  PullbackZonePoints = 300;  // zona de pullback en puntos (XAUUSD: 300 pts = $3)
input int     MaxBarsWaiting    = 20;    // barras máximas esperando pullback antes de cancelar
input bool    AllowDirectEntry  = true;  // permitir entrada directa si ruptura muy fuerte

input group   "=== GESTIÓN ==="
input double  RiskPercent       = 1.0;   // % riesgo sobre equity
input double  RRRatio           = 1.8;   // ratio riesgo:recompensa
input int     Slippage          = 30;    // slippage en puntos

input group   "=== IDENTIFICACIÓN ==="
input long    MagicNumber       = 20250101;
input string  TradeComment      = "XAU_BP";

//--- handles
int maHandle;

//--- estado del EA
int      lastBarsCount       = 0;    // para detectar vela nueva en backtester
datetime lastTradeDay        = 0;
int      tradeDirection      = 0;    // 1=long  -1=short  0=sin setup
double   breakoutLevel       = 0;
double   breakoutSwingOpp    = 0;    // swing opuesto para SL
int      barsWaiting         = 0;   // contador de barras esperando pullback
bool     waitingPullback     = false;

//+------------------------------------------------------------------+
int OnInit()
  {
   maHandle = iMA(Symbol(), PERIOD_CURRENT, MAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
     { Print("ERROR: no se pudo crear handle MA"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   Print("EA v2.0 iniciado — ", Symbol(), " ", EnumToString(Period()));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  { IndicatorRelease(maHandle); }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- 1. solo lun-vie
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return;

   //--- 2. detectar nueva vela (funciona en live y en backtester)
   int currentBars = Bars(Symbol(), PERIOD_CURRENT);
   if(currentBars == lastBarsCount) return;
   lastBarsCount = currentBars;

   //--- 3. máximo 1 operación por día
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(lastTradeDay == today) return;

   //--- 4. no operar con posición abierta
   if(HasOpenPosition()) return;

   //--- 5. leer datos — trabajamos sobre velas CERRADAS (índice 1 en adelante)
   int barsNeeded = SwingLookback + BodyAvgPeriod + 5;

   double maValues[];
   ArraySetAsSeries(maValues, true);
   if(CopyBuffer(maHandle, 0, 1, 1, maValues) < 1) return;
   double ma100 = maValues[0];

   double closes[], opens[], highs[], lows[];
   ArraySetAsSeries(closes, true); ArraySetAsSeries(opens, true);
   ArraySetAsSeries(highs,  true); ArraySetAsSeries(lows,  true);

   if(CopyClose(Symbol(), PERIOD_CURRENT, 1, barsNeeded, closes) < barsNeeded) return;
   if(CopyOpen (Symbol(), PERIOD_CURRENT, 1, barsNeeded, opens)  < barsNeeded) return;
   if(CopyHigh (Symbol(), PERIOD_CURRENT, 1, barsNeeded, highs)  < barsNeeded) return;
   if(CopyLow  (Symbol(), PERIOD_CURRENT, 1, barsNeeded, lows)   < barsNeeded) return;

   // Ahora: índice 0 = vela más reciente cerrada, índice 1 = la anterior, etc.
   double closeBar = closes[0];
   double openBar  = opens[0];
   double highBar  = highs[0];
   double lowBar   = lows[0];

   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   //--- 6. filtro de rango lateral
   //    calculamos el rango de las últimas RangeLookback velas en puntos
   if(IsRangeMarket(highs, lows, point)) return;

   //--- 7. swing high/low de las últimas SwingLookback velas (velas 0..N-1 = ya cerradas)
   //    NOTA: CopyHigh con offset 1 ya nos da velas cerradas, índice 0 = última cerrada
   double swingHigh = 0, swingLow = DBL_MAX;
   for(int i = 0; i < SwingLookback; i++)
     {
      if(highs[i]  > swingHigh) swingHigh = highs[i];
      if(lows[i]   < swingLow)  swingLow  = lows[i];
     }

   //--- 8. cuerpo promedio (excluye la vela actual en análisis)
   double avgBody = 0;
   for(int i = 1; i <= BodyAvgPeriod; i++)   // desde 1 para excluir la vela más reciente
      avgBody += MathAbs(closes[i] - opens[i]);
   avgBody /= BodyAvgPeriod;
   if(avgBody <= 0) return;

   double bodyLast    = MathAbs(closeBar - openBar);
   bool   isStrong    = (bodyLast >= avgBody * BodyMultiplier);
   bool   isVeryStrong = (bodyLast >= avgBody * 2.2);

   //--- debug opcional (descomentar para ver en el log del backtester)
   // PrintFormat("Bar: close=%.2f swingH=%.2f swingL=%.2f MA=%.2f body=%.2f avgBody=%.2f strong=%d waiting=%d dir=%d",
   //             closeBar, swingHigh, swingLow, ma100, bodyLast, avgBody, (int)isStrong, (int)waitingPullback, tradeDirection);

   // ===================================================================
   //  BLOQUE A: DETECCIÓN DE NUEVA RUPTURA (solo si no hay setup activo)
   // ===================================================================
   if(!waitingPullback)
     {
      //--- RUPTURA ALCISTA: cierre rompe swing high CON FUERZA + precio sobre MA
      //    El swing incluye la vela actual, así que la condición correcta es
      //    cierre > swingHigh de las N-1 velas ANTERIORES.
      //    Como copiamos desde offset 1, closes[0] es la más reciente y
      //    swingHigh incluye highs[0]. Para ruptura real comparamos:
      //    closeBar > máximo de highs[1..SwingLookback-1]
      double prevHigh = 0, prevLow = DBL_MAX;
      for(int i = 1; i < SwingLookback; i++)
        {
         if(highs[i] > prevHigh) prevHigh = highs[i];
         if(lows[i]  < prevLow)  prevLow  = lows[i];
        }

      if(closeBar > prevHigh && isStrong && closeBar > ma100)
        {
         tradeDirection     = 1;
         breakoutLevel      = prevHigh;
         breakoutSwingOpp   = prevLow;
         waitingPullback    = true;
         barsWaiting        = 0;
         Print(">>> RUPTURA ALCISTA | close=", closeBar, " nivel=", prevHigh,
               " SL_ref=", prevLow, " MA=", ma100);

         if(AllowDirectEntry && isVeryStrong)
           {
            double ask    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
            double sl     = prevLow;
            double slDist = ask - sl;
            double tp     = ask + slDist * RRRatio;
            if(ValidarOrden(slDist, ask))
              {
               double lots = CalcLots(slDist);
               if(trade.Buy(lots, Symbol(), ask, sl, tp, TradeComment))
                 { lastTradeDay = today; waitingPullback = false;
                   Print("ENTRY LONG directo | lots=", lots, " sl=", sl, " tp=", tp); }
              }
           }
         return;
        }

      if(closeBar < prevLow && isStrong && closeBar < ma100)
        {
         tradeDirection     = -1;
         breakoutLevel      = prevLow;
         breakoutSwingOpp   = prevHigh;
         waitingPullback    = true;
         barsWaiting        = 0;
         Print(">>> RUPTURA BAJISTA | close=", closeBar, " nivel=", prevLow,
               " SL_ref=", prevHigh, " MA=", ma100);

         if(AllowDirectEntry && isVeryStrong)
           {
            double bid    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
            double sl     = prevHigh;
            double slDist = sl - bid;
            double tp     = bid - slDist * RRRatio;
            if(ValidarOrden(slDist, bid))
              {
               double lots = CalcLots(slDist);
               if(trade.Sell(lots, Symbol(), bid, sl, tp, TradeComment))
                 { lastTradeDay = today; waitingPullback = false;
                   Print("ENTRY SHORT directo | lots=", lots, " sl=", sl, " tp=", tp); }
              }
           }
         return;
        }
     }

   // ===================================================================
   //  BLOQUE B: ESPERA DE PULLBACK
   // ===================================================================
   if(waitingPullback)
     {
      barsWaiting++;

      //--- caducidad: demasiadas barras esperando
      if(barsWaiting > MaxBarsWaiting)
        { waitingPullback = false; tradeDirection = 0;
          Print("Setup caducado tras ", MaxBarsWaiting, " velas."); return; }

      //--- invalidación suave: el precio cerró claramente al otro lado del nivel de ruptura
      double invalidMargin = avgBody * 1.5;
      if(tradeDirection ==  1 && closeBar < breakoutLevel - invalidMargin)
        { waitingPullback = false; tradeDirection = 0;
          Print("Setup LONG invalidado. close=", closeBar, " nivel=", breakoutLevel); return; }
      if(tradeDirection == -1 && closeBar > breakoutLevel + invalidMargin)
        { waitingPullback = false; tradeDirection = 0;
          Print("Setup SHORT invalidado. close=", closeBar, " nivel=", breakoutLevel); return; }

      //--- zona de pullback en puntos absolutos
      double zone = PullbackZonePoints * point;

      //--- ENTRADA LONG en pullback
      if(tradeDirection == 1)
        {
         // pullback: precio regresó hacia la zona rota
         bool inZone    = (closeBar >= breakoutLevel - zone && closeBar <= breakoutLevel + zone * 2);
         // rechazo: vela cerró alcista y por encima del nivel
         bool rejection = (closeBar > openBar && closeBar > breakoutLevel - zone * 0.5);
         bool trendOk   = (closeBar > ma100);

         if(inZone && rejection && trendOk)
           {
            double ask    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
            double sl     = MathMin(breakoutSwingOpp, lowBar - point * 5);
            double slDist = ask - sl;
            double tp     = ask + slDist * RRRatio;
            if(ValidarOrden(slDist, ask))
              {
               double lots = CalcLots(slDist);
               if(trade.Buy(lots, Symbol(), ask, sl, tp, TradeComment))
                 { lastTradeDay = today; waitingPullback = false; tradeDirection = 0;
                   Print("ENTRY LONG pullback | lots=", lots, " sl=", sl, " tp=", tp,
                         " barsWaited=", barsWaiting); }
              }
           }
        }

      //--- ENTRADA SHORT en pullback
      if(tradeDirection == -1)
        {
         bool inZone    = (closeBar <= breakoutLevel + zone && closeBar >= breakoutLevel - zone * 2);
         bool rejection = (closeBar < openBar && closeBar < breakoutLevel + zone * 0.5);
         bool trendOk   = (closeBar < ma100);

         if(inZone && rejection && trendOk)
           {
            double bid    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
            double sl     = MathMax(breakoutSwingOpp, highBar + point * 5);
            double slDist = sl - bid;
            double tp     = bid - slDist * RRRatio;
            if(ValidarOrden(slDist, bid))
              {
               double lots = CalcLots(slDist);
               if(trade.Sell(lots, Symbol(), bid, sl, tp, TradeComment))
                 { lastTradeDay = today; waitingPullback = false; tradeDirection = 0;
                   Print("ENTRY SHORT pullback | lots=", lots, " sl=", sl, " tp=", tp,
                         " barsWaited=", barsWaiting); }
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Verifica que el SL no sea absurdo (mín 10 pts, máx 4% del precio)|
//+------------------------------------------------------------------+
bool ValidarOrden(double slDist, double precio)
  {
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(slDist < point * 10)    { Print("SL demasiado pequeño: ", slDist); return false; }
   if(slDist > precio * 0.04) { Print("SL demasiado grande: ", slDist); return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Mercado lateral: rango < RangeMinPoints puntos en N velas         |
//+------------------------------------------------------------------+
bool IsRangeMarket(const double &highs[], const double &lows[], double point)
  {
   double high = 0, low = DBL_MAX;
   for(int i = 0; i < RangeLookback; i++)
     {
      if(highs[i] > high) high = highs[i];
      if(lows[i]  < low)  low  = lows[i];
     }
   if(low <= 0 || low == DBL_MAX) return false;
   double rangePoints = (high - low) / point;
   return(rangePoints < RangeMinPoints);
  }

//+------------------------------------------------------------------+
//| Calcula lotaje basado en equity y distancia al SL                 |
//+------------------------------------------------------------------+
double CalcLots(double slDist)
  {
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmt  = equity * RiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);
   double minLot   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   if(tickVal <= 0 || tickSz <= 0 || slDist <= 0) return minLot;

   double slTicks = slDist / tickSz;
   double lots    = riskAmt / (slTicks * tickVal);
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return lots;
  }

//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     if(posInfo.SelectByIndex(i))
        if(posInfo.Magic() == MagicNumber && posInfo.Symbol() == Symbol())
           return true;
   return false;
  }
//+------------------------------------------------------------------+
