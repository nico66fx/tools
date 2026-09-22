# Datos de tick reales de Dukascopy dentro de MetaTrader 5, automático

**Cómo se usa:** abre Claude Code en una carpeta vacía, en el mismo ordenador donde tengas instalado MetaTrader 5, y pega este prompt entero. No hace falta que sepas programar ni que contestes nada por el camino.

---

Vas a construir y ejecutar, de principio a fin y sin pedir confirmación, una tubería que descargue datos históricos de tick de Dukascopy y los deje instalados dentro de MetaTrader 5 como símbolo personalizado, listos para usar en el Probador de Estrategias en modo *Every tick based on real ticks*.

**Trabaja de forma autónoma.** Toma tú las decisiones, aplica valores por defecto razonables y sigue adelante. La única excepción está en la comprobación previa: si MetaTrader 5 no aparece, te paras y avisas. En todo lo demás, no preguntes: decide, documenta lo que decidiste y continúa.

Trabaja en `./duka/`.

---

## Configuración

Usa estos valores. Están al principio para que quien lo lance pueda cambiarlos si quiere, pero funcionan tal cual:

```
SIMBOLOS        EURUSD
DESDE           2018-01-01
HASTA           hoy
SUFIJO          _DUKA
PRIMERA_PASADA  1 mes
```

Empieza siempre descargando **un solo mes**, pásalo entero por la tubería hasta tenerlo dentro de MetaTrader, y solo cuando esté verificado escala al rango completo. Así, si algo está mal, se ve en dos minutos y no en seis horas.

---

## Fase 0 · Comprobación previa

Localiza la instalación de MetaTrader 5 y su carpeta de datos, donde están `MQL5/Files` y `MQL5/Scripts`:

- **Windows:** bajo `%APPDATA%\MetaQuotes\Terminal\<hash>\`
- **macOS:** dentro del contenedor de Wine, normalmente en `~/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/<usuario>/AppData/Roaming/MetaQuotes/Terminal/<hash>/`
- **Linux:** bajo el prefijo de Wine que corresponda

Si encuentras **varios terminales**, quédate con el de modificación más reciente, dilo claramente y sigue.

**Si no encuentras ninguno, párate aquí.** No construyas nada, no descargues nada. Escribe un aviso claro diciendo que no se ha detectado ninguna instalación de MetaTrader 5 en este equipo, en qué rutas has buscado, y que este proceso necesita ejecutarse en el mismo ordenador donde esté instalado el terminal. Y termina ahí.

Si lo encuentras, comprueba también que puedes escribir en `MQL5/Files` y `MQL5/Scripts`. Si no puedes, mismo trato: aviso claro y parada.

---

## Fase 1 · Descarga

Prueba en este orden y quédate con la primera que funcione:

1. `tick-vault` — `pip install tick-vault`
2. `dukascopy-node` — vía npm
3. Un decodificador propio, solo si las dos anteriores fallan

Si acabas escribiendo el decodificador, este es el formato conocido, **pero trátalo como hipótesis a verificar, no como hecho**:

- URL: `https://datafeed.dukascopy.com/datafeed/{SIMBOLO}/{AAAA}/{MM}/{DD}/{HH}h_ticks.bi5`
- Un archivo por hora, comprimido con **LZMA**
- Registros de **20 bytes**, big-endian, `>3i2f`: milisegundos desde el inicio de la hora, dos precios y dos volúmenes

La descarga tiene que ser **reanudable**: si se corta, al relanzar continúa donde iba y no vuelve a bajar lo que ya tiene. Guarda los `.bi5` en crudo en `./duka/raw/` para no depender de la red en cada prueba. Espacia las peticiones para no castigar el servidor, y reintenta con espera creciente ante errores de red. Las horas de fin de semana no existen: que un archivo falte no es un error.

---

## Fase 2 · Resolver las ambigüedades tú mismo

Hay tres cosas que las fuentes públicas se contradicen. **Resuélvelas por experimento, no por documentación, y no me preguntes.**

**El mes en la URL.** Unas fuentes dicen que va de 0 a 11 y otras que de 1 a 12. Descarga una hora conocida de mercado abierto con las dos convenciones y quédate con la que devuelve un archivo con contenido. Deja escrito cuál era.

**Cuál de los dos precios es el ask.** Decodifica unos miles de ticks y mira qué campo es sistemáticamente mayor. Ese es el ask. Si no hay un ganador claro, algo va mal en la decodificación: párate y dilo.

**El factor de escala.** Lo habitual es dividir entre 100.000, pero no vale para todos los activos: los pares con yen y los metales usan otra escala. Determínalo así, en este orden:

1. Si MetaTrader ya tiene ese símbolo del bróker, extrae el precio de cierre de una vela diaria de una fecha cualquiera del rango.
2. Prueba los divisores candidatos (10³, 10⁴, 10⁵) y quédate con el que deja el precio decodificado dentro de un ±1 % del precio de referencia.
3. Si el símbolo no existe en el terminal, usa el número de dígitos que declara el activo para deducirlo.

Si ningún divisor encaja, **no lo fuerces con un número mágico**: para y explica qué obtuviste.

---

## Fase 3 · Validación automática

Escribe `validar.py` y ejecútalo sobre el primer mes. Tiene que comprobar, y dejar el resultado por escrito:

