-- =============================================================================
-- 31_dpa_derivar.sql — comunas oficiales al esquema propio
--   stgo.comunas      : una fila por comuna que toca la caja, MultiPolygon 5361
--                       válido, con su área total y el área dentro de la caja
--   stgo.comunas_sub  : las mismas comunas cortadas con ST_Subdivide (≤ 255
--                       vértices por pieza) para los joins pesados
-- =============================================================================
SET client_min_messages = warning;

-- ---------------------------------------------------------------------------
-- 1) Detección de tabla, columnas y SRID (el .sql del Lab 03 decide esos nombres)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tabla  text := NULLIF((SELECT valor FROM stgo.config WHERE clave = 'dpa_tabla'), '');
  v_sch    text;
  v_tbl    text;
  v_geom   text;
  v_srid   int;
  v_nombre text;
  v_cut    text;
  v_region text;
  v_ext    box2d;
BEGIN
  IF v_tabla IS NOT NULL THEN
    v_sch := split_part(v_tabla, '.', 1);
    v_tbl := split_part(v_tabla, '.', 2);
  ELSE
    -- la tabla poligonal de dpa_raw; si hubiera varias (regiones, provincias...)
    -- se prefiere la que se llama "comuna..." y luego la de más filas
    SELECT g.f_table_schema, g.f_table_name INTO v_sch, v_tbl
    FROM geometry_columns g
    JOIN pg_namespace n ON n.nspname = g.f_table_schema
    JOIN pg_class c ON c.relname = g.f_table_name AND c.relnamespace = n.oid
    WHERE g.f_table_schema = 'dpa_raw'
      AND (g.type ILIKE '%POLYGON%' OR g.type = 'GEOMETRY')
    ORDER BY (g.f_table_name ILIKE '%comun%') DESC, c.reltuples DESC
    LIMIT 1;
  END IF;
  IF v_tbl IS NULL THEN
    RAISE EXCEPTION 'No encontré la tabla de comunas en dpa_raw. Use DPA_TABLA=esquema.tabla';
  END IF;

  SELECT f_geometry_column, srid INTO v_geom, v_srid
  FROM geometry_columns WHERE f_table_schema = v_sch AND f_table_name = v_tbl LIMIT 1;

  -- nombres de columna habituales en la DPA del INE / IDE Chile
  SELECT column_name INTO v_nombre FROM information_schema.columns
  WHERE table_schema = v_sch AND table_name = v_tbl
    AND lower(column_name) = ANY (ARRAY['comuna','nom_comuna','nom_com','nombre_comuna','nombre','desc_comun','name'])
  ORDER BY array_position(ARRAY['comuna','nom_comuna','nom_com','nombre_comuna','nombre','desc_comun','name'],
                          lower(column_name::text))
  LIMIT 1;
  SELECT column_name INTO v_cut FROM information_schema.columns
  WHERE table_schema = v_sch AND table_name = v_tbl
    AND lower(column_name) = ANY (ARRAY['cut_com','cut','cod_comuna','codigo_comuna','cut_comuna','codcom','comuna_id'])
  ORDER BY array_position(ARRAY['cut_com','cut','cod_comuna','codigo_comuna','cut_comuna','codcom','comuna_id'],
                          lower(column_name::text))
  LIMIT 1;
  SELECT column_name INTO v_region FROM information_schema.columns
  WHERE table_schema = v_sch AND table_name = v_tbl
    AND lower(column_name) = ANY (ARRAY['region','nom_region','nom_reg','nombre_region'])
  LIMIT 1;
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'No encontré la columna con el nombre de la comuna en %.%', v_sch, v_tbl;
  END IF;

  -- SRID no declarado (0): se deduce del rango de coordenadas
  IF v_srid IS NULL OR v_srid = 0 THEN
    EXECUTE format('SELECT ST_Extent(%I)::box2d FROM %I.%I', v_geom, v_sch, v_tbl) INTO v_ext;
    v_srid := CASE
      WHEN ST_XMin(v_ext) BETWEEN -180 AND 180 AND ST_YMin(v_ext) BETWEEN -90 AND 90 THEN 4326
      WHEN ST_YMin(v_ext) < -1000000 THEN 3857        -- Web Mercator: y negativo en millones
      ELSE 5361 END;                                   -- UTM 19S: y ≈ 6,3 millones
    INSERT INTO stgo.etl_log(etapa, clave, valor) VALUES ('dpa', 'srid_deducido_por_coordenadas', v_srid::text);
  END IF;

  INSERT INTO stgo.config VALUES
    ('dpa_sch', v_sch), ('dpa_tbl', v_tbl), ('dpa_geom', v_geom), ('dpa_srid', v_srid::text),
    ('dpa_nombre', v_nombre), ('dpa_cut', COALESCE(v_cut, '')), ('dpa_region', COALESCE(v_region, ''))
  ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

  INSERT INTO stgo.etl_log(etapa, clave, valor) VALUES
    ('dpa', 'tabla_origen', v_sch || '.' || v_tbl),
    ('dpa', 'srid_origen', v_srid::text),
    ('dpa', 'columna_nombre', v_nombre),
    ('dpa', 'columna_codigo', COALESCE(v_cut, '(no hay; se usa el nombre)')),
    ('dpa', 'columna_region', COALESCE(v_region, '(no hay)'));
