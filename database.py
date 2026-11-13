import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env", override=False)


def get_connection():
    """Conectar a PostgreSQL usando la variable DATABASE_URL.

    En Render la define el propio servicio (URL interna de la base).
    En tu PC ponla en el archivo .env.
    """
    url = os.getenv("DATABASE_URL", "").strip()

    if not url:
        raise RuntimeError("Falta la variable de entorno DATABASE_URL")

    return psycopg.connect(url, connect_timeout=10)
