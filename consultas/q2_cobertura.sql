-- =============================================================================
-- Pregunta 2 — Cobertura: % de edificios OSM de cada comuna a MÁS de 500 m de
-- cualquier paradero, calculado con paraderos GTFS y con paraderos OSM.
-- Patrón: anti-join  NOT EXISTS (... ST_DWithin(p.geom, e.pto, 500))
--   ST_DWithin usa el GiST del paradero: por cada edificio se buscan solo los
--   paraderos cuya caja está a < 500 m, y se corta en el primero que cumple.
--
-- Decisiones:
--  * Edificio = su punto interior (pto). Distancia euclidiana en 5361 (metros),
--    no distancia caminando por la red vial: es una cota inferior del acceso real.
--  * Comuna del edificio = la que contiene su punto interior (una sola).
--  * Efecto borde: un edificio a < 500 m del borde de la caja puede tener su
--    paradero más cercano FUERA de la caja (no cargado) y aparecer como "lejos".
--    La última columna repite el cálculo GTFS solo con edificios del núcleo
--    (a > 500 m del borde) para ver cuánto pesa ese sesgo.
--  * La fila con comuna = 'TOTAL caja' (GROUPING SETS) resume toda la zona.
-- =============================================================================
WITH ed AS (
  SELECT DISTINCT ON (e.id) e.id, e.pto, s.cut
  FROM stgo.edificios e
  JOIN stgo.comunas_sub s ON ST_Intersects(s.geom, e.pto)
  ORDER BY e.id, s.cut
), marca AS (
  SELECT ed.cut,
         NOT EXISTS (SELECT 1 FROM stgo.paraderos_gtfs p
                     WHERE p.es_bus AND ST_DWithin(p.geom, ed.pto, 500)) AS lejos_gtfs,
         NOT EXISTS (SELECT 1 FROM stgo.paraderos_osm o
                     WHERE ST_DWithin(o.geom, ed.pto, 500))               AS lejos_osm,
         ST_Intersects(ed.pto, (SELECT ST_Buffer(geom, -500) FROM stgo.caja)) AS en_nucleo
  FROM ed
)
SELECT COALESCE(c.cut, 'TOTAL')                                            AS cut,
       COALESCE(c.nombre, 'TOTAL caja')                                   AS comuna,
       count(*)                                                           AS edificios,
       count(*) FILTER (WHERE lejos_gtfs)                                 AS lejos_gtfs,
       round(100.0 * avg(lejos_gtfs::int), 2)                             AS pct_lejos_gtfs,
       count(*) FILTER (WHERE lejos_osm)                                  AS lejos_osm,
       round(100.0 * avg(lejos_osm::int), 2)                              AS pct_lejos_osm,
       round(100.0 * avg(lejos_osm::int) - 100.0 * avg(lejos_gtfs::int), 2) AS dif_osm_menos_gtfs_pp,
       round(100.0 * avg(lejos_gtfs::int) FILTER (WHERE en_nucleo), 2)    AS pct_lejos_gtfs_nucleo
FROM marca m
JOIN stgo.comunas c USING (cut)
GROUP BY GROUPING SETS ((c.cut, c.nombre), ())
ORDER BY (c.nombre IS NULL), pct_lejos_gtfs DESC;
