# Carpeta de datos fuente (no versionada)

Deje aquí, con estos nombres exactos:

| Archivo | De dónde |
|---|---|
| `chile-latest.osm.pbf` | https://download.geofabrik.de/south-america/chile-latest.osm.pbf |
| `GTFS_AAAAMMDD.zip` (el vigente, p. ej. `GTFS_20260829.zip`) | https://www.dtpm.cl/index.php/noticias/gtfs-vigente |
| `comunas_cl.sql` | repositorio del curso, Lab 03: `03/datos/comunas_cl.sql` |

Opcional: `osm_santiago-centro.gpkg` generado con `python3 preparar_datos.py --zona santiago-centro`
(Lab 05). Si está, se carga ese en vez de recortar el PBF.

Todo lo de esta carpeta (salvo este archivo) está en `.gitignore`.
