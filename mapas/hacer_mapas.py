#!/usr/bin/env python3
"""
Mapas de la Tarea 1 (PNG para el informe) + GeoPackage con las capas de cada
mapa (salidas/mapas_tarea1.gpkg), para abrirlas en QGIS.

Lee de la base (psql --csv; no necesita psycopg ni geopandas): las geometrías
salen como GeoJSON en metros (SRID 5361) y se dibujan con matplotlib.
Cada mapa lleva título, escala de color con su unidad, barra de escala, norte y
la fuente con FECHA de cada dato (tomada de stgo.etl_log, no escrita a mano).

Corre dentro del contenedor (lo llama ./consultas.sh).
"""
import csv, io, json, os, shutil, subprocess, sys
from datetime import date

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.collections import LineCollection, PatchCollection
from matplotlib.colors import LogNorm, Normalize
from matplotlib.patches import PathPatch
from matplotlib.path import Path

PROY = os.environ.get("PROYECTO_DIR", "/proyecto")
SAL = os.environ.get("SALIDAS_DIR", os.path.join(PROY, "salidas"))
RES = os.environ.get("RESULTADOS_DIR", os.path.join(PROY, "resultados"))
os.makedirs(SAL, exist_ok=True)

plt.rcParams.update({"font.size": 8, "font.family": "DejaVu Sans", "axes.titlesize": 10,
                     "axes.titleweight": "bold", "figure.dpi": 100})


# ------------------------------------------------------------------ datos
def sql(q):
    r = subprocess.run(["psql", "-X", "-q", "--csv", "-c", q], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"Error en la consulta del mapa:\n{q}\n{r.stderr}")
    return list(csv.DictReader(io.StringIO(r.stdout)))


def existe(tabla):
    return sql(f"SELECT to_regclass('{tabla}') IS NOT NULL AS ok")[0]["ok"] == "t"


def meta():
    m = {}
    for f in sql("SELECT etapa || '.' || clave AS k, valor FROM stgo.etl_log ORDER BY id"):
        m[f["k"]] = f["valor"]
    return m


M = meta()


def fecha_osm():
    ts = M.get("osm.pbf_timestamp", "")
    if ts and ts != "desconocido":
        return ts[:10]
    for k in ("osm.gpkg_mtime", "osm.pbf_mtime"):
        if k in M:
            return M[k][:10] + " (fecha del archivo)"
    return "fecha no registrada"


def fuente_txt(con_osm=True, con_gtfs=True):
    partes = []
    if con_osm:
        partes.append(f"OSM © colaboradores de OpenStreetMap (ODbL), extracto Geofabrik chile-latest del {fecha_osm()}")
    if con_gtfs:
        partes.append(f"GTFS DTPM {M.get('gtfs.zip_archivo', '?')}")
    partes.append("DPA 2023 (comunas)")
    return "Fuentes: " + "; ".join(partes) + f".  SIRGAS-Chile UTM 19S (EPSG:5361). Elaboración propia, {date.today():%d-%m-%Y}."


# ------------------------------------------------------------------ geometría
def a_paths(gj):
    g = json.loads(gj) if isinstance(gj, str) else gj
    polys = [g["coordinates"]] if g["type"] == "Polygon" else g["coordinates"] if g["type"] == "MultiPolygon" else []
    if g["type"] == "GeometryCollection":
        out = []
        for h in g["geometries"]:
            out += a_paths(h)
        return out
    out = []
    for poly in polys:
        verts, codes = [], []
        for anillo in poly:
            verts += anillo
            codes += [Path.MOVETO] + [Path.LINETO] * (len(anillo) - 2) + [Path.CLOSEPOLY]
        out.append(Path(verts, codes))
    return out


def a_lineas(gj):
    g = json.loads(gj)
    if g["type"] == "LineString":
        return [g["coordinates"]]
    if g["type"] == "MultiLineString":
        return g["coordinates"]
    return []


def poligonos(ax, filas, valores=None, cmap=None, norm=None, **kw):
    patches, vals = [], []
    for i, f in enumerate(filas):
        for p in a_paths(f["gj"]):
            patches.append(PathPatch(p))
            if valores is not None:
                vals.append(valores[i])
    pc = PatchCollection(patches, **kw)
    if valores is not None:
        import numpy as np
        pc.set_array(np.array(vals, dtype=float))
        pc.set_cmap(cmap)
        pc.set_norm(norm)
    ax.add_collection(pc)
    return pc


