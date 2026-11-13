# Despliegue en Render (paso a paso)

Estructura del proyecto: `app.py`, `database.py`, `requirements.txt`, `.python-version`,
`templates/`, `static/`, `sql/postgres_completo.sql`, `simulador.py`.

> **Copia el logo:** pon `udec.png` (de tu proyecto anterior) en `static/img/udec.png`.
> No lo pude incluir porque no tengo ese archivo.

## 1. Subir el proyecto a GitHub
1. Crea un repositorio en github.com (puede ser privado).
2. Sube TODA esta carpeta (el `.gitignore` ya excluye `.env`).
   Con Git instalado, dentro de la carpeta:
   ```
   git init
   git add .
   git commit -m "Monitoreo de calidad del aire"
   git branch -M main
   git remote add origin https://github.com/TU_USUARIO/TU_REPO.git
   git push -u origin main
   ```

## 2. Crear la base de datos en Render
1. En dashboard.render.com: **New → PostgreSQL**. Nombre `aire-db`, plan **Free**,
   elige una región (usa la MISMA para el servicio web).
2. Cuando esté lista, abre la base y copia:
   - **External Database URL** (para cargar el script desde tu PC)
   - **Internal Database URL** (para el servicio web)
3. Anota la fecha: la base gratuita **vence a los 30 días** de crearla
   (14 días de gracia y luego se borra). Créala cerca de tu fecha de entrega.

## 3. Cargar tablas y datos de prueba
Con `psql` (viene con PostgreSQL), desde la carpeta del proyecto:
```
psql "EXTERNAL_DATABASE_URL" -f sql/postgres_completo.sql
```
Sin `psql`: en pgAdmin o DBeaver conéctate con los datos de la External URL, abre
`sql/postgres_completo.sql` en el editor de consultas y ejecútalo completo.
Al final debe mostrar `1728` medidas y 6 ubicaciones.

## 4. Crear el servicio web
1. **New → Web Service** → conecta tu repositorio de GitHub.
2. Configuración:
   - **Runtime:** Python 3
   - **Build Command:** `pip install -r requirements.txt`
   - **Start Command:** `gunicorn app:app`
   - **Instance Type:** Free
3. En **Environment** agrega:
   - `DATABASE_URL` = la **Internal** Database URL
   - `API_KEY` = una clave nueva, larga y aleatoria
4. **Create Web Service**. Cuando termine, abre `https://TU-SERVICIO.onrender.com/api/health`
   (debe decir `"ok": true`) y luego la raíz `/`.

## 5. Ajustar el ESP32
Render solo acepta HTTPS. En tu código del ESP32 cambia:
```cpp
#include <WiFiClientSecure.h>          // agregar junto a los otros #include

const char* API_URL = "https://TU-SERVICIO.onrender.com/api/mediciones";
const char* API_KEY = "LA_MISMA_CLAVE_NUEVA_DE_RENDER";
```
y en la función que envía, reemplaza `WiFiClient cliente;` por:
```cpp
  WiFiClientSecure cliente;
  cliente.setInsecure();     // no verifica el certificado del servidor
```
y sube el tiempo de espera, porque el servicio gratuito tarda hasta ~1 minuto en despertar:
```cpp
  http.setTimeout(60000);
```
(`setInsecure()` cifra la conexión pero no comprueba la identidad del servidor;
es suficiente para este proyecto.)

## 6. Probar sin el sensor físico
En tu PC, con un `.env` que tenga:
```
API_KEY=LA_CLAVE_DE_RENDER
SIM_URL=https://TU-SERVICIO.onrender.com/api/mediciones
```
ejecuta `python simulador.py`. Después de 30 s el panel mostrará lecturas nuevas.

## 7. Cuando ya tengas lecturas reales
Borra los datos de prueba (en psql/pgAdmin):
```sql
DELETE FROM fact_medidas WHERE es_demo;
```
Y calibra el sensor real (10 min en aire limpio):
```sql
SELECT calibrar_r0('MQ135-REAL-001', 10);
```

## 8. Power BI
Las vistas tienen los mismos nombres y columnas que en SQL Server
(`vw_Lecturas`, `vw_Gases`, `vw_UltimaPorUbicacion`, `DIM_Ubicacion`, `DIM_Gas`, `DIM_Sensor`),
así que solo hay que cambiar el origen de cada consulta. En Power BI Desktop:
**Inicio → Transformar datos**, selecciona una consulta → **Editor avanzado** y reemplaza todo por
(cambiando `Item` según la consulta):
```
let
    Origen = PostgreSQL.Database("HOST_EXTERNO:5432", "NOMBRE_BASE"),
    Tabla  = Origen{[Schema="public", Item="vw_Lecturas"]}[Data]
in
    Tabla
```
`HOST_EXTERNO` y `NOMBRE_BASE` salen de la External URL
(`postgresql://usuario:clave@HOST_EXTERNO/NOMBRE_BASE`). Pide usuario y contraseña de Render.
Si Power BI exige el proveedor Npgsql, instálalo desde el enlace que muestra el mensaje.
Con la base en internet, normalmente ya no necesitas la puerta de enlace para la actualización programada.
Después: **Cerrar y aplicar**, volver a publicar y revisar las credenciales en el servicio.

## Límites del plan gratuito (verificados en la documentación de Render)
- Servicio web: se duerme a los 15 min sin tráfico (el ESP32 enviando cada 30 s lo mantiene activo).
  750 horas gratis al mes por espacio de trabajo.
- Base: 1 GB y vence a los 30 días de creada.
