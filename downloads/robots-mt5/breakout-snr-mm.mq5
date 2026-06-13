//+------------------------------------------------------------------+
//|                                            Breakout_SNR_MM.mq5  |
//|   Réplica 1:1 de la especificación (sin filtros/inputs extra).  |
//+------------------------------------------------------------------+
#property version   "1.0"
#property strict

#include <Trade/Trade.mqh>

//==================================================================
// §1 / §2  INPUTS (nombres, tipos, defaults y ORDEN exactos)
//==================================================================
input string EA_Name           = "Breakout SNR (MM)";
input int    Lot_money_start   = 10;     // dinero de riesgo inicial por operación (divisa de la cuenta)
input bool   Mode_Lots_MM      = true;   // ON = recuperación de pérdidas; OFF = riesgo fijo
input int    Breakout_pips     = 15;     // distancia mínima de ruptura sobre/bajo la línea (en points)
input int    SL_end_candle_id  = 5;      // nº de velas para el extremo del SL dinámico
input int    TP_percent_SL     = 120;    // TP como % de la distancia del SL
input int    Higher_at_id_1    = 14;     // 1er índice de vela para detección SNR / swing
input int    Higher_at_id_2    = 28;     // 2º índice de vela para detección SNR / swing
input int    Slippage          = 4;
input int    MagicStart        = 5516;

// Inputs de color del panel (cosméticos)
input color  inp21_ObjTitleFontColor  = clrLimeGreen;
input color  inp21_ObjLabelsFontColor = clrDarkGray;
input color  inp21_ObjFontColor       = clrWhite;

//==================================================================
// §3  VARIABLES DE ESTADO GLOBALES (double, todas empiezan en 0)
//==================================================================
double Trend_B            = 0;
double Trend_S            = 0;
double Start_trading_BS   = 0;
double Balance_start_BS   = 0;
double Lots_money_BS      = 0;
double Loss_money_BS      = 0;
double Loss_money_all_BS  = 0;
double Negative_to_Positive = 0;

//==================================================================
// Mecánica interna (no forma parte de la lógica de la estrategia,
// solo da soporte a los "pass once" / "once per bar" / historial)
//==================================================================
bool      cycleInitialized = false;   // "pass once" de §4
datetime  g_lastBarTime    = 0;       // detección de barra nueva
ulong     last_deal_ticket = 0;       // último deal de cierre procesado (§9/§10)

CTrade    trade;

// Nombres de objetos
#define LINE_BUY   "LineBuy"
#define LINE_SELL  "LineSell"
#define PANEL_PFX  "BSNR_panel_"

//==================================================================
// Utilidades
//==================================================================
double AccountBalance() { return AccountInfoDouble(ACCOUNT_BALANCE); }
double AccountEquity()  { return AccountInfoDouble(ACCOUNT_EQUITY);  }

// Máximo de High en barras [fromBar..toBar] (inclusive, barras cerradas)
double HighestHigh(const int fromBar, const int toBar)
{
   double m = -DBL_MAX;
   for(int i = fromBar; i <= toBar; i++)
   {
      double h = iHigh(_Symbol, _Period, i);
      if(h > m) m = h;
   }
   return m;
}

// Mínimo de Low en barras [fromBar..toBar] (inclusive, barras cerradas)
double LowestLow(const int fromBar, const int toBar)
{
   double m = DBL_MAX;
   for(int i = fromBar; i <= toBar; i++)
   {
      double l = iLow(_Symbol, _Period, i);
      if(l < m) m = l;
   }
   return m;
}

// ¿Hay una posición abierta del EA en este símbolo?
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != MagicStart) continue;
      return true;
   }
   return false;
}

// Normaliza el volumen a min/max/step del símbolo
double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
}

// Volumen "fixedRisk": lote tal que, si salta el SL, la pérdida ≈ riskMoney
double LotsForRisk(const double riskMoney, const double entry, const double sl)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slDist    = MathAbs(entry - sl);

   if(tickSize <= 0 || tickValue <= 0 || slDist <= 0)
      return NormalizeLots(0); // -> min lot (guard mínimo, sin alterar la lógica)

   double lossPerLot = (slDist / tickSize) * tickValue; // pérdida de 1.0 lote al SL
   if(lossPerLot <= 0) return NormalizeLots(0);

   double lots = riskMoney / lossPerLot;
   return NormalizeLots(lots);
}

//==================================================================
// §6  Dibujo / actualización de una línea horizontal
//==================================================================
void DrawHLine(const string name, const double price, const color clr)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);

   ObjectSetDouble (0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
}