def caja():
    return sql("SELECT ST_AsGeoJSON(geom, 0) AS gj, ST_XMin(geom) x0, ST_YMin(geom) y0, "
               "ST_XMax(geom) x1, ST_YMax(geom) y1 FROM stgo.caja")[0]


CAJA = caja()


def marco(ax, extent=None, margen=300):
    x0, y0, x1, y1 = extent or (float(CAJA["x0"]), float(CAJA["y0"]), float(CAJA["x1"]), float(CAJA["y1"]))
    ax.set_xlim(x0 - margen, x1 + margen)
    ax.set_ylim(y0 - margen, y1 + margen)
    ax.set_aspect("equal")
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_color("#999999"); s.set_linewidth(0.5)
    # barra de escala
    ancho = x1 - x0
    largo = next(l for l in (500, 1000, 2000, 5000, 10000) if l >= ancho / 6)
    bx, by = x0 + ancho * 0.04, y0 + (y1 - y0) * 0.04
    ax.plot([bx, bx + largo], [by, by], color="black", lw=2.2, solid_capstyle="butt", zorder=20)
    ax.text(bx + largo / 2, by + (y1 - y0) * 0.012, f"{largo / 1000:g} km", ha="center", va="bottom",
            fontsize=7, zorder=20)
    # norte (en UTM 19S el norte de la grilla ≈ norte verdadero en esta zona)
    nx, ny = x1 - ancho * 0.05, y1 - (y1 - y0) * 0.12
    ax.annotate("N", xy=(nx, ny + (y1 - y0) * 0.08), xytext=(nx, ny), ha="center", fontsize=8,
                fontweight="bold", arrowprops=dict(arrowstyle="-|>", color="black", lw=1), zorder=20)


def borde_caja(ax):
    poligonos(ax, [CAJA], facecolor="none", edgecolor="#333333", linewidth=0.8, linestyle="--", zorder=15)


def pie(fig, texto):
    fig.text(0.01, 0.006, texto, fontsize=5.6, color="#444444", ha="left", va="bottom", wrap=True)


def guardar(fig, nombre):
    ruta = os.path.join(SAL, nombre)
    fig.savefig(ruta, dpi=200, bbox_inches="tight", pad_inches=0.06, facecolor="white")
    plt.close(fig)
    print(f"   {ruta}")


def etiquetas_comunas(ax, filas, tam=5.5):
    for f in filas:
        ax.text(float(f["lx"]), float(f["ly"]), f["nombre"].title(), fontsize=tam, ha="center",
                va="center", color="#111111", zorder=18,
                bbox=dict(boxstyle="round,pad=0.12", fc="white", ec="none", alpha=0.6))


def comunas_con(tabla_res, columnas):
    cols = ", ".join(f"r.{c}" for c in columnas)
    return sql(f"""
      SELECT c.cut, c.nombre, {cols},
             ST_AsGeoJSON(ST_SimplifyPreserveTopology(c.geom_caja, 5), 0) AS gj,
             ST_X(ST_PointOnSurface(c.geom_caja)) AS lx, ST_Y(ST_PointOnSurface(c.geom_caja)) AS ly
      FROM stgo.comunas c LEFT JOIN res.{tabla_res} r ON r.cut = c.cut
      ORDER BY c.cut""")


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return float("nan")


# ------------------------------------------------------------------ mapa 1
def mapa_q1():
    filas = comunas_con("q1_paraderos_comuna", ["paraderos", "densidad_km2"])
    vals = [num(f["densidad_km2"]) for f in filas]
    fig, ax = plt.subplots(figsize=(7.2, 6.0))
    norm = Normalize(vmin=0, vmax=max(v for v in vals if v == v))
    pc = poligonos(ax, filas, vals, plt.get_cmap("YlOrRd"), norm, edgecolor="white", linewidth=0.6)
    borde_caja(ax); marco(ax); etiquetas_comunas(ax, filas)
    cb = fig.colorbar(pc, ax=ax, shrink=0.7, pad=0.01)
    cb.set_label("paraderos GTFS de bus por km² (área de la comuna dentro de la caja)")
    ax.set_title("P1 · Densidad de paraderos GTFS por comuna — Santiago centro")
    pie(fig, fuente_txt(con_osm=False))
    guardar(fig, "mapa_q1_densidad_paraderos.png")


