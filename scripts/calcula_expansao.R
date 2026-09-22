# =============================================================================
# Expansao da mancha urbana sobre areas suscetiveis a processos geo-hidrologicos
#
# Cruza o ano da primeira urbanizacao (MapBiomas Colecao 11, classe 24) com as
# cartas de suscetibilidade do SGB/CPRM, agregando por municipio, categoria e
# periodo quinquenal.
#
# Escreve output/expansao_suscetibilidade_municipio.csv. O .qmd so consome esse
# arquivo, entao o render fica rapido e este script roda uma vez so.
#
# Uso:  Rscript scripts/calcula_expansao.R [AREA_INTERESSE]
#       AREA_INTERESSE: "BR" (padrao), uma sigla de UF ("RJ") ou um codigo IBGE.
# =============================================================================

suppressPackageStartupMessages({
  library(sf)
  library(terra)
  library(geobr)
  library(dplyr)
  library(readr)
  library(stringr)
  library(stringi)
  library(fs)
})

# ==== Constantes =============================================================

CRS_WGS84 <- 4326 # grade nativa do MapBiomas
CLASSE_URBANA <- 24 # "Area Urbanizada" na legenda do MapBiomas
ANOS_CORTE <- seq(1985, 2025, by = 5)
ANO_BASE <- min(ANOS_CORTE) # estoque pre-existente, nao e crescimento

DIR_DADOS <- "data"
DIR_SAIDA <- "output"
ARQUIVO_SAIDA <- path(DIR_SAIDA, "expansao_suscetibilidade_municipio.csv")
SALVA_A_CADA <- 50 # checkpoint parcial, para nao perder o trabalho num erro

args <- commandArgs(trailingOnly = TRUE)
AREA_INTERESSE <- if (length(args)) args[1] else "BR"

# Erros de grafia/UF nas cartas do SGB que impedem o casamento com a malha IBGE.
# RORAIMA-RR e nome de estado, nao de municipio: descartado.
CORRECOES <- c(
  "SAO LUIS DO PARAITINGA-SP" = "SAO LUIZ DO PARAITINGA-SP",
  "DORES DE RIO PRETO-ES"     = "DORES DO RIO PRETO-ES",
  "BOM JESUS DO ITABAPOANA-ES" = "BOM JESUS DO ITABAPOANA-RJ"
)
DESCARTA_CHAVE <- "RORAIMA-RR"

dir_create(c(DIR_DADOS, path(DIR_DADOS, "temp"), DIR_SAIDA))
terraOptions(memfrac = 0.5, tempdir = path(DIR_DADOS, "temp"))

mapbiomas_files <- path(DIR_DADOS, str_glue("brazil_coverage-col11_{ANOS_CORTE}.tif"))
names(mapbiomas_files) <- as.character(ANOS_CORTE)
stopifnot(all(file_exists(mapbiomas_files)))

categorias <- tibble::tribble(
  ~categoria, ~arquivo, ~camada,
  "Inundação", "suscetibilidade_inundacao_BR_v2.gpkg", "suscetibilidade_inundacao_BR_v2",
  "Enxurrada", "enxurrada.gpkg", "enxurrada",
  "Corrida de massa", "corrida_de_massa.gpkg", "corrida_de_massa"
) |>
  mutate(caminho = path(DIR_DADOS, arquivo))
stopifnot(all(file_exists(categorias$caminho)))

# Ordem global das cartas: e ela que define o bit de cada uma na chave de
# combinacao. ROTULO_COMBO traduz o codigo 1..7 no rotulo correspondente.
NOMES_CAT <- categorias$categoria
ROTULO_COMBO <- vapply(
  seq_len(2^length(NOMES_CAT) - 1),
  function(k) {
    presentes <- bitwAnd(k, bitwShiftL(1L, seq_along(NOMES_CAT) - 1L)) > 0
    paste(NOMES_CAT[presentes], collapse = " + ")
  },
  character(1)
)

# ==== Municipios-alvo ========================================================
# A lista de candidatos sai dos atributos das cartas (consulta SQL, sem carregar
# geometria: a camada de inundacao tem 588 mil feicoes e 3 GB). A atribuicao
# municipal final NAO usa esse atributo — no loop zonal cada pixel e recortado
# pelo poligono do municipio, o que trata as bacias que cruzam divisas.

normaliza <- function(x) {
  x |>
    stri_trans_general("Latin-ASCII") |>
    str_to_upper() |>
    str_replace_all("[^A-Z ]", " ") |>
    str_squish()
}

