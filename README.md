# Informação Geográfica para o mapeamento de riscos: o Avanço da Mancha Urbana sobre Áreas Suscetíveis a Processos Geo-Hidrológicos no Brasil

Repositório do artigo homônimo, submetido ao Simpósio Interdisciplinar de Ciência Ambiental (SICAM).

## O que a análise faz

Cruza o **ano da primeira urbanização** — derivado do MapBiomas Coleção 11 (classe 24, "Área Urbanizada"), de 1985 a 2025 em cortes quinquenais — com as **cartas de suscetibilidade do Serviço Geológico do Brasil (SGB/CPRM)** a inundação, enxurrada e corrida de massa. O resultado é a área urbanizada sobre terreno suscetível, por município, tipo de processo e quinquênio.

As cartas do SGB citam 766 municípios, e é esse o conjunto processado; 209 têm as três. Em 746 deles existe área urbanizada sobre terreno suscetível — os outros 20 são cobertos por alguma carta, mas não têm mancha urbana sobre ela.

## Principais resultados

### Quanto, e desde quando

Em 2025, **5.314 km²** de área urbanizada no Brasil estão sobre terreno suscetível a inundação, enxurrada ou corrida de massa, distribuídos por 746 municípios.

Desse total, **2.685 km² já existiam em 1985** — é o estoque herdado, não crescimento observado. Os outros **2.629 km² foram urbanizados entre 1986 e 2025**: em quarenta anos a área urbana sobre terreno suscetível praticamente **dobrou** (+98%). Metade de tudo que hoje está exposto foi construído depois do início da série.

| Período | Novo (km²) | Acumulado (km²) |
|---|---:|---:|
| Pré-1985 (estoque) | 2.685,5 | 2.685,5 |
| 1986–1990 | 354,3 | 3.039,7 |
| 1991–1995 | 410,6 | 3.450,3 |
| 1996–2000 | 415,3 | 3.865,6 |
| 2001–2005 | 338,2 | 4.203,8 |
| 2006–2010 | 272,1 | 4.476,0 |
| 2011–2015 | 327,6 | 4.803,6 |
| 2016–2020 | 215,2 | 5.018,8 |
| 2021–2025 | 295,8 | 5.314,5 |

O ritmo oscila entre 215 e 415 km² por quinquênio e não mostra queda sustentada: o último período (295,8 km²) supera os dois anteriores. A ocupação de áreas suscetíveis não é um passivo do passado que parou de crescer.

### Por tipo de processo

| Carta | Área 2025 (km²) | % da união |
|---|---:|---:|
| Inundação | 5.133,0 | 96,6% |
| Enxurrada | 207,9 | 3,9% |
| Corrida de massa | 44,2 | 0,8% |

Os totais por carta somam mais que os 5.314 km² da união porque as cartas se sobrepõem: 70,4 km² (1,3%) estão cobertos por mais de um processo. A decomposição exclusiva das sete combinações, gravada no CSV, é que soma a união exata.

A comparação entre tipos mede, em parte, cobertura desigual — são 742 municípios mapeados para inundação, 359 para enxurrada e 242 para corrida de massa. Nos **209 municípios que têm as três cartas**, onde a comparação é defensável, o quadro se mantém: 2.080 km² no total (+90% desde 1985), com inundação respondendo por 94,8%.

### Onde

O crescimento de 1986–2025 é concentrado. Rio de Janeiro (23,2%), Santa Catarina (18,9%) e São Paulo (12,9%) somam mais da metade; os dez municípios de maior avanço respondem por 17,1% do total nacional.

| Município | Crescimento 1986–2025 (km²) |
|---|---:|
| Rio de Janeiro/RJ | 114,9 |
| Duque de Caxias/RJ | 51,5 |
| Maricá/RJ | 44,4 |
| Aracaju/SE | 44,3 |
| Florianópolis/SC | 44,1 |
| Campos dos Goytacazes/RJ | 37,9 |
| Palhoça/SC | 31,3 |
| Fortaleza/CE | 27,4 |
| Araruama/RJ | 27,3 |
| São Paulo/SP | 27,1 |

As ressalvas metodológicas — área por célula, sobreposição entre cartas, reversões da classe urbana — estão em `urban_area_analysis.qmd`.

## Como reproduzir

Requer R 4.6+, Python 3.11+ e Quarto.

```r
install.packages(c(
  "sf", "terra", "geobr", "dplyr", "tidyr", "ggplot2", "ggpattern",
  "readr", "stringr", "stringi", "scales", "fs", "rmarkdown", "svglite"
), type = "binary")
```

```bash
python scripts/converte_parquet.py     # cartas do SGB: Parquet -> GeoPackage em WGS 84
Rscript scripts/calcula_expansao.R BR  # baixa o MapBiomas (~6 GB) e faz o cruzamento
quarto render urban_area_analysis.qmd  # desenha as figuras
```

O segundo passo aceita um recorte: `RJ` para uma UF, `3300100` para Angra dos Reis. Convém testar num município antes de rodar o país inteiro — a execução nacional leva horas.

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `scripts/calcula_expansao.R` | pipeline espacial; grava `output/expansao_suscetibilidade_municipio.csv` |
| `scripts/converte_parquet.py` | conversão única dos Parquet do SGB para GeoPackage |
| `urban_area_analysis.qmd` | consome o CSV e desenha as figuras |
| `data/` | insumos (não versionado) |
| `output/` | tabela e figuras (não versionado — reproduzir com o pipeline) |

## Fontes

- **MapBiomas** Coleção 11 — cobertura e uso da terra, 1985-2025, 30 m.
- **SGB/CPRM** — Cartas de Suscetibilidade a Movimentos Gravitacionais de Massa e Inundações.
- **IBGE** — malha municipal 2022, via pacote `geobr`.

## Nota metodológica

As três cartas do SGB cobrem conjuntos diferentes de municípios (742 para inundação, 359 para enxurrada, 242 para corrida de massa), e elas se sobrepõem entre si. Para não contar duas vezes o mesmo pixel, o resultado é gravado como decomposição exclusiva: cada pixel é atribuído à combinação exata de cartas que o cobrem, e essas combinações somam a área real. O total de cada carta é derivado somando as combinações que a contêm, e a fatia coberta por mais de um processo aparece destacada com hachura nas figuras.

A coluna `tem_3_cartas` marca os 209 municípios mapeados para os três processos, onde a comparação entre tipos é mais defensável.

As áreas são calculadas célula a célula com `terra::cellSize()`: o raster é geográfico, e a célula de 30 m só tem 900 m² no equador — na latitude do Sudeste ela encolhe para cerca de 825 m².
