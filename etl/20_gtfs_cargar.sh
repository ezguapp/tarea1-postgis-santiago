#!/usr/bin/env bash
# =============================================================================
# 20_gtfs_cargar.sh — GTFS (CSV dentro de un ZIP) a gtfs_raw, con COPY.
#
# * Cada .txt se carga con \copy (COPY del lado cliente: un solo flujo por archivo,
#   nunca INSERT fila por fila). Así entra stop_times (millones de filas) en
#   segundos y sin agotar memoria.
# * Las columnas se crean a partir de la cabecera de CADA archivo: el orden y el
#   conjunto de columnas opcionales varía entre versiones del GTFS de la DTPM.
# * Todo se carga como texto en tablas UNLOGGED (staging descartable: no vale la
#   pena escribir WAL); los tipos se fijan al derivar (21_gtfs_derivar.sql).
#   Ojo: shape_pt_sequence es texto aquí; se castea a integer antes de ordenar.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.sh"

# --- ZIP a usar ---------------------------------------------------------------
if [ -n "$GTFS_ZIP" ]; then
  ZIP="$DATA_DIR/$GTFS_ZIP"
else
  mapfile -t ZIPS < <(ls -1 "$DATA_DIR"/*.zip 2>/dev/null | sort)
  if [ "${#ZIPS[@]}" -eq 0 ]; then
    echo "ERROR: no hay ningún .zip de GTFS en $DATA_DIR. Ver README, sección 'Datos'." >&2; exit 1
  fi
  ZIP="${ZIPS[-1]}"   # GTFS_AAAAMMDD.zip: el último por nombre es el más reciente
  [ "${#ZIPS[@]}" -gt 1 ] && log "GTFS: hay ${#ZIPS[@]} ZIP; se usa el más reciente por nombre"
fi
[ -f "$ZIP" ] || { echo "ERROR: no existe $ZIP" >&2; exit 1; }
log "GTFS: $ZIP"
meta gtfs zip_archivo "$(basename "$ZIP")"
meta gtfs zip_bytes "$(stat -c %s "$ZIP")"
meta gtfs zip_sha256 "$(sha256sum "$ZIP" | cut -c1-16)"
meta gtfs zip_mtime "$(date -u -r "$ZIP" +%Y-%m-%dT%H:%M:%SZ)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
unzip -q -o -j "$ZIP" '*.txt' -d "$TMP"     # -j: ignora carpetas internas del ZIP

for f in stops shapes trips routes; do
  ls "$TMP" | grep -qix "$f.txt" || { echo "ERROR: el ZIP no trae $f.txt" >&2; exit 1; }
done

"${PSQL[@]}" -c "DROP SCHEMA IF EXISTS gtfs_raw CASCADE; CREATE SCHEMA gtfs_raw;"

cargar_txt() {  # cargar_txt <archivo.txt> <tabla>
  local archivo="$1" t="$2" cab cols
  # Cabecera: sin BOM, sin \r, sin comillas ni espacios, en minúsculas
  cab=$(head -n 1 "$archivo" | sed -e 's/^\xEF\xBB\xBF//' -e 's/\r$//' -e 's/"//g' -e 's/ //g' \
        | tr '[:upper:]' '[:lower:]')
  # columnas vacías (coma final) se nombran col_N para que el CREATE no falle
  cab=$(echo "$cab" | awk -F, -v OFS=, '{for(i=1;i<=NF;i++) if($i=="") $i="col_" i; print}')
  cols=$(echo "$cab" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\" text", (i>1?", ":""), $i}}')
  "${PSQL[@]}" -c "CREATE UNLOGGED TABLE gtfs_raw.$t ($cols);"
  local lista; lista=$(echo "$cab" | awk -F, '{for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}}')
  local t0=$SECONDS
  if ! "${PSQL[@]}" -c "\\copy gtfs_raw.$t ($lista) FROM '$archivo' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')" 2>"$TMP/err"; then
    log "   $t.txt falló como UTF-8 ($(head -c 200 "$TMP/err")); reintentando como LATIN1"
    "${PSQL[@]}" -c "TRUNCATE gtfs_raw.$t"
    "${PSQL[@]}" -c "\\copy gtfs_raw.$t ($lista) FROM '$archivo' WITH (FORMAT csv, HEADER true, ENCODING 'LATIN1')"
    meta gtfs "encoding_$t" LATIN1
  fi
  "${PSQL[@]}" -c "ANALYZE gtfs_raw.$t"
  local n; n=$("${PSQL[@]}" -At -c "SELECT count(*) FROM gtfs_raw.$t")
  log "   gtfs_raw.$t: $n filas ($((SECONDS - t0)) s)"
  meta gtfs "raw_$t" "$n"
  meta gtfs "raw_${t}_segundos" "$((SECONDS - t0))"
}

for f in "$TMP"/*.txt; do
  [ -s "$f" ] || { log "   $(basename "$f") vacío, se omite"; continue; }
  cargar_txt "$f" "$(basename "$f" .txt | tr '[:upper:]' '[:lower:]')"
done
