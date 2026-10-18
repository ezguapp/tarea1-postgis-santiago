#!/usr/bin/env python3
"""
Arma informe/informe.html (A4, ≤ 6 páginas al imprimir) con los resultados
REALES de la corrida: tablas desde resultados/*.csv, mapas desde salidas/*.png,
fuentes y fechas desde resultados/etl_log.csv. Además actualiza en README.md
las secciones marcadas <!-- AUTO:... --> (fuentes, conteos, reparaciones,
índices no usados), para que el README nunca contradiga a la base.

Los párrafos de interpretación se redactan a partir de los números (no son
texto fijo), pero son un BORRADOR: léanlos y ajústenlos antes de entregar.

PDF: abrir informe.html en Chrome/Firefox -> Imprimir -> Guardar como PDF
(A4, márgenes predeterminados, "gráficos de fondo" activado).
Corre dentro del contenedor (lo llama ./consultas.sh). Solo usa la biblioteca estándar.
"""
import csv, html, json, os, re, statistics
from datetime import date

PROY = os.environ.get("PROYECTO_DIR", "/proyecto")
RES = os.environ.get("RESULTADOS_DIR", os.path.join(PROY, "resultados"))
SAL = os.environ.get("SALIDAS_DIR", os.path.join(PROY, "salidas"))
INF = os.environ.get("INFORME_DIR", os.path.join(PROY, "informe"))
ACTUALIZAR_README = os.environ.get("ACTUALIZAR_README", "1") == "1"
os.makedirs(INF, exist_ok=True)


# ----------------------------------------------------------------- utilidades
def leer(nombre):
    ruta = os.path.join(RES, nombre)
    if not os.path.exists(ruta):
        return []
    with open(ruta, encoding="utf-8") as f:
        return list(csv.DictReader(f))


def n(v, dec=None):
    """número con formato chileno: miles con punto, decimales con coma"""
    try:
        x = float(v)
    except (TypeError, ValueError):
        return "—" if v in (None, "") else html.escape(str(v))
    if dec is None:
        dec = 0 if x == int(x) and abs(x) >= 1 else 1
    s = f"{x:,.{dec}f}"
    return s.replace(",", "§").replace(".", ",").replace("§", ".")


def f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def tc(s):
    """SANTIAGO -> Santiago (deja intactas palabras como 'de', 'la')"""
    if not s:
        return s
    menores = {"de", "del", "la", "las", "los", "y"}
    pal = s.lower().split()
    return " ".join(p if (i and p in menores) else p[:1].upper() + p[1:] for i, p in enumerate(pal))


def tabla(filas, columnas, clase=""):
    """columnas: lista de (clave, encabezado, formateador)"""
    if not filas:
        return "<p class='nota'>(sin resultados: ¿se corrió ./consultas.sh?)</p>"
    h = [f"<table class='{clase}'><thead><tr>"]
    h += [f"<th>{html.escape(t)}</th>" for _, t, _ in columnas]
    h.append("</tr></thead><tbody>")
    for fila in filas:
        h.append("<tr>" + "".join(f"<td>{fmt(fila.get(k))}</td>" for k, _, fmt in columnas) + "</tr>")
    h.append("</tbody></table>")
    return "".join(h)


def img(nombre, alto="", pie=""):
    ruta = os.path.join(SAL, nombre)
    if not os.path.exists(ruta):
        return f"<p class='nota'>(falta el mapa {html.escape(nombre)}; corra ./consultas.sh)</p>"
    rel = os.path.relpath(ruta, INF)
    est = f" style='max-height:{alto}'" if alto else ""
    p = f"<figcaption>{pie}</figcaption>" if pie else ""
    return f"<figure><img src='{html.escape(rel)}'{est}>{p}</figure>"


txt = lambda v: html.escape(tc(v) if v else "—")
raw = lambda v: html.escape(v or "—")

# ----------------------------------------------------------------- datos
LOG = {}
for r in leer("etl_log.csv"):
    LOG.setdefault(f"{r['etapa']}.{r['clave']}", r["valor"])
conteos = {r["tabla"]: r for r in leer("conteos.csv")}
q1 = leer("q1_paraderos_comuna.csv")
q2 = leer("q2_cobertura.csv")
q3 = leer("q3_dos_fuentes.csv")
q3b = leer("q3b_dos_fuentes_comuna.csv")
q4a = leer("q4a_km_comuna_sin_subdivide.csv")
q4b = leer("q4b_km_comuna_con_subdivide.csv")
q5 = leer("q5_vecino_salud.csv")
q5r = (leer("q5_ruta.csv") or [{}])[0]
q6 = leer("q6_top10.csv")
q6b = (leer("q6b_grilla_resumen.csv") or [{}])[0]
q7a = leer("q7a_jerarquia_vial.csv")
q7b = (leer("q7b_recorridos_sin_calle.csv") or [{}])[0]
tiempos = {(r["consulta"], r["variante"]): r for r in leer("tiempos.csv")}
uso = leer("indices_uso.csv")
try:
    with open(os.path.join(RES, "planes", "resumen.json"), encoding="utf-8") as fh:
        PLANES = json.load(fh)
