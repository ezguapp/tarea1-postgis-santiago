#!/usr/bin/env bash
# =============================================================================
# tests/humo.sh — prueba de humo con datos SINTÉTICOS (no reales).
# Verifica que ETL + consultas + mapas + informe corran de punta a punta sin
# descargar nada. Se puede correr dentro del contenedor:
#     docker compose exec db bash /proyecto/tests/humo.sh
# Usa una base aparte (tarea1_humo) para no tocar la base real.
# =============================================================================
set -euo pipefail
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
export PGDATABASE=tarea1_humo
export DATA_DIR="${TMPDIR:-/tmp}/tarea1_sinteticos"
export PROYECTO_DIR="$RAIZ"
export RESULTADOS_DIR="${TMPDIR:-/tmp}/tarea1_humo_resultados"
export SALIDAS_DIR="$RESULTADOS_DIR/salidas"
export INFORME_DIR="$RESULTADOS_DIR/informe"
export ACTUALIZAR_README=0          # no escribir números sintéticos en el README

psql -X -q -d postgres -c "DROP DATABASE IF EXISTS tarea1_humo" -c "CREATE DATABASE tarea1_humo"
psql -X -q -c "CREATE EXTENSION postgis"
python3 "$RAIZ/tests/generar_sinteticos.py" "$DATA_DIR"
psql -X -q -v ON_ERROR_STOP=1 -f "$DATA_DIR/osm_raw.sql" > /dev/null

OSM_RAW_PRELOADED=1 bash "$RAIZ/etl/run_etl.sh"
bash "$RAIZ/consultas/run_consultas.sh"
python3 "$RAIZ/mapas/hacer_mapas.py"
python3 "$RAIZ/informe/generar_informe.py"
echo "OK: prueba de humo completa. Salidas en $RESULTADOS_DIR"
