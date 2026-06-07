//+------------------------------------------------------------------+
//|                        XAUUSD_MartingaleEA.mq5                  |
//|                    Martingala Controlada para XAUUSD             |
//|                  Estrategia: EMA Cross + RSI Filter              |
//+------------------------------------------------------------------+
#property copyright   "Martingala Controlada XAUUSD"
#property version     "1.00"
#property description "EA de Martingala Controlada para XAUUSD con gestion de riesgo avanzada"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUTS - CONFIGURACION GENERAL                                  |
//+------------------------------------------------------------------+
input group "=== CONFIGURACION DE LOTES ==="
input double   InpLoteInicial        = 0.01;    // Lote inicial
input double   InpMultiplicador      = 1.5;     // Multiplicador de martingala
input int      InpNivelesMaximos     = 4;       // Niveles maximos de martingala (1-5)

input group "=== ESTRATEGIA DE ENTRADA ==="
input bool     InpUsarEMACross       = true;    // Usar cruce de EMA
input int      InpEMARapida          = 50;      // Periodo EMA rapida
input int      InpEMALenta           = 200;     // Periodo EMA lenta
input bool     InpUsarRSI            = true;    // Usar filtro RSI
input int      InpRSIPeriodo         = 14;      // Periodo RSI
input int      InpRSISobrecompra     = 70;      // Nivel sobrecompra RSI
input int      InpRSISobreventa      = 30;      // Nivel sobreventa RSI

input group "=== MARTINGALA - DISTANCIAS ==="
input int      InpDistanciaMinPuntos = 400;     // Distancia minima entre ordenes (puntos)
input double   InpTPCestaPuntos      = 500;     // Take Profit conjunto de la cesta (puntos)

input group "=== GESTION DE RIESGO ==="
input double   InpMaxDrawdownPct     = 10.0;    // Drawdown maximo permitido (% del balance)
input double   InpTPGlobalPct        = 5.0;     // Take Profit global del ciclo (% del balance)
input double   InpMaxSpreadPuntos    = 30;      // Spread maximo permitido (puntos)

input group "=== FILTRO HORARIO ==="
input bool     InpUsarFiltroHorario  = false;   // Activar filtro horario
input int      InpHoraInicio         = 3;       // Hora de inicio de operativa (UTC)
input int      InpHoraFin            = 20;      // Hora de fin de operativa (UTC)

input group "=== CONFIGURACION TECNICA ==="
input int      InpMagicNumber        = 123456;  // Numero magico del EA
input int      InpSlippage           = 10;      // Slippage maximo (puntos)
input int      InpReintentos         = 3;       // Numero de reintentos en caso de error
input int      InpEsperaReintento    = 500;     // Espera entre reintentos (ms)

//+------------------------------------------------------------------+
//|  VARIABLES GLOBALES                                              |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;

int            handleEMARapida  = INVALID_HANDLE;
int            handleEMALenta   = INVALID_HANDLE;
int            handleRSI        = INVALID_HANDLE;

int            g_nivelActual    = 0;
double         g_balanceInicio  = 0;
bool           g_cicloActivo    = false;
int            g_direccionCiclo = 0;       // 1=BUY, -1=SELL
double         g_precioUltOrden = 0;

string         g_nombrePanel    = "MartPanel";

//+------------------------------------------------------------------+
//|  INICIALIZACION                                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StringFind(Symbol(), "XAU") < 0 && StringFind(Symbol(), "GOLD") < 0)
      Print("[ADVERTENCIA] Este EA esta optimizado para XAUUSD. Simbolo actual: ", Symbol());

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   handleEMARapida = iMA(Symbol(), PERIOD_CURRENT, InpEMARapida, 0, MODE_EMA, PRICE_CLOSE);
   handleEMALenta  = iMA(Symbol(), PERIOD_CURRENT, InpEMALenta,  0, MODE_EMA, PRICE_CLOSE);
   handleRSI       = iRSI(Symbol(), PERIOD_CURRENT, InpRSIPeriodo, PRICE_CLOSE);

   if(handleEMARapida == INVALID_HANDLE || handleEMALenta == INVALID_HANDLE || handleRSI == INVALID_HANDLE)
   {
      Print("[ERROR] No se pudieron crear los handles de indicadores.");
      return INIT_FAILED;
   }

   g_balanceInicio = AccountInfoDouble(ACCOUNT_BALANCE);
   CrearPanel();

   Print("[EA] Iniciado correctamente. Magic: ", InpMagicNumber, " | Simbolo: ", Symbol());
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  DESINICIALIZACION                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleEMARapida != INVALID_HANDLE) IndicatorRelease(handleEMARapida);
   if(handleEMALenta  != INVALID_HANDLE) IndicatorRelease(handleEMALenta);
   if(handleRSI       != INVALID_HANDLE) IndicatorRelease(handleRSI);
   EliminarPanel();
   Print("[EA] Detenido. Razon: ", reason);
}

