-- =============================================================================
-- 21_gtfs_derivar.sql — de gtfs_raw (texto) al esquema propio con geometría
--   stgo.rutas, stgo.viajes, stgo.stop_times, stgo.paraderos_gtfs (Point 5361),
--   stgo.recorridos (una LineString 5361 por shape_id).
-- El recorte a la caja se hace AQUÍ, en la base, no a mano sobre los CSV.
-- =============================================================================
SET client_min_messages = warning;

-- Columnas opcionales del estándar GTFS que pueden no venir en el ZIP: se agregan
-- vacías para que las consultas de abajo no dependan de la versión del feed.
DO $$
DECLARE
  par text[];
BEGIN
  IF to_regclass('gtfs_raw.stop_times') IS NULL THEN
    CREATE UNLOGGED TABLE gtfs_raw.stop_times (trip_id text, stop_id text, stop_sequence text);
    INSERT INTO stgo.etl_log(etapa, clave, valor) VALUES ('gtfs', 'stop_times', 'no viene en el ZIP');
  END IF;
  FOREACH par SLICE 1 IN ARRAY ARRAY[
      ['stops', 'stop_code'], ['stops', 'location_type'], ['stops', 'parent_station'],
      ['routes', 'route_long_name'], ['routes', 'route_type'], ['routes', 'route_short_name'],
      ['trips', 'direction_id'], ['trips', 'shape_id'], ['trips', 'trip_headsign'], ['trips', 'service_id'],
      ['shapes', 'shape_dist_traveled'],
      ['stop_times', 'arrival_time'], ['stop_times', 'departure_time']] LOOP
    EXECUTE format('ALTER TABLE gtfs_raw.%I ADD COLUMN IF NOT EXISTS %I text', par[1], par[2]);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Tablas alfanuméricas
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.rutas AS
SELECT route_id,
       NULLIF(route_short_name, '') AS route_short_name,
       NULLIF(route_long_name, '')  AS route_long_name,
       NULLIF(route_type, '')::int  AS route_type      -- 3 = bus, 1 = metro, 2 = tren
FROM gtfs_raw.routes;
ALTER TABLE stgo.rutas ADD PRIMARY KEY (route_id);

CREATE TABLE stgo.viajes AS
SELECT trip_id, route_id, NULLIF(service_id, '') AS service_id,
       NULLIF(shape_id, '') AS shape_id,
       NULLIF(direction_id, '')::int AS direction_id,
       NULLIF(trip_headsign, '') AS trip_headsign
FROM gtfs_raw.trips;
ALTER TABLE stgo.viajes ADD PRIMARY KEY (trip_id);

CREATE TABLE stgo.stop_times AS
SELECT trip_id, stop_id, stop_sequence::int AS stop_sequence,
       NULLIF(arrival_time, '') AS arrival_time
FROM gtfs_raw.stop_times;

-- Estadísticas YA: sin ellas el planificador cree que estas tablas están vacías y
-- elige un Nested Loop sin índice para el join de abajo (stop_times x viajes),
-- que con millones de filas no termina nunca.
ANALYZE stgo.rutas;
ANALYZE stgo.viajes;
ANALYZE stgo.stop_times;

-- ---------------------------------------------------------------------------
-- Paraderos GTFS: punto construido desde lon/lat (4326) y llevado a 5361.
-- Solo location_type 0/vacío (paradas donde se sube/baja); las estaciones
-- "padre" (1) y accesos (2) no son paraderos. Se marca qué modo sirve a cada uno.
-- ---------------------------------------------------------------------------
-- Servicio por paradero, calculado aparte y con estadísticas: dentro de una sola
-- consulta el planificador subestima el filtro de la caja (casts de texto) y
-- re-agrega stop_times una vez por paradero (Nested Loop); con millones de filas
-- eso no termina. Materializado, el join es un Hash Join directo.
CREATE UNLOGGED TABLE stgo._servicio AS
SELECT st.stop_id,
       count(DISTINCT v.route_id)                      AS n_rutas,
       count(*)                                         AS n_viajes,
       bool_or(COALESCE(r.route_type, 3) = 3)           AS sirve_bus,
       bool_or(r.route_type IN (0, 1, 2))               AS sirve_riel
