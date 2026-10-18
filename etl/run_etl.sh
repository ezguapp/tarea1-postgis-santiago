#!/usr/bin/env bash
# =============================================================================
# run_etl.sh — orquestador del ETL. Corre DENTRO del contenedor (lo llama
# ./cargar.sh). Orden: esquema -> OSM -> GTFS -> DPA -> índices + ANALYZE -> conteos.
# =============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config.sh"
mkdir -p "$RESULTADOS_DIR"

T0=$SECONDS
paso() {  # paso <nombre> <comando...>
  local nombre="$1"; shift
  local t=$SECONDS
  log "== $nombre"
  "$@"
  meta tiempos "$nombre" "$((SECONDS - t))"
}

log "Caja: $BBOX  ·  SRID $SRID  ·  datos en $DATA_DIR"
ls -la "$DATA_DIR" || true

# El esquema stgo (con la bitácora) se crea primero; los demás pasos la usan.
log "== 00 esquema"; psql_f "$DIR/00_esquema.sql"

if [ "${OSM_RAW_PRELOADED:-0}" = 1 ]; then
  log "== 10 OSM: osm_raw ya cargado (modo prueba), se omite ogr2ogr"
  meta osm fuente_cargada "osm_raw precargado (prueba sintética)"
else
  paso "10 osm carga"    bash "$DIR/10_osm_cargar.sh"
fi
paso "11 osm derivar"  psql_f "$DIR/11_osm_derivar.sql"
paso "20 gtfs carga"   bash "$DIR/20_gtfs_cargar.sh"
paso "21 gtfs derivar" psql_f "$DIR/21_gtfs_derivar.sql"
paso "30 dpa carga"    bash "$DIR/30_dpa_cargar.sh"
paso "31 dpa derivar"  psql_f "$DIR/31_dpa_derivar.sql"
paso "90 indices"      psql_f "$DIR/90_indices.sql"
meta tiempos total "$((SECONDS - T0))"

log "== 95 conteos -> $RESULTADOS_DIR"
psql_f "$DIR/95_conteos.sql" > /dev/null
"${PSQL[@]}" --csv -c "SELECT * FROM stgo.v_conteos"  > "$RESULTADOS_DIR/conteos.csv"
"${PSQL[@]}" --csv -c "SELECT * FROM stgo.v_indices"  > "$RESULTADOS_DIR/indices.csv"
"${PSQL[@]}" --csv -c "SELECT etapa, clave, valor FROM stgo.etl_log ORDER BY id" > "$RESULTADOS_DIR/etl_log.csv"

echo
"${PSQL[@]}" -c "SELECT tabla, filas, tamano, indices FROM stgo.v_conteos"
log "ETL terminado en $((SECONDS - T0)) s. Siguiente paso: ./consultas.sh"