except (OSError, ValueError):
    PLANES = {}


def fecha_osm():
    ts = LOG.get("osm.pbf_timestamp", "")
    if ts and ts != "desconocido":
        return ts[:10]
    for k in ("osm.gpkg_mtime", "osm.pbf_mtime"):
        if k in LOG:
            return LOG[k][:10] + " (fecha del archivo)"
    return "COMPLETAR"


GTFS = LOG.get("gtfs.zip_archivo", "COMPLETAR")
m = re.search(r"(\d{8})", GTFS)
GTFS_FECHA = f"{m.group(1)[6:]}-{m.group(1)[4:6]}-{m.group(1)[:4]}" if m else "COMPLETAR"
F_OSM = fecha_osm()
FUENTE_OSM = f"OSM (Geofabrik, {F_OSM})"
FUENTE_GTFS = f"GTFS DTPM ({GTFS})"


def ms(consulta, variante="con_indices"):
    r = tiempos.get((consulta, variante))
    return f(r["execution_ms"]) if r and r.get("execution_ms") else None


def fila_total(filas, clave="comuna", valor="TOTAL caja"):
    return next((r for r in filas if r.get(clave) == valor), {})


# ----------------------------------------------------------------- textos
def interp_q1():
    v = [r for r in q1 if f(r["densidad_km2"]) is not None]
    if not v:
        return ""
    alto, bajo = v[0], v[-1]
    total = sum(int(r["paraderos"]) for r in q1)
    area = sum(f(r["area_en_caja_km2"]) or 0 for r in q1)
    parciales = [tc(r["comuna"]) for r in q1 if (f(r["pct_comuna_en_caja"]) or 0) < 99.5]
    s = (f"En la caja hay <b>{n(total)}</b> paraderos GTFS de bus ({n(total / area, 1)} por km² en promedio). "
         f"La densidad más alta está en <b>{tc(alto['comuna'])}</b> ({n(alto['densidad_km2'], 1)}/km²) y la más baja en "
         f"<b>{tc(bajo['comuna'])}</b> ({n(bajo['densidad_km2'], 1)}/km²). ")
    if parciales:
        s += (f"{len(parciales)} comunas quedan cortadas por la caja ({', '.join(parciales[:6])}"
              f"{'…' if len(parciales) > 6 else ''}); para ellas la densidad se calcula sobre el área dentro de la caja, "
              f"porque dividir por el área total (última columna) la subestimaría al no estar cargados sus paraderos de fuera. ")
    return s + f"Fuente: {FUENTE_GTFS}, comunas DPA 2023."


def interp_q2():
    t = fila_total(q2)
    if not t:
        return ""
    c = [r for r in q2 if r["comuna"] != "TOTAL caja"]
    peor = c[0] if c else {}
    cambia = [r for r in c if abs(f(r["dif_osm_menos_gtfs_pp"]) or 0) >= 5]
    dif = f(t.get("dif_osm_menos_gtfs_pp")) or 0
    s = (f"Con el GTFS, el <b>{n(t['pct_lejos_gtfs'], 1)} %</b> de los {n(t['edificios'])} edificios de la caja queda a más de 500 m "
         f"(en línea recta) de un paradero; con los bus_stop de OSM, el <b>{n(t['pct_lejos_osm'], 1)} %</b>. ")
    if peor:
        s += f"La comuna peor cubierta según el GTFS es <b>{tc(peor['comuna'])}</b> ({n(peor['pct_lejos_gtfs'], 1)} %). "
    if abs(dif) < 2 and not cambia:
        s += "<b>La conclusión no cambia con la fuente</b>: las diferencias son de pocos puntos porcentuales. "
    else:
        mas = "OSM" if dif > 0 else "GTFS"
        s += (f"<b>La fuente sí cambia la conclusión</b>: en conjunto, {mas} deja más edificios descubiertos "
              f"({n(abs(dif), 1)} pp de diferencia)")
        if cambia:
            s += f", sobre todo en {', '.join(tc(r['comuna']) for r in cambia[:5])}"
        s += ". "
    nuc = f(t.get("pct_lejos_gtfs_nucleo"))
    if nuc is not None:
        s += (f"Excluyendo los edificios a menos de 500 m del borde de la caja (cuyo paradero más cercano podría estar fuera) "
              f"el porcentaje GTFS es {n(nuc, 1)} %: el efecto borde {'es menor' if abs(nuc - f(t['pct_lejos_gtfs'])) < 1 else 'pesa y se reporta'}. ")
    return s + f"Fuentes: {FUENTE_GTFS}; {FUENTE_OSM}."


