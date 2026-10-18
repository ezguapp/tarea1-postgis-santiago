-- =============================================================================
-- Pregunta 4 (B) — km de recorrido por comuna, CON ST_Subdivide (comunas_sub)
-- Igual a (A) pero contra las piezas de ≤ 255 vértices. Cada pieza tiene una
-- caja envolvente ajustada (el GiST descarta más pares) y ST_Intersection
-- trabaja sobre pocos vértices. Las piezas de una comuna no se traslapan, así
-- que sumar por pieza da el mismo total que sumar por comuna.
-- =============================================================================
SELECT s.cut,
       s.nombre                                                                AS comuna,
       count(DISTINCT r.route_id)                                              AS rutas,
       round((sum(ST_Length(ST_Intersection(r.geom, s.geom))) / 1000)::numeric, 1) AS km_todos,
       round((sum(ST_Length(ST_Intersection(r.geom, s.geom))) FILTER (WHERE r.es_principal) / 1000)::numeric, 1) AS km_principales,
       round((sum(ST_Length(ST_Intersection(r.geom, s.geom))) FILTER (WHERE r.es_principal AND r.route_type = 3) / 1000)::numeric, 1) AS km_bus,
       round((sum(ST_Length(ST_Intersection(r.geom, s.geom))) FILTER (WHERE r.es_principal) / 1000
              / NULLIF(max(c.area_caja_km2), 0))::numeric, 1)                  AS km_por_km2
FROM stgo.recorridos r
JOIN stgo.comunas_sub s ON ST_Intersects(r.geom, s.geom)
JOIN stgo.comunas c ON c.cut = s.cut
GROUP BY s.cut, s.nombre
ORDER BY km_principales DESC;
