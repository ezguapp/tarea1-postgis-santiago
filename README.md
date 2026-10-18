# Tarea 1 — PostGIS de punta a punta: Santiago centro

Procesamiento Masivo de Datos · ELE051-B / EIN102B · USM 2026-2 · Paralelo 701

**Integrantes:** NOMBRE 1 · NOMBRE 2 · NOMBRE 3

Pipeline geoespacial reproducible que cruza **OpenStreetMap** (ciudad construida) con el **GTFS de la red de
transporte público** (DTPM) y las **comunas oficiales (DPA 2023)** en PostGIS, para responder:
*¿cómo se relaciona la ciudad construida con la red de transporte público?*

```
fuente ─► staging (osm_raw, gtfs_raw, dpa_raw) ─► esquema propio stgo (SRID 5361, reparado, indexado)
       ─► consultas (resultados/ + planes/) ─► mapas (salidas/*.png + mapas_tarea1.gpkg) ─► informe
```

---

## 1. Reproducir desde cero

**Requisitos:** Docker con Compose v2 (`docker compose version`), ~8 GB libres en disco, `bash`
(Linux / macOS; en Windows usar Git Bash o WSL). No hace falta instalar PostgreSQL, GDAL ni Python: todo corre
dentro del contenedor.

```bash
git clone https://github.com/USUARIO/REPO.git && cd REPO
# 1) dejar los 3 archivos fuente en ./data  (sección 2)
# 2) levantar PostGIS (la primera vez construye la imagen, ~3-5 min)
docker compose up -d
# 3) cargar todo: tablas creadas, reparadas, indexadas y con ANALYZE
./cargar.sh
# 4) (opcional para la carga) consultas, planes, mapas, GeoPackage e informe
./consultas.sh
```

`./cargar.sh` es el único script de carga: no hay que editar rutas ni correr pasos a mano. Es idempotente
(se puede repetir: rehace los esquemas). En Windows sin bash, el equivalente es
`docker compose exec -T db bash /proyecto/etl/run_etl.sh` y
`docker compose exec -T db bash /proyecto/consultas/run_consultas.sh`.

La base queda expuesta en `localhost:5433` (usuario `postgres`, clave `postgres`, base `tarea1`) para
conectarse desde QGIS o DBeaver. Se usa 5433 para no chocar con el PostGIS del Lab 05.

Parámetros opcionales (variables de entorno):

| Variable | Por defecto | Para qué |
|---|---|---|
| `BBOX` | `-70.75,-33.52,-70.52,-33.36` | achicar la caja si la máquina va justa (anotarlo aquí) |
| `RUTA` | `506` | recorrido de la pregunta 5 (`RUTA=210 ./consultas.sh`) |
| `GTFS_ZIP` | el `.zip` más reciente de `data/` | fijar qué ZIP del GTFS usar |
| `DPA_TABLA` | detección automática | `esquema.tabla` si la detección de la tabla de comunas falla |

## 2. Datos (no versionados)

Los datos fuente **no están en el repositorio** (`.gitignore`). Hay que dejarlos en `./data/` con estos nombres:

| Archivo en `data/` | Fuente | Cómo obtenerlo |
|---|---|---|
| `chile-latest.osm.pbf` (~330 MB) | Geofabrik, licencia ODbL | `curl -L -o data/chile-latest.osm.pbf https://download.geofabrik.de/south-america/chile-latest.osm.pbf` |
| `GTFS_AAAAMMDD.zip` | DTPM, GTFS vigente | descargar desde https://www.dtpm.cl/index.php/noticias/gtfs-vigente y dejarlo con su nombre original |
| `comunas_cl.sql` (~218 MB) | DPA 2023, Lab 03 | copiar desde el repositorio del curso: `03/datos/comunas_cl.sql` |

*Alternativa para OSM:* si se deja `data/osm_santiago-centro.gpkg` (salida de
`python3 preparar_datos.py --zona santiago-centro` del Lab 05), se carga ese archivo en vez del PBF. Sin él, el
pipeline recorta el PBF a la caja con `osmium extract` dentro del contenedor (mismo resultado, sin pasos extra).

### Versión y fecha de cada fuente

Fechas de descarga (completar a mano): OSM descargado el **DD-MM-AAAA**, GTFS descargado el **DD-MM-AAAA**.
El resto lo escribe el pipeline desde `stgo.etl_log` (fecha de la cabecera del PBF, nombre y hash del ZIP):

<!-- AUTO:FUENTES -->
(se completa al correr ./consultas.sh)
<!-- /AUTO:FUENTES -->

Si la DTPM publica un GTFS nuevo después de la descarga, **no se migra**: se entrega con el ZIP indicado arriba.

## 3. Esquema resultante