FROM stgo.stop_times st
JOIN stgo.viajes v USING (trip_id)
JOIN stgo.rutas  r USING (route_id)
GROUP BY st.stop_id;
ALTER TABLE stgo._servicio ADD PRIMARY KEY (stop_id);
ANALYZE stgo._servicio;

CREATE TABLE stgo.paraderos_gtfs AS
WITH s AS MATERIALIZED (
  SELECT stop_id, NULLIF(stop_code, '') AS stop_code, stop_name,
         COALESCE(NULLIF(location_type, '')::int, 0) AS location_type,
         NULLIF(parent_station, '') AS parent_station,
         stop_lon::float8 AS lon, stop_lat::float8 AS lat
  FROM gtfs_raw.stops
  WHERE NULLIF(stop_lon, '') IS NOT NULL AND NULLIF(stop_lat, '') IS NOT NULL
), hay_st AS (SELECT EXISTS (SELECT 1 FROM stgo.stop_times) AS si)
SELECT s.stop_id, s.stop_code, s.stop_name, s.location_type, s.parent_station,
       COALESCE(sv.n_rutas, 0)  AS n_rutas,
       COALESCE(sv.n_viajes, 0) AS n_viajes,
       -- sin stop_times no se puede saber el modo: se asume bus (y queda en etl_log)
       CASE WHEN (SELECT si FROM hay_st) THEN COALESCE(sv.sirve_bus, false) ELSE true END AS es_bus,
       COALESCE(sv.sirve_riel, false) AS es_riel,
       ST_Transform(ST_SetSRID(ST_MakePoint(s.lon, s.lat), 4326), 5361)::geometry(Point, 5361) AS geom
FROM s
LEFT JOIN stgo._servicio sv USING (stop_id)
WHERE s.lon BETWEEN :xmin AND :xmax
  AND s.lat BETWEEN :ymin AND :ymax
  AND s.location_type = 0;
DROP TABLE stgo._servicio;
ALTER TABLE stgo.paraderos_gtfs ADD PRIMARY KEY (stop_id);

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'gtfs', 'stops_total_feed', count(*)::text FROM gtfs_raw.stops
UNION ALL
SELECT 'gtfs', 'stops_en_caja_todas', count(*)::text FROM gtfs_raw.stops
 WHERE NULLIF(stop_lon, '')::float8 BETWEEN :xmin AND :xmax AND NULLIF(stop_lat, '')::float8 BETWEEN :ymin AND :ymax
UNION ALL
SELECT 'gtfs', 'paraderos_gtfs', count(*)::text FROM stgo.paraderos_gtfs
UNION ALL
SELECT 'gtfs', 'paraderos_gtfs_bus', count(*)::text FROM stgo.paraderos_gtfs WHERE es_bus
UNION ALL
SELECT 'gtfs', 'paraderos_gtfs_riel', count(*)::text FROM stgo.paraderos_gtfs WHERE es_riel
UNION ALL
SELECT 'gtfs', 'paraderos_gtfs_sin_viajes', count(*)::text FROM stgo.paraderos_gtfs WHERE n_viajes = 0;