def interp_q3():
    r = next((x for x in q3 if x["umbral_m"] == "50"), None)
    if not r:
        return ""
    r25 = next((x for x in q3 if x["umbral_m"] == "25"), r)
    r100 = next((x for x in q3 if x["umbral_m"] == "100"), r)
    s = (f"A 50 m, <b>{n(r['gtfs_sin_osm'])} paraderos GTFS ({n(r['pct_gtfs_sin_osm'], 1)} %) no tienen bus_stop en OSM</b>, "
         f"y <b>{n(r['osm_sin_gtfs'])} bus_stop de OSM ({n(r['pct_osm_sin_gtfs'], 1)} %) no tienen paradero GTFS</b>. "
         f"Con 25 m los porcentajes suben a {n(r25['pct_gtfs_sin_osm'], 1)} % y {n(r25['pct_osm_sin_gtfs'], 1)} %; con 100 m bajan a "
         f"{n(r100['pct_gtfs_sin_osm'], 1)} % y {n(r100['pct_osm_sin_gtfs'], 1)} %: parte del desacuerdo es posición (el mismo poste "
         f"dibujado a unos metros), no ausencia. ")
    s += ("El GTFS es lo que el operador declara que opera: un paradero GTFS sin par en OSM es sobre todo un vacío de OSM "
          "(nadie lo ha dibujado). Un bus_stop OSM sin par en GTFS puede ser un paradero eliminado o desplazado que OSM no "
          "actualizó, uno de otro servicio (rural, interurbano, de empresa), o un error de etiquetado. ")
    if q3b:
        peor = q3b[0]
        s += (f"La falta de cobertura de OSM no es pareja: va de {n(q3b[-1]['pct_gtfs_sin_osm'], 1)} % a "
              f"{n(peor['pct_gtfs_sin_osm'], 1)} % ({tc(peor['comuna'])}) según la comuna. ")
    return s + f"Fuentes: {FUENTE_GTFS}; {FUENTE_OSM}."


def interp_q4():
    if not q4b:
        return ""
    top = q4b[0]
    dens = max(q4b, key=lambda r: f(r["km_por_km2"]) or 0)
    ta, tb = ms("q4a_km_comuna_sin_subdivide"), ms("q4b_km_comuna_con_subdivide")
    iguales = all(a["km_principales"] == b["km_principales"] for a, b in
                  zip(sorted(q4a, key=lambda r: r["cut"]), sorted(q4b, key=lambda r: r["cut"])))
    s = (f"<b>{tc(top['comuna'])}</b> concentra más kilómetros de recorrido ({n(top['km_principales'], 1)} km de shapes principales, "
         f"{top['rutas']} rutas); por superficie, la red más densa está en <b>{tc(dens['comuna'])}</b> "
         f"({n(dens['km_por_km2'], 1)} km por km²). ")
    if ta and tb:
        s += (f"<b>ST_Subdivide</b>: la misma consulta tardó {n(ta, 0)} ms contra las comunas completas y {n(tb, 0)} ms contra las "
              f"piezas subdivididas (×{n(ta / tb, 1)}), con {'resultados idénticos' if iguales else 'diferencias mínimas por redondeo'}. ")
    s += ("Ida y vuelta se suman (son servicios distintos); las variantes cortas no (solo el shape principal de cada ruta y sentido). "
          f"Fuente: {FUENTE_GTFS}.")
    return s


def interp_q5():
    if not q5:
        return ""
    d = [f(r["distancia_m"]) for r in q5 if f(r["distancia_m"]) is not None]
    tipos = {}
    for r in q5:
        tipos[r["tipo_salud"]] = tipos.get(r["tipo_salud"], 0) + 1
    lejos = max(q5, key=lambda r: f(r["distancia_m"]) or 0)
    s = (f"Recorrido <b>{html.escape(q5r.get('route_short_name', '?'))}</b> ({html.escape(q5r.get('route_long_name') or '')}; "
         f"{html.escape(q5r.get('motivo', ''))}): {len(q5)} paradas en la caja (ambos sentidos). "
         f"Distancia a la farmacia o centro de salud más cercano: mediana <b>{n(statistics.median(d), 0)} m</b>, máxima "
         f"<b>{n(max(d), 0)} m</b> (parada {html.escape(lejos['paradero'] or '')}); el {n(100 * sum(x <= 300 for x in d) / len(d), 0)} % "
         f"tiene uno a 300 m o menos. Lo más cercano suele ser "
         f"{', '.join(f'{k} ({v})' for k, v in sorted(tipos.items(), key=lambda x: -x[1]))}. ")
    return s + (f"Distancia en línea recta; solo cuenta lo que está mapeado en OSM. Fuentes: {FUENTE_GTFS}; {FUENTE_OSM}.")