# ------------------------------------------------------------------ mapa 2
def mapa_q2():
    filas = comunas_con("q2_cobertura", ["pct_lejos_gtfs", "pct_lejos_osm"])
    g = [num(f["pct_lejos_gtfs"]) for f in filas]
    o = [num(f["pct_lejos_osm"]) for f in filas]
    vmax = max(v for v in g + o if v == v) or 1
    norm = Normalize(vmin=0, vmax=vmax)
    fig, axs = plt.subplots(1, 2, figsize=(10, 4.6))
    for ax, vals, t in ((axs[0], g, "según paraderos GTFS (operador)"), (axs[1], o, "según bus_stop de OSM (voluntarios)")):
        pc = poligonos(ax, filas, vals, plt.get_cmap("PuRd"), norm, edgecolor="white", linewidth=0.6)
        borde_caja(ax); marco(ax); etiquetas_comunas(ax, filas, 4.6)
        ax.set_title(t, fontsize=9)
    cb = fig.colorbar(pc, ax=axs, shrink=0.75, pad=0.01)
    cb.set_label("% de edificios OSM a más de 500 m de un paradero")
    fig.suptitle("P2 · Edificios sin paradero a 500 m (distancia euclidiana), por comuna", fontweight="bold", fontsize=10)
    pie(fig, fuente_txt())
    guardar(fig, "mapa_q2_cobertura_500m.png")


# ------------------------------------------------------------------ mapa 3
def mapa_q3():
    com = sql("SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom_caja, 5), 0) AS gj FROM stgo.comunas")
    pts = sql("""
      SELECT 'gtfs' AS f, ST_X(p.geom) x, ST_Y(p.geom) y,
             NOT EXISTS (SELECT 1 FROM stgo.paraderos_osm o WHERE ST_DWithin(o.geom, p.geom, 50)) AS sin
      FROM stgo.paraderos_gtfs p WHERE p.es_bus
      UNION ALL
      SELECT 'osm', ST_X(o.geom), ST_Y(o.geom),
             NOT EXISTS (SELECT 1 FROM stgo.paraderos_gtfs p WHERE p.es_bus AND ST_DWithin(p.geom, o.geom, 50))
      FROM stgo.paraderos_osm o""")
    fig, ax = plt.subplots(figsize=(7.2, 6.0))
    poligonos(ax, com, facecolor="#f2f2f2", edgecolor="#bbbbbb", linewidth=0.5)
    ok = [p for p in pts if p["f"] == "gtfs" and p["sin"] == "f"]
    gs = [p for p in pts if p["f"] == "gtfs" and p["sin"] == "t"]
    os_ = [p for p in pts if p["f"] == "osm" and p["sin"] == "t"]
    ax.scatter([num(p["x"]) for p in ok], [num(p["y"]) for p in ok], s=0.6, c="#9a9a9a", lw=0,
               label=f"GTFS con bus_stop OSM a < 50 m ({len(ok)})", zorder=5)
    ax.scatter([num(p["x"]) for p in gs], [num(p["y"]) for p in gs], s=3.5, c="#d7301f", lw=0,
               label=f"GTFS sin OSM a < 50 m ({len(gs)})", zorder=6)
    ax.scatter([num(p["x"]) for p in os_], [num(p["y"]) for p in os_], s=3.5, c="#2b8cbe", lw=0, marker="s",
               label=f"OSM sin GTFS a < 50 m ({len(os_)})", zorder=7)
    borde_caja(ax); marco(ax)
    ax.legend(loc="upper left", fontsize=6.5, markerscale=3, frameon=True, framealpha=0.9)
    ax.set_title("P3 · Paraderos que solo existen en una de las dos fuentes (umbral 50 m)")
    pie(fig, fuente_txt())
    guardar(fig, "mapa_q3_dos_fuentes.png")