-- ---------------------------------------------------------------------------
-- Recorridos: una LineString por shape_id.
--   * shape_pt_sequence se castea a INTEGER antes de ordenar: como texto,
--     '10' < '9' y la línea zigzaguea (se cuenta abajo cuántos shapes cambiarían).
--   * Si hubiera secuencias repetidas se desempata por shape_dist_traveled.
--   * Cada shape se asocia a la ruta/sentido que más viajes lo usan (trips.txt);
--     es_principal marca, por (ruta, sentido), el shape con más viajes: sirve
--     para no contar dos veces variantes cortas o de servicio del mismo recorrido.
-- ---------------------------------------------------------------------------
CREATE UNLOGGED TABLE stgo._shape_pts AS
SELECT shape_id,
       shape_pt_sequence           AS seq_txt,
       shape_pt_sequence::int      AS seq,
       NULLIF(shape_dist_traveled, '')::float8 AS dist,
       ST_SetSRID(ST_MakePoint(shape_pt_lon::float8, shape_pt_lat::float8), 4326) AS g
FROM gtfs_raw.shapes;
ANALYZE stgo._shape_pts;

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'gtfs', 'shapes_total_feed', count(DISTINCT shape_id)::text FROM stgo._shape_pts
UNION ALL
SELECT 'gtfs', 'shapes_puntos_total', count(*)::text FROM stgo._shape_pts
UNION ALL
SELECT 'gtfs', 'shapes_secuencias_duplicadas',
       (count(*) - count(DISTINCT (shape_id, seq)))::text FROM stgo._shape_pts
UNION ALL
SELECT 'gtfs', 'shapes_que_quedarian_mal_ordenando_como_texto', count(*)::text
FROM (SELECT shape_id, array_agg(seq ORDER BY seq_txt) AS a, array_agg(seq ORDER BY seq) AS b
      FROM stgo._shape_pts GROUP BY shape_id) x
WHERE a <> b
UNION ALL
SELECT 'gtfs', 'shapes_con_shape_dist_traveled_decreciente', count(DISTINCT shape_id)::text
FROM (SELECT shape_id, dist, lag(dist) OVER (PARTITION BY shape_id ORDER BY seq) AS prev
      FROM stgo._shape_pts) x
WHERE dist < prev;

CREATE TABLE stgo.recorridos AS
WITH lineas AS (
  SELECT shape_id,
         count(*) AS n_pts,
         ST_RemoveRepeatedPoints(ST_MakeLine(g ORDER BY seq, dist NULLS LAST)) AS geom_4326
  FROM stgo._shape_pts
  GROUP BY shape_id
  HAVING count(*) >= 2
), uso AS (                      -- (shape, ruta, sentido) -> nº de viajes
  SELECT shape_id, route_id, direction_id, count(*) AS n_viajes
  FROM stgo.viajes WHERE shape_id IS NOT NULL
  GROUP BY 1, 2, 3
), uso_dominante AS (
  SELECT DISTINCT ON (shape_id) shape_id, route_id, direction_id,
         sum(n_viajes) OVER (PARTITION BY shape_id) AS n_viajes,
         count(*)      OVER (PARTITION BY shape_id) AS n_combinaciones
  FROM uso
  -- calificado: sin 'uso.' el ORDER BY tomaría el alias de salida (la suma)
  ORDER BY shape_id, uso.n_viajes DESC, uso.route_id
)
SELECT l.shape_id, u.route_id, r.route_short_name, r.route_long_name, r.route_type,
       u.direction_id, u.n_viajes::int, u.n_combinaciones::int, l.n_pts::int,
       ST_Transform(l.geom_4326, 5361)::geometry(LineString, 5361) AS geom
FROM lineas l
JOIN uso_dominante u USING (shape_id)
JOIN stgo.rutas r USING (route_id)
WHERE ST_Intersects(l.geom_4326, (SELECT geom_4326 FROM stgo.caja));

ALTER TABLE stgo.recorridos
  ADD PRIMARY KEY (shape_id),
  ADD COLUMN longitud_km double precision,
  ADD COLUMN es_principal boolean;
UPDATE stgo.recorridos SET longitud_km = ST_Length(geom) / 1000;
UPDATE stgo.recorridos r SET es_principal = (x.rk = 1)
FROM (SELECT shape_id,
             row_number() OVER (PARTITION BY route_id, COALESCE(direction_id, -1)
                                ORDER BY n_viajes DESC, longitud_km DESC, shape_id) AS rk
      FROM stgo.recorridos) x
