-- =============================================================================
-- Pregunta 3 — Dos fuentes, un objeto: anti-join en los dos sentidos
--   GTFS sin OSM : paraderos GTFS (bus) sin ningún highway=bus_stop OSM a < d m
--   OSM sin GTFS : bus_stop OSM sin ningún paradero GTFS (bus) a < d m
-- La respuesta pedida es d = 50 m; 25 y 100 m muestran qué tan sensible es la
-- conclusión al umbral (el GTFS ubica el poste; en OSM alguien lo dibujó a mano,
-- a veces en el eje de la calle y no en la vereda).
-- Cada NOT EXISTS + ST_DWithin usa el GiST de la tabla del lado interno.
-- =============================================================================
SELECT d.umbral_m,
       g.total                                               AS paraderos_gtfs,
       g.sin_par                                             AS gtfs_sin_osm,
       round(100.0 * g.sin_par / NULLIF(g.total, 0), 1)      AS pct_gtfs_sin_osm,
       o.total                                               AS paraderos_osm,
       o.sin_par                                             AS osm_sin_gtfs,
       round(100.0 * o.sin_par / NULLIF(o.total, 0), 1)      AS pct_osm_sin_gtfs
FROM (VALUES (25), (50), (100)) AS d(umbral_m)
CROSS JOIN LATERAL (
  SELECT count(*) AS total,
         count(*) FILTER (WHERE NOT EXISTS (
             SELECT 1 FROM stgo.paraderos_osm o
             WHERE ST_DWithin(o.geom, p.geom, d.umbral_m))) AS sin_par
  FROM stgo.paraderos_gtfs p
  WHERE p.es_bus
) g
CROSS JOIN LATERAL (
  SELECT count(*) AS total,
         count(*) FILTER (WHERE NOT EXISTS (
             SELECT 1 FROM stgo.paraderos_gtfs p
             WHERE p.es_bus AND ST_DWithin(p.geom, o.geom, d.umbral_m))) AS sin_par
  FROM stgo.paraderos_osm o
) o
ORDER BY d.umbral_m;