message("Lendo municipios citados nas cartas...")
lista <- list()
for (i in seq_len(nrow(categorias))) {
  q <- str_glue("SELECT DISTINCT municipio, uf FROM \"{categorias$camada[i]}\"")
  d <- st_read(categorias$caminho[i], query = q, quiet = TRUE)
  if (inherits(d, "sf")) d <- st_drop_geometry(d)
  lista[[i]] <- as_tibble(d) |>
    filter(!is.na(municipio), municipio != "", !is.na(uf), uf != "") |>
    mutate(categoria = categorias$categoria[i])
}

munis_carta <- bind_rows(lista) |>
  mutate(chave = str_c(normaliza(municipio), "-", str_to_upper(str_trim(uf)))) |>
  mutate(chave = coalesce(CORRECOES[chave], chave)) |>
  filter(chave != DESCARTA_CHAVE)

message("Baixando a malha municipal do IBGE...")
malha <- read_municipality(year = 2022, showProgress = FALSE) |>
  st_transform(CRS_WGS84) |>
  mutate(chave = str_c(normaliza(name_muni), "-", str_to_upper(abbrev_state)))

tem_3 <- munis_carta |>
  distinct(chave, categoria) |>
  count(chave) |>
  filter(n == nrow(categorias)) |>
  pull(chave)

alvos <- malha |>
  filter(chave %in% unique(munis_carta$chave)) |>
  mutate(tem_3_cartas = chave %in% tem_3)

sem_match <- setdiff(unique(munis_carta$chave), malha$chave)
message(str_glue(
  "Municipios nas cartas: {n_distinct(munis_carta$chave)} | ",
  "casados: {nrow(alvos)} | sem correspondencia: {length(sem_match)} | ",
  "com as 3 cartas: {sum(alvos$tem_3_cartas)}"
))
if (length(sem_match)) message("  sem match: ", paste(sem_match, collapse = " | "))

if (AREA_INTERESSE != "BR") {
  alvos <- if (str_detect(AREA_INTERESSE, "^[A-Za-z]{2}$")) {
    filter(alvos, abbrev_state == str_to_upper(AREA_INTERESSE))
  } else {
    filter(alvos, code_muni == as.numeric(AREA_INTERESSE))
  }
  message(str_glue("Recorte '{AREA_INTERESSE}': {nrow(alvos)} municipios"))
}

# ==== Loop zonal =============================================================

# Grade de referencia (so metadados: nenhum pixel e lido daqui).
TEMPLATE <- rast(mapbiomas_files[[1]])
TILE_PX <- 1024 # ~1 M celulas por ladrilho, ~0,28 grau

#' Extensao de um bloco de colunas/linhas, nas bordas exatas das celulas.
#' Ancorar na grade e o que garante que ladrilhos vizinhos nao compartilhem
#' celula — sem isso, pixels de borda seriam contados duas vezes.
ext_bloco <- function(c0, c1, r0, r1) {
  rx <- xres(TEMPLATE)
  ry <- yres(TEMPLATE)
  ext(
    xmin(TEMPLATE) + (c0 - 1) * rx,
    xmin(TEMPLATE) + c1 * rx,
    ymax(TEMPLATE) - r1 * ry,
    ymax(TEMPLATE) - (r0 - 1) * ry
  )
}

