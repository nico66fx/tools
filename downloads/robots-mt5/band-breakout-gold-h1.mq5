//+------------------------------------------------------------------+
//|  Ruptura de banda superior de Bollinger — XAUUSD H1, solo largo   |
//|                                                                  |
//|  ENTRADA  el maximo de la vela cerrada supera la banda superior   |
//|           y el de la anterior no la superaba (cruce al alza).     |
//|           Compra a mercado al abrir la vela siguiente.            |
//|                                                                  |
//|  SALIDA   solo por Stop Loss o Take Profit.                       |
//|           SL = 1.5 x ATR(14)   TP = 2.3 x ATR(14)                 |
//|           ATR tomado de la ultima vela cerrada.                   |
//|                                                                  |
//|  Una posicion a la vez. Decide siempre sobre velas cerradas.      |
//|                                                                  |
//|  El periodo 147 y la desviacion 2.198 no son redondos porque      |
//|  salieron de una busqueda. Es el parametro mas delicado que tiene |
//|  el sistema: al moverlo mucho, el comportamiento cambia.          |
//+------------------------------------------------------------------+
#property copyright "Uso libre"
#property version   "1.00"
#property description "Ruptura de la banda superior de Bollinger en XAUUSD H1, solo largo."
#property description "SL 1.5xATR(14), TP 2.3xATR(14). Una posicion, salida solo por SL/TP."

#include <Trade/Trade.mqh>

//--- Senal
input group           "Senal"
input int    InpBandsPeriod  = 147;        // Periodo de las bandas de Bollinger
input double InpBandsDev     = 2.198;      // Desviaciones de las bandas
input int    InpAtrPeriod    = 14;         // Periodo del ATR

//--- Riesgo
input group           "Riesgo"
input double InpLots         = 0.01;       // Lotes por operacion
input double InpSlAtrMult    = 1.5;        // Stop Loss   = mult x ATR  (0 = sin SL)
input double InpTpAtrMult    = 2.3;        // Take Profit = mult x ATR  (0 = sin TP)

//--- Ejecucion
input group           "Ejecucion"
input ulong  InpSlippage     = 10;         // Desviacion maxima de precio, en puntos
input int    InpMaxSpread    = 0;          // Spread maximo para entrar, en puntos (0 = sin limite)
input bool   InpRespetarStopLevel = true;  // Omitir la entrada si el broker no admite ese SL/TP
input ulong  InpMagic        = 20260919;   // Numero magico
input string InpComment      = "BandBreak"; // Comentario de las ordenes

//--- Estado interno
CTrade    trade;
int       hBands   = INVALID_HANDLE;
int       hAtr     = INVALID_HANDLE;
datetime  lastBar  = 0;
bool      avisoLote = false;

