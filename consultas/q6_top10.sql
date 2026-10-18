-- =============================================================================
-- Pregunta 6 — las 10 celdas con MÁS edificios y MENOS recorridos
-- Criterio (dos objetivos en uno): índice = n_edificios / (n_recorridos + 1).
-- Crece con los edificios y cae con cada recorrido; el +1 evita dividir por 0
-- y hace que una celda sin ninguna ruta pese como "una ruta", no infinito.
-- Solo celdas completas (frac_en_caja ≥ 0,99) y con edificios.
-- La comuna es la que contiene el centro de la celda; lon/lat del centro sirven
-- para ubicarla en cualquier visor.
-- =============================================================================
SELECT row_number() OVER (ORDER BY g.n_edificios::numeric / (g.n_recorridos + 1) DESC,
                                   g.n_edificios DESC, g.celda)       AS rk,
       g.celda,
       g.n_edificios,
       g.n_recorridos,
       g.n_rutas_bus,
       g.n_paraderos,
       round(g.n_edificios::numeric / (g.n_recorridos + 1), 1)        AS indice,
       c.nombre                                                       AS comuna,
       round(ST_X(ST_Transform(ST_Centroid(g.geom), 4326))::numeric, 5) AS lon,
       round(ST_Y(ST_Transform(ST_Centroid(g.geom), 4326))::numeric, 5) AS lat
FROM stgo.mv_grilla g
LEFT JOIN LATERAL (
  SELECT s.nombre FROM stgo.comunas_sub s
  WHERE ST_Intersects(s.geom, ST_Centroid(g.geom)) LIMIT 1
) c ON true
WHERE g.frac_en_caja >= 0.99 AND g.n_edificios > 0
ORDER BY rk
LIMIT 10;
