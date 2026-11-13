"""
Simulador de los sensores MQ135-SIM-002 y MQ135-SIM-003.
Envía una lectura cada 30 s a la API, igual que el ESP32, para ver
las gráficas y el mapa moviéndose sin tener 3 sensores físicos.

Uso (con app.py en ejecución):   python simulador.py
"""
import json
import math
import os
import random
import time
import urllib.request
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent / ".env", override=True)

URL = os.getenv("SIM_URL", "http://localhost:5000/api/mediciones")
API_KEY = os.getenv("API_KEY", "")

# Mismos valores por defecto que DIM_Sensor
VCC, RL, R0, FACTOR = 5.0, 10.0, 20.0, 1.0

# (sensor, ubicación, Rs/R0 típico, variación por hora pico)
PERFILES = [
    ("MQ135-SIM-002", "UBICACION-003", 0.75, 0.10),   # Centro comercial
    ("MQ135-SIM-003", "UBICACION-005", 0.62, 0.10),   # Avenida principal
]


def ratio_actual(base, amp):
    hora = datetime.now().hour
    pico = 1.0 if hora in (7, 8, 9, 17, 18, 19) else 0.5 if 10 <= hora <= 16 else 0.1
    return max(0.25, base - amp * pico + random.uniform(-0.03, 0.03))


def enviar(sensor, ubicacion, ratio):
    rs = ratio * R0
    v_modulo = VCC * RL / (rs + RL)
    v_pin = v_modulo / FACTOR
    adc = v_pin / 3.3 * 4095

    cuerpo = json.dumps({
        "codigo_sensor": sensor,
        "codigo_ubicacion": ubicacion,
        "codigo_tipo": "ADC",
        "valor": round(adc, 1),
        "voltaje": round(v_pin, 3),
    }).encode()

    pedido = urllib.request.Request(
        URL, data=cuerpo, method="POST",
        headers={"Content-Type": "application/json", "X-API-Key": API_KEY},
    )
    with urllib.request.urlopen(pedido, timeout=10) as r:
        print(datetime.now().strftime("%H:%M:%S"), sensor, ubicacion,
              f"ADC={adc:.0f}", "HTTP", r.status)


if __name__ == "__main__":
    print("Simulando sensores. Ctrl+C para detener.")
    while True:
        for sensor, ubicacion, base, amp in PERFILES:
            try:
                enviar(sensor, ubicacion, ratio_actual(base, amp))
            except Exception as error:
                print("Error:", error)
        time.sleep(30)