def interp_q6():
    if not q6:
        return ""
    comunas = {}
    for r in q6:
        comunas[tc(r["comuna"])] = comunas.get(tc(r["comuna"]), 0) + 1
    sin = sum(1 for r in q6 if r["n_recorridos"] == "0")
    s = (f"La grilla tiene {n(q6b.get('celdas'))} celdas ({n(q6b.get('celdas_completas'))} completamente dentro de la caja). "
         f"Una celda completa tiene en promedio {n(q6b.get('edificios_prom_celda'), 1)} edificios y la cruzan "
         f"{n(q6b.get('recorridos_prom_celda'), 1)} recorridos; la correlación entre ambos es {n(q6b.get('correlacion_edificios_recorridos'), 2)}. "
         f"Las 10 celdas con más edificios y menos recorridos (índice edificios/(recorridos+1)) están en "
         f"{', '.join(f'{k} ({v})' for k, v in sorted(comunas.items(), key=lambda x: -x[1]))}; "
         f"{sin} de ellas no tienen ningún recorrido. ")
    s += ("Son candidatas a zonas construidas mal servidas, con dos cautelas: OSM puede tener edificios de más o de menos "
          "según quién mapeó la zona, y una celda sin recorridos puede estar a pocos metros de una avenida con muchos. "
          f"Fuentes: {FUENTE_OSM}; {FUENTE_GTFS}.")
    return s


def interp_q7():
    if not q7a:
        return ""
    por = {r["categoria"]: r for r in q7a}
    princ = [por[c] for c in ("primary", "secondary") if c in por]
    res = por.get("residential", {})
    s = ""
    if princ:
        s += ("De las vías principales de OSM, "
              + " y ".join(f"las <b>{r['categoria']}</b> tienen bus en el {n(r['pct_con_bus'], 1)} % de su largo "
                          f"({n(r['km_sin_bus'], 1)} km sin bus)" for r in princ) + ". ")
    if res:
        s += (f"Las calles residenciales llevan el {n(res.get('pct_de_la_red_bus'), 1)} % de los km de calle con bus. ")
    if q7b:
        s += (f"Mirado desde el GTFS, el {n(q7b.get('pct_sin_calle_osm'), 2)} % de los km de trazado principal de bus "
              f"({n(q7b.get('km_sin_calle_osm'), 1)} km, en {q7b.get('rutas_afectadas')} rutas) no tiene ninguna calle OSM a 15 m: "
              "esos tramos son o trazados imprecisos del operador o calles que faltan en OSM. ")
    return s + f"Fuentes: {FUENTE_OSM}; {FUENTE_GTFS}."


def tabla_planes():
    filas = []
    etiquetas = {
        "q1_paraderos_comuna": "P1 punto en polígono", "q2_cobertura": "P2 anti-join 500 m",
        "q3_dos_fuentes": "P3 anti-join 2 sentidos", "q4a_km_comuna_sin_subdivide": "P4 sin subdividir",
        "q4b_km_comuna_con_subdivide": "P4 con ST_Subdivide", "q5_vecino_salud": "P5 KNN <->",
        "q6_grilla_calculo": "P6 construcción grilla", "q6_top10": "P6 top 10", "q7a_jerarquia_vial": "P7 jerarquía vial"}
    for clave, et in etiquetas.items():
        p = PLANES.get(clave)
        if not p or "error" in p:
            continue
        idx = []
        vistos = set()
        for i in p["indices"]:
            if i["indice"] in vistos or i["indice"].endswith("_pkey") and clave != "q5_vecino_salud":
                continue
            vistos.add(i["indice"])
            lado = i["lado"].split(" (")[0]
            idx.append(f"<code>{html.escape(i['indice'])}</code> — {html.escape(lado)}, {n(i['loops'])}×")
        sin = ms(clave, "sin_indices")
        con = p.get("execution_ms")
        filas.append(dict(c=et, i="<br>".join(idx[:3]) or "—",
                          t=f"{n(con, 0)} ms" + (f" → sin índices {n(sin, 0)} ms (×{n(sin / con, 1)})" if sin and con else "")))
    if not filas:
        return ""
    return tabla(filas, [("c", "Consulta", raw), ("i", "Índice usado — lado del join, veces sondeado", lambda v: v),
                         ("t", "Tiempo", raw)], "planes")


def indices_no_usados():
    no = [r for r in uso if r.get("usos") == "0" and not r["indice"].endswith("_pkey")
          and r["tabla"] not in ("etl_log", "config")]
    return no


