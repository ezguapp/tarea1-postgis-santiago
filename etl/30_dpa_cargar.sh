#!/usr/bin/env bash
# =============================================================================
# 30_dpa_cargar.sh — División Político Administrativa 2023 (comunas_cl.sql, Lab 03)
#
# El .sql del Lab 03 crea su propia tabla (nombre, esquema y SRID los decide ese
# archivo). Para no depender de esos detalles:
#   1. se anotan las tablas con geometría que existen ANTES de cargarlo,
#   2. se ejecuta el .sql con search_path = dpa_raw,
#   3. la(s) tabla(s) nueva(s) se mueven a dpa_raw (así una segunda corrida parte
#      limpia y no duplica filas),
#   4. 31_dpa_derivar.sql detecta columnas de nombre/código y el SRID.
# Si la detección automática no sirve: DPA_TABLA=esquema.tabla ./cargar.sh
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.sh"

SQL="$DATA_DIR/$DPA_SQL"
[ -f "$SQL" ] || { echo "ERROR: no existe $SQL. Ver README, sección 'Datos'." >&2; exit 1; }
meta dpa sql_archivo "$DPA_SQL"
meta dpa sql_bytes "$(stat -c %s "$SQL")"

"${PSQL[@]}" -c "DROP SCHEMA IF EXISTS dpa_raw CASCADE; CREATE SCHEMA dpa_raw;"

ANTES=$("${PSQL[@]}" -At -c "SELECT string_agg(quote_ident(f_table_schema)||'.'||quote_ident(f_table_name), ',')
                              FROM geometry_columns")

log "DPA: ejecutando $DPA_SQL (puede tardar ~1 min)"
# ON_ERROR_STOP=0 a propósito: un dump suele traer 'CREATE EXTENSION postgis' u
# 'ALTER ... OWNER TO <rol del lab>' que fallan aquí sin consecuencia. Los errores
# quedan en resultados/dpa_carga_errores.log y la verificación de abajo decide.
mkdir -p "$RESULTADOS_DIR"
psql -X -q -v ON_ERROR_STOP=0 \
     -c "SET search_path TO dpa_raw, public" \
     -f "$SQL" > /dev/null 2> "$RESULTADOS_DIR/dpa_carga_errores.log" || true
NERR=$(grep -c "ERROR" "$RESULTADOS_DIR/dpa_carga_errores.log" || true)
meta dpa errores_no_fatales_al_cargar "$NERR"

# Tablas con geometría que aparecieron con la carga
mapfile -t NUEVAS < <("${PSQL[@]}" -At -v antes="${ANTES:-}" <<'SQL'
SELECT quote_ident(f_table_schema) || '.' || quote_ident(f_table_name)
FROM geometry_columns
WHERE NOT (quote_ident(f_table_schema) || '.' || quote_ident(f_table_name)) = ANY (string_to_array(:'antes', ','))
  AND f_table_schema NOT IN ('stgo', 'osm_raw', 'gtfs_raw');
SQL
)
for t in "${NUEVAS[@]}"; do
  [ -z "$t" ] && continue
  case "$t" in dpa_raw.*) ;; *)
    log "   moviendo $t a dpa_raw"
    "${PSQL[@]}" -c "ALTER TABLE $t SET SCHEMA dpa_raw" ;;
  esac
done

"${PSQL[@]}" -v tabla="$DPA_TABLA" <<'SQL'
INSERT INTO stgo.config VALUES ('dpa_tabla', :'tabla');
SQL

N=$("${PSQL[@]}" -At -c "SELECT count(*) FROM geometry_columns WHERE f_table_schema = 'dpa_raw'")
if [ "$N" = 0 ] && [ -z "$DPA_TABLA" ]; then
  echo "ERROR: $DPA_SQL no creó ninguna tabla con geometría. Revise $RESULTADOS_DIR/dpa_carga_errores.log" >&2
  exit 1
fi
log "   tablas con geometría en dpa_raw: $N"
