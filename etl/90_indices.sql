-- =============================================================================
-- 90_indices.sql — índices de todas las tablas derivadas + VACUUM ANALYZE
-- Se crean al final (después de cargar) porque construir un GiST sobre datos
-- ya cargados es mucho más rápido que mantenerlo fila por fila durante la carga.
-- Cuáles se usaron de verdad lo dice resultados/indices_uso.csv
-- (pg_stat_user_indexes, medido después de correr las consultas).
-- =============================================================================

-- Espaciales (GiST) ------------------------------------------------------------
CREATE INDEX calles_geom_gix          ON stgo.calles          USING gist (geom);
CREATE INDEX edificios_geom_gix       ON stgo.edificios       USING gist (geom);   -- polígono
CREATE INDEX edificios_pto_gix        ON stgo.edificios       USING gist (pto);    -- punto interior
CREATE INDEX paraderos_osm_geom_gix   ON stgo.paraderos_osm   USING gist (geom);
CREATE INDEX paraderos_gtfs_geom_gix  ON stgo.paraderos_gtfs  USING gist (geom);
CREATE INDEX amenidades_geom_gix      ON stgo.amenidades      USING gist (geom);
-- parcial: solo farmacias y centros de salud (pregunta 5). El planificador lo
-- puede usar cuando el WHERE de la consulta implica el predicado del índice.
CREATE INDEX amenidades_salud_gix     ON stgo.amenidades      USING gist (geom)
  WHERE amenity IN ('pharmacy', 'hospital', 'clinic', 'doctors');
CREATE INDEX recorridos_geom_gix      ON stgo.recorridos      USING gist (geom);
CREATE INDEX recorridos_tramos_geom_gix ON stgo.recorridos_tramos USING gist (geom);
CREATE INDEX comunas_geom_gix         ON stgo.comunas         USING gist (geom);
CREATE INDEX comunas_sub_geom_gix     ON stgo.comunas_sub     USING gist (geom);

-- Alfanuméricos (B-tree) ---------------------------------------------------------
CREATE INDEX calles_highway_idx       ON stgo.calles (highway);
CREATE INDEX amenidades_amenity_idx   ON stgo.amenidades (amenity);
CREATE INDEX recorridos_route_idx     ON stgo.recorridos (route_id);
CREATE INDEX recorridos_short_idx     ON stgo.recorridos (route_short_name);
CREATE INDEX viajes_route_idx         ON stgo.viajes (route_id);
CREATE INDEX viajes_shape_idx         ON stgo.viajes (shape_id);
CREATE INDEX stop_times_trip_idx      ON stgo.stop_times (trip_id, stop_sequence);
CREATE INDEX stop_times_stop_idx      ON stgo.stop_times (stop_id);
CREATE INDEX comunas_sub_cut_idx      ON stgo.comunas_sub (cut);

-- Estadísticas para el planificador (y visibility map para index-only scans)
VACUUM (ANALYZE) stgo.calles;
VACUUM (ANALYZE) stgo.edificios;
VACUUM (ANALYZE) stgo.paraderos_osm;
VACUUM (ANALYZE) stgo.paraderos_gtfs;
VACUUM (ANALYZE) stgo.amenidades;
VACUUM (ANALYZE) stgo.recorridos;
VACUUM (ANALYZE) stgo.recorridos_tramos;
VACUUM (ANALYZE) stgo.rutas;
VACUUM (ANALYZE) stgo.viajes;
VACUUM (ANALYZE) stgo.stop_times;
VACUUM (ANALYZE) stgo.comunas;
VACUUM (ANALYZE) stgo.comunas_sub;
VACUUM (ANALYZE) stgo.caja;
ANALYZE;   -- el resto de la base (staging incluido)
