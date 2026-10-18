-- =============================================================================
-- Pregunta 6 (contexto) — distribución de la grilla, para interpretar el top 10
-- =============================================================================
SELECT count(*)                                                      AS celdas,
       count(*) FILTER (WHERE frac_en_caja >= 0.99)                  AS celdas_completas,
       sum(n_edificios)                                              AS edificios,
       round(avg(n_edificios) FILTER (WHERE frac_en_caja >= 0.99), 1) AS edificios_prom_celda,
       round(avg(n_recorridos) FILTER (WHERE frac_en_caja >= 0.99), 1) AS recorridos_prom_celda,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY n_recorridos)
         FILTER (WHERE frac_en_caja >= 0.99)                         AS recorridos_mediana,
       count(*) FILTER (WHERE frac_en_caja >= 0.99 AND n_recorridos = 0 AND n_edificios > 0)
                                                                     AS celdas_con_edificios_sin_recorridos,
       round(corr(n_edificios, n_recorridos) FILTER (WHERE frac_en_caja >= 0.99)::numeric, 3)
                                                                     AS correlacion_edificios_recorridos
FROM stgo.mv_grilla;
