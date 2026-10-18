# Tarea 1 — PostGIS de punta a punta: Santiago centro

Procesamiento Masivo de Datos · ELE051-B / EIN102B · USM 2026-2 · Paralelo 701

**Integrantes:** Martin Valenzuela · Diego Leiton · Matias Millan

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
| Fuente | Versión / fecha | Detalle (de stgo.etl_log) |
|---|---|---|
| OSM chile-latest.osm.pbf (Geofabrik) | 2026-10-17 | chile-latest.osm.pbf (recorte osmium extract --strategy complete_ways) |
| GTFS DTPM | GTFS_20261003.zip | sha256 e2dded096b18fdf8…, vigencia 20261003 a 20261231 |
| DPA 2023 comunas (Lab 03) | comunas_cl.sql | tabla dpa_raw.comunas_cl, SRID origen 5361 |
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
| Tabla (stgo.) | Filas | Geometría | Tamaño | Índices |
|---|---|---|---|---|
| amenidades | 20989 | POINT 5361 | 3728 kB | amenidades_amenity_idx (btree), amenidades_geom_gix (gist), amenidades_pkey (btree), amenidades_salud_gix (gist) |
| caja | 1 | POLYGON 5361 | 48 kB | — |
| calles | 100925 | MULTILINESTRING 5361 | 25 MB | calles_geom_gix (gist), calles_highway_idx (btree), calles_pkey (btree) |
| comunas | 30 | MULTIPOLYGON 5361 | 672 kB | comunas_geom_gix (gist), comunas_pkey (btree) |
| comunas_sub | 86 | POLYGON 5361 | 320 kB | comunas_sub_cut_idx (btree), comunas_sub_geom_gix (gist), comunas_sub_pkey (btree) |
| edificios | 118950 | MULTIPOLYGON 5361 | 67 MB | edificios_geom_gix (gist), edificios_pkey (btree), edificios_pto_gix (gist) |
| paraderos_gtfs | 6812 | POINT 5361 | 1424 kB | paraderos_gtfs_geom_gix (gist), paraderos_gtfs_pkey (btree) |
| paraderos_osm | 6572 | POINT 5361 | 1216 kB | paraderos_osm_geom_gix (gist), paraderos_osm_pkey (btree) |
| recorridos | 708 | LINESTRING 5361 | 12 MB | recorridos_geom_gix (gist), recorridos_pkey (btree), recorridos_route_idx (btree), recorridos_short_idx (btree) |
| recorridos_tramos | 33286 | LINESTRING 5361 | 11 MB | recorridos_tramos_geom_gix (gist), recorridos_tramos_pkey (btree) |
| rutas | 428 | — | 104 kB | rutas_pkey (btree) |
| stop_times | 1098529 | — | 118 MB | stop_times_stop_idx (btree), stop_times_trip_idx (btree) |
| viajes | 26159 | — | 3488 kB | viajes_pkey (btree), viajes_route_idx (btree), viajes_shape_idx (btree) |
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
- `osm.edificios_invalidos`: **227**
- `osm.edificios_invalidos_motivo:IllegalArgumentException: Invalid number of points in LinearRing found 2 - must be 0 or >= 4`: **46**
- `osm.edificios_invalidos_motivo:IllegalArgumentException: Invalid number of points in LinearRing found 3 - must be 0 or >= 4`: **155**
- `osm.edificios_invalidos_motivo:Self-intersection`: **26**
- `osm.edificios_descartados_vacios_tras_reparar`: **201**
- `osm.edificios_fuera_de_caja_descartados`: **0**
- `osm.edificios_invalidos_despues`: **0**
- `osm.amenidades_area_invalidas`: **26**
- `gtfs.paraderos_gtfs_sin_viajes`: **1**
- `gtfs.shapes_secuencias_duplicadas`: **0**
- `gtfs.shapes_que_quedarian_mal_ordenando_como_texto`: **981**
- `gtfs.shapes_sin_viajes`: **122**
- `gtfs.shapes_usados_por_mas_de_una_ruta_o_sentido`: **0**
- `gtfs.rutas_con_mas_de_un_shape`: **270**
- `gtfs.recorridos_no_simples(autointersectan)`: **257**
- `dpa.comunas_invalidas`: **0**
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
- `amenidades_amenity_idx` (amenidades, 168 kB)
- `amenidades_geom_gix` (amenidades, 872 kB)
- `calles_highway_idx` (calles, 712 kB)
- `comunas_geom_gix` (comunas, 8192 bytes)
- `edificios_geom_gix` (edificios, 4864 kB)
- `mv_grilla_geom_gix` (mv_grilla, 40 kB)
- `mv_grilla_ij_idx` (mv_grilla, 32 kB)
- `recorridos_short_idx` (recorridos, 32 kB)
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

- Durante la ejecución del proyecto, el computador presentó un rendimiento lento y un uso elevado de recursos al ejecutar los comandos, especialmente durante la descarga de los datos geográficos y la construcción de la imagen de Docker. Esto provocó demoras en la ejecución de algunas tareas.

Además, hubo dificultades para iniciar Docker y construir correctamente la imagen del proyecto debido a errores durante la instalación de dependencias y problemas con los repositorios de paquetes de Debian. Fue necesario revisar y modificar la configuración del Dockerfile para intentar solucionar estos inconvenientes.

Estas dificultades retrasaron el desarrollo y la ejecución del proyecto, por lo que fue necesario realizar varias pruebas y ajustes hasta intentar conseguir un entorno de trabajo funcional.

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
