-- =============================================================================
-- 00_esquema.sql — esquema propio, parámetros y caja de estudio
--   osm_raw / gtfs_raw / dpa_raw : lo que llega tal cual de cada fuente (staging)
--   stgo                         : esquema propio derivado, todo en SRID 5361
-- Se rehace desde cero en cada corrida (idempotente).
-- =============================================================================
CREATE EXTENSION IF NOT EXISTS postgis;

DROP SCHEMA IF EXISTS stgo CASCADE;
CREATE SCHEMA stgo;

-- Bitácora del ETL: fuentes, versiones, conteos, reparaciones. Alimenta README e informe.
CREATE TABLE stgo.etl_log (
  id     serial PRIMARY KEY,
  ts     timestamptz NOT NULL DEFAULT now(),
  etapa  text NOT NULL,
  clave  text NOT NULL,
  valor  text
);

-- Parámetros de la corrida (los leen los bloques DO, donde psql no interpola variables)
CREATE TABLE stgo.config (clave text PRIMARY KEY, valor text NOT NULL);
INSERT INTO stgo.config VALUES
  ('srid', :'srid'), ('xmin', :'xmin'), ('ymin', :'ymin'), ('xmax', :'xmax'), ('ymax', :'ymax');

-- Caja de estudio. Se densifica en 4326 antes de proyectar para que los bordes
-- (rectos en lon/lat) se proyecten como curvas fieles y no como 4 vértices.
CREATE TABLE stgo.caja AS
SELECT ST_MakeEnvelope(:xmin, :ymin, :xmax, :ymax, 4326) AS geom_4326,
       ST_Transform(ST_Segmentize(ST_MakeEnvelope(:xmin, :ymin, :xmax, :ymax, 4326), 0.002),
                    :srid)::geometry(Polygon, 5361) AS geom;

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'config', 'bbox_4326', concat_ws(',', :'xmin', :'ymin', :'xmax', :'ymax')
UNION ALL SELECT 'config', 'srid', :'srid'
UNION ALL SELECT 'config', 'area_caja_km2', round((ST_Area(geom) / 1e6)::numeric, 1)::text FROM stgo.caja
UNION ALL SELECT 'config', 'postgis_version', postgis_full_version()
UNION ALL SELECT 'config', 'postgres_version', version();
