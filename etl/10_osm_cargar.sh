#!/usr/bin/env bash
# =============================================================================
# 10_osm_cargar.sh — OSM a staging (osm_raw.points / lines / multipolygons)
#
# Dos caminos, en este orden de preferencia:
#   A) $DATA_DIR/osm_santiago-centro.gpkg  (salida de preparar_datos.py del Lab 05)
#   B) $DATA_DIR/chile-latest.osm.pbf      (recorte propio: osmium extract a la caja
#                                           + ogr2ogr, mismo driver OSM de GDAL)
# En ambos casos el resultado es el mismo esquema que produce el driver OSM de
# GDAL (columnas name/highway/building/... + other_tags en formato hstore).
# Las geometrías se dejan en su SRID de origen; la reproyección a 5361 y la
# reparación se hacen en SQL (11_osm_derivar.sql) para poder contarlas.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/config.sh"

"${PSQL[@]}" -c "DROP SCHEMA IF EXISTS osm_raw CASCADE; CREATE SCHEMA osm_raw;"

OGR_OPTS=(-f PostgreSQL "$PG_OGR" -overwrite -lco SCHEMA=osm_raw -lco GEOMETRY_NAME=geom
          -lco SPATIAL_INDEX=NONE -lco FID=ogc_fid -lco PRECISION=NO
          --config PG_USE_COPY YES
          -spat "$BBOX_XMIN" "$BBOX_YMIN" "$BBOX_XMAX" "$BBOX_YMAX" -spat_srs EPSG:4326)

GPKG="$DATA_DIR/$OSM_GPKG"
PBF="$DATA_DIR/$OSM_PBF"

# Fecha del extracto de Geofabrik (va en la cabecera del PBF). Se registra si el PBF
# está presente, aunque se cargue desde el GeoPackage.
if [ -f "$PBF" ]; then
  TS=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "$PBF" 2>/dev/null || true)
  [ -z "$TS" ] && TS=$(osmium fileinfo -g header.option.timestamp "$PBF" 2>/dev/null || true)
  meta osm pbf_archivo "$OSM_PBF"
  meta osm pbf_bytes "$(stat -c %s "$PBF")"
  meta osm pbf_timestamp "${TS:-desconocido}"
  meta osm pbf_mtime "$(date -u -r "$PBF" +%Y-%m-%dT%H:%M:%SZ)"
fi

if [ -f "$GPKG" ]; then
  log "OSM: cargando GeoPackage $OSM_GPKG (camino A)"
  meta osm fuente_cargada "$OSM_GPKG"
  meta osm gpkg_mtime "$(date -u -r "$GPKG" +%Y-%m-%dT%H:%M:%SZ)"
  # Cada capa se identifica por su tipo de geometría, no por su nombre, para no
  # depender de cómo nombró las capas el script del laboratorio.
  #   "1: points (Point)"  /  "2: lines (Line String)"  /  "4: multipolygons (Multi Polygon)"
  mapfile -t CAPAS < <(ogrinfo -ro -q "$GPKG" | sed -n 's/^[0-9]*: \(.*\) (\(.*\))$/\1|\2/p')
  declare -A DESTINO=()
  for c in "${CAPAS[@]}"; do
    nombre="${c%%|*}"; tipo="${c##*|}"
    case "$tipo" in
      "Point"|"3D Point")                         dst=points ;;
      "Line String"|"3D Line String"|"Multi Line String") dst=lines ;;
      "Multi Polygon"|"3D Multi Polygon"|"Polygon"|"3D Polygon") dst=multipolygons ;;
      *) dst="" ;;
    esac
    # si hay más de una capa del mismo tipo, preferir la que se llama como el destino
    if [ -n "$dst" ] && { [ -z "${DESTINO[$dst]:-}" ] || [ "$nombre" = "$dst" ]; }; then
      DESTINO[$dst]="$nombre"
    fi
  done
  for dst in points lines multipolygons; do
    src="${DESTINO[$dst]:-}"
    if [ -z "$src" ]; then echo "ERROR: el GeoPackage no tiene capa de tipo $dst" >&2; exit 1; fi
    log "   capa '$src' -> osm_raw.$dst"
    extra=(); [ "$dst" = multipolygons ] && extra=(-nlt MULTIPOLYGON)
    ogr2ogr "${OGR_OPTS[@]}" ${extra[@]+"${extra[@]}"} -nln "$dst" "$GPKG" "$src"
    meta osm "capa_$dst" "$src"
  done

elif [ -f "$PBF" ]; then
  log "OSM: recortando $OSM_PBF a la caja con osmium (camino B)"
  meta osm fuente_cargada "$OSM_PBF (recorte osmium extract --strategy complete_ways)"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  osmium extract --overwrite --strategy complete_ways -b "$BBOX" "$PBF" -o "$TMP/recorte.osm.pbf"
  meta osm recorte_bytes "$(stat -c %s "$TMP/recorte.osm.pbf")"
  log "OSM: ogr2ogr recorte -> osm_raw (points, lines, multipolygons)"
  # El driver OSM lee las capas intercaladas; se piden las tres en una sola pasada.
  # (points = Point, lines = LineString, multipolygons = MultiPolygon: no hace falta -nlt)
  ogr2ogr "${OGR_OPTS[@]}" --config OSM_MAX_TMPFILE_SIZE 1024 \
          "$TMP/recorte.osm.pbf" points lines multipolygons
else
  echo "ERROR: no encuentro ni $GPKG ni $PBF. Ver README, sección 'Datos'." >&2
  exit 1
fi

for t in points lines multipolygons; do
  "${PSQL[@]}" -c "ANALYZE osm_raw.$t"
  n=$("${PSQL[@]}" -At -c "SELECT count(*) FROM osm_raw.$t")
  log "   osm_raw.$t: $n filas"
  meta osm "raw_$t" "$n"
done