//+------------------------------------------------------------------+
//|  TICK PRINCIPAL                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   ActualizarEstadoCiclo();

   if(VerificarProteccionesGlobales()) return;
   if(g_cicloActivo && VerificarTPCesta()) return;
   if(!FiltrosOK()) return;

   if(!g_cicloActivo)
   {
      int senalEntrada = ObtenerSenalEntrada();
      if(senalEntrada != 0)
      {
         g_balanceInicio = AccountInfoDouble(ACCOUNT_BALANCE);
         AbrirOrden(senalEntrada, InpLoteInicial, 1);
      }
   }
   else
   {
      VerificarSiguienteNivelMartingala();
   }

   ActualizarPanel();
}

//+------------------------------------------------------------------+
//|  ACTUALIZAR ESTADO DEL CICLO                                     |
//+------------------------------------------------------------------+
void ActualizarEstadoCiclo()
{
   int totalPos = 0;
   g_nivelActual    = 0;
   g_direccionCiclo = 0;
   g_precioUltOrden = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == (ulong)InpMagicNumber)
         {
            totalPos++;
            g_direccionCiclo = (posInfo.PositionType() == POSITION_TYPE_BUY) ? 1 : -1;
            g_precioUltOrden = posInfo.PriceOpen();
         }
      }
   }

   g_cicloActivo = (totalPos > 0);
   g_nivelActual = totalPos;
}

