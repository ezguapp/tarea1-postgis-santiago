#!/usr/bin/env python3
"""
Genera datos SINTÉTICOS con la misma forma que las fuentes reales, para probar
el pipeline de punta a punta sin descargar nada (prueba de humo).

  * osm_raw.sql          : las tablas que deja ogr2ogr al leer un PBF con el
                           osmconf.ini por defecto de GDAL (amenity de los nodos
                           queda dentro de other_tags, como en la realidad)
  * GTFS_20990101.zip    : stops (con BOM y CRLF), shapes, trips, routes,
                           stop_times, calendar, agency; buses + 1 línea de metro
  * comunas_cl.sql       : al estilo shp2pgsql, en EPSG:4326

Incluye a propósito: edificios inválidos (corbatín), shapes con >10 puntos (orden
texto != numérico), una ruta con variante, paraderos OSM corridos o faltantes.

Uso:  python3 tests/generar_sinteticos.py <carpeta_salida>
NO son datos reales: sirven solo para verificar que todo corre.
"""
import csv, io, math, os, random, sys, zipfile

random.seed(42)
OUT = sys.argv[1] if len(sys.argv) > 1 else "data_sintetica"
ESCALA = float(os.environ.get("ESCALA", "1"))   # >1 para probar con volúmenes parecidos a los reales
os.makedirs(OUT, exist_ok=True)

X0, Y0, X1, Y1 = -70.75, -33.52, -70.52, -33.36          # caja del enunciado
MX = 111320 * math.cos(math.radians(33.44))               # m por grado de lon
MY = 110950                                               # m por grado de lat

def m2lon(m): return m / MX
def m2lat(m): return m / MY

# ---------------------------------------------------------------- calles (grilla)
STEP_X, STEP_Y = 0.0045, 0.0038                           # ~420 m
xs = [X0 - 0.01 + i * STEP_X for i in range(int((X1 - X0 + 0.02) / STEP_X) + 1)]
ys = [Y0 - 0.01 + j * STEP_Y for j in range(int((Y1 - Y0 + 0.02) / STEP_Y) + 1)]

def categoria(k):
    return "primary" if k % 6 == 0 else "secondary" if k % 3 == 0 else \
           "tertiary" if k % 5 == 0 else "residential"

lineas = []      # (osm_id, name, highway, [(x,y),...])
oid = 1000
for i, x in enumerate(xs):        # calles norte-sur, cortadas en cada cruce (como vías OSM)
    for j in range(len(ys) - 1):
        oid += 1
        lineas.append((oid, f"Calle NS {i}", categoria(i), [(x, ys[j]), (x, ys[j + 1])]))
for j, y in enumerate(ys):
    for i in range(len(xs) - 1):
        oid += 1
        lineas.append((oid, f"Avenida EO {j}", categoria(j + 1), [(xs[i], y), (xs[i + 1], y)]))
# algunos pasajes (footway) que no deberían tener buses
for _ in range(300):
    x = random.uniform(X0, X1); y = random.uniform(Y0, Y1)
    oid += 1
    lineas.append((oid, None, "footway", [(x, y), (x + m2lon(80), y + m2lat(30))]))

# ---------------------------------------------------------------- edificios
def rect(cx, cy, w, h):
    dx, dy = m2lon(w / 2), m2lat(h / 2)
    return [(cx - dx, cy - dy), (cx + dx, cy - dy), (cx + dx, cy + dy), (cx - dx, cy + dy), (cx - dx, cy - dy)]

def corbatin(cx, cy, s):
    dx, dy = m2lon(s), m2lat(s)
    return [(cx - dx, cy - dy), (cx + dx, cy + dy), (cx + dx, cy - dy), (cx - dx, cy + dy), (cx - dx, cy - dy)]