# ----------------------------------------------------------------- HTML
CSS = """
@page { size: A4; margin: 13mm 12mm 13mm 12mm; }
* { box-sizing: border-box; }
body { font-family: "DejaVu Sans", Arial, sans-serif; font-size: 8.6pt; line-height: 1.32; color: #1a1a1a; margin: 0; }
h1 { font-size: 13.5pt; margin: 0 0 2px; }
h2 { font-size: 10.4pt; margin: 9px 0 3px; border-bottom: 1.2px solid #c51b7d; padding-bottom: 1px; color: #6b0f45; }
h3 { font-size: 9pt; margin: 6px 0 2px; }
p { margin: 2px 0 4px; text-align: justify; }
.sub { color: #555; font-size: 8pt; margin-bottom: 6px; }
table { border-collapse: collapse; width: 100%; margin: 3px 0 5px; font-size: 7.3pt; page-break-inside: avoid; }
th { background: #f3e6ee; text-align: left; padding: 2px 4px; font-weight: 600; }
td { padding: 1.5px 4px; border-bottom: 0.5px solid #ddd; vertical-align: top; }
td:not(:first-child), th:not(:first-child) { text-align: right; }
table.planes td, table.planes th, table.texto td, table.texto th { text-align: left; }
figure { margin: 3px 0 5px; text-align: center; page-break-inside: avoid; }
figure img { max-width: 100%; }
figcaption { font-size: 7pt; color: #555; }
.dos { display: flex; gap: 10px; align-items: flex-start; }
.dos > div { flex: 1; min-width: 0; }
.nota { color: #666; font-size: 7.5pt; }
.salto { page-break-before: always; }
code { font-size: 7pt; }
.q { font-style: italic; color: #333; }
"""


