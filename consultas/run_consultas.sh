#!/usr/bin/env bash
# =============================================================================
# run_consultas.sh — corre las preguntas de la Parte C (dentro del contenedor;
# lo llama ./consultas.sh). Por cada consulta deja en resultados/:
#   qN_*.csv                     el resultado
#   planes/qN_*.txt              EXPLAIN (ANALYZE, BUFFERS) legible
#   planes/qN_*.json             el mismo plan en JSON (lo resume resumen_planes.py)
#   planes/qN_*_sin_indice.txt   el plan con los índices apagados (enable_*scan = off)
# y además tiempos.csv, indices_uso.csv (pg_stat_user_indexes) y planes/resumen.md
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/../etl/config.sh"
R="$RESULTADOS_DIR"
mkdir -p "$R/planes"

"${PSQL[@]}" -At -c "SELECT 1 FROM stgo.recorridos LIMIT 1" >/dev/null 2>&1 \
  || { echo "ERROR: la base no está cargada. Corra primero ./cargar.sh" >&2; exit 1; }

# ---------------------------------------------------------------- recorrido Q5
RUTA="${RUTA:-506}"
RUTA_ID=$(echo "SELECT route_id FROM stgo.recorridos WHERE route_short_name = :'r' AND route_type = 3
                ORDER BY es_principal DESC, n_viajes DESC LIMIT 1;" | "${PSQL[@]}" -At -v r="$RUTA")
MOTIVO="elegido (RUTA=$RUTA)"
if [ -z "$RUTA_ID" ]; then
  # el recorrido pedido no está en este GTFS: se toma el de más paraderos en la caja
  read -r RUTA_ID RUTA <<< "$("${PSQL[@]}" -At -F ' ' -c "
     SELECT v.route_id, r.route_short_name FROM stgo.viajes v
     JOIN stgo.stop_times st USING (trip_id) JOIN stgo.paraderos_gtfs p USING (stop_id)
     JOIN stgo.rutas r USING (route_id) WHERE r.route_type = 3
     GROUP BY 1, 2 ORDER BY count(DISTINCT st.stop_id) DESC, 1 LIMIT 1")"
  MOTIVO="RUTA pedida no existe en el GTFS; se usa la de más paraderos en la caja"
fi
log "Pregunta 5: recorrido $RUTA (route_id $RUTA_ID) — $MOTIVO"
"${PSQL[@]}" --csv -v rid="$RUTA_ID" -v motivo="$MOTIVO" <<'SQL' > "$R/q5_ruta.csv"
SELECT route_id, route_short_name, route_long_name, :'motivo' AS motivo,
       count(*) AS shapes, round(sum(longitud_km) FILTER (WHERE es_principal)::numeric, 1) AS km_principales
FROM stgo.recorridos WHERE route_id = :'rid' GROUP BY 1, 2, 3;
SQL

# ---------------------------------------------------------------- utilidades
VARS=(-v ruta_id="$RUTA_ID")
SIN_INDICE="SET enable_indexscan = off; SET enable_bitmapscan = off; SET enable_indexonlyscan = off;"
echo "consulta,variante,planning_ms,execution_ms" > "$R/tiempos.csv"

tiempo_json() {  # extrae Planning/Execution Time del JSON de EXPLAIN
  python3 -I -c "import json,sys; p=json.load(open(sys.argv[1]))[0]; print(f\"{p['Planning Time']:.1f},{p['Execution Time']:.1f}\")" "$1"
}

correr() {  # correr <archivo.sql> <explain:0|1> <sin_indice:0|1>
  local f="$1" ex="$2" si="$3" base; base="$(basename "$f" .sql)"
  log "   $base"
  # El resultado queda también como tabla res.<consulta>: de ahí leen los mapas,
  # el GeoPackage exportado y el informe (una sola ejecución por resultado).
  { echo "DROP TABLE IF EXISTS res.$base; CREATE TABLE res.$base AS"; cat "$f"; } | "${PSQL[@]}" "${VARS[@]}"
  "${PSQL[@]}" --csv -c "SELECT * FROM res.$base" > "$R/$base.csv"
  if [ "$ex" = 1 ]; then
    { echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)"; cat "$f"; } \
      | "${PSQL[@]}" "${VARS[@]}" -At > "$R/planes/$base.txt"
    { echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)"; cat "$f"; } \
      | "${PSQL[@]}" "${VARS[@]}" -At > "$R/planes/$base.json"
    echo "$base,con_indices,$(tiempo_json "$R/planes/$base.json")" >> "$R/tiempos.csv"
  fi
  if [ "$si" = 1 ]; then
    { echo "$SIN_INDICE EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)"; cat "$f"; } \
      | "${PSQL[@]}" "${VARS[@]}" -At > "$R/planes/${base}_sin_indice.txt"
    { echo "$SIN_INDICE EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)"; cat "$f"; } \
      | "${PSQL[@]}" "${VARS[@]}" -At > "$R/planes/${base}_sin_indice.json"
    echo "$base,sin_indices,$(tiempo_json "$R/planes/${base}_sin_indice.json")" >> "$R/tiempos.csv"
  fi
}

"${PSQL[@]}" -c "CREATE SCHEMA IF NOT EXISTS res"

# Contadores de uso de índices en cero: lo que se mida después es de las consultas
"${PSQL[@]}" -c "SELECT pg_stat_reset()" >/dev/null

log "Consultas:"
correr "$DIR/q1_paraderos_comuna.sql"         1 1
correr "$DIR/q2_cobertura.sql"                1 0
correr "$DIR/q3_dos_fuentes.sql"              1 0
correr "$DIR/q3b_dos_fuentes_comuna.sql"      0 0
correr "$DIR/q4a_km_comuna_sin_subdivide.sql" 1 1
correr "$DIR/q4b_km_comuna_con_subdivide.sql" 1 0
correr "$DIR/q5_vecino_salud.sql"             1 1

log "   q6_grilla_mv (vista materializada)"
T=$(date +%s%N)
"${PSQL[@]}" -f "$DIR/q6_grilla_mv.sql"
echo "q6_grilla_mv,construccion_vista,,$(( ($(date +%s%N) - T) / 1000000 ))" >> "$R/tiempos.csv"
# Plan de la construcción de la grilla (la parte cara de la pregunta 6)
sed -n '/\[inicio consulta\]/,/\[fin consulta\]/p' "$DIR/q6_grilla_mv.sql" > "$R/planes/.q6_calculo.sql"
{ echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)"; cat "$R/planes/.q6_calculo.sql"; } \
  | "${PSQL[@]}" -At > "$R/planes/q6_grilla_calculo.txt"
{ echo "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)"; cat "$R/planes/.q6_calculo.sql"; } \
  | "${PSQL[@]}" -At > "$R/planes/q6_grilla_calculo.json"
echo "q6_grilla_calculo,con_indices,$(tiempo_json "$R/planes/q6_grilla_calculo.json")" >> "$R/tiempos.csv"
rm -f "$R/planes/.q6_calculo.sql"
correr "$DIR/q6_top10.sql"                    1 0
correr "$DIR/q6b_grilla_resumen.sql"          0 0
correr "$DIR/q7a_jerarquia_vial.sql"          1 0
correr "$DIR/q7b_recorridos_sin_calle.sql"    0 0

# Uso de índices. Cada sesión publica sus contadores al cerrarse; se leen en una
# sesión nueva, con todas las de las consultas ya cerradas.
sleep 1
"${PSQL[@]}" --csv -c "
  SELECT s.relname AS tabla, s.indexrelname AS indice, s.idx_scan AS usos,
         s.idx_tup_read AS tuplas_leidas, pg_size_pretty(pg_relation_size(s.indexrelid)) AS tamano,
         CASE WHEN s.idx_scan = 0 THEN 'NO USADO' ELSE '' END AS nota
  FROM pg_stat_user_indexes s
  WHERE s.schemaname = 'stgo'
  ORDER BY s.idx_scan, s.relname, s.indexrelname" > "$R/indices_uso.csv"

python3 -I "$DIR/resumen_planes.py" "$R/planes"
log "Resultados en $R (resumen de planes: planes/resumen.md)"
