-- =============================================================================
-- 11_osm_derivar.sql — de osm_raw (tal como lo deja ogr2ogr) al esquema propio
--   stgo.calles, stgo.edificios (polígono + punto interior), stgo.paraderos_osm,
--   stgo.amenidades. Todo en 5361, reparado y recortado a la caja.
-- =============================================================================

SET client_min_messages = warning;   -- ST_IsValid emite un NOTICE por cada inválido

-- ---------------------------------------------------------------------------
-- 1) Vistas normalizadas sobre osm_raw.
--    El driver OSM de GDAL deja algunas claves como columna (highway, building...)
--    y el resto dentro de other_tags ('"k"=>"v","k2"=>"v2"'). Qué clave queda como
--    columna depende del osmconf.ini con que se generó el archivo: por ejemplo
--    amenity NO es columna en la capa points por defecto. Para no depender de eso,
--    cada clave se lee de su columna si existe y si no, de other_tags.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stgo._osm_expr(p_tabla text, p_clave text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  tiene_col  boolean;
  tiene_tags boolean;
  desde_tags text;
BEGIN
  SELECT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'osm_raw' AND table_name = p_tabla AND column_name = p_clave)
    INTO tiene_col;
  SELECT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'osm_raw' AND table_name = p_tabla AND column_name = 'other_tags')
    INTO tiene_tags;
  desde_tags := CASE WHEN tiene_tags
                     THEN format('substring(other_tags from %L)', '"' || p_clave || '"=>"([^"]*)"')
                     ELSE 'NULL::text' END;
  IF tiene_col THEN
    RETURN format('COALESCE(NULLIF(%I::text, %L), %s)', p_clave, '', desde_tags);
  END IF;
  RETURN desde_tags;
END $$;

DO $$
DECLARE
  t       text;
  id_expr text;