//+------------------------------------------------------------------+
//|  VERIFICAR PROTECCIONES GLOBALES                                 |
//+------------------------------------------------------------------+
bool VerificarProteccionesGlobales()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown = (balance > 0) ? ((balance - equity) / balance) * 100.0 : 0.0;

   if(drawdown >= InpMaxDrawdownPct)
   {
      Print("[RIESGO] Drawdown maximo alcanzado: ", DoubleToString(drawdown, 2), "%. Cerrando posiciones.");
      CerrarTodasLasPosiciones("DRAWDOWN_MAX");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  VERIFICAR TAKE PROFIT DE LA CESTA                               |
//+------------------------------------------------------------------+
bool VerificarTPCesta()
{
   double beneficioTotal = CalcularBeneficioFlotante();
   double balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   double tpPorPct       = balance * (InpTPGlobalPct / 100.0);

   double breakEven    = CalcularBreakEven();
   double precioActual = (g_direccionCiclo == 1)
                         ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                         : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double puntoValor   = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   double distBE = 0.0;
   if(puntoValor > 0.0 && breakEven > 0.0)
      distBE = (g_direccionCiclo == 1) ? (precioActual - breakEven) / puntoValor
                                        : (breakEven - precioActual) / puntoValor;

   bool tpAlcanzado = (beneficioTotal >= tpPorPct) ||
                      (distBE >= InpTPCestaPuntos && beneficioTotal > 0.0);

   if(tpAlcanzado)
   {
      Print("[TP] Take Profit alcanzado. Beneficio: ", DoubleToString(beneficioTotal, 2),
            " | Dist BE: ", DoubleToString(distBE, 1), " pts");
      CerrarTodasLasPosiciones("TAKE_PROFIT");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  FILTROS DE MERCADO                                              |
//+------------------------------------------------------------------+
bool FiltrosOK()
{
   long spreadActual = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(spreadActual > (long)InpMaxSpreadPuntos)
      return false;

   if(InpUsarFiltroHorario)
   {
      MqlDateTime dt;
      TimeToStruct(TimeGMT(), dt);
      int horaActual = dt.hour;
      if(horaActual < InpHoraInicio || horaActual >= InpHoraFin)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//|  OBTENER SENAL DE ENTRADA                                        |
//+------------------------------------------------------------------+
int ObtenerSenalEntrada()
{
   // Declarar arrays dinamicos (requerido por CopyBuffer con ArraySetAsSeries)
   double emaRapidaBuf[];
   double emaLentaBuf[];
   double rsiBuf[];

   ArraySetAsSeries(emaRapidaBuf, true);
   ArraySetAsSeries(emaLentaBuf,  true);
   ArraySetAsSeries(rsiBuf,       true);

   if(CopyBuffer(handleEMARapida, 0, 0, 3, emaRapidaBuf) < 3) return 0;
   if(CopyBuffer(handleEMALenta,  0, 0, 3, emaLentaBuf)  < 3) return 0;
   if(CopyBuffer(handleRSI,       0, 0, 3, rsiBuf)        < 3) return 0;

   int senalEMA = 0;
   int senalRSI = 0;

   // Senal EMA Cross
   if(InpUsarEMACross)
   {
      if(emaRapidaBuf[1] < emaLentaBuf[1] && emaRapidaBuf[0] > emaLentaBuf[0])
         senalEMA = 1;
      else if(emaRapidaBuf[1] > emaLentaBuf[1] && emaRapidaBuf[0] < emaLentaBuf[0])
         senalEMA = -1;
   }

   // Senal RSI
   if(InpUsarRSI)
   {
      double nivelSV = (double)InpRSISobreventa;
      double nivelSC = (double)InpRSISobrecompra;
      if(rsiBuf[1] < nivelSV && rsiBuf[0] >= nivelSV)
         senalRSI = 1;
      else if(rsiBuf[1] > nivelSC && rsiBuf[0] <= nivelSC)
         senalRSI = -1;
   }

   // Combinar senales
   if(InpUsarEMACross && InpUsarRSI)
   {
      if(senalEMA == senalRSI && senalEMA != 0) return senalEMA;
   }
   else if(InpUsarEMACross) return senalEMA;
   else if(InpUsarRSI)      return senalRSI;

   return 0;
}

//+------------------------------------------------------------------+
//|  VERIFICAR SIGUIENTE NIVEL DE MARTINGALA                        |
//+------------------------------------------------------------------+
void VerificarSiguienteNivelMartingala()
{
   if(g_nivelActual >= InpNivelesMaximos) return;

   double precioActual = (g_direccionCiclo == 1)
                         ? SymbolInfoDouble(Symbol(), SYMBOL_BID)
                         : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double puntoValor   = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   if(puntoValor <= 0.0) return;

   double distancia = MathAbs(precioActual - g_precioUltOrden) / puntoValor;
   bool   enContra  = (g_direccionCiclo == 1 && precioActual < g_precioUltOrden) ||
                      (g_direccionCiclo == -1 && precioActual > g_precioUltOrden);

   if(enContra && distancia >= (double)InpDistanciaMinPuntos)
   {
      double loteSig   = CalcularLoteSiguienteNivel();
      int    nivelSig  = g_nivelActual + 1;
      Print("[MARTINGALA] Nivel ", nivelSig, " | Lote: ", DoubleToString(loteSig, 2),
            " | Distancia: ", DoubleToString(distancia, 0), " pts");
      AbrirOrden(g_direccionCiclo, loteSig, nivelSig);
   }
}

//+------------------------------------------------------------------+
//|  CALCULAR LOTE PARA EL SIGUIENTE NIVEL                          |
//+------------------------------------------------------------------+
double CalcularLoteSiguienteNivel()
{
   double lote = InpLoteInicial;
   for(int i = 0; i < g_nivelActual; i++)
      lote *= InpMultiplicador;

   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   if(lotStep > 0.0) lote = MathFloor(lote / lotStep) * lotStep;

   double loteMin = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double loteMax = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   return MathMax(loteMin, MathMin(loteMax, lote));
}

//+------------------------------------------------------------------+
//|  ABRIR ORDEN CON REINTENTOS                                      |
//+------------------------------------------------------------------+
bool AbrirOrden(int direccion, double lote, int nivelNum)
{
   double precio = 0.0;
   double sl     = 0.0;
   double tp     = 0.0;
   ENUM_ORDER_TYPE tipoOrden;

   if(direccion == 1)
   {
      precio    = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
      tipoOrden = ORDER_TYPE_BUY;
   }
   else
   {
      precio    = SymbolInfoDouble(Symbol(), SYMBOL_BID);
      tipoOrden = ORDER_TYPE_SELL;
   }

   // Construir comentario usando cast (string) en lugar de IntToString()
   string comentario = "Mart_N" + (string)nivelNum + "_M" + (string)InpMagicNumber;

   for(int intento = 1; intento <= InpReintentos; intento++)
   {
      bool resultado = (tipoOrden == ORDER_TYPE_BUY)
                       ? trade.Buy(lote, Symbol(), precio, sl, tp, comentario)
                       : trade.Sell(lote, Symbol(), precio, sl, tp, comentario);

      if(resultado)
      {
         int digitos = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
         Print("[ORDEN] Nivel: ", nivelNum,
               " | ", (direccion == 1 ? "BUY" : "SELL"),
               " | Lote: ", DoubleToString(lote, 2),
               " | Precio: ", DoubleToString(precio, digitos));
         return true;
      }
      else
      {
         int codigoErr = GetLastError();
         Print("[ERROR] Intento ", intento, "/", InpReintentos,
               " | Codigo: ", codigoErr, " | ", DescripcionError(codigoErr));
         if(intento < InpReintentos) Sleep(InpEsperaReintento);
      }
   }

   Print("[ERROR CRITICO] No se pudo abrir la orden despues de ", InpReintentos, " intentos.");
   return false;
}

//+------------------------------------------------------------------+
//|  CERRAR TODAS LAS POSICIONES DEL CICLO                          |
//+------------------------------------------------------------------+
void CerrarTodasLasPosiciones(string motivo)
{
   int cerradas = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == (ulong)InpMagicNumber)
         {
            ulong ticket = posInfo.Ticket();
            for(int intento = 1; intento <= InpReintentos; intento++)
            {
               if(trade.PositionClose(ticket, InpSlippage))
               {
                  cerradas++;
                  Print("[CIERRE] Ticket ", ticket, " cerrado. Motivo: ", motivo);
                  break;
               }
               else
               {
                  Print("[ERROR] Cierre fallido ticket ", ticket,
                        " | Intento ", intento, "/", InpReintentos);
                  if(intento < InpReintentos) Sleep(InpEsperaReintento);
               }
            }
         }
      }
   }
   Print("[CICLO] Cerrado. Posiciones: ", cerradas, " | Motivo: ", motivo);
   g_cicloActivo    = false;
   g_nivelActual    = 0;
   g_direccionCiclo = 0;
   g_precioUltOrden = 0.0;
}

//+------------------------------------------------------------------+
//|  CALCULAR BENEFICIO FLOTANTE TOTAL                               |
//+------------------------------------------------------------------+
double CalcularBeneficioFlotante()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == (ulong)InpMagicNumber)
            total += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   }
   return total;
}

