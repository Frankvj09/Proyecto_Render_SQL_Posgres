import os
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation
from zoneinfo import ZoneInfo

from flask import Flask, request, jsonify, render_template
from dotenv import load_dotenv

from database import get_connection, BASE_DIR

# ==========================================
# CONFIGURACIÓN
# ==========================================

load_dotenv(BASE_DIR / ".env", override=False)

app = Flask(__name__)

API_KEY = os.getenv("API_KEY", "")

ZONA = ZoneInfo("America/Bogota")

# El ESP32 envía cada 30 s. Pasado este tiempo la lectura se considera sin señal.
SEGUNDOS_MAXIMOS_SIN_DATOS = 120

# Lecturas ADC fuera de este rango indican sensor desconectado o saturado.
ADC_MINIMO = 20
ADC_MAXIMO = 4075

MENSAJES = {
    "Bueno": "El aire está en buenas condiciones. No se requiere ninguna acción.",
    "Medio": "Calidad moderada. Las personas sensibles deberían reducir el "
             "tiempo en este lugar. Conviene ventilar.",
    "Malo": "Calidad mala. Se recomienda ventilar el espacio o salir del "
            "lugar si es posible.",
}


# ==========================================
# UTILIDADES
# ==========================================

def ahora():
    """Hora actual de Colombia (sin zona), igual a como se guardan las lecturas."""
    return datetime.now(ZONA).replace(tzinfo=None)


def validar_api_key():
    """Validar la clave enviada en X-API-Key."""
    if not API_KEY:
        return False
    return request.headers.get("X-API-Key", "") == API_KEY


def nivel_de_puntaje(puntaje):
    if puntaje is None:
        return None
    if puntaje >= 66:
        return "Malo"
    if puntaje >= 33:
        return "Medio"
    return "Bueno"


def num(valor, decimales=4):
    return None if valor is None else round(float(valor), decimales)


def fecha_texto(fecha):
    return fecha.strftime("%Y-%m-%d %H:%M:%S") if fecha else None


def validar_lectura(fecha, adc, tiene_calidad):
    """Comprobar si la última lectura es confiable. Devuelve (valida, motivo)."""
    if fecha is None:
        return False, "Todavía no hay lecturas"

    edad = (ahora() - fecha).total_seconds()

    if edad > SEGUNDOS_MAXIMOS_SIN_DATOS:
        if edad < 3600:
            hace = f"{int(edad // 60)} min"
        elif edad < 86400:
            hace = f"{int(edad // 3600)} h"
        else:
            hace = f"{int(edad // 86400)} días"
        return False, f"Sin señal: la última lectura llegó hace {hace}"

    if adc is None or adc < ADC_MINIMO or adc > ADC_MAXIMO:
        return False, "Valor fuera de rango: revisa el cableado del sensor"

    if not tiene_calidad:
        return False, "No se pudo calcular la calidad (voltaje fuera de rango)"

    return True, "Lectura válida y reciente"


def consultar_estado(cursor, codigo_ubicacion=None):
    """Última lectura ADC (global o de una ubicación) con sus gases."""

    cursor.execute("""
        SELECT m.id_medida, m.fecha_registro, m.valor_medido, m.voltaje,
               s.codigo_sensor, s.es_simulado,
               u.codigo_ubicacion, u.nombre, u.tipo_lugar,
               c.ratio_rs_r0, c.puntaje_ica, c.nivel, gd.nombre
        FROM fact_medidas m
        JOIN dim_tipo_medicion t
             ON t.id_tipo_medicion = m.id_tipo_medicion AND t.codigo_tipo = 'ADC'
        JOIN dim_sensor s    ON s.id_sensor = m.id_sensor
        JOIN dim_ubicacion u ON u.id_ubicacion = m.id_ubicacion
        LEFT JOIN fact_calidad c ON c.id_medida = m.id_medida
        LEFT JOIN dim_gas gd     ON gd.id_gas = c.id_gas_dominante
        WHERE (%s::text IS NULL OR u.codigo_ubicacion = %s)
        ORDER BY m.fecha_registro DESC, m.id_medida DESC
        LIMIT 1
    """, (codigo_ubicacion or None, codigo_ubicacion or None))

    fila = cursor.fetchone()

    if fila is None:
        return None

    (id_medida, fecha, adc, voltaje, sensor, simulado, cod_ubic, ubic,
     tipo_lugar, ratio, puntaje, nivel, gas_dominante) = fila

    cursor.execute("""
        SELECT g.codigo_gas, g.nombre, g.formula, g.unidad,
               fg.concentracion, fg.puntaje,
               g.umbral_medio, g.umbral_malo, g.origen_curva
        FROM fact_gases fg
        JOIN dim_gas g ON g.id_gas = fg.id_gas
        WHERE fg.id_medida = %s
        ORDER BY g.orden
    """, (id_medida,))

    gases = [{
        "codigo": g[0], "nombre": g[1], "formula": g[2], "unidad": g[3],
        "concentracion": num(g[4], 4), "puntaje": num(g[5], 1),
        "nivel": nivel_de_puntaje(float(g[5])),
        "umbral_medio": num(g[6]), "umbral_malo": num(g[7]),
        "origen": g[8],
    } for g in cursor.fetchall()]

    valida, motivo = validar_lectura(fecha, float(adc), nivel is not None)

    return {
        "fecha": fecha_texto(fecha),
        "adc": num(adc, 1),
        "voltaje": num(voltaje, 3),
        "sensor": sensor,
        "simulado": bool(simulado),
        "ubicacion": {"codigo": cod_ubic, "nombre": ubic, "tipo": tipo_lugar},
        "ratio": num(ratio, 3),
        "puntaje": num(puntaje, 1),
        "nivel": nivel,
        "gas_dominante": gas_dominante,
        "mensaje": MENSAJES.get(nivel, ""),
        "valida": valida,
        "motivo_validacion": motivo,
        "gases": gases,
    }