# ------------------------------------------------------------------ mapa 5
def mapa_q5():
    if not existe("res.q5_vecino_salud"):
        return
    # el recorrido elegido para la P5 lo deja run_consultas.sh en resultados/q5_ruta.csv
    with open(os.path.join(RES, "q5_ruta.csv")) as f:
        info = next(csv.DictReader(f))
    r = info["route_id"].replace("'", "''")
    lin = sql(f"SELECT direction_id, ST_AsGeoJSON(geom, 0) gj FROM stgo.recorridos WHERE route_id = '{r}' AND es_principal")
    par = sql(f"""
      WITH vt AS (
        SELECT DISTINCT ON (v.direction_id) v.trip_id FROM stgo.viajes v
        JOIN stgo.recorridos rr ON rr.shape_id = v.shape_id AND rr.es_principal
        WHERE v.route_id = '{r}' ORDER BY v.direction_id, v.trip_id)
      SELECT DISTINCT ON (p.stop_id) ST_X(p.geom) x, ST_Y(p.geom) y, ST_X(s.geom) sx, ST_Y(s.geom) sy, s.d
      FROM vt JOIN stgo.stop_times st USING (trip_id) JOIN stgo.paraderos_gtfs p USING (stop_id)
      CROSS JOIN LATERAL (SELECT a.geom, a.geom <-> p.geom AS d FROM stgo.amenidades a
                          WHERE a.amenity IN ('pharmacy','hospital','clinic','doctors')
                          ORDER BY a.geom <-> p.geom LIMIT 1) s""")
    if not par:
        return
    import numpy as np
    xs = [num(p["x"]) for p in par] + [num(p["sx"]) for p in par]
    ys = [num(p["y"]) for p in par] + [num(p["sy"]) for p in par]
    ext = (min(xs), min(ys), max(xs), max(ys))
    fig, ax = plt.subplots(figsize=(7.2, 5.2))
    com = sql("SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom_caja, 5), 0) AS gj FROM stgo.comunas")
    poligonos(ax, com, facecolor="#f5f5f5", edgecolor="#cccccc", linewidth=0.5)
    for l in lin:
        ax.add_collection(LineCollection(a_lineas(l["gj"]), colors="#555555", linewidths=1.0, zorder=4))
    ax.add_collection(LineCollection([[(num(p["x"]), num(p["y"])), (num(p["sx"]), num(p["sy"]))] for p in par],
                                     colors="#e08214", linewidths=0.5, zorder=5))
    d = np.array([num(p["d"]) for p in par])
    sc = ax.scatter([num(p["x"]) for p in par], [num(p["y"]) for p in par], c=d, cmap="viridis_r",
                    s=9, zorder=6, norm=Normalize(0, max(d.max(), 1)))
    ax.scatter([num(p["sx"]) for p in par], [num(p["sy"]) for p in par], marker="P", s=16, c="#b2182b",
               zorder=7, label="farmacia / centro de salud más cercano")
    marco(ax, ext, margen=600)
    cb = fig.colorbar(sc, ax=ax, shrink=0.7, pad=0.01); cb.set_label("distancia al más cercano (m)")
    ax.legend(loc="lower right", fontsize=6.5)
    ax.set_title(f"P5 · Recorrido {info['route_short_name']}: salud más cercana a cada paradero")
    pie(fig, fuente_txt())
    guardar(fig, "mapa_q5_ruta_salud.png")


# ------------------------------------------------------------------ mapa 6
def mapa_q6():
    if not existe("stgo.mv_grilla"):
        return
    celdas = sql("SELECT celda, n_edificios, n_recorridos, ST_AsGeoJSON(geom, 0) gj FROM stgo.mv_grilla")
    top = sql("""SELECT t.rk, ST_AsGeoJSON(g.geom, 0) gj, ST_X(ST_Centroid(g.geom)) x, ST_Y(ST_Centroid(g.geom)) y
                 FROM res.q6_top10 t JOIN stgo.mv_grilla g USING (celda)""")
    com = sql("SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom_caja, 5), 0) AS gj FROM stgo.comunas")
    fig, axs = plt.subplots(1, 2, figsize=(10.4, 4.9))
    e = [num(c["n_edificios"]) for c in celdas]
    r = [num(c["n_recorridos"]) for c in celdas]
    specs = ((axs[0], e, "YlGnBu", "edificios OSM por celda (punto interior)", "Edificios"),
             (axs[1], r, "OrRd", "recorridos GTFS distintos que cruzan la celda", "Recorridos"))
    for ax, vals, cm, etiqueta, titulo in specs:
        pc = poligonos(ax, celdas, vals, plt.get_cmap(cm), Normalize(0, max(vals) or 1),
                       edgecolor="white", linewidth=0.15)
        poligonos(ax, com, facecolor="none", edgecolor="#666666", linewidth=0.35, zorder=8)
        poligonos(ax, top, facecolor="none", edgecolor="#e7298a", linewidth=1.6, zorder=12)
        for t in top:
            ax.text(num(t["x"]), num(t["y"]), t["rk"], fontsize=5.5, ha="center", va="center",
                    color="#e7298a", fontweight="bold", zorder=13)
        borde_caja(ax); marco(ax)
        cb = fig.colorbar(pc, ax=ax, shrink=0.72, pad=0.01, orientation="horizontal")
        cb.set_label(etiqueta, fontsize=7)
        ax.set_title(titulo, fontsize=9)
    fig.suptitle("P6 · Grilla hexagonal de 500 m de lado: edificios vs. recorridos "
                 "(contorno fucsia = 10 celdas con más edificios y menos recorridos)", fontweight="bold", fontsize=9.5)
    pie(fig, fuente_txt())
    guardar(fig, "mapa_q6_grilla_hexagonal.png")