//+------------------------------------------------------------------+
//|  CALCULAR BREAK-EVEN DINAMICO DE LA CESTA                       |
//+------------------------------------------------------------------+
double CalcularBreakEven()
{
   double volTotal = 0.0;
   double volPrecio = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == Symbol() && posInfo.Magic() == (ulong)InpMagicNumber)
         {
            double vol = posInfo.Volume();
            volTotal  += vol;
            volPrecio += vol * posInfo.PriceOpen();
         }
      }
   }
   return (volTotal > 0.0) ? volPrecio / volTotal : 0.0;
}

//+------------------------------------------------------------------+
//|  DESCRIPCION DE ERROR                                            |
//+------------------------------------------------------------------+
string DescripcionError(int codigoErr)
{
   switch(codigoErr)
   {
      case 10004: return "Requote";
      case 10006: return "Orden rechazada";
      case 10007: return "Cancelada por trader";
      case 10009: return "Solicitud completada";
      case 10010: return "Completada parcialmente";
      case 10011: return "Error de procesamiento";
      case 10012: return "Timeout";
      case 10013: return "Solicitud no valida";
      case 10014: return "Volumen no valido";
      case 10015: return "Precio no valido";
      case 10016: return "Stop no valido";
      case 10017: return "Trading desactivado";
      case 10018: return "Mercado cerrado";
      case 10019: return "Fondos insuficientes";
      case 10020: return "Precios cambiados";
      case 10021: return "No hay cotizaciones";
      case 10024: return "Demasiadas solicitudes";
      case 10030: return "Tipo de relleno no soportado";
      case 10031: return "Sin conexion";
      case 10034: return "Limite de volumen alcanzado";
      default:    return "Error: " + (string)codigoErr;
   }
}