# ==========================================
# PÁGINA PRINCIPAL
# ==========================================

@app.route("/", methods=["GET"])
def inicio():
    return render_template("index.html")


# ==========================================
# ESTADO DEL SERVIDOR Y LA BASE DE DATOS
# ==========================================

@app.route("/api/health", methods=["GET"])
def health():
    try:
        with get_connection() as conexion:
            conexion.execute("SELECT 1")

        return jsonify({
            "ok": True,
            "estado": "activo",
            "mensaje": "Conexión con PostgreSQL exitosa",
            "proyecto": "Monitoreo de calidad del aire",
            "base_datos": "PostgreSQL"
        }), 200

    except Exception as error:
        app.logger.exception("Error al conectar con la base de datos")
        return jsonify({"ok": False, "estado": "error", "error": str(error)}), 500


# ==========================================
# ESTADÍSTICAS Y ESTADO ACTUAL
# ==========================================

@app.route("/api/estadisticas", methods=["GET"])
def estadisticas():
    """Totales + última lectura validada. Parámetro opcional: ubicacion."""

    try:
        with get_connection() as conexion:
            cursor = conexion.cursor()

            cursor.execute("SELECT COUNT(*) FROM fact_medidas")
            total = cursor.fetchone()[0] or 0

            estado = consultar_estado(cursor, request.args.get("ubicacion"))

        return jsonify({
            "ok": True,
            "total_lecturas": total,
            "ultima_lectura": estado["adc"] if estado else None,
            "ultima_fecha": estado["fecha"] if estado else None,
            "estado": estado,
        }), 200

    except Exception as error:
        app.logger.exception("Error al consultar estadísticas")
        return jsonify({"ok": False, "error": str(error)}), 500


# ==========================================
# SERIE DE TIEMPO PARA LAS GRÁFICAS
# ==========================================