END $$;

-- ---------------------------------------------------------------------------
-- 2) Staging de las comunas que tocan la caja, ya en 5361
-- ---------------------------------------------------------------------------
CREATE TABLE stgo._comunas_src (cut text, nombre text, region text, geom geometry);

DO $$
DECLARE
  c   jsonb := (SELECT jsonb_object_agg(clave, valor) FROM stgo.config);
  v_cut text := CASE WHEN c->>'dpa_cut' = '' THEN quote_ident(c->>'dpa_nombre') ELSE quote_ident(c->>'dpa_cut') END;
  v_reg text := CASE WHEN c->>'dpa_region' = '' THEN 'NULL' ELSE quote_ident(c->>'dpa_region') END;
BEGIN
  -- Filtro por caja envolvente en el SRID de origen (barato) antes de reproyectar
  -- las ~350 comunas del país; el filtro exacto se hace ya en 5361.
  EXECUTE format($f$
    INSERT INTO stgo._comunas_src (cut, nombre, region, geom)
    SELECT %1$s::text, %2$I::text, %3$s::text,
           ST_Force2D(ST_Transform(ST_SetSRID(%4$I, %5$s), 5361))
    FROM %6$I.%7$I
    WHERE %4$I IS NOT NULL
      AND ST_SetSRID(%4$I, %5$s) && ST_Transform((SELECT geom_4326 FROM stgo.caja), %5$s)$f$,
    v_cut, c->>'dpa_nombre', v_reg, c->>'dpa_geom', c->>'dpa_srid', c->>'dpa_sch', c->>'dpa_tbl');
END $$;

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'dpa', 'filas_en_caja_envolvente', count(*)::text FROM stgo._comunas_src
UNION ALL
SELECT 'dpa', 'comunas_invalidas', count(*)::text FROM stgo._comunas_src WHERE NOT ST_IsValid(geom);

UPDATE stgo._comunas_src
SET geom = ST_CollectionExtract(ST_MakeValid(geom), 3)
WHERE NOT ST_IsValid(geom);

-- ---------------------------------------------------------------------------
-- 3) stgo.comunas: una fila por comuna (si la fuente la trae en varias filas se
--    unen), solo las que tienen área real dentro de la caja (> 0,01 km²; deja
--    fuera astillas de comunas vecinas que apenas rozan el borde).
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.comunas AS
WITH u AS (
  SELECT cut, min(nombre) AS nombre, min(region) AS region,
         ST_Multi(ST_CollectionExtract(ST_Union(geom), 3)) AS geom
  FROM stgo._comunas_src
  GROUP BY cut
)
SELECT u.cut, u.nombre, u.region,
       u.geom::geometry(MultiPolygon, 5361) AS geom,
       ST_Multi(ST_CollectionExtract(ST_Intersection(u.geom, k.geom), 3))::geometry(MultiPolygon, 5361) AS geom_caja
FROM u, stgo.caja k
WHERE ST_Intersects(u.geom, k.geom)
  AND ST_Area(ST_Intersection(u.geom, k.geom)) > 10000;

ALTER TABLE stgo.comunas
  ADD PRIMARY KEY (cut),
  ADD COLUMN area_km2 double precision,
  ADD COLUMN area_caja_km2 double precision,
  ADD COLUMN pct_en_caja double precision;
UPDATE stgo.comunas SET
  area_km2      = ST_Area(geom) / 1e6,
  area_caja_km2 = ST_Area(geom_caja) / 1e6,
  pct_en_caja   = 100 * ST_Area(geom_caja) / ST_Area(geom);

-- ---------------------------------------------------------------------------
-- 4) Subdivisión: piezas de ≤ 255 vértices. Un polígono comunal tiene miles de
--    vértices y una caja envolvente enorme: el índice GiST filtra poco y cada
--    ST_Intersects/ST_Intersection recorre el polígono entero. Con piezas
--    chicas, la caja de cada pieza es ajustada y el cálculo exacto es local.
-- ---------------------------------------------------------------------------
CREATE TABLE stgo.comunas_sub AS
SELECT row_number() OVER ()::int AS id, cut, nombre, geom
FROM (SELECT cut, nombre, ST_Subdivide(geom, 255)::geometry(Polygon, 5361) AS geom
      FROM stgo.comunas) s;      -- (row_number fuera: se evalúa antes que el SRF)
ALTER TABLE stgo.comunas_sub ADD PRIMARY KEY (id);

INSERT INTO stgo.etl_log(etapa, clave, valor)
SELECT 'dpa', 'comunas', count(*)::text FROM stgo.comunas
UNION ALL
SELECT 'dpa', 'comunas_completas_en_caja', count(*)::text FROM stgo.comunas WHERE pct_en_caja > 99.5
UNION ALL
SELECT 'dpa', 'comunas_sub_piezas', count(*)::text FROM stgo.comunas_sub
UNION ALL
SELECT 'dpa', 'vertices_promedio_comuna', round(avg(ST_NPoints(geom)))::text FROM stgo.comunas
UNION ALL
SELECT 'dpa', 'vertices_promedio_pieza', round(avg(ST_NPoints(geom)))::text FROM stgo.comunas_sub;

DROP TABLE stgo._comunas_src;