WHERE x.shape_id = r.shape_id;

-- Tramos: cada recorrido cortado en piezas de ≤ 32 vértices (ST_Subdivide sobre
-- líneas). Un trazado de bus cruza media ciudad: su caja envolvente es enorme y
-- el GiST casi no filtra. Con tramos chicos el índice descarta de verdad y el
-- cálculo exacto se hace sobre pocos vértices. Mismo resultado lógico ("la ruta
-- toca X" <=> "algún tramo de la ruta toca X"), mucho más barato.
CREATE TABLE stgo.recorridos_tramos AS
SELECT row_number() OVER ()::int AS id, shape_id, route_id, route_type, es_principal, geom
FROM (SELECT shape_id, route_id, route_type, es_principal,
             ST_Subdivide(geom, 32)::geometry(LineString, 5361) AS geom
      FROM stgo.recorridos) s;
ALTER TABLE stgo.recorridos_tramos ADD PRIMARY KEY (id);

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'gtfs', 'recorridos_tramos', count(*)::text FROM stgo.recorridos_tramos
UNION ALL
SELECT 'gtfs', 'shapes_sin_viajes', count(*)::text
FROM (SELECT DISTINCT shape_id FROM stgo._shape_pts) s
WHERE NOT EXISTS (SELECT 1 FROM stgo.viajes v WHERE v.shape_id = s.shape_id)
UNION ALL
SELECT 'gtfs', 'shapes_usados_por_mas_de_una_ruta_o_sentido', count(*)::text
FROM stgo.recorridos WHERE n_combinaciones > 1
UNION ALL
SELECT 'gtfs', 'recorridos', count(*)::text FROM stgo.recorridos
UNION ALL
SELECT 'gtfs', 'recorridos_principales', count(*)::text FROM stgo.recorridos WHERE es_principal
UNION ALL
SELECT 'gtfs', 'rutas_en_caja', count(DISTINCT route_id)::text FROM stgo.recorridos
UNION ALL
SELECT 'gtfs', 'rutas_con_mas_de_un_shape', count(*)::text
FROM (SELECT route_id FROM stgo.recorridos GROUP BY route_id HAVING count(*) > 1) x
UNION ALL
SELECT 'gtfs', 'recorridos_no_simples(autointersectan)', count(*)::text
FROM stgo.recorridos WHERE NOT ST_IsSimple(geom)
UNION ALL
SELECT 'gtfs', 'stop_times', count(*)::text FROM stgo.stop_times;

-- Rango de vigencia declarado por el operador (si el feed trae feed_info/calendar)
DO $$
BEGIN
  BEGIN
    INSERT INTO stgo.etl_log(etapa, clave, valor)
    SELECT 'gtfs', 'feed_info:' || j.key, j.value
    FROM gtfs_raw.feed_info f, LATERAL jsonb_each_text(to_jsonb(f)) AS j(key, value);
  EXCEPTION WHEN undefined_table THEN NULL;
  END;
  BEGIN
    INSERT INTO stgo.etl_log(etapa, clave, valor)
    SELECT 'gtfs', 'calendar_rango', min(start_date) || ' a ' || max(end_date) FROM gtfs_raw.calendar;
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
  END;
  BEGIN
    INSERT INTO stgo.etl_log(etapa, clave, valor)
    SELECT 'gtfs', 'agencias', string_agg(DISTINCT agency_name, '; ') FROM gtfs_raw.agency;
  EXCEPTION WHEN undefined_table OR undefined_column THEN NULL;
  END;
  BEGIN
    INSERT INTO stgo.etl_log(etapa, clave, valor)
    SELECT 'gtfs', 'frequencies', count(*)::text FROM gtfs_raw.frequencies;
  EXCEPTION WHEN undefined_table THEN NULL;
  END;
END $$;

DROP TABLE stgo._shape_pts;
