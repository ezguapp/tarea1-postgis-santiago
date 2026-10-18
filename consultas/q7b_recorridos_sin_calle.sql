-- =============================================================================
-- Pregunta 7 (cara inversa) — ¿qué fracción de los trazados de bus GTFS NO
-- tiene ninguna calle OSM a ≤ 15 m? Mismo método (segmentos de 10 m, punto
-- medio, EXISTS + ST_DWithin contra calles con GiST), mirado desde el GTFS.
-- Si es alta, o el trazado del operador está mal dibujado, o falta la calle en
-- OSM (o la ruta va por un corredor que OSM clasifica distinto, p. ej. busway).
-- Solo shapes principales de bus, para no pesar variantes.
-- =============================================================================
WITH seg AS (
  SELECT r.route_id, r.route_short_name,
         ST_Length(d.geom)                    AS largo,
         ST_LineInterpolatePoint(d.geom, 0.5) AS medio
  FROM stgo.recorridos r
  CROSS JOIN LATERAL ST_DumpSegments(ST_Segmentize(r.geom, 10)) AS d
  WHERE r.es_principal AND r.route_type = 3
    AND ST_Intersects(ST_LineInterpolatePoint(d.geom, 0.5), (SELECT geom FROM stgo.caja))
), marca AS (
  SELECT seg.*,
         NOT EXISTS (SELECT 1 FROM stgo.calles c WHERE ST_DWithin(c.geom, seg.medio, 15)) AS sin_calle
  FROM seg
)
SELECT round((sum(largo) / 1000)::numeric, 1)                                       AS km_trazado_en_caja,
       round((COALESCE(sum(largo) FILTER (WHERE sin_calle), 0) / 1000)::numeric, 2) AS km_sin_calle_osm,
       round((100 * COALESCE(sum(largo) FILTER (WHERE sin_calle), 0) / sum(largo))::numeric, 2) AS pct_sin_calle_osm,
       count(DISTINCT route_id) FILTER (WHERE sin_calle)                            AS rutas_afectadas,
       count(DISTINCT route_id)                                                     AS rutas
FROM marca;
