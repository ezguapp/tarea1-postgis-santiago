#!/usr/bin/env bash
# =============================================================================
# consultas.sh — corre las 7 preguntas (Parte C) sobre la base ya cargada:
#   * resultados/qN_*.csv              resultado de cada consulta
#   * resultados/planes/*.txt|.json    EXPLAIN (ANALYZE, BUFFERS) de las pedidas
#   * resultados/indices_uso.csv       pg_stat_user_indexes tras las consultas
#   * salidas/*.png                    mapas
#   * salidas/mapas_tarea1.gpkg        capas exportadas de los mapas (para QGIS)
#   * informe/informe.html             informe armado con los resultados
#
# Uso:  ./consultas.sh            (requiere haber corrido ./cargar.sh)
#       RUTA=210 ./consultas.sh   (cambia el recorrido de la pregunta 5)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
SERVICIO=db

if ! docker compose ps --status running --services 2>/dev/null | grep -qx "$SERVICIO"; then
  echo ">> El contenedor no está corriendo; ejecutando 'docker compose up -d'..."
  docker compose up -d
  sleep 5
fi

USUARIO=()
if [ "$(uname -s)" = "Linux" ]; then USUARIO=(--user "$(id -u):$(id -g)"); fi

ENVS=()
[ -n "${RUTA:-}" ] && ENVS+=(-e "RUTA=$RUTA")

docker compose exec -T ${USUARIO[@]+"${USUARIO[@]}"} ${ENVS[@]+"${ENVS[@]}"} "$SERVICIO" bash /proyecto/consultas/run_consultas.sh
docker compose exec -T ${USUARIO[@]+"${USUARIO[@]}"} "$SERVICIO" python3 -I /proyecto/mapas/hacer_mapas.py
docker compose exec -T ${USUARIO[@]+"${USUARIO[@]}"} "$SERVICIO" python3 -I /proyecto/informe/generar_informe.py
echo ">> Listo. Abra informe/informe.html en el navegador y exporte a PDF (Ctrl+P)."