//+------------------------------------------------------------------+
//|  PANEL VISUAL - CREACION                                         |
//+------------------------------------------------------------------+
void CrearPanel()
{
   ObjectCreate(0, g_nombrePanel + "_BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_XDISTANCE,   10);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_YDISTANCE,   30);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_XSIZE,       230);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_YSIZE,       135);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_BGCOLOR,     clrMidnightBlue);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_COLOR,       clrGold);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_WIDTH,       1);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_BACK,        false);
   ObjectSetInteger(0, g_nombrePanel + "_BG", OBJPROP_SELECTABLE,  false);

   CrearTextoPanel(g_nombrePanel + "_TITULO",  "MARTINGALA XAUUSD EA",  15, 38,  clrGold,   9);
   CrearTextoPanel(g_nombrePanel + "_LBL_NV",  "Nivel Martingala:",      15, 62,  clrSilver, 8);
   CrearTextoPanel(g_nombrePanel + "_VAL_NV",  "-",                     160, 62,  clrWhite,  8);
   CrearTextoPanel(g_nombrePanel + "_LBL_DD",  "Drawdown:",              15, 82,  clrSilver, 8);
   CrearTextoPanel(g_nombrePanel + "_VAL_DD",  "-",                     160, 82,  clrWhite,  8);
   CrearTextoPanel(g_nombrePanel + "_LBL_BP",  "Beneficio flotante:",    15, 102, clrSilver, 8);
   CrearTextoPanel(g_nombrePanel + "_VAL_BP",  "-",                     160, 102, clrWhite,  8);
   CrearTextoPanel(g_nombrePanel + "_LBL_BE",  "Break-Even:",            15, 122, clrSilver, 8);
   CrearTextoPanel(g_nombrePanel + "_VAL_BE",  "-",                     160, 122, clrWhite,  8);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//|  PANEL VISUAL - CREAR ETIQUETA                                   |
//+------------------------------------------------------------------+
void CrearTextoPanel(string nombre, string texto, int x, int y, color col, int tam)
{
   ObjectCreate(0, nombre, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, nombre, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, nombre, OBJPROP_YDISTANCE,  y);
   ObjectSetString(0,  nombre, OBJPROP_TEXT,        texto);
   ObjectSetInteger(0, nombre, OBJPROP_COLOR,       col);
   ObjectSetInteger(0, nombre, OBJPROP_FONTSIZE,    tam);
   ObjectSetString(0,  nombre, OBJPROP_FONT,        "Arial Bold");
   ObjectSetInteger(0, nombre, OBJPROP_SELECTABLE,  false);
   ObjectSetInteger(0, nombre, OBJPROP_BACK,        false);
}

//+------------------------------------------------------------------+
//|  PANEL VISUAL - ACTUALIZACION                                    |
//+------------------------------------------------------------------+
void ActualizarPanel()
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown  = (balance > 0.0) ? ((balance - equity) / balance) * 100.0 : 0.0;
   double beneficio = CalcularBeneficioFlotante();
   double breakEven = CalcularBreakEven();

   // Nivel con semaforo de color
   string txtNivel = (string)g_nivelActual + "/" + (string)InpNivelesMaximos;
   color  colNivel = (g_nivelActual == 0) ? clrLime :
                     (g_nivelActual < InpNivelesMaximos) ? clrYellow : clrRed;

   color colDD = (drawdown < InpMaxDrawdownPct * 0.5) ? clrLime :
                 (drawdown < InpMaxDrawdownPct * 0.8) ? clrYellow : clrRed;

   color colBP = (beneficio >= 0.0) ? clrLime : clrRed;

   int digitos = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   ObjectSetString(0,  g_nombrePanel + "_VAL_NV", OBJPROP_TEXT,  txtNivel);
   ObjectSetInteger(0, g_nombrePanel + "_VAL_NV", OBJPROP_COLOR, colNivel);

   ObjectSetString(0,  g_nombrePanel + "_VAL_DD", OBJPROP_TEXT,  DoubleToString(drawdown, 2) + "%");
   ObjectSetInteger(0, g_nombrePanel + "_VAL_DD", OBJPROP_COLOR, colDD);

   ObjectSetString(0,  g_nombrePanel + "_VAL_BP", OBJPROP_TEXT,  DoubleToString(beneficio, 2) + " $");
   ObjectSetInteger(0, g_nombrePanel + "_VAL_BP", OBJPROP_COLOR, colBP);

   string txtBE = (breakEven > 0.0) ? DoubleToString(breakEven, digitos) : "N/A";
   ObjectSetString(0,  g_nombrePanel + "_VAL_BE", OBJPROP_TEXT,  txtBE);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//|  PANEL VISUAL - ELIMINACION                                      |
//+------------------------------------------------------------------+
void EliminarPanel()
{
   ObjectDelete(0, g_nombrePanel + "_BG");
   ObjectDelete(0, g_nombrePanel + "_TITULO");
   ObjectDelete(0, g_nombrePanel + "_LBL_NV");
   ObjectDelete(0, g_nombrePanel + "_VAL_NV");
   ObjectDelete(0, g_nombrePanel + "_LBL_DD");
   ObjectDelete(0, g_nombrePanel + "_VAL_DD");
   ObjectDelete(0, g_nombrePanel + "_LBL_BP");
   ObjectDelete(0, g_nombrePanel + "_VAL_BP");
   ObjectDelete(0, g_nombrePanel + "_LBL_BE");
   ObjectDelete(0, g_nombrePanel + "_VAL_BE");
   ChartRedraw();
}

//+------------------------------------------------------------------+
//|  FIN DEL ARCHIVO                                                 |
//+------------------------------------------------------------------+
