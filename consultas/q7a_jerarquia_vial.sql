-- =============================================================================
-- Pregunta 7 (propia) — ¿Sobre qué jerarquía de calles OSM circula la red de
-- buses GTFS, y cuántos km de vías principales no tienen ningún bus?
--
-- Cruza OSM (calles, con su clasificación highway) con GTFS (trazados): no es
-- una variante de las anteriores (ni conteo por comuna, ni distancia a puntos,
-- ni grilla): es una relación línea–línea y responde algo que ninguna fuente
-- dice sola: OSM sabe qué tipo de calle es, GTFS sabe por dónde pasa el bus.
--
-- Método (resolución 10 m):
--  1. cada calle se densifica (ST_Segmentize 10 m) y se parte en segmentos
--     (ST_DumpSegments); cada segmento se representa por su punto medio,
--  2. un segmento "tiene bus" si algún tramo de recorrido de bus pasa a ≤ 15 m
--     de su punto medio (EXISTS + ST_DWithin sobre recorridos_tramos, con GiST),
--  3. se suman longitudes por categoría.
-- Por qué así y no "la calle toca un recorrido": una calle residencial que solo
-- CRUZA una avenida con buses tocaría el recorrido en un punto y contaría
-- entera. Midiendo por segmento solo cuentan los ~30 m del cruce.
-- 15 m: media calzada de una avenida + desfase típico entre el trazado GTFS y
-- el eje dibujado en OSM. Las vías *_link se suman a su categoría.
-- =============================================================================
WITH seg AS (
  SELECT regexp_replace(c.highway, '_link$', '')                        AS categoria,
         ST_Length(d.geom)                                              AS largo,
         ST_LineInterpolatePoint(d.geom, 0.5)                           AS medio
  FROM stgo.calles c
  CROSS JOIN LATERAL ST_DumpSegments(ST_Segmentize(c.geom, 10)) AS d
  WHERE c.highway IN ('motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link',
                      'secondary', 'secondary_link', 'tertiary', 'tertiary_link',
                      'unclassified', 'residential', 'living_street', 'service')
), marca AS (
  SELECT categoria, largo,
         EXISTS (SELECT 1 FROM stgo.recorridos_tramos t
                 WHERE t.route_type = 3 AND ST_DWithin(t.geom, seg.medio, 15)) AS con_bus
  FROM seg
)
SELECT categoria,
       round((sum(largo) / 1000)::numeric, 1)                                   AS km_calle,
       round((sum(largo) FILTER (WHERE con_bus) / 1000)::numeric, 1)            AS km_con_bus,
       round((100 * sum(largo) FILTER (WHERE con_bus) / sum(largo))::numeric, 1) AS pct_con_bus,
       round((sum(largo) FILTER (WHERE NOT con_bus) / 1000)::numeric, 1)        AS km_sin_bus,
       round((100 * COALESCE(sum(largo) FILTER (WHERE con_bus), 0)
              / sum(sum(largo) FILTER (WHERE con_bus)) OVER ())::numeric, 1)    AS pct_de_la_red_bus
FROM marca
GROUP BY categoria
ORDER BY array_position(ARRAY['motorway','trunk','primary','secondary','tertiary','unclassified',
                              'residential','living_street','service'], categoria);