//==================================================================
// §5  Detección de tendencia SNR (una vez por barra cerrada)
//==================================================================
void DetectTrend()
{
   if(Bars(_Symbol, _Period) <= Higher_at_id_2 + 1) return;

   // Alcista: swing reciente más alto que el swing previo
   if(HighestHigh(1, Higher_at_id_1) > HighestHigh(Higher_at_id_1, Higher_at_id_2))
   {
      Trend_B = 1;
      Trend_S = 0;
   }

   // Bajista: swing reciente más bajo que el swing previo
   if(LowestLow(1, Higher_at_id_1) < LowestLow(Higher_at_id_1, Higher_at_id_2))
   {
      Trend_S = 1;
      Trend_B = 0;
   }
}

//==================================================================
// §6  Líneas SNR (cada tick, si Start_trading_BS==1 y sin posición)
//==================================================================
void DrawLines()
{
   double c1 = iClose(_Symbol, _Period, 1);

   if(Trend_B == 1)
   {
      double res = HighestHigh(2, Higher_at_id_1); // resistencia por encima
      if(c1 < res)
         DrawHLine(LINE_BUY, res, clrLimeGreen);
   }

   if(Trend_S == 1)
   {
      double sup = LowestLow(2, Higher_at_id_1);    // soporte por debajo
      if(c1 > sup)
         DrawHLine(LINE_SELL, sup, clrOrangeRed);
   }
}

//==================================================================
// §7 / §8  Entrada de COMPRA (cada tick)
//==================================================================
void CheckBuyEntry()
{
   if(ObjectFind(0, LINE_BUY) < 0) return;

   double linePrice = ObjectGetDouble(0, LINE_BUY, OBJPROP_PRICE);
   double c1        = iClose(_Symbol, _Period, 1);

   // (1) ruptura por encima  (2) distancia absoluta >= Breakout_pips (points)
   if(c1 > linePrice && MathAbs(c1 - linePrice) >= Breakout_pips * _Point)
   {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl    = LowestLow(1, SL_end_candle_id);                 // dynamicLevel
      double slDist= entry - sl;
      double tp    = entry + (TP_percent_SL / 100.0) * slDist;       // percentSL

      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);

      double lots = LotsForRisk(Lots_money_BS, entry, sl);           // fixedRisk

      trade.SetExpertMagicNumber(MagicStart);
      trade.SetDeviationInPoints(Slippage);

      if(trade.Buy(lots, _Symbol, 0.0, sl, tp, EA_Name))
      {
         // §8 reset tras BUY
         Trend_B          = 0;
         Start_trading_BS = 0;
         ObjectDelete(0, LINE_BUY);
      }
   }
}

//==================================================================
// §7 / §8  Entrada de VENTA (gestionada "once per bar")
//==================================================================
void CheckSellEntry(const bool isNewBar)
{
   if(!isNewBar) return;                  // guard "once per bar"
   if(ObjectFind(0, LINE_SELL) < 0) return;

   double linePrice = ObjectGetDouble(0, LINE_SELL, OBJPROP_PRICE);
   double c1        = iClose(_Symbol, _Period, 1);

   if(c1 < linePrice && MathAbs(c1 - linePrice) >= Breakout_pips * _Point)
   {
      double entry = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl    = HighestHigh(1, SL_end_candle_id);               // dynamicLevel
      double slDist= sl - entry;
      double tp    = entry - (TP_percent_SL / 100.0) * slDist;       // percentSL

      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);

      double lots = LotsForRisk(Lots_money_BS, entry, sl);           // fixedRisk

      trade.SetExpertMagicNumber(MagicStart);
      trade.SetDeviationInPoints(Slippage);

      if(trade.Sell(lots, _Symbol, 0.0, sl, tp, EA_Name))
      {
         // §8 reset tras SELL
         Trend_S          = 0;
         Start_trading_BS = 0;
         ObjectDelete(0, LINE_SELL);
      }
   }
}

//==================================================================
// §9 / §10  Money Management sobre operaciones cerradas del EA
//           (recorre el historial cada tick, procesa cada cierre
//            una sola vez)
//==================================================================
void HandleClosedTrade(const double profit)
{
   if(Mode_Lots_MM == false)
   {
      // §9 riesgo fijo: solo rearmar
      Start_trading_BS = 1;
      return;
   }

   // Mode_Lots_MM == true
   if(AccountBalance() >= Balance_start_BS)
   {
      // §10 recuperado al balance inicial -> reset total del ciclo
      Balance_start_BS    = 0;
      Lots_money_BS       = 0;
      Loss_money_BS       = 0;
      Loss_money_all_BS   = 0;
      Negative_to_Positive= 0;
      cycleInitialized    = false;   // rearma §4 en el próximo tick sin posición
   }
   else
   {
      // §9 en drawdown respecto al balance de inicio de ciclo
      if(profit < 0)
      {
         Loss_money_BS       = profit;                    // negativo
         Loss_money_all_BS  += Loss_money_BS;             // acumulado negativo
         Negative_to_Positive= Loss_money_all_BS * -1.0;  // positivo
         Lots_money_BS       = Negative_to_Positive;      // recuperación
      }
      Start_trading_BS = 1;   // rearmar (también con operaciones ganadoras)
   }
}

