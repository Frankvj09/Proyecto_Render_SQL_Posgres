/* ==========================================================
   MONITOREO DE CALIDAD DEL AIRE - Script completo para PostgreSQL
   Para la base de datos de Render (o cualquier PostgreSQL 14+).

   !!! BORRA todo el esquema public y lo recrea con datos de prueba.
   Los timestamps se guardan en hora de Colombia (America/Bogota).
   ========================================================== */

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

/* ---------- 1. DIMENSIONES ---------- */

CREATE TABLE dim_ubicacion (
    id_ubicacion     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_ubicacion VARCHAR(30)  NOT NULL UNIQUE,
    nombre           VARCHAR(80)  NOT NULL,
    tipo_lugar       VARCHAR(40)  NOT NULL,
    latitud          NUMERIC(9,6) NOT NULL,
    longitud         NUMERIC(9,6) NOT NULL
);

CREATE TABLE dim_sensor (
    id_sensor      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_sensor  VARCHAR(30)   NOT NULL UNIQUE,
    modelo         VARCHAR(20)   NOT NULL DEFAULT 'MQ-135',
    vcc            NUMERIC(4,2)  NOT NULL DEFAULT 5.00,    -- alimentación del módulo
    rl_kohm        NUMERIC(8,2)  NOT NULL DEFAULT 10.00,   -- resistencia de carga
    r0_kohm        NUMERIC(10,3) NOT NULL DEFAULT 20.000,  -- Rs en aire limpio (CALIBRAR)
    factor_divisor NUMERIC(6,3)  NOT NULL DEFAULT 1.000,   -- (R1+R2)/R2 si usas divisor
    es_simulado    BOOLEAN       NOT NULL DEFAULT FALSE,
    activo         BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE dim_tipo_medicion (
    id_tipo_medicion INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_tipo      VARCHAR(20) NOT NULL UNIQUE,
    descripcion      VARCHAR(80) NOT NULL
);

/* concentración = base * (Rs/R0) ^ -B   (estimación, ver nota en la página) */
CREATE TABLE dim_gas (
    id_gas             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_gas         VARCHAR(10)   NOT NULL UNIQUE,
    nombre             VARCHAR(40)   NOT NULL,
    formula            VARCHAR(12)   NOT NULL,
    unidad             VARCHAR(10)   NOT NULL,
    concentracion_base NUMERIC(18,6) NOT NULL,
    pendiente_b        NUMERIC(8,4)  NOT NULL,
    umbral_medio       NUMERIC(18,6) NOT NULL,
    umbral_malo        NUMERIC(18,6) NOT NULL,
    origen_curva       VARCHAR(60)   NOT NULL,
    orden              INT           NOT NULL
);

/* ---------- 2. HECHOS ---------- */

CREATE TABLE fact_medidas (
    id_medida        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_sensor        INT NOT NULL REFERENCES dim_sensor(id_sensor),
    id_ubicacion     INT NOT NULL REFERENCES dim_ubicacion(id_ubicacion),
    id_tipo_medicion INT NOT NULL REFERENCES dim_tipo_medicion(id_tipo_medicion),
    valor_medido     NUMERIC(10,2) NOT NULL,
    voltaje          NUMERIC(6,3)  NOT NULL DEFAULT 0,
    fecha_registro   TIMESTAMP(0)  NOT NULL DEFAULT (now() AT TIME ZONE 'America/Bogota'),
    es_demo          BOOLEAN       NOT NULL DEFAULT FALSE
);
CREATE INDEX ix_medidas_fecha ON fact_medidas (fecha_registro DESC);
CREATE INDEX ix_medidas_ubic  ON fact_medidas (id_ubicacion, fecha_registro DESC);

CREATE TABLE fact_calidad (
    id_medida        BIGINT PRIMARY KEY REFERENCES fact_medidas(id_medida) ON DELETE CASCADE,
    rs_kohm          NUMERIC(10,3) NOT NULL,
    ratio_rs_r0      NUMERIC(8,4)  NOT NULL,
    puntaje_ica      NUMERIC(5,2)  NOT NULL,        -- 0 a 100
    nivel            VARCHAR(10)   NOT NULL,        -- Bueno / Medio / Malo
    id_gas_dominante INT           NOT NULL REFERENCES dim_gas(id_gas)
);

CREATE TABLE fact_gases (
    id_medida     BIGINT NOT NULL REFERENCES fact_medidas(id_medida) ON DELETE CASCADE,
    id_gas        INT    NOT NULL REFERENCES dim_gas(id_gas),
    concentracion NUMERIC(18,6) NOT NULL,
    puntaje       NUMERIC(5,2)  NOT NULL,
    PRIMARY KEY (id_medida, id_gas)
);

/* ---------- 3. DATOS BASE ---------- */

INSERT INTO dim_tipo_medicion (codigo_tipo, descripcion)
VALUES ('ADC', 'Lectura analógica del ESP32 (0-4095)');

/* Coordenadas de EJEMPLO: cámbialas por las reales. */
INSERT INTO dim_ubicacion (codigo_ubicacion, nombre, tipo_lugar, latitud, longitud) VALUES
('UBICACION-001', 'Universidad',         'Educativo',   4.8600, -74.0330),
('UBICACION-002', 'Parque principal',    'Parque',      4.8625, -74.0590),
('UBICACION-003', 'Centro comercial',    'Comercial',   4.8700, -74.0480),
('UBICACION-004', 'Parqueadero central', 'Parqueadero', 4.8560, -74.0520),
('UBICACION-005', 'Avenida principal',   'Vía',         4.8650, -74.0650),
('UBICACION-006', 'Plaza de mercado',    'Mercado',     4.8590, -74.0620);

INSERT INTO dim_sensor (codigo_sensor, es_simulado) VALUES
('MQ135-REAL-001', FALSE),
('MQ135-SIM-002',  TRUE),
('MQ135-SIM-003',  TRUE);

INSERT INTO dim_gas
(codigo_gas, nombre, formula, unidad, concentracion_base, pendiente_b, umbral_medio, umbral_malo, origen_curva, orden)
VALUES
('CO2', 'Dióxido de carbono',  'CO₂',   'ppm', 420,   2.769, 1000, 2000, 'Datasheet (ajuste)',        1),
('NH3', 'Amoníaco',            'NH₃',   'ppm', 0.5,   2.473, 10,   25,   'Datasheet (ajuste)',        2),
('ALC', 'Alcohol (etanol)',    'C₂H₆O', 'ppm', 0.5,   3.180, 50,   200,  'Datasheet (ajuste)',        3),
('BEN', 'Benceno',             'C₆H₆',  'ppm', 0.005, 3.445, 0.1,  1,    'Curva de tolueno (aprox.)', 4),
('HUM', 'Humo',                'CO eq.','ppm', 0.5,   3.937, 9,    35,   'Curva de CO (aprox.)',      5),
('NOX', 'Óxidos de nitrógeno', 'NOx',   'ppm', 0.02,  2.500, 0.05, 0.1,  'Supuesto (sin curva)',      6);

/* ---------- 4. FUNCIONES ---------- */

/* Puntaje 0-100: 0-33 Bueno | 33-66 Medio | 66-100 Malo */
CREATE FUNCTION fn_puntaje(c NUMERIC, medio NUMERIC, malo NUMERIC)
RETURNS NUMERIC(5,2) LANGUAGE sql IMMUTABLE AS $$
    SELECT LEAST(100,
        CASE WHEN c < medio THEN 33.0 * c / medio
             WHEN c < malo  THEN 33.0 + 33.0 * (c - medio) / (malo - medio)
             ELSE 66.0 + 34.0 * (c - malo) / malo END)::NUMERIC(5,2)
$$;

/* Calcula gases y calidad para un rango de id_medida (solo las que faltan) */
CREATE FUNCTION calcular_calidad(p_desde BIGINT, p_hasta BIGINT)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    WITH r AS (
        SELECT m.id_medida,
               ((s.vcc - v.vm) / v.vm) * s.rl_kohm              AS rs,
               (((s.vcc - v.vm) / v.vm) * s.rl_kohm) / s.r0_kohm AS ratio
        FROM fact_medidas m
        JOIN dim_sensor s        ON s.id_sensor = m.id_sensor
        JOIN dim_tipo_medicion t ON t.id_tipo_medicion = m.id_tipo_medicion
                                AND t.codigo_tipo = 'ADC'
        CROSS JOIN LATERAL (SELECT m.voltaje * s.factor_divisor AS vm) v
        WHERE m.id_medida BETWEEN p_desde AND p_hasta
          AND v.vm > 0.05 AND v.vm < s.vcc - 0.05
          AND NOT EXISTS (SELECT 1 FROM fact_calidad c WHERE c.id_medida = m.id_medida)
    ),
    r2 AS (SELECT * FROM r WHERE ratio BETWEEN 0.05 AND 20),
    g AS (
        INSERT INTO fact_gases (id_medida, id_gas, concentracion, puntaje)
        SELECT r2.id_medida, d.id_gas, x.conc,
               fn_puntaje(x.conc, d.umbral_medio, d.umbral_malo)
        FROM r2
        CROSS JOIN dim_gas d
        CROSS JOIN LATERAL (
            SELECT (d.concentracion_base *
                    power(r2.ratio::float8, -d.pendiente_b::float8))::NUMERIC(18,6) AS conc
        ) x
        RETURNING id_medida, id_gas, puntaje
    )
    INSERT INTO fact_calidad (id_medida, rs_kohm, ratio_rs_r0, puntaje_ica, nivel, id_gas_dominante)
    SELECT r2.id_medida, r2.rs, r2.ratio, top.puntaje,
           CASE WHEN top.puntaje >= 66 THEN 'Malo'
                WHEN top.puntaje >= 33 THEN 'Medio' ELSE 'Bueno' END,
           top.id_gas
    FROM r2
    CROSS JOIN LATERAL (
        SELECT g.id_gas, g.puntaje FROM g
        WHERE g.id_medida = r2.id_medida
        ORDER BY g.puntaje DESC, g.id_gas
        LIMIT 1
    ) top;
END;
$$;

/* La usa Flask para cada lectura del ESP32 */
CREATE FUNCTION registrar_medida(
    p_sensor VARCHAR, p_ubicacion VARCHAR, p_tipo VARCHAR,
    p_valor NUMERIC, p_voltaje NUMERIC DEFAULT 0)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_sensor INT; v_ubic INT; v_tipo INT; v_id BIGINT; v_volt NUMERIC := p_voltaje;
BEGIN
    SELECT id_sensor INTO v_sensor FROM dim_sensor
     WHERE codigo_sensor = p_sensor AND activo;
    SELECT id_ubicacion INTO v_ubic FROM dim_ubicacion WHERE codigo_ubicacion = p_ubicacion;
    SELECT id_tipo_medicion INTO v_tipo FROM dim_tipo_medicion WHERE codigo_tipo = p_tipo;

    IF v_sensor IS NULL THEN RAISE EXCEPTION 'Sensor no registrado o inactivo'; END IF;
    IF v_ubic   IS NULL THEN RAISE EXCEPTION 'Ubicación no registrada'; END IF;
    IF v_tipo   IS NULL THEN RAISE EXCEPTION 'Tipo de medición no registrado'; END IF;

    IF v_volt = 0 THEN v_volt := p_valor * 3.3 / 4095.0; END IF;

    INSERT INTO fact_medidas (id_sensor, id_ubicacion, id_tipo_medicion, valor_medido, voltaje)
    VALUES (v_sensor, v_ubic, v_tipo, p_valor, v_volt)
    RETURNING id_medida INTO v_id;

    PERFORM calcular_calidad(v_id, v_id);
    RETURN v_id;
END;
$$;

/* Calibración: sensor 10 min en aire limpio y luego
   SELECT calibrar_r0('MQ135-REAL-001', 10);                         */
CREATE FUNCTION calibrar_r0(p_sensor VARCHAR, p_minutos INT DEFAULT 10)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_rs NUMERIC;
BEGIN
    SELECT AVG(((s.vcc - v.vm) / v.vm) * s.rl_kohm) INTO v_rs
    FROM fact_medidas m
    JOIN dim_sensor s ON s.id_sensor = m.id_sensor
    CROSS JOIN LATERAL (SELECT m.voltaje * s.factor_divisor AS vm) v
    WHERE s.codigo_sensor = p_sensor
      AND m.fecha_registro >= (now() AT TIME ZONE 'America/Bogota') - make_interval(mins => p_minutos)
      AND v.vm > 0.05 AND v.vm < s.vcc - 0.05;

    IF v_rs IS NOT NULL THEN
        UPDATE dim_sensor SET r0_kohm = ROUND(v_rs, 3) WHERE codigo_sensor = p_sensor;
    END IF;
    RETURN v_rs;
END;
$$;

/* ---------- 5. VISTAS PARA POWER BI ----------
   Mismos nombres de tablas y columnas que tenía el modelo en SQL Server,
   así el informe solo necesita cambiar de origen de datos. */

CREATE VIEW "vw_Lecturas" AS
SELECT m.id_medida                      AS "Id_medida",
       m.fecha_registro                 AS "Fecha",
       m.fecha_registro::date           AS "Dia",
       EXTRACT(HOUR FROM m.fecha_registro)::int AS "Hora",
       s.codigo_sensor                  AS "Codigo_sensor",
       s.es_simulado                    AS "Es_simulado",
       u.codigo_ubicacion               AS "Codigo_ubicacion",
       u.nombre                         AS "Ubicacion",
       u.tipo_lugar                     AS "Tipo_lugar",
       u.latitud                        AS "Latitud",
       u.longitud                       AS "Longitud",
       m.valor_medido                   AS "Lectura_ADC",
       m.voltaje                        AS "Voltaje",
       c.ratio_rs_r0                    AS "Ratio_Rs_R0",
       c.puntaje_ica                    AS "Puntaje_ICA",
       c.nivel                          AS "Nivel",
       g.nombre                         AS "Gas_dominante",
       m.es_demo                        AS "Es_demo"
FROM fact_medidas m
JOIN dim_sensor s    ON s.id_sensor = m.id_sensor
JOIN dim_ubicacion u ON u.id_ubicacion = m.id_ubicacion
LEFT JOIN fact_calidad c ON c.id_medida = m.id_medida
LEFT JOIN dim_gas g      ON g.id_gas = c.id_gas_dominante;

CREATE VIEW "vw_Gases" AS
SELECT m.id_medida                AS "Id_medida",
       m.fecha_registro           AS "Fecha",
       u.nombre                   AS "Ubicacion",
       u.tipo_lugar               AS "Tipo_lugar",
       g.codigo_gas               AS "Codigo_gas",
       g.nombre                   AS "Gas",
       g.formula                  AS "Formula",
       g.unidad                   AS "Unidad",
       fg.concentracion           AS "Concentracion",
       fg.puntaje                 AS "Puntaje",
       CASE WHEN fg.puntaje >= 66 THEN 'Malo'
            WHEN fg.puntaje >= 33 THEN 'Medio' ELSE 'Bueno' END AS "Nivel_gas",
       g.umbral_medio             AS "Umbral_medio",
       g.umbral_malo              AS "Umbral_malo"
FROM fact_gases fg
JOIN fact_medidas m  ON m.id_medida = fg.id_medida
JOIN dim_gas g       ON g.id_gas = fg.id_gas
JOIN dim_ubicacion u ON u.id_ubicacion = m.id_ubicacion;

CREATE VIEW "vw_UltimaPorUbicacion" AS
SELECT * FROM (
    SELECT l.*, ROW_NUMBER() OVER (PARTITION BY l."Codigo_ubicacion"
                                   ORDER BY l."Fecha" DESC, l."Id_medida" DESC) AS rn
    FROM "vw_Lecturas" l
) z WHERE rn = 1;

CREATE VIEW "DIM_Ubicacion" AS
SELECT id_ubicacion AS "Id_ubicacion", codigo_ubicacion AS "Codigo_ubicacion",
       nombre AS "Nombre", tipo_lugar AS "Tipo_lugar",
       latitud AS "Latitud", longitud AS "Longitud"
FROM dim_ubicacion;

CREATE VIEW "DIM_Gas" AS
SELECT id_gas AS "Id_gas", codigo_gas AS "Codigo_gas", nombre AS "Nombre",
       formula AS "Formula", unidad AS "Unidad",
       umbral_medio AS "Umbral_medio", umbral_malo AS "Umbral_malo"
FROM dim_gas;

CREATE VIEW "DIM_Sensor" AS
SELECT id_sensor AS "Id_sensor", codigo_sensor AS "Codigo_sensor", modelo AS "Modelo",
       es_simulado AS "Es_simulado", activo AS "Activo"
FROM dim_sensor;

/* ---------- 6. DATOS DE PRUEBA ----------
   2 días, 1 lectura cada 5 min, 3 sensores, cada uno alterna entre dos lugares
   cada 4 horas. Para borrarlos:  DELETE FROM fact_medidas WHERE es_demo;   */

WITH plan(sensor, bloque, ubic, base_r, amp) AS (
    VALUES
      ('MQ135-REAL-001', 0, 'UBICACION-001', 0.88, 0.07),
      ('MQ135-REAL-001', 1, 'UBICACION-002', 0.97, 0.03),
      ('MQ135-SIM-002',  0, 'UBICACION-003', 0.75, 0.10),
      ('MQ135-SIM-002',  1, 'UBICACION-004', 0.52, 0.12),
      ('MQ135-SIM-003',  0, 'UBICACION-005', 0.62, 0.10),
      ('MQ135-SIM-003',  1, 'UBICACION-006', 0.70, 0.08)
),
base AS MATERIALIZED (
    SELECT s.id_sensor, s.vcc, s.rl_kohm, s.r0_kohm, s.factor_divisor,
           u.id_ubicacion, g.f, pl.base_r, pl.amp,
           (random() * 2 - 1) AS ruido
    FROM generate_series(0, 575) AS n
    CROSS JOIN LATERAL (
        SELECT ((now() AT TIME ZONE 'America/Bogota')::TIMESTAMP(0) - n * INTERVAL '5 minutes') AS f
    ) g
    JOIN plan pl ON pl.bloque = ((EXTRACT(EPOCH FROM g.f)::BIGINT / 3600 / 4) % 2)
    JOIN dim_sensor s    ON s.codigo_sensor = pl.sensor
    JOIN dim_ubicacion u ON u.codigo_ubicacion = pl.ubic
),
calc AS (
    SELECT b.*,
           GREATEST(0.25, LEAST(1.1,
               b.base_r
               - b.amp * (CASE WHEN EXTRACT(HOUR FROM b.f) IN (7,8,9,17,18,19) THEN 1.0
                               WHEN EXTRACT(HOUR FROM b.f) BETWEEN 10 AND 16   THEN 0.5
                               ELSE 0.1 END)
               + 0.03 * b.ruido)) AS rr
    FROM base b
)
INSERT INTO fact_medidas (id_sensor, id_ubicacion, id_tipo_medicion, valor_medido, voltaje, fecha_registro, es_demo)
SELECT c.id_sensor, c.id_ubicacion, t.id_tipo_medicion,
       ROUND((y.vpin / 3.3 * 4095)::NUMERIC, 2),
       ROUND(y.vpin::NUMERIC, 3),
       c.f, TRUE
FROM calc c
CROSS JOIN (SELECT id_tipo_medicion FROM dim_tipo_medicion WHERE codigo_tipo = 'ADC') t
CROSS JOIN LATERAL (
    SELECT (c.vcc * c.rl_kohm / (c.rr * c.r0_kohm + c.rl_kohm)) / c.factor_divisor AS vpin
) y;

SELECT calcular_calidad(MIN(id_medida), MAX(id_medida)) FROM fact_medidas WHERE es_demo;

/* Verificación rápida */
SELECT COUNT(*) AS medidas FROM fact_medidas;
SELECT "Ubicacion", "Nivel", "Puntaje_ICA", "Gas_dominante", "Fecha" FROM "vw_UltimaPorUbicacion";