poligonos = []   # (osm_id, osm_way_id, name, building, amenity, other_tags, rings)
# densidad de edificios decreciente hacia el oriente/sur para que haya contraste
for n in range(int(26000 * ESCALA)):
    while True:
        cx = random.uniform(X0 - 0.005, X1 + 0.005)
        cy = random.uniform(Y0 - 0.005, Y1 + 0.005)
        peso = 0.25 + 0.75 * math.exp(-(((cx + 70.65) / 0.06) ** 2 + ((cy + 33.45) / 0.05) ** 2))
        if random.random() < peso:
            break
    oid += 1
    if n % 150 == 0:
        anillo = corbatin(cx, cy, 8)                         # inválido: autointersección
    else:
        anillo = rect(cx, cy, random.uniform(8, 30), random.uniform(8, 25))
    tipo = random.choice(["yes", "yes", "yes", "house", "apartments", "commercial"])
    poligonos.append((None, oid, None, tipo, None, None, [anillo]))

# hospitales / clínicas como áreas (amenity en columna, como en multipolygons de GDAL)
for n in range(25):
    oid += 1
    cx, cy = random.uniform(X0, X1), random.uniform(Y0, Y1)
    am = random.choice(["hospital", "clinic"])
    poligonos.append((None, oid, f"{am.title()} {n}", "hospital", am, None, [rect(cx, cy, 120, 90)]))

# ---------------------------------------------------------------- GTFS: rutas
def camino_aleatorio():
    """Recorrido por la grilla: alterna tramos NS/EO, cruzando la caja."""
    i = random.randrange(len(xs)); j = 0 if random.random() < .5 else len(ys) - 1
    pts = [(xs[i], ys[j])]
    sentido_y = 1 if j == 0 else -1
    while 0 <= j + sentido_y < len(ys) and len(pts) < 14:
        k = random.randint(2, 6)
        j2 = max(0, min(len(ys) - 1, j + sentido_y * k))
        pts.append((xs[i], ys[j2])); j = j2
        k = random.randint(-5, 5)
        i2 = max(0, min(len(xs) - 1, i + k))
        if i2 != i:
            pts.append((xs[i2], ys[j])); i = i2
        if j in (0, len(ys) - 1):
            break
    return pts

def densificar(pts, paso_m=50):
    out = [pts[0]]
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        d = math.hypot((bx - ax) * MX, (by - ay) * MY)
        n = max(1, int(d / paso_m))
        for k in range(1, n + 1):
            out.append((ax + (bx - ax) * k / n, ay + (by - ay) * k / n))
    return out

routes, trips, shapes, stop_times = [], [], [], []
stops = {}            # stop_id -> (code, name, lon, lat, loc_type, parent)

def stop_en(x, y, lado):
    """Paradero a 8 m de la vereda; se reutiliza si ya existe uno a < 15 m."""
    key = (round(x / m2lon(15)), round(y / m2lat(15)), lado)
    sid = f"PA{abs(hash(key)) % 10_000_000}"
    if sid not in stops:
        ox, oy = (m2lon(8), 0) if lado else (0, m2lat(8))
        stops[sid] = (sid.replace("PA", "PC"), f"Parada {len(stops)}", x + ox, y + oy, 0, "")
    return sid