void ProcessClosedTrades()
{
   if(!HistorySelect(0, TimeCurrent())) return;

   ulong prev   = last_deal_ticket;
   ulong maxAll = last_deal_ticket;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(ticket > maxAll) maxAll = ticket;
      if(ticket <= prev) continue;  // ya procesado en ticks anteriores

      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != MagicStart) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)          continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT)   continue;

      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
      HandleClosedTrade(profit);
   }

   last_deal_ticket = maxAll;
}

//==================================================================
// §11  Panel en gráfico
//==================================================================
void SetPanelLabel(const int idx, const int y, const string text, const color clr, const int fontsize)
{
   string name = PANEL_PFX + (string)idx;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 12);
   }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontsize);
   ObjectSetString (0, name, OBJPROP_TEXT, text);
}

// Cada fila usa dos labels: etiqueta (gris) + valor (blanco) -> usamos
// el formato "Etiqueta: valor" en un único label para simplicidad,
// con el color de "valor" (inp21_ObjFontColor) para las filas.
void UpdatePanel()
{
   int y = 14;
   SetPanelLabel(0,  y, EA_Name, inp21_ObjTitleFontColor, 11); y += 20;

   SetPanelLabel(1,  y, "Balance: "          + DoubleToString(AccountBalance(), 2), inp21_ObjFontColor, 9); y += 16;
   SetPanelLabel(2,  y, "Equity: "           + DoubleToString(AccountEquity(),  2), inp21_ObjFontColor, 9); y += 16;
   SetPanelLabel(3,  y, "Balance Start BS: " + DoubleToString(Balance_start_BS, 2), inp21_ObjFontColor, 9); y += 16;
   SetPanelLabel(4,  y, "Lots Money BS: "    + DoubleToString(Lots_money_BS,    2), inp21_ObjFontColor, 9); y += 16;
   SetPanelLabel(5,  y, "Trend Buy: "        + DoubleToString(Trend_B,          0), inp21_ObjLabelsFontColor, 9); y += 16;
   SetPanelLabel(6,  y, "Trend Sell: "       + DoubleToString(Trend_S,          0), inp21_ObjLabelsFontColor, 9); y += 16;
}

//==================================================================
// OnInit / OnDeinit / OnTick
//==================================================================
int OnInit()
{
   trade.SetExpertMagicNumber(MagicStart);
   trade.SetDeviationInPoints(Slippage);

   // No procesar el historial previo a la puesta en marcha del EA:
   // memorizamos el último deal existente para tratar como "nuevos"
   // solo los cierres posteriores.
   if(HistorySelect(0, TimeCurrent()))
   {
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > last_deal_ticket) last_deal_ticket = ticket;
      }
   }

   g_lastBarTime = iTime(_Symbol, _Period, 0);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ObjectDelete(0, LINE_BUY);
   ObjectDelete(0, LINE_SELL);
   for(int i = 0; i <= 6; i++)
      ObjectDelete(0, PANEL_PFX + (string)i);
   Comment("");
}

void OnTick()
{
   // Detección de barra nueva (una sola lectura por tick)
   bool isNewBar = false;
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != g_lastBarTime)
   {
      isNewBar      = true;
      g_lastBarTime = t;
   }

   bool hasPos = HasOpenPosition();

   // §9 / §10  Gestión de operaciones cerradas (cada tick)
   ProcessClosedTrades();

   // §4  Inicialización del ciclo ("pass once") mientras NO haya posición
   if(!hasPos && !cycleInitialized)
   {
      Balance_start_BS = AccountBalance();
      Lots_money_BS    = Lot_money_start;
      Start_trading_BS = 1;
      cycleInitialized = true;
   }

   // §5  Detección de tendencia SNR (una vez por barra cerrada)
   if(isNewBar)
      DetectTrend();

   // §6 / §7  Líneas y entradas (solo si Start_trading_BS==1 y sin posición)
   if(Start_trading_BS == 1 && !hasPos)
   {
      DrawLines();              // cada tick
      CheckBuyEntry();          // cada tick
      CheckSellEntry(isNewBar); // "once per bar"
   }

   // §11  Panel
   UpdatePanel();
}
//+------------------------------------------------------------------+
