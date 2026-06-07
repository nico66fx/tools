//+------------------------------------------------------------------+
//|                                          SupplyDemandZones.mq5   |
//|                        Indicador de Zonas de Oferta y Demanda    |
//|                   Basado en acción del precio (Price Action)     |
//+------------------------------------------------------------------+
#property copyright   "Supply & Demand Zones Indicator"
#property link        ""
#property version     "2.00"
#property description "Detecta y dibuja zonas de oferta y demanda con rectángulos visibles."
#property indicator_chart_window
#property indicator_plots 0

//--- Parámetros de entrada configurables
input double InpMultiplicadorVelas    = 2.0;           // MultiplicadorVelas: Factor de impulso (1.5-3.0)
input int    InpVelasAnalisis         = 50;            // VelasAnalisis: Velas para promedio (20-100)
input int    InpTamanoMinimoZona      = 5;             // TamanoMinimoZona: Minimo en puntos
input int    InpMaximoZonasEnPantalla = 10;            // MaximoZonasEnPantalla: Zonas visibles max.
input color  InpColorDemanda          = C'30,100,200'; // ColorDemanda: Azul zonas de demanda
input color  InpColorOferta           = C'200,50,50';  // ColorOferta: Rojo zonas de oferta
input color  InpColorInvalidada       = C'80,80,80';   // ColorInvalidada: Gris zonas rotas
input int    InpGrosorBorde           = 2;             // GrosorBorde: Grosor del borde (1-5)
input bool   InpRellenarZona          = true;          // RellenarZona: Rellenar rectangulo
input bool   InpMostrarEtiquetas      = true;          // MostrarEtiquetas: Texto en la zona
input bool   InpEliminarInvalidadas   = true;          // EliminarInvalidadas: Invalidar zonas rotas
input bool   InpOcultarInvalidadas    = false;         // OcultarInvalidadas: Ocultar al invalidar

//--- Constantes
#define ZONA_DEMANDA   1
#define ZONA_OFERTA   -1
#define PREFIX         "SDZ_"

//--- Estructura de zona
struct ZonaPrecio
{
   int      tipo;
   double   precioAlto;
   double   precioBajo;
   datetime tiempoInicio;
   int      barraInicio;
   bool     activa;
   string   nombreRect;
   string   nombreLabel;
   int      id;
};

