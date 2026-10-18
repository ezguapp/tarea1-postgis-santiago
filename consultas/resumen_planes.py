#!/usr/bin/env python3
"""
Resume los planes EXPLAIN (ANALYZE, FORMAT JSON) de resultados/planes/:
qué índices se usaron, sobre qué tabla, de qué lado del join (externo / interno /
subplan) y cuántas veces se sondearon; qué tablas se recorrieron enteras (Seq
Scan); y cuánto cambia el tiempo con los índices apagados.

Escribe planes/resumen.md (para leer) y planes/resumen.json (lo usa el informe).
Uso: python3 resumen_planes.py <carpeta_planes>
"""
import json, os, sys

CARPETA = sys.argv[1]

LADO = {
    "Outer": "lado externo (se recorre una vez y guía el join)",
    "Inner": "lado interno (se sondea una vez por cada fila del lado externo)",
    "SubPlan": "dentro de un subplan (EXISTS/NOT EXISTS o subconsulta por fila)",
    "InitPlan": "en un InitPlan (se calcula una sola vez)",
    "Member": "miembro de un Append",
    "Subquery": "dentro de una subconsulta",
}


def recorrer(nodo, padre=None, rel_padre=None, out=None):
    out = [] if out is None else out
    nodo["_padre"] = padre
    nodo["_rel"] = nodo.get("Parent Relationship", rel_padre)
    out.append(nodo)
    for h in nodo.get("Plans", []):
        rel = h.get("Parent Relationship")
        # un Bitmap Index Scan cuelga de su Bitmap Heap Scan: hereda el lado de éste
        if nodo["Node Type"] == "Bitmap Heap Scan" and h["Node Type"] == "Bitmap Index Scan":
            rel = nodo["_rel"]
        recorrer(h, nodo, rel, out)
    return out


JOINS = ("Nested Loop", "Hash Join", "Merge Join")


def lado_en_join(n):
    """Sube por nodos de paso (Limit, Memoize, Bitmap Heap Scan, Hash, Sort...)
    hasta el join o subplan que lo contiene, y devuelve de qué lado quedó."""
    actual = n
    while actual is not None:
        rel = actual.get("Parent Relationship")
        if rel in ("SubPlan", "InitPlan"):
            return rel, actual.get("Subplan Name"), None
        padre = actual["_padre"]
        if padre is None:
            return None, None, None
        if padre["Node Type"] in JOINS:
            return rel, None, padre["Node Type"]
        actual = padre
    return None, None, None


def resumir(ruta):
    with open(ruta) as f:
        plan = json.load(f)[0]
    nodos = recorrer(plan["Plan"])
    indices, secuenciales = [], []
    for n in nodos:
        tipo = n["Node Type"]
        loops = n.get("Actual Loops", 1)
        if "Index Name" in n:
            rel, nombre_sp, join = lado_en_join(n)
            lado = LADO.get(rel, "sin join (acceso directo)") if rel else "sin join (acceso directo)"
            if join and rel in ("Outer", "Inner"):
                lado = f"{join}: {lado}"
            padre = join
            indices.append(dict(
                tipo=tipo, indice=n["Index Name"], tabla=n.get("Relation Name") or (n["_padre"] or {}).get("Relation Name"),
                condicion=n.get("Index Cond", n.get("Order By", "")), orden_knn=n.get("Order By"),
                lado=lado, subplan=nombre_sp, loops=loops,
                filas_por_loop=n.get("Actual Rows"), nodo_padre=padre))
        if tipo == "Seq Scan":
            secuenciales.append(dict(tabla=n.get("Relation Name"), loops=loops, filas=n.get("Actual Rows"),
                                     filtro=n.get("Filter", "")))
    return dict(archivo=os.path.basename(ruta), planning_ms=plan.get("Planning Time"),
                execution_ms=plan.get("Execution Time"), indices=indices, seq_scans=secuenciales)


resumen = {}
for nombre in sorted(os.listdir(CARPETA)):
    if nombre.endswith(".json") and nombre != "resumen.json":
        clave = nombre[:-5]
        try:
            resumen[clave] = resumir(os.path.join(CARPETA, nombre))
        except Exception as e:                     # un plan ilegible no debe botar todo
            resumen[clave] = dict(error=str(e))

with open(os.path.join(CARPETA, "resumen.json"), "w") as f:
    json.dump(resumen, f, indent=1, ensure_ascii=False, default=str)

lineas = ["# Resumen automático de los planes de ejecución", "",
          "Generado por `consultas/resumen_planes.py` a partir de `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.",
          "Los tiempos son de una ejecución con caché caliente en la máquina donde se corrió.", ""]
for clave, r in resumen.items():
    if clave.endswith("_sin_indice"):
        continue
    lineas.append(f"## {clave}")
    if "error" in r:
        lineas += [f"(no se pudo leer: {r['error']})", ""]
        continue
    sin = resumen.get(clave + "_sin_indice")
    t = f"Ejecución: **{r['execution_ms']:.0f} ms** (planificación {r['planning_ms']:.1f} ms)"
    if sin and "error" not in sin:
        x = sin["execution_ms"] / max(r["execution_ms"], 0.001)
        t += f" · con índices apagados: **{sin['execution_ms']:.0f} ms** (×{x:.1f})"
    lineas += [t, ""]
    if r["indices"]:
        lineas.append("| Índice | Tabla | Nodo | Lado | Veces | Condición |")
        lineas.append("|---|---|---|---|---|---|")
        vistos = set()
        for i in r["indices"]:
            k = (i["indice"], i["lado"], i["tipo"])
            if k in vistos:
                continue
            vistos.add(k)
            cond = (i["condicion"] or "").replace("|", "\\|")
            lineas.append(f"| `{i['indice']}` | {i['tabla']} | {i['tipo']} | {i['lado']} | {i['loops']} | `{cond[:90]}` |")
        lineas.append("")
    else:
        lineas += ["No usa índices.", ""]
    if r["seq_scans"]:
        tablas = ", ".join(f"{s['tabla']} ({s['filas']} filas × {s['loops']})" for s in r["seq_scans"])
        lineas += [f"Recorridos secuenciales: {tablas}", ""]
with open(os.path.join(CARPETA, "resumen.md"), "w") as f:
    f.write("\n".join(lineas) + "\n")
print(f"resumen de {len(resumen)} planes -> {CARPETA}/resumen.md")