# ------------------------------------------------------------------ GeoPackage
def exportar_gpkg():
    if shutil.which("ogr2ogr") is None:
        print("   (ogr2ogr no disponible: se omite el GeoPackage; corre dentro del contenedor)")
        return
    ruta = os.path.join(SAL, "mapas_tarea1.gpkg")
    if os.path.exists(ruta):
        os.remove(ruta)
    pg = ("PG:dbname={d} host={h} port={p} user={u} password={w}".format(
        d=os.environ.get("PGDATABASE", "tarea1"), h=os.environ.get("PGHOST", "localhost"),
        p=os.environ.get("PGPORT", "5432"), u=os.environ.get("PGUSER", "postgres"),
        w=os.environ.get("PGPASSWORD", "postgres")))
    capas = {
        "p1_p2_p4_comunas": """
            SELECT c.cut, c.nombre, c.area_caja_km2, c.pct_en_caja,
                   q1.paraderos, q1.densidad_km2,
                   q2.edificios, q2.pct_lejos_gtfs, q2.pct_lejos_osm, q2.dif_osm_menos_gtfs_pp,
                   q3.pct_gtfs_sin_osm, q3.pct_osm_sin_gtfs,
                   q4.km_principales, q4.km_por_km2, q4.rutas,
                   c.geom_caja AS geom
            FROM stgo.comunas c
            LEFT JOIN res.q1_paraderos_comuna q1 USING (cut)
            LEFT JOIN res.q2_cobertura q2 USING (cut)
            LEFT JOIN res.q3b_dos_fuentes_comuna q3 USING (cut)
            LEFT JOIN res.q4b_km_comuna_con_subdivide q4 USING (cut)""",
        "p3_paraderos_gtfs": """
            SELECT p.stop_id, p.stop_code, p.stop_name, p.n_rutas,
                   NOT EXISTS (SELECT 1 FROM stgo.paraderos_osm o WHERE ST_DWithin(o.geom, p.geom, 50)) AS sin_osm_50m,
                   p.geom FROM stgo.paraderos_gtfs p WHERE p.es_bus""",
        "p3_paraderos_osm": """
            SELECT o.osm_id, o.nombre,
                   NOT EXISTS (SELECT 1 FROM stgo.paraderos_gtfs p WHERE p.es_bus AND ST_DWithin(p.geom, o.geom, 50)) AS sin_gtfs_50m,
                   o.geom FROM stgo.paraderos_osm o""",
        "p6_grilla": """
            SELECT g.celda, g.n_edificios, g.n_recorridos, g.n_rutas_bus, g.n_paraderos, g.frac_en_caja,
                   t.rk AS top10_rk, g.geom
            FROM stgo.mv_grilla g LEFT JOIN res.q6_top10 t USING (celda)""",
        "recorridos_principales": """
            SELECT shape_id, route_id, route_short_name, direction_id, route_type, longitud_km, geom
            FROM stgo.recorridos WHERE es_principal""",
        "caja_estudio": "SELECT 'santiago-centro' AS nombre, geom FROM stgo.caja",
    }
    for k, (nombre, q) in enumerate(capas.items()):
        extra = ["-update"] if k > 0 else []          # la primera capa crea el archivo
        r = subprocess.run(["ogr2ogr", "-f", "GPKG", ruta, pg, "-sql", " ".join(q.split()), "-nln", nombre,
                            "-a_srs", "EPSG:5361"] + extra, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"   (capa {nombre} no exportada: {r.stderr.strip()[:200]})")
    print(f"   {ruta}")


if __name__ == "__main__":
    print("Mapas:")
    for f in (mapa_q1, mapa_q2, mapa_q3, mapa_q5, mapa_q6):
        try:
            f()
        except Exception as e:          # un mapa que falla no bota los demás
            print(f"   ERROR en {f.__name__}: {e}")
    exportar_gpkg()
