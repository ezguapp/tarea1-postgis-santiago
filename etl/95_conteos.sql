-- =============================================================================
-- 95_conteos.sql — conteos e índices de cada tabla derivada (van al README)
-- =============================================================================
CREATE OR REPLACE FUNCTION stgo._filas(t regclass) RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE n bigint;
BEGIN
  EXECUTE format('SELECT count(*) FROM %s', t) INTO n;
  RETURN n;
END $$;

CREATE OR REPLACE VIEW stgo.v_indices AS
SELECT c.relname                                         AS tabla,
       i.relname                                         AS indice,
       am.amname                                         AS tipo,
       pg_get_indexdef(i.oid)                            AS definicion,
       pg_size_pretty(pg_relation_size(i.oid))           AS tamano
FROM pg_index x
JOIN pg_class i ON i.oid = x.indexrelid
JOIN pg_class c ON c.oid = x.indrelid
JOIN pg_am am   ON am.oid = i.relam
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'stgo'
ORDER BY c.relname, i.relname;

CREATE OR REPLACE VIEW stgo.v_conteos AS
SELECT c.relname AS tabla,
       stgo._filas(c.oid::regclass) AS filas,
       COALESCE((SELECT type || ' ' || srid FROM geometry_columns g
                 WHERE g.f_table_schema = 'stgo' AND g.f_table_name = c.relname
                 ORDER BY f_geometry_column LIMIT 1), '—') AS geometria,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS tamano,
       COALESCE((SELECT string_agg(i.relname || ' (' || am.amname || ')', ', ' ORDER BY i.relname)
                 FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid
                 JOIN pg_am am ON am.oid = i.relam
                 WHERE x.indrelid = c.oid), '—') AS indices
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'stgo' AND c.relkind IN ('r', 'm')
  AND c.relname NOT IN ('etl_log', 'config')
ORDER BY c.relname;