Todo lo derivado vive en el esquema `stgo`, en **SRID 5361** (SIRGAS-Chile / UTM 19S). Los esquemas `osm_raw`,
`gtfs_raw` y `dpa_raw` son staging (lo que llega de cada fuente, tal cual); `res` guarda el resultado de cada consulta.

| Tabla | Qué es |
|---|---|
| `calles` | vías OSM con `highway` (MultiLineString) |
| `edificios` | polígonos OSM con `building` reparados (`geom`) + punto interior (`pto`) y área |
| `paraderos_osm` | nodos OSM `highway=bus_stop` |
| `amenidades` | nodos y áreas OSM con `amenity` (las áreas por su punto interior) |
| `paraderos_gtfs` | `stops.txt` → `ST_SetSRID(ST_MakePoint(lon, lat), 4326)` → 5361; marca bus / metro y nº de viajes |
| `recorridos` | una LineString por `shape_id` (`ST_MakeLine(... ORDER BY shape_pt_sequence::int)`), con su ruta, sentido y `es_principal` |
| `recorridos_tramos` | los recorridos cortados con `ST_Subdivide` (≤ 32 vértices) para joins con índice |
| `rutas`, `viajes`, `stop_times` | `routes.txt`, `trips.txt`, `stop_times.txt` tipados |
| `comunas` | DPA 2023: comunas que tocan la caja, con área total y área dentro de la caja |
| `comunas_sub` | comunas cortadas con `ST_Subdivide` (≤ 255 vértices) |
| `mv_grilla` | vista materializada de la grilla hexagonal de la pregunta 6 |
| `etl_log` | bitácora: fuentes, versiones, conteos, reparaciones, tiempos |

Conteos e índices de la última corrida (`resultados/conteos.csv`, `resultados/indices.csv`):

<!-- AUTO:CONTEOS -->
(se completa al correr ./consultas.sh)
<!-- /AUTO:CONTEOS -->

## 4. Decisiones tomadas

- **SRID 5361 para todo.** Es métrico y conforme en la zona: `ST_DWithin(…, 500)`, `ST_Length` y `ST_Area` dan
  metros sin pasar a `geography`. OSM y GTFS llegan en 4326 y se transforman al derivar. La caja se densifica en
  4326 antes de proyectarla (sus bordes rectos en lon/lat no lo son en UTM).
- **OSM con ogr2ogr** (driver OSM de GDAL) a staging; las claves que no quedan como columna (por ejemplo `amenity`
  en los nodos, con el `osmconf.ini` por defecto) se leen de `other_tags`. Así funciona igual con el GeoPackage del
  Lab 05 o con el PBF.
- **Punto interior vs polígono.** Los edificios guardan ambos. Cobertura, asignación a comuna y grilla usan
  `ST_PointOnSurface`: cada edificio se cuenta una vez, y el punto cae siempre dentro del edificio (un centroide
  puede caer fuera de un edificio en «L» o con patio, e incluso en otra comuna o celda).
- **Reparación con `ST_MakeValid`** en 5361, conservando solo la parte poligonal (`ST_CollectionExtract(…, 3)`);
  los que quedan vacíos se descartan. Cuántos y por qué:

  <!-- AUTO:REPARACIONES -->
  (se completa al correr ./consultas.sh)
  <!-- /AUTO:REPARACIONES -->

- **GTFS con `\copy`** (COPY del lado cliente, un flujo por archivo; nunca INSERT por fila) a tablas `UNLOGGED`
  de texto con las columnas de la cabecera de cada archivo; los tipos se fijan al derivar. `stop_times.txt` se carga
  igual (número de filas en `etl_log`, clave `gtfs.raw_stop_times`).
- **Orden de vértices:** `shape_pt_sequence` se castea a `integer` antes de ordenar (como texto, `'10' < '9'`).
  El ETL registra cuántos shapes quedarían mal ordenados si no se hiciera.
- **Varios shapes por ruta** (ida/vuelta/variantes): se conservan todos; cada shape se asocia vía `trips` a la ruta
  y sentido con más viajes, y `es_principal` marca el shape con más viajes de cada (ruta, sentido). Los km por
  comuna (P4) suman ida y vuelta pero no variantes; la grilla (P6) cuenta rutas distintas (`route_id`).
- **Recorte a la caja en la base, no a mano:** paraderos por lon/lat; shapes que intersectan la caja (completos);
  comunas con su área total y su área dentro de la caja (las densidades usan esta última, si no las comunas que la
  caja corta quedarían subestimadas).
- **Solo paraderos de bus** en P1–P3 (`es_bus`, derivado de `stop_times` → `routes.route_type = 3`): las
  estaciones de metro no son comparables con `highway=bus_stop` de OSM.
- **Índices:** GiST en cada geometría, uno parcial para las amenidades de salud (P5), B-tree en las llaves de join;
  `VACUUM ANALYZE` al final. `ST_Subdivide` en comunas y recorridos. Índices que **no** se usaron en ninguna
  consulta (`pg_stat_user_indexes`, medido después de `./consultas.sh`; es un hallazgo, no un error):

  <!-- AUTO:INDICES_NO_USADOS -->
  (se completa al correr ./consultas.sh)
  <!-- /AUTO:INDICES_NO_USADOS -->