def doc():
    t1 = fila_total(q2)
    h = [f"<!doctype html><html lang='es'><head><meta charset='utf-8'><title>Tarea 1 — PostGIS de punta a punta</title>"
         f"<style>{CSS}</style></head><body>"]
    h.append("<h1>Tarea 1 — PostGIS de punta a punta: Santiago centro</h1>")
    h.append("<div class='sub'>Procesamiento Masivo de Datos · ELE051-B / EIN102B · USM 2026-2 · Paralelo 701 · "
             "Integrantes: <b>NOMBRE 1, NOMBRE 2, NOMBRE 3</b> · Repositorio: <b>https://github.com/USUARIO/REPO</b></div>")
    h.append("<p class='q'>¿Cómo se relaciona la ciudad construida (OSM) con la red de transporte público (GTFS)?</p>")

    # datos
    h.append("<h2>Datos y fechas</h2>")
    fuentes = [
        dict(a="OpenStreetMap (Geofabrik, chile-latest.osm.pbf)", b=F_OSM,
             c=f"{n(conteos.get('edificios', {}).get('filas'))} edificios · {n(conteos.get('calles', {}).get('filas'))} calles · "
               f"{n(conteos.get('paraderos_osm', {}).get('filas'))} bus_stop · {n(conteos.get('amenidades', {}).get('filas'))} amenidades"),
        dict(a=f"GTFS DTPM ({GTFS})", b=GTFS_FECHA,
             c=f"{n(LOG.get('gtfs.paraderos_gtfs_bus'))} paraderos de bus · {n(conteos.get('recorridos', {}).get('filas'))} shapes · "
               f"{n(LOG.get('gtfs.rutas_en_caja'))} rutas · {n(LOG.get('gtfs.stop_times'))} stop_times"),
        dict(a="DPA 2023 — comunas (Lab 03, comunas_cl.sql)", b="2023",
             c=f"{n(conteos.get('comunas', {}).get('filas'))} comunas tocan la caja ({n(LOG.get('dpa.comunas_completas_en_caja'))} completas)"),
    ]
    h.append(tabla(fuentes, [("a", "Fuente", raw), ("b", "Fecha / versión", raw), ("c", "En la caja (tablas derivadas)", raw)], "texto"))
    h.append(f"<p class='nota'>Caja lon {LOG.get('config.bbox_4326', '−70,75…−70,52 · lat −33,52…−33,36')} "
             f"({n(LOG.get('config.area_caja_km2'), 1)} km²); todo en SIRGAS-Chile UTM 19S (EPSG:5361). "
             "Los paraderos OSM son los que alguien dibujó; el GTFS es lo que el operador declara: cada conclusión indica su fuente y fecha.</p>")

    # P1
    h.append("<h2>1. Paraderos por comuna</h2>")
    h.append("<div class='dos'><div>")
    h.append(tabla(q1, [("comuna", "Comuna", txt), ("paraderos", "Paraderos", n), ("area_en_caja_km2", "km² en caja", lambda v: n(v, 1)),
                        ("pct_comuna_en_caja", "% en caja", lambda v: n(v, 0)), ("densidad_km2", "por km²", lambda v: n(v, 1)),
                        ("densidad_area_total_km2", "por km² total", lambda v: n(v, 1))]))
    h.append("</div><div>" + img("mapa_q1_densidad_paraderos.png", "92mm") + "</div></div>")
    h.append(f"<p>{interp_q1()}</p>")

    # P2
    h.append("<h2>2. Cobertura: edificios a más de 500 m de un paradero</h2>")
    h.append(tabla(q2, [("comuna", "Comuna", txt), ("edificios", "Edificios", n), ("pct_lejos_gtfs", "% lejos (GTFS)", lambda v: n(v, 1)),
                        ("pct_lejos_osm", "% lejos (OSM)", lambda v: n(v, 1)), ("dif_osm_menos_gtfs_pp", "OSM − GTFS (pp)", lambda v: n(v, 1)),
                        ("pct_lejos_gtfs_nucleo", "% GTFS sin borde", lambda v: n(v, 1))]))
    h.append(img("mapa_q2_cobertura_500m.png", "78mm"))
    h.append(f"<p>{interp_q2()}</p>")

    # P3
    h.append("<h2>3. Dos fuentes, un objeto</h2>")
    h.append("<div class='dos'><div>")
    h.append(tabla(q3, [("umbral_m", "Umbral (m)", n), ("paraderos_gtfs", "GTFS", n), ("gtfs_sin_osm", "GTFS sin OSM", n),
                        ("pct_gtfs_sin_osm", "%", lambda v: n(v, 1)), ("paraderos_osm", "OSM", n),
                        ("osm_sin_gtfs", "OSM sin GTFS", n), ("pct_osm_sin_gtfs", "%", lambda v: n(v, 1))]))
    h.append(f"<p>{interp_q3()}</p>")
    h.append("</div><div>" + img("mapa_q3_dos_fuentes.png", "88mm") + "</div></div>")

    # P4
    h.append("<h2>4. Kilómetros de recorrido por comuna (ST_Intersection)</h2>")
    h.append(tabla(q4b[:12], [("comuna", "Comuna", txt), ("rutas", "Rutas", n), ("km_todos", "km todos los shapes", lambda v: n(v, 1)),
                              ("km_principales", "km shapes principales", lambda v: n(v, 1)), ("km_bus", "km bus", lambda v: n(v, 1)),
                              ("km_por_km2", "km / km²", lambda v: n(v, 1))]))
    if len(q4b) > 12:
        h.append(f"<p class='nota'>Se muestran 12 de {len(q4b)} comunas; tabla completa en resultados/q4b_km_comuna_con_subdivide.csv.</p>")
    h.append(f"<p>{interp_q4()}</p>")

    # P5
    h.append("<h2>5. Vecino más cercano: salud desde cada paradero</h2>")
    lejanos = sorted(q5, key=lambda r: -(f(r["distancia_m"]) or 0))[:6]
    h.append("<div class='dos'><div>")
    h.append(f"<p>{interp_q5()}</p>")
    h.append("<h3>Paradas más alejadas</h3>")
    h.append(tabla(lejanos, [("sentido", "Sentido", n), ("orden", "Orden", n), ("paradero", "Paradero", raw),
                             ("tipo_salud", "Tipo", raw), ("salud_mas_cercana", "Más cercano", raw), ("distancia_m", "m", n)], "texto"))
    h.append("</div><div>" + img("mapa_q5_ruta_salud.png", "80mm") + "</div></div>")

    # P6
    h.append("<h2>6. Grilla hexagonal: edificios vs. recorridos (mapa principal)</h2>")
    h.append(img("mapa_q6_grilla_hexagonal.png", "98mm"))
    h.append(tabla(q6, [("rk", "#", n), ("celda", "Celda (i_j)", raw), ("comuna", "Comuna", txt), ("n_edificios", "Edificios", n),
                        ("n_recorridos", "Recorridos", n), ("n_paraderos", "Paraderos", n), ("indice", "Índice", lambda v: n(v, 1)),
                        ("lat", "Lat", lambda v: n(v, 4)), ("lon", "Lon", lambda v: n(v, 4))]))
    h.append(f"<p>{interp_q6()}</p>")

    # P7
    h.append("<h2>7. Pregunta propia: ¿por qué calles circula el bus?</h2>")
    h.append("<p class='q'>¿Sobre qué jerarquía de calles de OSM circula la red de buses del GTFS, y cuántos km de vías principales "
             "no tienen ningún bus? (y al revés: ¿qué parte de los trazados GTFS no coincide con ninguna calle OSM?)</p>")
    h.append("<p>Cada calle se parte en segmentos de 10 m (ST_Segmentize + ST_DumpSegments); un segmento «tiene bus» si algún tramo "
             "de recorrido de bus pasa a ≤ 15 m de su punto medio (EXISTS + ST_DWithin con GiST sobre los tramos subdivididos). "
             "Medir por segmento evita contar entera una calle que solo cruza una avenida con buses.</p>")
    h.append(tabla(q7a, [("categoria", "Categoría OSM", raw), ("km_calle", "km de calle", lambda v: n(v, 1)),
                         ("km_con_bus", "km con bus", lambda v: n(v, 1)), ("pct_con_bus", "% con bus", lambda v: n(v, 1)),
                         ("km_sin_bus", "km sin bus", lambda v: n(v, 1)), ("pct_de_la_red_bus", "% de la red con bus", lambda v: n(v, 1))]))
    h.append(f"<p>{interp_q7()}</p>")

    # Planes
    h.append("<h2>Planes de ejecución (EXPLAIN ANALYZE)</h2>")
    h.append("<p>Resumen de los planes en <code>resultados/planes/</code> (texto completo y JSON). En un <i>Nested Loop</i> el índice útil "
             "es el del lado interno: se sondea una vez por fila del externo. En los anti-join (NOT EXISTS) el índice queda en el "
             "subplan y se consulta una vez por fila evaluada, deteniéndose en el primer paradero que cumple. Sin el GiST cada sondeo "
             "es un recorrido completo de la tabla: el costo pasa de ~N·log M a N·M comparaciones exactas (columna «sin índices», medida "
             "con <code>enable_indexscan/bitmapscan = off</code>).</p>")
    h.append(tabla_planes())

    # Decisiones
    h.append("<h2 class='salto'>Decisiones del pipeline</h2>")
    no = indices_no_usados()
    rep = LOG.get("osm.edificios_invalidos", "?")
    motivos = "; ".join(f"{k.split(':', 1)[1]}: {v}" for k, v in LOG.items() if k.startswith("osm.edificios_invalidos_motivo:"))
    dec = [
        ("SRID", "Todo en 5361 (SIRGAS-Chile / UTM 19S): métrico y conforme en la zona, así ST_DWithin, ST_Length y ST_Area "
                 "trabajan en metros sin geography. OSM y GTFS llegan en 4326 y se transforman al derivar; la caja se densifica en "
                 "4326 antes de proyectarla."),
        ("Carga OSM", f"{html.escape(LOG.get('osm.fuente_cargada', '?'))}. ogr2ogr (driver OSM de GDAL) a un esquema de staging; "
                      "las claves que no son columna (p. ej. amenity en los nodos) se leen de other_tags."),
        ("Punto interior vs polígono", "Los edificios guardan su polígono y su ST_PointOnSurface. Cobertura (P2), comuna y grilla (P6) "
                                       "usan el punto: cada edificio cuenta una vez y cae siempre dentro de sí mismo (un centroide "
                                       "puede caer fuera de un edificio en «L» o con patio)."),
        ("Reparaciones", f"{n(rep)} edificios inválidos ({html.escape(motivos or 's/d')}) reparados con ST_MakeValid + ST_CollectionExtract "
                         f"(solo la parte poligonal); {n(LOG.get('osm.edificios_descartados_vacios_tras_reparar'))} quedaron vacíos y se "
                         f"descartaron; {n(LOG.get('osm.edificios_invalidos_despues'))} inválidos al final. Amenidades-área inválidas: "
                         f"{n(LOG.get('osm.amenidades_area_invalidas'))}; comunas inválidas: {n(LOG.get('dpa.comunas_invalidas'))}."),
        ("Recorridos (shapes)", f"Una LineString por shape_id con ST_MakeLine(punto ORDER BY shape_pt_sequence::int): el cast importa, "
                                f"ordenando como texto {n(LOG.get('gtfs.shapes_que_quedarian_mal_ordenando_como_texto'))} shapes quedarían "
                                f"con los vértices desordenados. shapes.txt ({n(LOG.get('gtfs.raw_shapes'))} puntos) y stop_times "
                                f"({n(LOG.get('gtfs.raw_stop_times'))} filas) entran con \\copy, nunca INSERT por fila."),
        ("Varios shapes por ruta", f"Cada shape se asocia (vía trips) a la ruta y sentido con más viajes; {n(LOG.get('gtfs.rutas_con_mas_de_un_shape'))} "
                                   "rutas tienen más de un shape. Se conservan todos, y <i>es_principal</i> marca el de más viajes por "
                                   "(ruta, sentido): P4 suma ida y vuelta pero no variantes; P6 cuenta rutas distintas (route_id)."),
        ("Recorte a la caja", "En SQL: paraderos por lon/lat dentro de la caja; shapes que la intersectan (completos); comunas con su área "
                              "total y su área dentro de la caja (las densidades usan esta última)."),
        ("Índices", f"GiST en cada geometría (incluido un GiST parcial de amenidades de salud y uno sobre los tramos subdivididos de los "
                    f"recorridos), B-tree en llaves de join; VACUUM ANALYZE al final. ST_Subdivide para comunas (≤ 255 vértices) y "
                    f"recorridos (≤ 32). <b>No usados</b> (pg_stat_user_indexes tras las consultas): "
                    + (", ".join(f"<code>{html.escape(r['indice'])}</code>" for r in no) or "ninguno") +
                    ". Ejemplo: el GiST del polígono de edificios no lo usa nadie porque todas las consultas usan el punto interior; "
                    "es un hallazgo: sobra si no se dibujan polígonos."),
        ("Qué no funcionó / límites", "Distancias euclidianas, no por red vial. Efecto borde: lo que está justo fuera de la caja no se "
                                      "cargó (se cuantifica en P2 y se filtran celdas incompletas en P6). OSM es incompleto de forma "
                                      "desigual por zona (P3). COMPLETAR con lo que les haya fallado en su corrida."),
    ]
    h.append(tabla([dict(a=a, b=b) for a, b in dec], [("a", "Decisión", raw), ("b", "Qué se hizo y por qué", lambda v: v)], "texto"))
    h.append(f"<p class='nota'>Generado el {date.today():%d-%m-%Y} por informe/generar_informe.py a partir de resultados/ y salidas/.</p>")
    h.append("</body></html>")
    return "\n".join(h)