@app.route("/api/serie", methods=["GET"])
def serie():
    """Serie agregada de una ubicación. Parámetros: ubicacion, minutos."""

    codigo = request.args.get("ubicacion", "")
    minutos = request.args.get("minutos", default=60, type=int)
    minutos = max(10, min(minutos, 1440))

    # Hasta ~120 puntos por gráfica: se promedian lecturas en "cubetas" de tiempo.
    cubeta = max(1, minutos // 120)
    segundos_cubeta = cubeta * 60

    try:
        with get_connection() as conexion:
            cursor = conexion.cursor()

            cursor.execute("""
                SELECT x.cb, x.codigo_gas,
                       AVG(x.concentracion) AS concentracion,
                       AVG(x.puntaje_ica)   AS puntaje_ica
                FROM (
                    SELECT FLOOR(EXTRACT(EPOCH FROM m.fecha_registro) / %s)::BIGINT AS cb,
                           g.codigo_gas, fg.concentracion, c.puntaje_ica
                    FROM fact_medidas m
                    JOIN dim_ubicacion u ON u.id_ubicacion = m.id_ubicacion
                    JOIN fact_calidad c  ON c.id_medida = m.id_medida
                    JOIN fact_gases fg   ON fg.id_medida = m.id_medida
                    JOIN dim_gas g       ON g.id_gas = fg.id_gas
                    WHERE u.codigo_ubicacion = %s
                      AND m.fecha_registro >= %s
                ) x
                GROUP BY x.cb, x.codigo_gas
                ORDER BY x.cb
            """, (segundos_cubeta, codigo, ahora() - timedelta(minutes=minutos)))

            filas = cursor.fetchall()

            etiquetas, ica, gases = [], {}, {}

            for cb, gas, conc, puntaje in filas:
                # cb está en "hora de pared" de Colombia expresada como época
                clave = fecha_texto(datetime.utcfromtimestamp(int(cb) * segundos_cubeta))
                if clave not in ica:
                    etiquetas.append(clave)
                    ica[clave] = num(puntaje, 1)
                gases.setdefault(gas, {})[clave] = num(conc, 4)

            cursor.execute("""
                SELECT codigo_gas, nombre, formula, unidad, umbral_medio, umbral_malo
                FROM dim_gas ORDER BY orden
            """)

            catalogo = [{
                "codigo": g[0], "nombre": g[1], "formula": g[2], "unidad": g[3],
                "umbral_medio": num(g[4]), "umbral_malo": num(g[5]),
            } for g in cursor.fetchall()]

        return jsonify({
            "ok": True,
            "etiquetas": etiquetas,
            "ica": [ica[e] for e in etiquetas],
            "gases": {
                codigo_gas: [valores.get(e) for e in etiquetas]
                for codigo_gas, valores in gases.items()
            },
            "catalogo": catalogo,
        }), 200

    except Exception as error:
        app.logger.exception("Error al consultar la serie")
        return jsonify({"ok": False, "error": str(error)}), 500


# ==========================================
# MAPA: ÚLTIMA LECTURA POR UBICACIÓN
# ==========================================

@app.route("/api/mapa", methods=["GET"])
def mapa():

    try:
        with get_connection() as conexion:
            cursor = conexion.cursor()

            cursor.execute("""
                SELECT "Codigo_ubicacion", "Ubicacion", "Tipo_lugar", "Latitud", "Longitud",
                       "Fecha", "Lectura_ADC", "Puntaje_ICA", "Nivel", "Gas_dominante",
                       "Codigo_sensor"
                FROM "vw_UltimaPorUbicacion"
                ORDER BY "Ubicacion"
            """)

            filas = cursor.fetchall()

        puntos = []

        for f in filas:
            valida, motivo = validar_lectura(f[5], float(f[6]), f[8] is not None)
            puntos.append({
                "codigo": f[0], "nombre": f[1], "tipo": f[2],
                "lat": float(f[3]), "lon": float(f[4]),
                "fecha": fecha_texto(f[5]),
                "puntaje": num(f[7], 1), "nivel": f[8],
                "gas_dominante": f[9], "sensor": f[10],
                "reciente": valida, "motivo": motivo,
            })

        return jsonify({"ok": True, "ubicaciones": puntos}), 200

    except Exception as error:
        app.logger.exception("Error al consultar el mapa")
        return jsonify({"ok": False, "error": str(error)}), 500


# ==========================================
# RECEPCIÓN DE MEDICIONES DEL ESP32
# ==========================================

@app.route("/api/mediciones", methods=["POST"])
def registrar_medicion():
    """Recibir y registrar mediciones del ESP32."""

    if not validar_api_key():
        return jsonify({"ok": False, "error": "Clave API ausente o incorrecta"}), 401

    datos = request.get_json(silent=True)

    if not isinstance(datos, dict):
        return jsonify({"ok": False, "error": "Envía un objeto JSON válido"}), 400

    codigo_sensor = datos.get("codigo_sensor")
    codigo_ubicacion = datos.get("codigo_ubicacion")
    codigo_tipo = datos.get("codigo_tipo")
    valor = datos.get("valor")
    voltaje = datos.get("voltaje", 0)

    if not all([
        isinstance(codigo_sensor, str) and codigo_sensor.strip(),
        isinstance(codigo_ubicacion, str) and codigo_ubicacion.strip(),
        isinstance(codigo_tipo, str) and codigo_tipo.strip()
    ]):
        return jsonify({
            "ok": False,
            "error": "Se requieren codigo_sensor, codigo_ubicacion y codigo_tipo como textos no vacíos"
        }), 400

    try:
        valor = Decimal(str(valor))
        voltaje = Decimal(str(voltaje))

        if not valor.is_finite() or not voltaje.is_finite():
            raise InvalidOperation

        if voltaje < 0:
            return jsonify({"ok": False, "error": "El voltaje no puede ser negativo"}), 400

    except (InvalidOperation, ValueError, TypeError):
        return jsonify({"ok": False, "error": "valor y voltaje deben ser números válidos"}), 400

    try:
        with get_connection() as conexion:
            conexion.execute(
                "SELECT registrar_medida(%s, %s, %s, %s, %s)",
                (codigo_sensor.strip(), codigo_ubicacion.strip(),
                 codigo_tipo.strip(), valor, voltaje)
            )
            # al salir del bloque "with" sin error, psycopg confirma (commit)

        return jsonify({
            "ok": True,
            "mensaje": "Medición registrada correctamente",
            "codigo_sensor": codigo_sensor,
            "codigo_ubicacion": codigo_ubicacion,
            "codigo_tipo": codigo_tipo,
            "valor": str(valor),
            "voltaje": str(voltaje)
        }), 201

    except Exception as error:
        app.logger.exception("Error al registrar la medición")
        mensaje = str(error).split("\n")[0]
        return jsonify({"ok": False, "error": mensaje}), 500


# ==========================================
# EJECUCIÓN LOCAL (en Render se usa gunicorn)
# ==========================================

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5000")), debug=False)