BEGIN
  FOREACH t IN ARRAY ARRAY['points', 'lines', 'multipolygons'] LOOP
    -- osm_id: en multipolygons el id viene en osm_id (relaciones) u osm_way_id (vías cerradas)
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'osm_raw' AND table_name = t AND column_name = 'osm_way_id') THEN
      id_expr := 'COALESCE(NULLIF(osm_id::text, ''''), ''w'' || osm_way_id::text)';
    ELSE
      id_expr := 'osm_id::text';
    END IF;
    EXECUTE format($f$
      CREATE OR REPLACE VIEW osm_raw.v_%1$s AS
      SELECT ogc_fid,
             %2$s AS osm_id,
             %3$s AS name,
             %4$s AS highway,
             %5$s AS building,
             %6$s AS amenity,
             %7$s AS public_transport,
             geom
      FROM osm_raw.%1$I
      WHERE geom IS NOT NULL$f$,
      t, id_expr,
      stgo._osm_expr(t, 'name'), stgo._osm_expr(t, 'highway'), stgo._osm_expr(t, 'building'),
      stgo._osm_expr(t, 'amenity'), stgo._osm_expr(t, 'public_transport'));
  END LOOP;
END $$;

-- SRID de origen de cada capa (4326 si viene del PBF; el GeoPackage del lab podría
-- traer otro). Si viniera en 0 se asume 4326 (coordenadas OSM son lon/lat).
CREATE OR REPLACE FUNCTION stgo._a_5361(g geometry) RETURNS geometry
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE WHEN ST_SRID(g) = 5361 THEN g
              WHEN ST_SRID(g) = 0    THEN ST_Transform(ST_SetSRID(g, 4326), 5361)
              ELSE ST_Transform(g, 5361) END
$$;

-- ---------------------------------------------------------------------------
-- 2) Calles: toda vía con highway (incluye peatonales y de servicio; la consulta
--    7 agrupa por categoría). Se guardan como MultiLineString para aceptar tanto
--    LineString (PBF) como MultiLineString (si el GeoPackage las promovió).
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.calles AS
SELECT row_number() OVER ()::int AS id,
       l.osm_id, l.name AS nombre, l.highway,
       ST_Multi(ST_Force2D(stgo._a_5361(l.geom)))::geometry(MultiLineString, 5361) AS geom
FROM osm_raw.v_lines l
WHERE l.highway IS NOT NULL
  AND ST_Intersects(stgo._a_5361(l.geom), (SELECT geom FROM stgo.caja));
ALTER TABLE stgo.calles ADD PRIMARY KEY (id);

-- ---------------------------------------------------------------------------
-- 3) Edificios: polígono reparado + punto interior.
--    Se valida en 5361 (el SRID donde se calcula todo): reproyectar también puede
--    volver inválido un anillo muy fino, así que validar antes no basta.
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.edificios AS
SELECT row_number() OVER ()::int AS id,
       m.osm_id, m.name AS nombre, m.building AS tipo,
       ST_Force2D(stgo._a_5361(m.geom)) AS geom
FROM osm_raw.v_multipolygons m
WHERE m.building IS NOT NULL AND m.building <> 'no'
  -- && (cajas envolventes) y no ST_Intersects: un polígono inválido puede hacer
  -- fallar a GEOS. El filtro exacto se aplica después de reparar.
  AND stgo._a_5361(m.geom) && (SELECT geom FROM stgo.caja);

-- Registro de inválidos (cuántos y por qué) ANTES de reparar
INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'osm', 'edificios_total_antes', count(*)::text FROM stgo.edificios
UNION ALL
SELECT 'osm', 'edificios_invalidos', count(*)::text FROM stgo.edificios WHERE NOT ST_IsValid(geom)
UNION ALL
SELECT 'osm', 'edificios_invalidos_motivo:' || motivo, n::text
FROM (SELECT split_part(ST_IsValidReason(geom), '[', 1) AS motivo, count(*) AS n
      FROM stgo.edificios WHERE NOT ST_IsValid(geom) GROUP BY 1) r;

-- Reparación: ST_MakeValid puede devolver GeometryCollection (polígono + líneas
-- sueltas); nos quedamos solo con la parte poligonal (CollectionExtract tipo 3).
UPDATE stgo.edificios
SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3))
WHERE NOT ST_IsValid(geom);
UPDATE stgo.edificios SET geom = ST_Multi(geom) WHERE GeometryType(geom) = 'POLYGON';

WITH borrados AS (
  DELETE FROM stgo.edificios WHERE geom IS NULL OR ST_IsEmpty(geom) OR ST_Area(geom) = 0
  RETURNING 1)
INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'osm', 'edificios_descartados_vacios_tras_reparar', count(*)::text FROM borrados;

WITH fuera AS (
  DELETE FROM stgo.edificios WHERE NOT ST_Intersects(geom, (SELECT geom FROM stgo.caja))
  RETURNING 1)
INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'osm', 'edificios_fuera_de_caja_descartados', count(*)::text FROM fuera;

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'osm', 'edificios_invalidos_despues', count(*)::text FROM stgo.edificios WHERE NOT ST_IsValid(geom);

ALTER TABLE stgo.edificios
  ALTER COLUMN geom TYPE geometry(MultiPolygon, 5361) USING geom,
  ADD COLUMN area_m2 double precision,
  ADD COLUMN pto geometry(Point, 5361);
-- Punto interior y no centroide: ST_PointOnSurface cae siempre DENTRO del
-- polígono (un centroide de un edificio en "L" o de un patio puede caer fuera, y
-- en otra comuna o en otra celda de la grilla).
UPDATE stgo.edificios SET area_m2 = ST_Area(geom), pto = ST_PointOnSurface(geom);
ALTER TABLE stgo.edificios ADD PRIMARY KEY (id), ALTER COLUMN pto SET NOT NULL;

-- ---------------------------------------------------------------------------
-- 4) Paraderos OSM: nodos highway=bus_stop dentro de la caja (lo que pide el
--    enunciado). Se guarda además public_transport para discutir completitud.
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.paraderos_osm AS
SELECT row_number() OVER ()::int AS id,
       p.osm_id, p.name AS nombre, p.public_transport,
       ST_Force2D(stgo._a_5361(p.geom))::geometry(Point, 5361) AS geom
FROM osm_raw.v_points p
WHERE p.highway = 'bus_stop'
  AND ST_Intersects(stgo._a_5361(p.geom), (SELECT geom FROM stgo.caja));
ALTER TABLE stgo.paraderos_osm ADD PRIMARY KEY (id);

-- ---------------------------------------------------------------------------
-- 5) Amenidades: nodos con amenity + áreas con amenity (un hospital suele estar
--    dibujado como polígono, no como punto). Las áreas se reparan igual que los
--    edificios y se representan por su punto interior, para tener una sola capa
--    de puntos sobre la que funcione el vecino más cercano (<->) con índice.
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.amenidades AS
SELECT osm_id, name AS nombre, amenity, 'nodo'::text AS origen,
       ST_Force2D(stgo._a_5361(geom)) AS geom
FROM osm_raw.v_points
WHERE amenity IS NOT NULL
UNION ALL
SELECT osm_id, name, amenity, 'area',
       ST_Force2D(stgo._a_5361(geom))
FROM osm_raw.v_multipolygons
WHERE amenity IS NOT NULL
  AND stgo._a_5361(geom) && (SELECT geom FROM stgo.caja);

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'osm', 'amenidades_area_invalidas', count(*)::text
FROM stgo.amenidades WHERE origen = 'area' AND NOT ST_IsValid(geom);

UPDATE stgo.amenidades
SET geom = ST_CollectionExtract(ST_MakeValid(geom), 3)
WHERE origen = 'area' AND NOT ST_IsValid(geom);
DELETE FROM stgo.amenidades WHERE geom IS NULL OR ST_IsEmpty(geom);
UPDATE stgo.amenidades SET geom = ST_PointOnSurface(geom) WHERE origen = 'area';
DELETE FROM stgo.amenidades WHERE NOT ST_Intersects(geom, (SELECT geom FROM stgo.caja));

ALTER TABLE stgo.amenidades
  ALTER COLUMN geom TYPE geometry(Point, 5361) USING geom,
  ADD COLUMN id serial PRIMARY KEY;

-- ---------------------------------------------------------------------------
-- 6) Conteos
-- ---------------------------------------------------------------------------
INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'osm', 'calles', count(*)::text FROM stgo.calles
UNION ALL SELECT 'osm', 'edificios', count(*)::text FROM stgo.edificios
UNION ALL SELECT 'osm', 'paraderos_osm', count(*)::text FROM stgo.paraderos_osm
UNION ALL SELECT 'osm', 'amenidades', count(*)::text FROM stgo.amenidades
UNION ALL SELECT 'osm', 'amenidades_salud', count(*)::text FROM stgo.amenidades
          WHERE amenity IN ('pharmacy', 'hospital', 'clinic', 'doctors');