n_rutas = min(int(55 * ESCALA), 600)
nombres = [f"{random.choice('123456789BCDEFGHI')}{random.randint(0, 9)}{random.randint(0, 9)}" for _ in range(n_rutas * 3)]
nombres = [x for x in dict.fromkeys(nombres) if x not in ("506", "210")][:n_rutas] + ["506", "210", "D18"]
for r_id, short in enumerate(nombres):
    rid = f"R{r_id}"
    routes.append(dict(route_id=rid, agency_id="DTPM", route_short_name=short,
                       route_long_name=f"Origen {short} - Destino {short}", route_type=3,
                       route_color="", route_text_color=""))
    base = camino_aleatorio()
    variantes = [("I", base), ("R", base[::-1])]
    if r_id % 7 == 0:                                       # variante corta de servicio
        variantes.append(("I2", base[: max(2, len(base) // 2)]))
    for suf, pts in variantes:
        shp = f"{short}{suf}"
        dens = densificar(pts)
        for seq, (x, y) in enumerate(dens, start=1):
            shapes.append(dict(shape_id=shp, shape_pt_lat=f"{y:.6f}", shape_pt_lon=f"{x:.6f}",
                               shape_pt_sequence=seq, shape_dist_traveled=""))
        lado = suf.startswith("I")
        paradas = [stop_en(x, y, lado) for k, (x, y) in enumerate(dens) if k % 8 == 4]
        ntrips = int((12 if suf in ("I", "R") else 2) * max(1, ESCALA / 2))
        for t in range(ntrips):
            tid = f"{rid}-{suf}-{t}"
            trips.append(dict(route_id=rid, service_id="L", trip_id=tid, trip_headsign=f"Dest {short}",
                              direction_id=0 if suf.startswith("I") else 1, shape_id=shp))
            for seq, sid in enumerate(paradas, start=1):
                h = 6 + t + seq // 30
                stop_times.append(dict(trip_id=tid, arrival_time=f"{h:02d}:{(seq * 2) % 60:02d}:00",
                                       departure_time=f"{h:02d}:{(seq * 2) % 60:02d}:00",
                                       stop_id=sid, stop_sequence=seq))

# una línea de metro (route_type 1) con estaciones padre + andenes
routes.append(dict(route_id="L1", agency_id="METRO", route_short_name="L1",
                   route_long_name="Línea 1", route_type=1, route_color="", route_text_color=""))
mpts = [(X0 + 0.01, -33.445), (X1 - 0.01, -33.43)]
dens = densificar(mpts, 100)
for seq, (x, y) in enumerate(dens, start=1):
    shapes.append(dict(shape_id="L1I", shape_pt_lat=f"{y:.6f}", shape_pt_lon=f"{x:.6f}",
                       shape_pt_sequence=seq, shape_dist_traveled=""))
est = []
for k in range(0, len(dens), 10):
    x, y = dens[k]
    p = f"EST{k}"; a = f"AND{k}"
    stops[p] = ("", f"Estación {k}", x, y, 1, "")
    stops[a] = ("", f"Estación {k} andén", x, y, 0, p)
    est.append(a)
for t in range(20):
    tid = f"L1-{t}"
    trips.append(dict(route_id="L1", service_id="L", trip_id=tid, trip_headsign="Los Dominicos",
                      direction_id=0, shape_id="L1I"))
    for seq, sid in enumerate(est, start=1):
        stop_times.append(dict(trip_id=tid, arrival_time="07:00:00", departure_time="07:00:00",
                               stop_id=sid, stop_sequence=seq))
# paraderos fuera de la caja (deben quedar fuera)
stops["PAFUERA1"] = ("PCF1", "Paradero lejano", -70.90, -33.60, 0, "")

def csv_bytes(rows, campos, bom=False, crlf=False):
    s = io.StringIO()
    w = csv.DictWriter(s, fieldnames=campos, lineterminator="\r\n" if crlf else "\n")
    w.writeheader(); w.writerows(rows)
    b = s.getvalue().encode("utf-8")
    return (b"\xef\xbb\xbf" + b) if bom else b

with zipfile.ZipFile(os.path.join(OUT, "GTFS_20990101.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("agency.txt", csv_bytes([dict(agency_id="DTPM", agency_name="Red (sintético)",
               agency_url="https://example.org", agency_timezone="America/Santiago")],
               ["agency_id", "agency_name", "agency_url", "agency_timezone"]))
    z.writestr("routes.txt", csv_bytes(routes, list(routes[0])))
    z.writestr("trips.txt", csv_bytes(trips, list(trips[0])))
    z.writestr("shapes.txt", csv_bytes(shapes, list(shapes[0])))
    z.writestr("stop_times.txt", csv_bytes(stop_times, list(stop_times[0])))
    z.writestr("stops.txt", csv_bytes(
        [dict(stop_id=k, stop_code=v[0], stop_name=v[1], stop_lat=f"{v[3]:.6f}", stop_lon=f"{v[2]:.6f}",
              location_type=v[4] if v[4] else "", parent_station=v[5]) for k, v in stops.items()],
        ["stop_id", "stop_code", "stop_name", "stop_lat", "stop_lon", "location_type", "parent_station"],
        bom=True, crlf=True))
    z.writestr("calendar.txt", csv_bytes([dict(service_id="L", monday=1, tuesday=1, wednesday=1, thursday=1,
               friday=1, saturday=0, sunday=0, start_date="20990101", end_date="20991231")],
               ["service_id", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                "sunday", "start_date", "end_date"]))

# ---------------------------------------------------------------- OSM: puntos
puntos = []   # (osm_id, name, highway, other_tags, x, y)
for sid, (code, name, x, y, lt, par) in stops.items():
    if lt != 0 or not sid.startswith("PA") or sid == "PAFUERA1":
        continue
    r = random.random()
    if r < 0.12:
        continue                                            # falta en OSM
    d = random.uniform(0, 25) if r < 0.95 else random.uniform(60, 140)
    a = random.uniform(0, 2 * math.pi)
    oid += 1
    puntos.append((oid, name if random.random() < .6 else None, "bus_stop",
                   '"bus"=>"yes","public_transport"=>"platform"', x + m2lon(d * math.cos(a)), y + m2lat(d * math.sin(a))))
for _ in range(int(len(stops) * 0.05)):                     # solo en OSM
    oid += 1
    puntos.append((oid, None, "bus_stop", '"bus"=>"yes"', random.uniform(X0, X1), random.uniform(Y0, Y1)))
for n in range(400):
    oid += 1
    am = random.choice(["pharmacy", "pharmacy", "doctors", "clinic", "restaurant", "school", "bank", "cafe"])
    puntos.append((oid, f"{am} {n}", None, f'"amenity"=>"{am}","name:es"=>"x \\"q\\""',
                   random.uniform(X0, X1), random.uniform(Y0, Y1)))
for _ in range(200):                                         # semáforos y otros nodos
    oid += 1
    puntos.append((oid, None, "traffic_signals", None, random.choice(xs), random.choice(ys)))

def q(s):
    return "NULL" if s is None else "'" + str(s).replace("'", "''") + "'"

def wkt_line(p): return "LINESTRING(" + ",".join(f"{x:.7f} {y:.7f}" for x, y in p) + ")"
def wkt_mpoly(rings): return "MULTIPOLYGON(((" + "),(".join(",".join(f"{x:.7f} {y:.7f}" for x, y in r) for r in rings) + ")))"

with open(os.path.join(OUT, "osm_raw.sql"), "w") as f:
    f.write("DROP SCHEMA IF EXISTS osm_raw CASCADE; CREATE SCHEMA osm_raw;\n")
    f.write("CREATE TABLE osm_raw.points (ogc_fid serial PRIMARY KEY, osm_id varchar, name varchar, barrier varchar,"
            " highway varchar, ref varchar, address varchar, is_in varchar, place varchar, man_made varchar,"
            " other_tags varchar, geom geometry(Point,4326));\n")
    f.write("CREATE TABLE osm_raw.lines (ogc_fid serial PRIMARY KEY, osm_id varchar, name varchar, highway varchar,"
            " waterway varchar, aerialway varchar, barrier varchar, man_made varchar, railway varchar, z_order int,"
            " other_tags varchar, geom geometry(LineString,4326));\n")
    f.write("CREATE TABLE osm_raw.multipolygons (ogc_fid serial PRIMARY KEY, osm_id varchar, osm_way_id varchar,"
            " name varchar, type varchar, amenity varchar, building varchar, landuse varchar, shop varchar,"
            " other_tags varchar, geom geometry(MultiPolygon,4326));\n")
    f.write("INSERT INTO osm_raw.points (osm_id, name, highway, other_tags, geom) VALUES\n")
    f.write(",\n".join(f"({q(o)},{q(n)},{q(h)},{q(t)},ST_SetSRID(ST_MakePoint({x:.7f},{y:.7f}),4326))"
                       for o, n, h, t, x, y in puntos) + ";\n")
    f.write("INSERT INTO osm_raw.lines (osm_id, name, highway, geom) VALUES\n")
    f.write(",\n".join(f"({q(o)},{q(n)},{q(h)},ST_GeomFromText('{wkt_line(p)}',4326))"
                       for o, n, h, p in lineas) + ";\n")
    f.write("INSERT INTO osm_raw.multipolygons (osm_id, osm_way_id, name, building, amenity, other_tags, geom) VALUES\n")
    f.write(",\n".join(f"({q(a)},{q(b)},{q(n)},{q(bu)},{q(am)},{q(t)},ST_GeomFromText('{wkt_mpoly(r)}',4326))"
                       for a, b, n, bu, am, t, r in poligonos) + ";\n")

# ---------------------------------------------------------------- DPA (shp2pgsql)
nombres_c = ["SANTIAGO", "PROVIDENCIA", "ÑUÑOA", "MACUL", "SAN JOAQUÍN", "SAN MIGUEL", "ESTACIÓN CENTRAL",
             "QUINTA NORMAL", "INDEPENDENCIA", "RECOLETA", "LAS CONDES", "LA REINA", "PEÑALOLÉN",
             "LA FLORIDA", "MAIPÚ", "RENCA"]
cx = [-70.80, -70.72, -70.64, -70.56, -70.47]
cy = [-33.57, -33.49, -33.41, -33.31]
def borde(a, b, n=300):  # aristas con muchos vértices, como un límite real
    return [(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n) for k in range(n)]
with open(os.path.join(OUT, "comunas_cl.sql"), "w") as f:
    f.write("SET CLIENT_ENCODING TO UTF8;\nSET STANDARD_CONFORMING_STRINGS TO ON;\nBEGIN;\n")
    f.write('CREATE TABLE "comunas_cl" (gid serial,\n"cut_reg" varchar(2),\n"region" varchar(80),\n'
            '"cut_com" varchar(5),\n"comuna" varchar(80),\n"superficie" numeric);\n')
    f.write('ALTER TABLE "comunas_cl" ADD PRIMARY KEY (gid);\n')
    f.write("SELECT AddGeometryColumn('','comunas_cl','geom','4326','MULTIPOLYGON',2);\n")
    k = 0
    for j in range(len(cy) - 1):
        for i in range(len(cx) - 1):
            a, b, c, d = (cx[i], cy[j]), (cx[i + 1], cy[j]), (cx[i + 1], cy[j + 1]), (cx[i], cy[j + 1])
            ring = borde(a, b) + borde(b, c) + borde(c, d) + borde(d, a) + [a]
            wkt = "MULTIPOLYGON(((" + ",".join(f"{x:.7f} {y:.7f}" for x, y in ring) + ")))"
            f.write(f"INSERT INTO \"comunas_cl\" (\"cut_reg\",\"region\",\"cut_com\",\"comuna\",\"superficie\",geom) "
                    f"VALUES ('13','Metropolitana de Santiago','{13101 + k}','{nombres_c[k]}',0,"
                    f"ST_GeomFromText('{wkt}',4326));\n")
            k += 1
    # una comuna de otra región, lejos de la caja (debe quedar fuera)
    f.write("INSERT INTO \"comunas_cl\" (\"cut_reg\",\"region\",\"cut_com\",\"comuna\",\"superficie\",geom) VALUES "
            "('05','Valparaíso','05101','VALPARAÍSO',0,ST_GeomFromText('MULTIPOLYGON(((-71.7 -33.1,-71.5 -33.1,"
            "-71.5 -33.0,-71.7 -33.0,-71.7 -33.1)))',4326));\n")
    f.write("COMMIT;\nANALYZE \"comunas_cl\";\n")

print(f"Sintéticos en {OUT}: {len(lineas)} calles, {len(poligonos)} polígonos, {len(puntos)} puntos OSM, "
      f"{len(stops)} stops, {len(shapes)} puntos de shape, {len(trips)} viajes, {len(stop_times)} stop_times")
