-- =============================================================================
-- Pregunta 1 — Paraderos GTFS por comuna y densidad (paraderos / km²)
-- Patrón: join espacial punto-en-polígono (ST_Intersects) contra las comunas
-- subdivididas, con el GiST de comunas_sub.
--
-- Decisiones:
--  * Solo paraderos de bus (es_bus): las estaciones de metro no son "paraderos"
--    y no son comparables con highway=bus_stop de OSM (preguntas 2 y 3).
--  * Cada paradero se asigna a UNA comuna (DISTINCT ON): un punto justo sobre el
--    límite entre dos comunas, o entre dos piezas de ST_Subdivide de la misma
--    comuna, no se cuenta dos veces.
--  * La densidad principal se calcula sobre el área de la comuna DENTRO de la
--    caja: los paraderos se recortaron a la caja, así que dividir por el área
--    total subestima la densidad de las comunas que la caja corta (Las Condes,
--    La Florida, ...). Se informa también sobre el área total, para comparar.
-- =============================================================================
WITH asignacion AS (
  SELECT DISTINCT ON (p.stop_id) p.stop_id, s.cut
  FROM stgo.paraderos_gtfs p
  JOIN stgo.comunas_sub s ON ST_Intersects(s.geom, p.geom)
  WHERE p.es_bus
  ORDER BY p.stop_id, s.cut
)
SELECT c.cut,
       c.nombre                                                    AS comuna,
       count(a.stop_id)                                            AS paraderos,
       round(c.area_caja_km2::numeric, 2)                          AS area_en_caja_km2,
       round(c.pct_en_caja::numeric, 1)                            AS pct_comuna_en_caja,
       round((count(a.stop_id) / NULLIF(c.area_caja_km2, 0))::numeric, 1) AS densidad_km2,
       round((count(a.stop_id) / NULLIF(c.area_km2, 0))::numeric, 1)      AS densidad_area_total_km2
FROM stgo.comunas c
LEFT JOIN asignacion a USING (cut)
GROUP BY c.cut, c.nombre, c.area_caja_km2, c.area_km2, c.pct_en_caja
ORDER BY densidad_km2 DESC NULLS LAST;
