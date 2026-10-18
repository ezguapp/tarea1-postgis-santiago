-- =============================================================================
-- Pregunta 6 (construcción) — grilla hexagonal de 500 m como VISTA MATERIALIZADA
-- ST_HexagonGrid(500, caja): el parámetro es el LADO del hexágono (= radio del
-- círculo circunscrito); cada celda mide 3·√3/2·500² ≈ 0,65 km² y 866 m entre
-- lados opuestos.
-- Por celda:
--   n_edificios  : edificios cuyo PUNTO INTERIOR cae en la celda (cada edificio
--                  se cuenta una vez; con el polígono un edificio grande podría
--                  caer en dos celdas)
--   n_recorridos : rutas distintas (route_id) con algún trazado que cruza la
--                  celda; se usan los tramos subdivididos para que el GiST filtre
--   n_rutas_bus  : ídem, solo buses (route_type 3)
--   n_paraderos  : paraderos GTFS de bus dentro de la celda
--   frac_en_caja : fracción del área de la celda dentro de la caja. Las celdas
--                  del borde quedan subcontadas en todo (lo de fuera no se cargó);
--                  el ranking usa solo celdas completas.
-- Vista materializada: se calcula una vez (lo caro) y se consulta/mapea muchas;
-- índice único (i, j) para poder hacer REFRESH MATERIALIZED VIEW CONCURRENTLY.
-- =============================================================================
DROP MATERIALIZED VIEW IF EXISTS stgo.mv_grilla;
CREATE MATERIALIZED VIEW stgo.mv_grilla AS
-- [inicio consulta]  (run_consultas.sh toma desde aquí para el EXPLAIN ANALYZE)
WITH hex AS (
  SELECT h.i, h.j, h.geom
  FROM stgo.caja k
  CROSS JOIN LATERAL ST_HexagonGrid(500, k.geom) AS h
  WHERE ST_Intersects(h.geom, k.geom)
), ed AS (
  SELECT h.i, h.j, count(*) AS n
  FROM hex h JOIN stgo.edificios e ON ST_Intersects(h.geom, e.pto)
  GROUP BY h.i, h.j
), rec AS (
  SELECT h.i, h.j,
         count(DISTINCT t.route_id)                                 AS n,
         count(DISTINCT t.route_id) FILTER (WHERE t.route_type = 3) AS n_bus
  FROM hex h JOIN stgo.recorridos_tramos t ON ST_Intersects(h.geom, t.geom)
  GROUP BY h.i, h.j
), par AS (
  SELECT h.i, h.j, count(*) AS n
  FROM hex h JOIN stgo.paraderos_gtfs p ON ST_Intersects(h.geom, p.geom) AND p.es_bus
  GROUP BY h.i, h.j
)
SELECT h.i, h.j,
       h.i || '_' || h.j                                     AS celda,
       h.geom::geometry(Polygon, 5361)                       AS geom,
       COALESCE(ed.n, 0)::int                                AS n_edificios,
       COALESCE(rec.n, 0)::int                               AS n_recorridos,
       COALESCE(rec.n_bus, 0)::int                           AS n_rutas_bus,
       COALESCE(par.n, 0)::int                               AS n_paraderos,
       round((ST_Area(ST_Intersection(h.geom, k.geom)) / ST_Area(h.geom))::numeric, 3) AS frac_en_caja
FROM hex h
CROSS JOIN stgo.caja k
LEFT JOIN ed  USING (i, j)
LEFT JOIN rec USING (i, j)
LEFT JOIN par USING (i, j);
-- [fin consulta]

CREATE UNIQUE INDEX mv_grilla_ij_idx  ON stgo.mv_grilla (i, j);
CREATE INDEX mv_grilla_geom_gix       ON stgo.mv_grilla USING gist (geom);
ANALYZE stgo.mv_grilla;