#' Cruzamento dentro de um ladrilho. Retorna NULL se nao ha mancha urbana.
processa_bloco <- function(muni_v, geoms, e) {
  # Atalho: se nao ha urbano no ultimo ano, nao houve em nenhum — a mancha
  # urbana e essencialmente monotonica. Evita 8 das 9 leituras na maioria dos
  # ladrilhos, que sao planicies de inundacao em area rural.
  ultimo <- crop(rast(mapbiomas_files[[as.character(max(ANOS_CORTE))]]), e) == CLASSE_URBANA
  if (!any(values(ultimo)[, 1], na.rm = TRUE)) {
    return(NULL)
  }

  primeiro <- NULL
  for (yr in ANOS_CORTE) {
    urbano <- if (yr == max(ANOS_CORTE)) {
      ultimo
    } else {
      crop(rast(mapbiomas_files[[as.character(yr)]]), e) == CLASSE_URBANA
    }
    primeiro <- if (is.null(primeiro)) {
      ifel(urbano, yr, NA)
    } else {
      ifel(urbano & is.na(primeiro), yr, primeiro)
    }
  }

  ano <- values(primeiro)[, 1]
  if (all(is.na(ano))) {
    return(NULL)
  }

  # Area real por celula. O raster e geografico (graus): a celula so mede
  # 30 x 30 m no equador e encolhe para ~825 m2 na latitude de Angra. Usar
  # 900 m2 fixo superestimaria a area em 8-17% no Centro-Sul.
  area <- values(cellSize(primeiro, unit = "m"))[, 1]
  dentro_muni <- !is.na(values(rasterize(muni_v, primeiro, field = 1))[, 1])

  # Chave de bits por celula, na ordem GLOBAL das categorias — nunca na ordem
  # local do bloco, que varia conforme quais cartas tocam aquele ladrilho.
  codigo <- integer(length(ano))
  conferencia <- numeric(length(NOMES_CAT))
  names(conferencia) <- NOMES_CAT

  for (i in seq_along(NOMES_CAT)) {
    g <- geoms[[NOMES_CAT[i]]]
    if (is.null(g)) next
    mk <- rasterize(g, primeiro, field = 1, touches = TRUE)
    dentro <- !is.na(values(mk)[, 1]) & dentro_muni & !is.na(ano)
    codigo <- codigo + dentro * bitwShiftL(1L, i - 1L)
    # total direto da carta, guardado para aferir a decomposicao
    conferencia[i] <- sum(area[dentro])
  }

  sel <- codigo > 0
  if (!any(sel)) {
    return(NULL)
  }

  # As 7 combinacoes sao mutuamente exclusivas e somam exatamente a uniao.
  list(
    dados = tibble(
      combinacao = ROTULO_COMBO[codigo[sel]],
      ano = ano[sel],
      area_m2 = area[sel]
    ),
    conferencia = conferencia
  )
}

#' Area urbanizada por categoria e ano dentro de um municipio.
#' Percorre a area em ladrilhos: ler a caixa inteira de um municipio amazonico
#' significaria varrer dezenas de milhoes de celulas quase todas vazias, nove
#' vezes. Aqui so os ladrilhos com suscetibilidade sao lidos.
zonal_municipio <- function(muni) {
  caixa <- st_as_text(st_as_sfc(st_bbox(muni)))

  geoms <- list()
  for (i in seq_len(nrow(categorias))) {
    g <- read_sf(categorias$caminho[i], wkt_filter = caixa)
    if (nrow(g) > 0) {
      geoms[[categorias$categoria[i]]] <- vect(st_make_valid(st_geometry(g)))
    }
  }
  if (length(geoms) == 0) {
    return(NULL)
  }
  muni_v <- vect(muni)

  # area de interesse = caixa dos poligonos, limitada a do municipio
  bb <- do.call(rbind, lapply(geoms, function(g) as.vector(ext(g))))
  bm <- as.numeric(st_bbox(muni))
  x0 <- max(min(bb[, 1]), bm[1]); x1 <- min(max(bb[, 2]), bm[3])
  y0 <- max(min(bb[, 3]), bm[2]); y1 <- min(max(bb[, 4]), bm[4])
  if (x1 <= x0 || y1 <= y0) {
    return(NULL)
  }

  c0 <- max(1L, colFromX(TEMPLATE, x0)); c1 <- min(ncol(TEMPLATE), colFromX(TEMPLATE, x1))
  r0 <- max(1L, rowFromY(TEMPLATE, y1)); r1 <- min(nrow(TEMPLATE), rowFromY(TEMPLATE, y0))
  if (anyNA(c(c0, c1, r0, r1)) || c1 < c0 || r1 < r0) {
    return(NULL)
  }

  partes <- list()
  for (ca in seq(c0, c1, by = TILE_PX)) {
    for (ra in seq(r0, r1, by = TILE_PX)) {
      e <- ext_bloco(ca, min(ca + TILE_PX - 1L, c1), ra, min(ra + TILE_PX - 1L, r1))

      gs <- list()
      for (nome in names(geoms)) {
        gg <- crop(geoms[[nome]], e)
        if (!is.null(gg) && nrow(gg) > 0) gs[[nome]] <- gg
      }
      if (length(gs) == 0) next

      mv <- crop(muni_v, e)
      if (is.null(mv) || nrow(mv) == 0) next

      bloco <- processa_bloco(mv, gs, e)
      if (!is.null(bloco)) partes[[length(partes) + 1]] <- bloco
    }
  }

  if (length(partes) == 0) {
    return(NULL)
  }

  saida <- bind_rows(lapply(partes, `[[`, "dados")) |>
    group_by(combinacao, ano) |>
    summarise(area_m2 = sum(area_m2), .groups = "drop") |>
    mutate(
      code_muni = muni$code_muni,
      name_muni = muni$name_muni,
      abbrev_state = muni$abbrev_state,
      tem_3_cartas = muni$tem_3_cartas
    )

  # Afericao da logica de bits: o total de cada carta derivado das combinacoes
  # tem de bater com a soma direta da mascara daquela carta.
  direto <- rowSums(do.call(cbind, lapply(partes, `[[`, "conferencia")))
  derivado <- vapply(NOMES_CAT, function(nc) {
    sum(saida$area_m2[grepl(nc, saida$combinacao, fixed = TRUE)])
  }, numeric(1))
  discrepancia <- max(abs(direto - derivado))
  if (discrepancia > 1e-6) {
    warning(str_glue(
      "{muni$name_muni}-{muni$abbrev_state}: decomposicao diverge em {discrepancia} m2"
    ))
  }

  saida
}

