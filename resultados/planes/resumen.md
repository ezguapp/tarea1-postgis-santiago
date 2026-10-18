# Resumen automático de los planes de ejecución

Generado por `consultas/resumen_planes.py` a partir de `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.
Los tiempos son de una ejecución con caché caliente en la máquina donde se corrió.

## q1_paraderos_comuna
Ejecución: **40 ms** (planificación 11.1 ms) · con índices apagados: **532 ms** (×13.4)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `paraderos_gtfs_geom_gix` | paraderos_gtfs | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 86 | `(geom && s.geom)` |
| `comunas_pkey` | comunas | Index Scan | Hash Join: lado interno (se sondea una vez por cada fila del lado externo) | 1 | `` |

Recorridos secuenciales: comunas_sub (86 filas × 1)

## q2_cobertura
Ejecución: **4720 ms** (planificación 10.3 ms)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `edificios_pto_gix` | edificios | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 86 | `(pto && s.geom)` |
| `paraderos_gtfs_geom_gix` | paraderos_gtfs | Index Scan | dentro de un subplan (EXISTS/NOT EXISTS o subconsulta por fila) | 118950 | `(geom && st_expand(ed.pto, '500'::double precision))` |
| `paraderos_osm_geom_gix` | paraderos_osm | Index Scan | dentro de un subplan (EXISTS/NOT EXISTS o subconsulta por fila) | 118950 | `(geom && st_expand(ed.pto, '500'::double precision))` |
| `comunas_pkey` | comunas | Index Scan | Hash Join: lado interno (se sondea una vez por cada fila del lado externo) | 1 | `` |

Recorridos secuenciales: caja (1 filas × 1), comunas_sub (86 filas × 1)

## q3_dos_fuentes
Ejecución: **945 ms** (planificación 9.7 ms)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `paraderos_osm_geom_gix` | paraderos_osm | Index Scan | dentro de un subplan (EXISTS/NOT EXISTS o subconsulta por fila) | 19707 | `(geom && st_expand(p.geom, ("*VALUES*".column1)::double precision))` |
| `paraderos_gtfs_geom_gix` | paraderos_gtfs | Index Scan | dentro de un subplan (EXISTS/NOT EXISTS o subconsulta por fila) | 19716 | `(geom && st_expand(o.geom, ("*VALUES*".column1)::double precision))` |

Recorridos secuenciales: paraderos_gtfs (6569 filas × 3), paraderos_osm (6572 filas × 3)

## q4a_km_comuna_sin_subdivide
Ejecución: **2497 ms** (planificación 9.3 ms) · con índices apagados: **2912 ms** (×1.2)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `comunas_pkey` | comunas | Index Scan | Nested Loop: lado externo (se recorre una vez y guía el join) | 1 | `` |
| `recorridos_geom_gix` | recorridos | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 30 | `(geom && c.geom)` |

## q4b_km_comuna_con_subdivide
Ejecución: **2495 ms** (planificación 9.5 ms)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `comunas_sub_cut_idx` | comunas_sub | Index Scan | Nested Loop: lado externo (se recorre una vez y guía el join) | 1 | `` |
| `recorridos_geom_gix` | recorridos | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 86 | `(geom && s.geom)` |
| `comunas_pkey` | comunas | Index Scan | Merge Join: lado interno (se sondea una vez por cada fila del lado externo) | 1 | `` |

## q5_vecino_salud
Ejecución: **15 ms** (planificación 2.0 ms) · con índices apagados: **599 ms** (×39.5)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `viajes_route_idx` | viajes | Index Scan | Nested Loop: lado externo (se recorre una vez y guía el join) | 1 | `(route_id = '506'::text)` |
| `recorridos_pkey` | recorridos | Bitmap Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 2 | `(shape_id = v.shape_id)` |
| `stop_times_trip_idx` | stop_times | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 2 | `(trip_id = v.trip_id)` |
| `paraderos_gtfs_pkey` | paraderos_gtfs | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 183 | `(stop_id = st.stop_id)` |
| `amenidades_salud_gix` | amenidades | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 117 | `(geom <-> p.geom)` |

## q6_grilla_calculo
Ejecución: **4646 ms** (planificación 2.0 ms)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `recorridos_tramos_geom_gix` | recorridos_tramos | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 636 | `(geom && h_1.geom)` |
| `paraderos_gtfs_geom_gix` | paraderos_gtfs | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 636 | `(geom && h_2.geom)` |
| `edificios_pto_gix` | edificios | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 636 | `(pto && h_3.geom)` |

Recorridos secuenciales: caja (1 filas × 1), caja (1 filas × 1)

## q6_top10
Ejecución: **100 ms** (planificación 9.2 ms)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `comunas_sub_geom_gix` | comunas_sub | Index Scan | Nested Loop: lado interno (se sondea una vez por cada fila del lado externo) | 521 | `(geom && st_centroid(g.geom))` |

Recorridos secuenciales: mv_grilla (521 filas × 1)

## q7a_jerarquia_vial
Ejecución: **179436 ms** (planificación 10.0 ms)

| Índice | Tabla | Nodo | Lado | Veces | Condición |
|---|---|---|---|---|---|
| `recorridos_tramos_geom_gix` | recorridos_tramos | Index Scan | dentro de un subplan (EXISTS/NOT EXISTS o subconsulta por fila) | 960010 | `(geom && st_expand(st_lineinterpolatepoint(d.geom, '0.5'::double precision), '15'::double ` |

Recorridos secuenciales: calles (35088 filas × 2)