## 5. Consultas (Parte C)

`./consultas.sh` corre todo y deja cada resultado en `resultados/<consulta>.csv` (y como tabla `res.<consulta>`).
Los planes `EXPLAIN (ANALYZE, BUFFERS)` quedan en `resultados/planes/` en texto y JSON, con un resumen automático
(`planes/resumen.md`: qué índice, de qué lado del join, cuántas veces) y, para P1, P4 y P5, el mismo plan con los
índices apagados (`*_sin_indice.txt`) para mostrar qué pasaría sin ellos. Tiempos en `resultados/tiempos.csv`.

| # | Pregunta | Archivo(s) | Patrón | Plan | Mapa |
|---|---|---|---|---|---|
| 1 | Paraderos GTFS por comuna y densidad | `q1_paraderos_comuna.sql` | punto-en-polígono | sí (+ sin índice) | `mapa_q1_…` |
| 2 | % de edificios a > 500 m (GTFS vs OSM) | `q2_cobertura.sql` | anti-join `ST_DWithin` | sí | `mapa_q2_…` |
| 3 | Paraderos en una sola fuente (50 m) | `q3_dos_fuentes.sql`, `q3b_…` | anti-join en dos sentidos | sí | `mapa_q3_…` |
| 4 | km de recorrido por comuna | `q4a_…sin_subdivide.sql`, `q4b_…con_subdivide.sql` | `ST_Intersection` línea–polígono | sí, ambas | — |
| 5 | Salud más cercana a cada paradero | `q5_vecino_salud.sql` | `CROSS JOIN LATERAL` + `<->` + `LIMIT 1` | sí (+ sin índice) | `mapa_q5_…` |
| 6 | Grilla hexagonal 500 m | `q6_grilla_mv.sql`, `q6_top10.sql`, `q6b_…` | `ST_HexagonGrid` + vista materializada | sí | `mapa_q6_…` (principal) |
| 7 | Propia: jerarquía vial con buses | `q7a_jerarquia_vial.sql`, `q7b_…` | línea–línea por segmentos + `EXISTS` | sí | capa en GPKG |

Salidas: `salidas/*.png` (mapas con título, escala de color, barra de escala y fuente con fecha) y
`salidas/mapas_tarea1.gpkg` (capas de los mapas para QGIS; es una **salida**, no un dato fuente).
El informe se arma en `informe/informe.html` → abrir en Chrome → Imprimir → Guardar como PDF (A4).

## 6. Qué no funcionó / límites conocidos

- COMPLETAR con lo que les haya pasado en la corrida real (errores, tiempos largos, cambios de fuente).
- Distancias euclidianas (no por red vial): son una cota inferior del acceso real.
- Efecto borde: lo que está justo fuera de la caja no se cargó. Se cuantifica en P2 (columna «núcleo») y la P6
  ordena solo celdas completamente dentro de la caja.
- La DPA del Lab 03 se carga con su propio `.sql`; nombres de tabla, columnas y SRID se detectan solos y quedan
  en `etl_log` (`dpa.*`). Si un dump trajo errores no fatales (p. ej. `OWNER TO` un rol inexistente), quedan en
  `resultados/dpa_carga_errores.log`.

## 7. Prueba sin datos reales

`tests/humo.sh` genera datos **sintéticos** con la forma de las fuentes reales (incluye edificios inválidos,
shapes de más de 10 puntos, paraderos OSM corridos o faltantes, cabecera con BOM y CRLF) y corre ETL + consultas
+ mapas + informe en una base aparte (`tarea1_humo`), sin tocar la base real:

```bash
docker compose exec db bash /proyecto/tests/humo.sh
```

## 8. Estructura

```
docker-compose.yml, docker/Dockerfile   PostGIS 16-3.4 + GDAL + osmium + matplotlib
cargar.sh                               carga completa (ETL)
consultas.sh                            consultas + planes + mapas + GeoPackage + informe
etl/                                    00 esquema · 10/11 OSM · 20/21 GTFS · 30/31 DPA · 90 índices · 95 conteos
consultas/                              una consulta por archivo + run_consultas.sh + resumen_planes.py
mapas/hacer_mapas.py                    mapas PNG y GeoPackage
informe/generar_informe.py              informe HTML (→ PDF) y secciones AUTO de este README
resultados/                             CSV, planes, tiempos, conteos, uso de índices, bitácora
salidas/                                mapas y GeoPackage exportado
data/                                   datos fuente (NO versionados)
tests/                                  prueba de humo con datos sintéticos
```

Datos OSM © colaboradores de OpenStreetMap, disponibles bajo la Open Database License (ODbL).