//--- Variables globales
ZonaPrecio g_zonas[];
int        g_totalZonas = 0;
int        g_contadorID = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpMultiplicadorVelas < 1.0 || InpMultiplicadorVelas > 10.0)
   { Alert("MultiplicadorVelas debe estar entre 1.0 y 10.0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpVelasAnalisis < 5 || InpVelasAnalisis > 500)
   { Alert("VelasAnalisis debe estar entre 5 y 500"); return INIT_PARAMETERS_INCORRECT; }

   EliminarTodosLosObjetos();
   ArrayResize(g_zonas, 0);
   g_totalZonas = 0;
   g_contadorID = 0;

   Print("SupplyDemandZones v2.0 iniciado.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EliminarTodosLosObjetos();
   ArrayResize(g_zonas, 0);
   g_totalZonas = 0;
   Comment("");
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < InpVelasAnalisis + 5)
      return 0;

   int inicio;
   if(prev_calculated == 0)
   {
      EliminarTodosLosObjetos();
      ArrayResize(g_zonas, 0);
      g_totalZonas = 0;
      inicio = InpVelasAnalisis + 2;
   }
   else
   {
      inicio = MathMax(rates_total - 3, InpVelasAnalisis + 2);
   }

   ActualizarZonasExistentes(rates_total, time, high, low, close);

   for(int i = inicio; i < rates_total - 1; i++)
   {
      double promedio = CalcularPromedioCuerpo(i, InpVelasAnalisis, open, close);
      if(promedio <= 0.0) continue;

      double cuerpo = MathAbs(close[i] - open[i]);
      double rango  = high[i] - low[i];

      if(rango < InpTamanoMinimoZona * _Point) continue;
      if(ZonaYaExiste(time[i])) continue;

      bool alcista = (close[i] > open[i]) && (cuerpo >= InpMultiplicadorVelas * promedio);
      bool bajista = (close[i] < open[i]) && (cuerpo >= InpMultiplicadorVelas * promedio);

      if(!alcista && !bajista) continue;

      double zonaAlto, zonaBajo;
      if(!IdentificarZonaBase(i, alcista, open, high, low, close, rates_total, zonaAlto, zonaBajo))
         continue;

      if((zonaAlto - zonaBajo) < InpTamanoMinimoZona * _Point) continue;

      if(ContarZonasActivas() >= InpMaximoZonasEnPantalla)
         EliminarZonaMasAntigua();

      int tipo = alcista ? ZONA_DEMANDA : ZONA_OFERTA;
      CrearZona(tipo, zonaAlto, zonaBajo, time[i], i, time, rates_total);
   }

   ExtenderZonasActivas(time, rates_total);
   ChartRedraw(0);
   return rates_total;
}

//+------------------------------------------------------------------+
double CalcularPromedioCuerpo(const int barra, const int periodo,
                               const double &open[], const double &close[])
{
   double suma  = 0.0;
   int    count = 0;
   int    desde = MathMax(0, barra - periodo);
   for(int j = desde; j < barra; j++)
   {
      suma += MathAbs(close[j] - open[j]);
      count++;
   }
   return (count > 0) ? suma / count : 0.0;
}

//+------------------------------------------------------------------+
bool IdentificarZonaBase(const int barraImpulso,
                          const bool esAlcista,
                          const double &open[],
                          const double &high[],
                          const double &low[],
                          const double &close[],
                          const int rates_total,
                          double &zonaAlto,
                          double &zonaBajo)
{
   double promedio = CalcularPromedioCuerpo(barraImpulso, InpVelasAnalisis, open, close);

   if(esAlcista)
   {
      // Zona de demanda: base inferior del impulso alcista
      zonaBajo = low[barraImpulso];
      zonaAlto = (open[barraImpulso] < close[barraImpulso]) ? open[barraImpulso] : close[barraImpulso];
   }
   else
   {
      // Zona de oferta: techo superior del impulso bajista
      zonaAlto = high[barraImpulso];
      zonaBajo = (open[barraImpulso] > close[barraImpulso]) ? open[barraImpulso] : close[barraImpulso];
   }

   // Expandir con velas de consolidacion previas (hasta 3)
   int velasBase = 0;
   for(int k = barraImpulso - 1; k >= 0 && velasBase < 3; k--)
   {
      double cuerpoK = MathAbs(close[k] - open[k]);
      if(cuerpoK >= promedio * 1.0) break;

      if(low[k]  < zonaBajo) zonaBajo = low[k];
      if(high[k] > zonaAlto) zonaAlto = high[k];
      velasBase++;
   }

   return (zonaAlto > zonaBajo);
}

//+------------------------------------------------------------------+
void CrearZona(const int tipo,
               const double alto, const double bajo,
               const datetime tInicio, const int barraInicio,
               const datetime &time[], const int rates_total)
{
   g_contadorID++;
   int idx = g_totalZonas;
   ArrayResize(g_zonas, g_totalZonas + 1);

   string sufijo     = IntegerToString(g_contadorID);
   string tipoStr    = (tipo == ZONA_DEMANDA) ? "DEM" : "OFR";
   string nombreRect  = PREFIX + tipoStr + "_R_" + sufijo;
   string nombreLabel = PREFIX + tipoStr + "_L_" + sufijo;

   color clrZona = (tipo == ZONA_DEMANDA) ? InpColorDemanda : InpColorOferta;
   datetime tFin = time[rates_total - 1];

   DibujarRectangulo(nombreRect, tInicio, alto, tFin, bajo, clrZona);

   if(InpMostrarEtiquetas)
   {
      string textoLabel = (tipo == ZONA_DEMANDA) ? "DEMANDA" : "OFERTA";
      DibujarEtiqueta(nombreLabel, tInicio, alto, bajo, textoLabel, clrZona);
   }

   g_zonas[idx].tipo         = tipo;
   g_zonas[idx].precioAlto   = alto;
   g_zonas[idx].precioBajo   = bajo;
   g_zonas[idx].tiempoInicio = tInicio;
   g_zonas[idx].barraInicio  = barraInicio;
   g_zonas[idx].activa       = true;
   g_zonas[idx].nombreRect   = nombreRect;
   g_zonas[idx].nombreLabel  = nombreLabel;
   g_zonas[idx].id           = g_contadorID;
   g_totalZonas++;
}

//+------------------------------------------------------------------+
// DibujarRectangulo: version corregida para MT5 fondo oscuro
// CLAVE: En MT5, OBJ_RECTANGLE con OBJPROP_BACK=true se dibuja
// detras de las velas. El color del borde = OBJPROP_COLOR.
// El relleno se activa con OBJPROP_FILL=true y usa el MISMO color.
// NO existe OBJPROP_BGCOLOR para rectangulos en MT5.
//+------------------------------------------------------------------+
void DibujarRectangulo(const string nombre,
                        const datetime t1, const double p1,
                        const datetime t2, const double p2,
                        const color clr)
{
   ObjectDelete(0, nombre);

   if(!ObjectCreate(0, nombre, OBJ_RECTANGLE, 0, t1, p1, t2, p2))
   {
      Print("Error creando rectangulo '", nombre, "': ", GetLastError());
      return;
   }

   // Color del borde: visible y solido
   ObjectSetInteger(0, nombre, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, nombre, OBJPROP_STYLE,      STYLE_SOLID);
   ObjectSetInteger(0, nombre, OBJPROP_WIDTH,      InpGrosorBorde);

   // Relleno: true = rellena con el color del borde (semi-transparente visualmente
   // porque OBJPROP_BACK=true lo pone detras de las velas)
   ObjectSetInteger(0, nombre, OBJPROP_FILL,       InpRellenarZona ? 1 : 0);

   // BACK=true es CRITICO: pone el rectangulo DETRAS de las velas
   // Esto da el efecto de zona semitransparente sin necesidad de canal alfa
   ObjectSetInteger(0, nombre, OBJPROP_BACK,       true);

   ObjectSetInteger(0, nombre, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nombre, OBJPROP_SELECTED,   false);
   ObjectSetInteger(0, nombre, OBJPROP_HIDDEN,     false);
   ObjectSetInteger(0, nombre, OBJPROP_ZORDER,     0);
}

//+------------------------------------------------------------------+
void DibujarEtiqueta(const string nombre,
                      const datetime tiempo,
                      const double alto, const double bajo,
                      const string texto,
                      const color clr)
{
   ObjectDelete(0, nombre);

   double centro = (alto + bajo) / 2.0;

   if(!ObjectCreate(0, nombre, OBJ_TEXT, 0, tiempo, centro))
      return;

   ObjectSetString(0,  nombre, OBJPROP_TEXT,       texto);
   ObjectSetInteger(0, nombre, OBJPROP_COLOR,      clrWhite);
   ObjectSetInteger(0, nombre, OBJPROP_FONTSIZE,   8);
   ObjectSetString(0,  nombre, OBJPROP_FONT,       "Arial Bold");
   ObjectSetInteger(0, nombre, OBJPROP_ANCHOR,     ANCHOR_LEFT);
   ObjectSetInteger(0, nombre, OBJPROP_BACK,       false);
   ObjectSetInteger(0, nombre, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nombre, OBJPROP_HIDDEN,     false);
}

//+------------------------------------------------------------------+
void ActualizarZonasExistentes(const int rates_total,
                                const datetime &time[],
                                const double &high[],
                                const double &low[],
                                const double &close[])
{
   if(!InpEliminarInvalidadas) return;

   for(int z = 0; z < g_totalZonas; z++)
   {
      if(!g_zonas[z].activa) continue;

      int desde = g_zonas[z].barraInicio + 1;
      for(int i = desde; i < rates_total; i++)
      {
         bool invalida = false;

         if(g_zonas[z].tipo == ZONA_DEMANDA)
         {
            if(close[i] < g_zonas[z].precioBajo - (_Point * 3))
               invalida = true;
         }
         else
         {
            if(close[i] > g_zonas[z].precioAlto + (_Point * 3))
               invalida = true;
         }

         if(invalida)
         {
            g_zonas[z].activa = false;

            if(InpOcultarInvalidadas)
            {
               ObjectDelete(0, g_zonas[z].nombreRect);
               ObjectDelete(0, g_zonas[z].nombreLabel);
            }
            else
            {
               // Atenuar a gris y quitar relleno
               ObjectSetInteger(0, g_zonas[z].nombreRect, OBJPROP_COLOR, InpColorInvalidada);
               ObjectSetInteger(0, g_zonas[z].nombreRect, OBJPROP_FILL,  false);
               // Cortar rectangulo en el momento de ruptura
               ObjectSetInteger(0, g_zonas[z].nombreRect, OBJPROP_TIME, 1, (long)time[i]);
               ObjectDelete(0, g_zonas[z].nombreLabel);
            }
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
void ExtenderZonasActivas(const datetime &time[], const int rates_total)
{
   if(rates_total < 1) return;
   datetime tFin = time[rates_total - 1];

   for(int z = 0; z < g_totalZonas; z++)
   {
      if(!g_zonas[z].activa) continue;
      ObjectSetInteger(0, g_zonas[z].nombreRect, OBJPROP_TIME, 1, (long)tFin);
   }
}

//+------------------------------------------------------------------+
bool ZonaYaExiste(const datetime t)
{
   for(int z = 0; z < g_totalZonas; z++)
      if(g_zonas[z].tiempoInicio == t) return true;
   return false;
}

//+------------------------------------------------------------------+
int ContarZonasActivas()
{
   int n = 0;
   for(int z = 0; z < g_totalZonas; z++)
      if(g_zonas[z].activa) n++;
   return n;
}

//+------------------------------------------------------------------+
void EliminarZonaMasAntigua()
{
   int      idx  = -1;
   datetime tMin = TimeCurrent();
   for(int z = 0; z < g_totalZonas; z++)
   {
      if(g_zonas[z].activa && g_zonas[z].tiempoInicio < tMin)
      {
         tMin = g_zonas[z].tiempoInicio;
         idx  = z;
      }
   }
   if(idx >= 0)
   {
      ObjectDelete(0, g_zonas[idx].nombreRect);
      ObjectDelete(0, g_zonas[idx].nombreLabel);
      g_zonas[idx].activa = false;
   }
}

//+------------------------------------------------------------------+
void EliminarTodosLosObjetos()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string nombre = ObjectName(0, i, 0, -1);
      if(StringFind(nombre, PREFIX) == 0)
         ObjectDelete(0, nombre);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE)
      ChartRedraw(0);
}
//+------------------------------------------------------------------+
