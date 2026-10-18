# Configuración única del pipeline. Cualquier valor se puede sobrescribir con una
# variable de entorno del mismo nombre (p. ej. para achicar la caja con BBOX).
#
# Caja santiago-centro del enunciado: lon -70.75 .. -70.52, lat -33.52 .. -33.36
BBOX="${BBOX:--70.75,-33.52,-70.52,-33.36}"      # xmin,ymin,xmax,ymax en EPSG:4326
SRID="${SRID:-5361}"                              # SIRGAS-Chile / UTM 19S

DATA_DIR="${DATA_DIR:-/datos}"
PROYECTO_DIR="${PROYECTO_DIR:-/proyecto}"
RESULTADOS_DIR="${RESULTADOS_DIR:-$PROYECTO_DIR/resultados}"

# Nombres esperados de los archivos fuente dentro de $DATA_DIR (ver README).
OSM_PBF="${OSM_PBF:-chile-latest.osm.pbf}"
OSM_GPKG="${OSM_GPKG:-osm_santiago-centro.gpkg}"   # salida de preparar_datos.py (Lab 05)
GTFS_ZIP="${GTFS_ZIP:-}"                          # vacío = el único/último GTFS*.zip de $DATA_DIR
DPA_SQL="${DPA_SQL:-comunas_cl.sql}"              # Lab 03: 03/datos/comunas_cl.sql
DPA_TABLA="${DPA_TABLA:-}"                        # vacío = se detecta sola tras cargar el .sql

IFS=, read -r BBOX_XMIN BBOX_YMIN BBOX_XMAX BBOX_YMAX <<< "$BBOX"
export BBOX SRID DATA_DIR PROYECTO_DIR RESULTADOS_DIR BBOX_XMIN BBOX_YMIN BBOX_XMAX BBOX_YMAX

export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"   # sin NOTICEs de "ya existe"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)
PG_OGR="PG:dbname=${PGDATABASE:-tarea1} host=${PGHOST:-localhost} port=${PGPORT:-5432} user=${PGUSER:-postgres} password=${PGPASSWORD:-postgres}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Registra un hecho del ETL en stgo.etl_log (aparece en el README y en el informe)
meta() {  # meta <etapa> <clave> <valor>
  # (las variables :'x' de psql no se interpolan en -c; por eso va por stdin)
  echo "INSERT INTO stgo.etl_log(etapa, clave, valor) VALUES (:'e', :'k', :'v');" \
    | "${PSQL[@]}" -v e="$1" -v k="$2" -v v="$3" >/dev/null
}

# Ejecuta un .sql con la configuración disponible como variables psql
psql_f() {
  "${PSQL[@]}" -v srid="$SRID" -v xmin="$BBOX_XMIN" -v ymin="$BBOX_YMIN" \
     -v xmax="$BBOX_XMAX" -v ymax="$BBOX_YMAX" -f "$1"
}
