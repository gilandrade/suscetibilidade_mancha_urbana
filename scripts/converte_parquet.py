"""Converte os Parquet do SGB para GeoPackage em EPSG:4326.

As cartas de enxurrada e corrida de massa chegam como GeoParquet em SIRGAS 2000
(EPSG:4674). O pipeline em R le GeoPackage (o binario do sf no Windows nao traz o
driver Parquet) e trabalha na grade do MapBiomas, em WGS 84 — entao a conversao
faz as duas coisas de uma vez e grava indice espacial.

Os textos ja estao em UTF-8 valido no Parquet; caracteres estranhos vistos no
console do Windows sao limitacao de exibicao, nao defeito no dado. Nao aplicar
iconv/latin1 aqui: isso corromperia os acentos.

Uso:
    python scripts/converte_parquet.py
"""

import re
import unicodedata

import geopandas as gpd

DATA = "data"
CRS_WGS84 = 4326
CRS_SIRGAS = 4674

FONTES = {
    "SGB_Suscetibilidade_Enxurrada.parquet": "enxurrada.gpkg",
    "SGB_Corrida_de_Massa.parquet": "corrida_de_massa.gpkg",
}

# colunas tecnicas do geoparquet e do export do ArcGIS que nao interessam
DESCARTA = {"geometry_bbox", "geometria", "st_area_shape", "st_length_shape"}


def limpa_nome(nome: str) -> str:
    """Normaliza um nome de coluna para snake_case ASCII."""
    n = unicodedata.normalize("NFKD", nome).encode("ascii", "ignore").decode()
    return re.sub(r"[^0-9a-zA-Z]+", "_", n).strip("_").lower()


def converte(arquivo: str, saida: str) -> None:
    gdf = gpd.read_parquet(f"{DATA}/{arquivo}")
    geom_col = gdf.geometry.name

    gdf = gdf.rename(columns={c: limpa_nome(c) for c in gdf.columns if c != geom_col})
    gdf = gdf.drop(columns=[c for c in gdf.columns if c in DESCARTA])

    for coluna in gdf.columns:
        if coluna != geom_col and gdf[coluna].dtype == object:
            gdf[coluna] = gdf[coluna].str.strip()

    if gdf.crs is None:
        gdf = gdf.set_crs(CRS_SIRGAS)
    gdf = gdf.to_crs(CRS_WGS84)

    destino = f"{DATA}/{saida}"
    gdf.to_file(destino, driver="GPKG", layer=saida.replace(".gpkg", ""))

    print(f"=== {saida}: {len(gdf)} feicoes, EPSG:{gdf.crs.to_epsg()}")
    print("    colunas:", list(gdf.columns))
    print("    municipios:", gdf["municipio"].nunique())
    print("    classes:", gdf["classe"].value_counts().to_dict())


if __name__ == "__main__":
    for arquivo, saida in FONTES.items():
        converte(arquivo, saida)