- El ask es mayor o igual que el bid en prácticamente todos los ticks.
- El spread medio es un número creíble para ese activo — ni cero, ni cuarenta pips.
- Las marcas de tiempo crecen dentro de cada hora y no hay duplicados exactos.
- Hay ticks en horario de mercado y no los hay en fin de semana.
- El máximo y el mínimo del periodo encajan con los de la vela correspondiente en MetaTrader, si el símbolo del bróker está disponible.
- El recuento de huecos: qué horas de mercado abierto se quedaron sin archivo.

**Si alguna comprobación falla, no sigas a la fase 4.** Escribe qué falló y para. Un fallo aquí significa datos corruptos, y meter datos corruptos en el terminal es peor que no meter nada.

---

## Fase 4 · Desfase horario

Dukascopy publica en **UTC**. Casi ningún servidor de bróker está en UTC, y si no lo corriges, todo lo que dependa de la hora queda desplazado.

Determínalo tú, automáticamente: coge las velas M1 del símbolo del bróker desde MetaTrader para un tramo del mismo periodo, construye velas M1 desde los ticks de Dukascopy, y busca el desplazamiento en horas enteras que mejor las alinea. Ese es el desfase. Aplícalo al escribir los archivos.

Si el símbolo del bróker no está disponible en el terminal, escribe los datos en UTC y **déjalo señalado en grande** en el informe final, explicando que hay que corregirlo a mano.

---

## Fase 5 · Formato de MetaTrader

Genera en `MQL5/Files/` un archivo separado por tabuladores con exactamente estas columnas y en este orden:

```
<DATE> <TIME> <BID> <ASK> <LAST> <VOLUME>
```

- Fecha y hora en `AAAA.MM.DD HH:MM:SS.mmm`, con milisegundos.
- `LAST` y `VOLUME` a `0` si no hay dato.
- Línea de ejemplo válida: `2018.01.03	00:03:47.212	1.20161	1.20174	0.00000	0`

Genera además la variante en **barras de un minuto**, como respaldo:

```
<DATE> <TIME> <OPEN> <HIGH> <LOW> <CLOSE> <TICKVOL> <VOL> <SPREAD>
```
con la hora en `AAAA.MM.DD HH:MM:SS`, sin milisegundos.

Si el rango completo da un archivo enorme, trocéalo por años y numera los trozos.

---

## Fase 6 · Meterlos dentro del terminal

Escribe `ImportarTicksDuka.mq5` en `MQL5/Scripts/`. Al ejecutarse tiene que:

1. Crear el símbolo personalizado con `CustomSymbolCreate()`, **clonando las propiedades del símbolo original del bróker** si existe — dígitos, tamaño de contrato, tick size y tick value — para que el Probador calcule bien. Nombre: el del activo más el sufijo configurado, por ejemplo `EURUSD_DUKA`.
2. Leer el CSV **por bloques**, nunca entero en memoria: el archivo puede pesar varios gigas.
3. Rellenar un array de `MqlTick` con `bid`, `ask`, `time`, `time_msc` y los flags correctos.
4. Inyectarlo con `CustomTicksReplace()` por tramos, informando del progreso en el registro.
5. Ser **idempotente**: ejecutarlo dos veces no debe duplicar nada.
6. Al terminar, imprimir cuántos ticks entraron, el primer y el último instante, y cualquier tramo rechazado.

Coméntalo en español y de forma legible.

**Restricciones de seguridad, sin excepciones:** este script solo crea símbolos personalizados con el sufijo configurado y solo escribe dentro de `MQL5/Files` y `MQL5/Scripts`. No toca símbolos reales del bróker, no modifica ninguna configuración del terminal, no abre ni cierra operaciones, y no interactúa con la cuenta de trading de ninguna manera.

---

## Fase 7 · Verificación final

Después de importar, comprueba desde dentro de MetaTrader que los ticks están de verdad:

- Lee de vuelta un tramo del símbolo personalizado y compara el recuento con las líneas del CSV.
- Comprueba que el primer y el último instante coinciden con lo esperado.
- Comprueba que el símbolo aparece disponible para el Probador de Estrategias.

Si el recuento no cuadra, dilo con el número exacto de diferencia en lugar de darlo por bueno.

---

## Reglas

- **Ni una cifra inventada.** Todo número del informe sale de una ejecución real. Lo que no se pudo medir, se dice que no se pudo medir.
- **Si algo falla tres veces seguidas, para y explica.** No des vueltas sobre el mismo error.
- Todo reproducible: si se borra `./duka/` y se relanza, tiene que salir lo mismo.

---

## Entregables

Al terminar, en `./duka/`:

- [ ] `descargar.py` (o equivalente), reanudable
- [ ] `validar.py` y su salida completa
- [ ] El CSV de ticks en formato MetaTrader, y la variante de barras M1
- [ ] `ImportarTicksDuka.mq5`, ya ejecutado y verificado
- [ ] `README.md` con: qué terminal se usó, qué convención de mes resultó ser la correcta, qué factor de escala se aplicó y por qué, qué desfase horario se aplicó y cómo se determinó, cuántos ticks entraron, qué huecos hay y cómo repetirlo todo desde cero

---

## Advertencia sobre los datos

Los datos de Dukascopy **no son los de tu bróker**. Sirven para comprobar si una estrategia tiene sentido, no para predecir el resultado exacto que tendrás en tu cuenta: el spread, la comisión, el horario del servidor y el deslizamiento son distintos. Que esta advertencia aparezca en el `README.md` final.
