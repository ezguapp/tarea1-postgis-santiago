-- =============================================================================
-- Pregunta 4 (A) — km de recorrido por comuna, SIN ST_Subdivide
-- Patrón: líneas contra polígonos. ST_Intersects (con GiST) elige los pares
-- trazado–comuna que se tocan y ST_Intersection recorta cada trazado en el
-- límite comunal; se suma ST_Length en metros (5361).
-- Se compara en tiempo con la versión (B) sobre comunas_sub: mismas cifras.
--
-- Columnas:
--  km_todos        : todos los shapes (ida, vuelta y variantes de servicio)
--  km_principales  : solo el shape principal de cada (ruta, sentido): evita
--                    contar dos veces variantes cortas del mismo recorrido.
--                    Ida y vuelta SÍ se suman: son dos servicios distintos.
--  km_bus          : principales con route_type = 3 (sin metro)
--  km_por_km2      : km_principales / km² de comuna dentro de la caja
-- =============================================================================
SELECT c.cut,
       c.nombre                                                                AS comuna,
       count(DISTINCT r.route_id)                                              AS rutas,
       round((sum(ST_Length(ST_Intersection(r.geom, c.geom))) / 1000)::numeric, 1) AS km_todos,
       round((sum(ST_Length(ST_Intersection(r.geom, c.geom))) FILTER (WHERE r.es_principal) / 1000)::numeric, 1) AS km_principales,
       round((sum(ST_Length(ST_Intersection(r.geom, c.geom))) FILTER (WHERE r.es_principal AND r.route_type = 3) / 1000)::numeric, 1) AS km_bus,
       round((sum(ST_Length(ST_Intersection(r.geom, c.geom))) FILTER (WHERE r.es_principal) / 1000
              / NULLIF(c.area_caja_km2, 0))::numeric, 1)                       AS km_por_km2
FROM stgo.recorridos r
JOIN stgo.comunas c ON ST_Intersects(r.geom, c.geom)
GROUP BY c.cut, c.nombre, c.area_caja_km2
ORDER BY km_principales DESC;
