#!/usr/bin/env bash
# =============================================================================
# cargar.sh — deja TODA la base cargada: OSM + GTFS + DPA en SRID 5361,
# geometrías reparadas, tablas derivadas, índices y ANALYZE.
#
# Uso (desde la raíz del repositorio):
#     docker compose up -d
#     ./cargar.sh
#
# Requisitos: los archivos fuente en ./data (ver README, sección "Datos").
# Todo lo demás corre DENTRO del contenedor: no hay que instalar GDAL, Python
# ni editar rutas. Es idempotente: se puede correr de nuevo y rehace todo.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

export MSYS_NO_PATHCONV=1          # Git Bash en Windows: no reescribir /proyecto/...
SERVICIO=db

if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$SERVICIO"; then
  echo ">> El contenedor no está corriendo; ejecutando 'docker compose up -d'..."
  docker compose up -d
fi

echo ">> Esperando que PostgreSQL acepte conexiones..."
for i in $(seq 1 60); do
  if docker compose exec -T "$SERVICIO" pg_isready -q -U postgres -d tarea1; then break; fi
  sleep 2
  if [ "$i" = 60 ]; then echo "PostgreSQL no respondió en 2 minutos" >&2; exit 1; fi
done

# En Linux los archivos que se escriben en ./resultados quedan con el usuario del
# anfitrión (no root). En macOS/Windows Docker Desktop ya hace ese mapeo.
USUARIO=()
if [ "$(uname -s)" = "Linux" ]; then USUARIO=(--user "$(id -u):$(id -g)"); fi

docker compose exec -T ${USUARIO[@]+"${USUARIO[@]}"} "$SERVICIO" bash /proyecto/etl/run_etl.sh "$@"
