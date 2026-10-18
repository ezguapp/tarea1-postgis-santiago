# PostGIS + herramientas de ETL y mapas en una sola imagen.
# Base: imagen oficial postgis/postgis (PostgreSQL 16, PostGIS 3.4, Debian).
FROM postgis/postgis:16-3.4

# gdal-bin      -> ogr2ogr / ogrinfo (carga OSM desde PBF o GeoPackage, exporta GeoPackage)
# osmium-tool   -> recorte rápido del PBF de Chile a la caja de estudio + fecha del extracto
# unzip         -> extraer el ZIP del GTFS
# python3-*     -> mapas (matplotlib) y armado del informe; sin pip, solo paquetes Debian
RUN set -eux; \
    rm -f /etc/apt/sources.list.d/*pgdg* /etc/apt/sources.list.d/*.sources; \
    echo 'deb http://deb.debian.org/debian bullseye main' > /etc/apt/sources.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      gdal-bin osmium-tool unzip ca-certificates \
      python3 python3-matplotlib python3-numpy; \
    rm -rf /var/lib/apt/lists/*

# Los scripts corren con el usuario del anfitrión (sin home ni permiso en /):
# temporales de GDAL (driver OSM) y caché de matplotlib van a /tmp.
ENV MPLBACKEND=Agg \
    MPLCONFIGDIR=/tmp/matplotlib \
    CPL_TMPDIR=/tmp \
    HOME=/tmp
WORKDIR /tmp