//+------------------------------------------------------------------+
//| Inicializacion                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpBandsPeriod < 2 || InpAtrPeriod < 1)
   {
      Print("Parametros de indicador invalidos.");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(InpLots <= 0.0)
   {
      Print("El tamano de lote debe ser mayor que cero.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   //--- Si el lote pedido no cabe en el broker hay que saberlo AHORA, no en la
   //    primera senal. Subirlo en silencio multiplicaria el riesgo probado.
   double loteMinimo = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(loteMinimo > 0.0 && InpLots < loteMinimo)
   {
      PrintFormat("AVISO: el lote configurado (%.3f) esta por debajo del minimo de %s (%.3f). "
                  "No se abriran operaciones. Sube InpLots asumiendo que el riesgo sera mayor.",
                  InpLots, _Symbol, loteMinimo);
   }

   hBands = iBands(_Symbol, PERIOD_CURRENT, InpBandsPeriod, 0, InpBandsDev, PRICE_CLOSE);
   if(hBands == INVALID_HANDLE)
   {
      Print("No se pudo crear el indicador Bollinger.");
      return(INIT_FAILED);
   }

   hAtr = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   if(hAtr == INVALID_HANDLE)
   {
      Print("No se pudo crear el indicador ATR.");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Cierre                                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hBands != INVALID_HANDLE) IndicatorRelease(hBands);
   if(hAtr   != INVALID_HANDLE) IndicatorRelease(hAtr);
}

//+------------------------------------------------------------------+
//| True si ya tenemos una posicion abierta en este simbolo           |
//+------------------------------------------------------------------+
bool TenemosPosicion()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Ajusta el lote al paso del broker.                                |
//| Devuelve 0 si no llega al minimo: preferimos NO operar antes que  |
//| operar con un tamano mayor del previsto.                          |
//+------------------------------------------------------------------+
double LoteValido(double lotes)
{
   double minimo = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maximo = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double paso   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(paso <= 0.0) paso = 0.01;

   int decimales = 0;
   double p = paso;
   while(p < 1.0 && decimales < 8) { p *= 10.0; decimales++; }

   double ajustado = NormalizeDouble(MathFloor(lotes / paso + 0.5) * paso, decimales);

   if(maximo > 0.0 && ajustado > maximo) ajustado = NormalizeDouble(maximo, decimales);
   if(minimo > 0.0 && ajustado < minimo) return(0.0);

   return(ajustado);
}

//+------------------------------------------------------------------+
//| Distancia minima que el broker exige entre precio y SL/TP          |
//| Solo STOPS_LEVEL: el FREEZE_LEVEL regula modificar o cerrar        |
//| posiciones ya abiertas, y este EA no hace ni lo uno ni lo otro.    |
//+------------------------------------------------------------------+
double DistanciaMinima()
{
   long puntos = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return(puntos * _Point);
}

//+------------------------------------------------------------------+
//| Lee un buffer en las dos ultimas velas cerradas                   |
//| destino[0] = vela cerrada mas reciente, destino[1] = la anterior  |
//+------------------------------------------------------------------+
bool LeerBuffer(int handle, int buffer, double &destino[])
{
   ArraySetAsSeries(destino, true);
   if(CopyBuffer(handle, buffer, 1, 2, destino) < 2) return(false);
   if(destino[0] == EMPTY_VALUE || destino[1] == EMPTY_VALUE) return(false);
   return(true);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Trabajamos una sola vez por vela, al abrirse una nueva
   datetime velaActual = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(velaActual == 0 || velaActual == lastBar) return;
   lastBar = velaActual;

   //--- Con posicion abierta no hacemos nada: la operacion vive de su SL/TP
   if(TenemosPosicion()) return;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))           return;

   long modo = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(modo == SYMBOL_TRADE_MODE_DISABLED || modo == SYMBOL_TRADE_MODE_CLOSEONLY) return;

   //--- Spread: en picos de noticias la entrada se ejecuta muy lejos del precio esperado
   if(InpMaxSpread > 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > InpMaxSpread) return;
   }

   //--- Banda superior y ATR en las dos ultimas velas cerradas
   double banda[];
   if(!LeerBuffer(hBands, 1, banda)) return;   // buffer 1 = banda superior

   double atr[];
   if(!LeerBuffer(hAtr, 0, atr)) return;

   //--- Maximos de esas mismas dos velas
   double maxAnterior = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double maxReciente = iHigh(_Symbol, PERIOD_CURRENT, 1);
   if(maxAnterior <= 0.0 || maxReciente <= 0.0) return;

   //--- Cruce al alza: antes no la superaba, ahora si
   bool cruceAlAlza = (maxReciente > banda[0] && maxAnterior <= banda[1]);
   if(!cruceAlAlza) return;

   //--- Distancias de SL y TP a partir del ATR de la ultima vela cerrada
   int    digitos = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double distSl  = NormalizeDouble(InpSlAtrMult * atr[0], digitos);
   double distTp  = NormalizeDouble(InpTpAtrMult * atr[0], digitos);

   if(InpSlAtrMult > 0.0 && distSl <= 0.0) return;   // ATR aun sin valor util
   if(InpTpAtrMult > 0.0 && distTp <= 0.0) return;

   if(InpRespetarStopLevel)
   {
      double minima = DistanciaMinima();
      if((InpSlAtrMult > 0.0 && distSl < minima) || (InpTpAtrMult > 0.0 && distTp < minima))
      {
         PrintFormat("Entrada omitida: SL %.*f y TP %.*f quedan por debajo de la distancia "
                     "minima que exige el broker (%.*f).",
                     digitos, distSl, digitos, distTp, digitos, minima);
         return;
      }
   }

   //--- Tamano de la operacion
   double lotes = LoteValido(InpLots);
   if(lotes <= 0.0)
   {
      if(!avisoLote)
      {
         avisoLote = true;
         PrintFormat("Sin operar: el lote configurado (%.3f) no llega al minimo de %s.",
                     InpLots, _Symbol);
      }
      return;
   }

   //--- Compra a mercado
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0) return;

   double sl = (distSl > 0.0) ? NormalizeDouble(ask - distSl, digitos) : 0.0;
   double tp = (distTp > 0.0) ? NormalizeDouble(ask + distTp, digitos) : 0.0;

   if(sl < 0.0) return;

   if(!trade.Buy(lotes, _Symbol, 0.0, sl, tp, InpComment))
   {
      PrintFormat("Compra rechazada. Codigo %d: %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}
//+------------------------------------------------------------------+
