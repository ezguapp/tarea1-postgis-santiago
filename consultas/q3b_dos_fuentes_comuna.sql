-- =============================================================================
-- Pregunta 3 (detalle) — los mismos dos anti-join a 50 m, por comuna.
-- Sirve para ver si la falta de completitud de OSM es pareja o se concentra.
-- La distancia mediana al par más cercano (KNN <->) dice cuán corridas están
-- las dos fuentes cuando sí coinciden.
-- =============================================================================
WITH g AS (
  SELECT DISTINCT ON (p.stop_id) p.stop_id, s.cut,
         NOT EXISTS (SELECT 1 FROM stgo.paraderos_osm o WHERE ST_DWithin(o.geom, p.geom, 50)) AS sin_par,
         (SELECT o.geom <-> p.geom FROM stgo.paraderos_osm o ORDER BY o.geom <-> p.geom LIMIT 1) AS dist_mas_cercano
  FROM stgo.paraderos_gtfs p
  JOIN stgo.comunas_sub s ON ST_Intersects(s.geom, p.geom)
  WHERE p.es_bus
  ORDER BY p.stop_id, s.cut
), o AS (
  SELECT DISTINCT ON (o.id) o.id, s.cut,
         NOT EXISTS (SELECT 1 FROM stgo.paraderos_gtfs p WHERE p.es_bus AND ST_DWithin(p.geom, o.geom, 50)) AS sin_par
  FROM stgo.paraderos_osm o
  JOIN stgo.comunas_sub s ON ST_Intersects(s.geom, o.geom)
  ORDER BY o.id, s.cut
), gg AS (
  SELECT cut, count(*) AS n, count(*) FILTER (WHERE sin_par) AS sin_par,
         percentile_cont(0.5) WITHIN GROUP (ORDER BY dist_mas_cercano) AS mediana
  FROM g GROUP BY cut
), oo AS (
  SELECT cut, count(*) AS n, count(*) FILTER (WHERE sin_par) AS sin_par FROM o GROUP BY cut
)
SELECT c.cut,
       c.nombre                                          AS comuna,
       COALESCE(gg.n, 0)                                 AS paraderos_gtfs,
       COALESCE(gg.sin_par, 0)                           AS gtfs_sin_osm_50m,
       round(100.0 * gg.sin_par / NULLIF(gg.n, 0), 1)    AS pct_gtfs_sin_osm,
       COALESCE(oo.n, 0)                                 AS paraderos_osm,
       COALESCE(oo.sin_par, 0)                           AS osm_sin_gtfs_50m,
       round(100.0 * oo.sin_par / NULLIF(oo.n, 0), 1)    AS pct_osm_sin_gtfs,
       round((COALESCE(oo.n, 0)::numeric / NULLIF(gg.n, 0)), 2) AS razon_osm_gtfs,
       round(gg.mediana::numeric, 1)                     AS mediana_dist_gtfs_a_osm_m
FROM stgo.comunas c
LEFT JOIN gg USING (cut)
LEFT JOIN oo USING (cut)
ORDER BY pct_gtfs_sin_osm DESC NULLS LAST;
