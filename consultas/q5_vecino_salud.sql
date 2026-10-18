-- =============================================================================
-- Pregunta 5 — Vecino más cercano: para cada paradero del recorrido elegido,
-- la farmacia o centro de salud OSM más cercano y a qué distancia.
-- Patrón: CROSS JOIN LATERAL + ORDER BY a.geom <-> p.geom + LIMIT 1
--   El operador <-> recorre el GiST en orden de distancia (KNN): no calcula la
--   distancia a todas las amenidades, se detiene en la primera.
--   El WHERE coincide con el predicado del índice parcial amenidades_salud_gix.
--
-- Variable psql :ruta_id (la fija run_consultas.sh a partir de RUTA, por
-- defecto el recorrido 506). Paraderos y orden salen de stop_times de UN viaje
-- representativo por sentido: un viaje del shape principal.
-- Solo se consideran amenidades dentro de la caja (las de fuera no se cargaron).
-- =============================================================================
WITH viaje_tipo AS (
  SELECT DISTINCT ON (v.direction_id) v.trip_id, v.direction_id
  FROM stgo.viajes v
  JOIN stgo.recorridos r ON r.shape_id = v.shape_id AND r.es_principal
  WHERE v.route_id = :'ruta_id'
  ORDER BY v.direction_id, v.trip_id
), paradas AS (
  SELECT vt.direction_id, st.stop_sequence, p.stop_id, p.stop_code, p.stop_name, p.geom
  FROM viaje_tipo vt
  JOIN stgo.stop_times st ON st.trip_id = vt.trip_id
  JOIN stgo.paraderos_gtfs p ON p.stop_id = st.stop_id
)
SELECT pa.direction_id               AS sentido,
       pa.stop_sequence              AS orden,
       pa.stop_code                  AS codigo,
       pa.stop_name                  AS paradero,
       s.amenity                     AS tipo_salud,
       s.nombre                      AS salud_mas_cercana,
       round(s.dist_m::numeric, 0)   AS distancia_m
FROM paradas pa
CROSS JOIN LATERAL (
  SELECT a.nombre, a.amenity, a.geom <-> pa.geom AS dist_m
  FROM stgo.amenidades a
  WHERE a.amenity IN ('pharmacy', 'hospital', 'clinic', 'doctors')
  ORDER BY a.geom <-> pa.geom
  LIMIT 1
) s
ORDER BY sentido, orden;