with open(os.path.join(INF, "informe.html"), "w", encoding="utf-8") as fh:
    fh.write(doc())
print(f"   {os.path.join(INF, 'informe.html')}")


# ----------------------------------------------------------------- README
def bloque(nombre, contenido, texto):
    patron = re.compile(rf"(<!-- AUTO:{nombre} -->)(.*?)(<!-- /AUTO:{nombre} -->)", re.S)
    return patron.sub(lambda m: m.group(1) + "\n" + contenido.strip() + "\n" + m.group(3), texto)


def md_tabla(filas, cols):
    out = ["| " + " | ".join(t for _, t in cols) + " |", "|" + "---|" * len(cols)]
    for r in filas:
        out.append("| " + " | ".join(str(r.get(k, "")).replace("|", "\\|") for k, _ in cols) + " |")
    return "\n".join(out)


readme = os.path.join(PROY, "README.md")
if ACTUALIZAR_README and os.path.exists(readme):
    with open(readme, encoding="utf-8") as fh:
        t = fh.read()
    fuentes_md = md_tabla([
        dict(f="OSM chile-latest.osm.pbf (Geofabrik)", v=F_OSM, d=LOG.get("osm.fuente_cargada", "")),
        dict(f="GTFS DTPM", v=GTFS, d=f"sha256 {LOG.get('gtfs.zip_sha256', '?')}…, vigencia {LOG.get('gtfs.calendar_rango', 's/d')}"),
        dict(f="DPA 2023 comunas (Lab 03)", v=LOG.get("dpa.sql_archivo", "comunas_cl.sql"),
             d=f"tabla {LOG.get('dpa.tabla_origen', '?')}, SRID origen {LOG.get('dpa.srid_origen', '?')}"),
    ], [("f", "Fuente"), ("v", "Versión / fecha"), ("d", "Detalle (de stgo.etl_log)")])
    conteos_md = md_tabla(list(conteos.values()), [("tabla", "Tabla (stgo.)"), ("filas", "Filas"), ("geometria", "Geometría"),
                                                   ("tamano", "Tamaño"), ("indices", "Índices")])
    rep_md = "\n".join(f"- `{k}`: **{v}**" for k, v in LOG.items()
                       if any(s in k for s in ("invalid", "descartad", "fuera_de_caja", "mal_ordenando", "duplicadas",
                                               "sin_viajes", "mas_de_una_ruta", "mas_de_un_shape", "no_simples")))
    no_md = "\n".join(f"- `{r['indice']}` ({r['tabla']}, {r['tamano']})" for r in indices_no_usados()) or "- (ninguno)"
    t = bloque("FUENTES", fuentes_md, t)
    t = bloque("CONTEOS", conteos_md, t)
    t = bloque("REPARACIONES", rep_md, t)
    t = bloque("INDICES_NO_USADOS", no_md, t)
    with open(readme, "w", encoding="utf-8") as fh:
        fh.write(t)
    print(f"   {readme} (secciones AUTO actualizadas)")