message(str_glue("\nProcessando {nrow(alvos)} municipios...\n"))
t_inicio <- Sys.time()
resultados <- vector("list", nrow(alvos))

for (i in seq_len(nrow(alvos))) {
  muni <- alvos[i, ]
  resultados[[i]] <- tryCatch(
    zonal_municipio(muni),
    error = function(e) {
      warning(str_glue("Falhou em {muni$name_muni}-{muni$abbrev_state}: {conditionMessage(e)}"))
      NULL
    }
  )

  if (i %% 10 == 0 || i == nrow(alvos)) {
    decorrido <- as.numeric(difftime(Sys.time(), t_inicio, units = "mins"))
    message(sprintf(
      "[%4d/%4d] %-32s %5.1f min decorridos, ~%.0f min restantes",
      i, nrow(alvos), str_c(muni$name_muni, "-", muni$abbrev_state),
      decorrido, decorrido / i * (nrow(alvos) - i)
    ))
  }
  if (i %% SALVA_A_CADA == 0) {
    saveRDS(bind_rows(resultados), path(DIR_SAIDA, "_parcial.rds"))
    gc(verbose = FALSE)
  }
}

# ==== Tabela tidy ============================================================

bruto <- bind_rows(resultados)
stopifnot(nrow(bruto) > 0)

niveis_periodo <- c("Pré-1985", str_c(ANOS_CORTE[-1] - 4, "-", ANOS_CORTE[-1]))

expansao <- bruto |>
  mutate(
    periodo = if_else(ano == ANO_BASE, "Pré-1985", str_c(ano - 4, "-", ano)),
    periodo = factor(periodo, levels = niveis_periodo),
    area_km2 = area_m2 / 1e6,
    combinacao = factor(combinacao, levels = ROTULO_COMBO),
    n_tipos = str_count(as.character(combinacao), fixed(" + ")) + 1L
  ) |>
  select(
    code_muni, name_muni, abbrev_state, tem_3_cartas,
    combinacao, n_tipos, ano, periodo, area_km2
  ) |>
  arrange(abbrev_state, name_muni, combinacao, ano)

write_csv(expansao, ARQUIVO_SAIDA)

parcial <- path(DIR_SAIDA, "_parcial.rds")
if (file_exists(parcial)) file_delete(parcial)

message(str_glue(
  "\nConcluido em {round(difftime(Sys.time(), t_inicio, units = 'mins'))} min. ",
  "{nrow(expansao)} linhas, {n_distinct(expansao$code_muni)} municipios -> {ARQUIVO_SAIDA}"
))

# ==== Verificacao ============================================================
# As 7 combinacoes sao exclusivas, entao somam a uniao por construcao. O que
# vale reportar e o peso da sobreposicao e o total por carta (que soma as
# combinacoes que a contem, e por isso excede a uniao).
crescimento <- filter(expansao, ano > ANO_BASE)

cat("\n=== crescimento 1986-2025 ===\n")
cat(sprintf("uniao (todas as combinacoes) %8.1f km2\n", sum(crescimento$area_km2)))
cat(sprintf("  com um tipo so             %8.1f km2\n",
            sum(crescimento$area_km2[crescimento$n_tipos == 1])))
cat(sprintf("  com mais de um tipo        %8.1f km2  (%.1f%%)\n",
            sum(crescimento$area_km2[crescimento$n_tipos > 1]),
            100 * sum(crescimento$area_km2[crescimento$n_tipos > 1]) / sum(crescimento$area_km2)))

cat("\n=== total por carta (combinacoes que a contem) ===\n")
for (nc in NOMES_CAT) {
  cat(sprintf("  %-18s %8.1f km2\n", nc,
              sum(crescimento$area_km2[str_detect(as.character(crescimento$combinacao), fixed(nc))])))
}

cat("\n=== area por combinacao (km2) ===\n")
print(as.data.frame(
  crescimento |>
    group_by(combinacao) |>
    summarise(km2 = round(sum(area_km2), 2), .groups = "drop")
))
