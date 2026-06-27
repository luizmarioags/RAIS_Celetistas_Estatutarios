# ============================================================
# RAIS 2025 - Processamento local dos Parquets já gerados
# SEM BigQuery
# SEM DuckDB
# SEM SQL
#
# Objetivo:
#   Criar base de percentis salariais para gráficos por:
#   - Brasil / Região / UF
#   - Regime: celetista x estatutário
#   - Sexo
#   - Escolaridade dentro desses grupos
#
# Saídas:
#   - Parquet particionado de percentis
#   - DTA único de percentis
#   - DTAs por tipo de recorte
#   - Base KDE de densidade salarial para gráficos separados
#   - Catálogo de recortes
#   - Resumo dos grupos
#
# Recortes de escolaridade usados:
#   - geral: todas as escolaridades
#   - escolaridade_macro: categorias agregadas; Ensino Médio reúne
#     Ensino Médio incompleto + Ensino Médio completo
#   - escolaridade_detalhada: categorias completas do dicionário RAIS
#
# Ajustes incluídos:
#   - Barras de progresso com:
#       * percentual concluído
#       * tempo decorrido
#       * ETA / tempo estimado restante
#       * mensagem da etapa atual
#   - Limpeza reforçada de memória:
#       * gc(full = TRUE) em pontos críticos
#       * remoção explícita de objetos intermediários grandes
#       * remoção de colunas auxiliares depois de usadas
#       * evita cópias desnecessárias em write_dta()
# ============================================================


# ------------------------------------------------------------
# 1. Pacotes
# ------------------------------------------------------------

pacotes <- c(
  "arrow",
  "dplyr",
  "data.table",
  "haven",
  "progress"
)

faltantes <- setdiff(pacotes, rownames(installed.packages()))

if (length(faltantes) > 0L) {
  install.packages(faltantes)
}

invisible(lapply(pacotes, library, character.only = TRUE))

# Reduz paralelismo para diminuir picos de memória em operações grandes.
# Aumente para 4L se houver bastante RAM disponível.
data.table::setDTthreads(2L)
try(arrow::set_cpu_count(2L), silent = TRUE)


# ------------------------------------------------------------
# 2. Configurações principais
# ------------------------------------------------------------


# ------------------------------------------------------------
# 2.0. Diretório do projeto
# ------------------------------------------------------------
# Os caminhos de entrada e saída são definidos a partir da raiz local do
# repositório. Assim, após um `git clone`, os resultados são salvos dentro
# da própria pasta clonada, sem depender de caminhos pessoais/absolutos.
#
# Prioridade:
#   1) variável de ambiente RAIS_DIR_BASE, útil em shell scripts/CI;
#   2) diretório do próprio script executado com Rscript;
#   3) diretório de trabalho atual.

detectar_raiz_repositorio <- function() {
  env_dir <- Sys.getenv("RAIS_DIR_BASE", unset = "")

  if (nzchar(env_dir)) {
    return(normalizePath(env_dir, winslash = "/", mustWork = FALSE))
  }

  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- "--file="
  script_arg <- args[startsWith(args, file_arg)]

  if (length(script_arg) > 0L) {
    script_path <- sub(file_arg, "", script_arg[[1L]], fixed = TRUE)
    return(dirname(normalizePath(script_path, winslash = "/", mustWork = FALSE)))
  }

  normalizePath(getwd(), winslash = "/", mustWork = FALSE)
}

dir_base <- detectar_raiz_repositorio()

# Pasta dos Parquets já gerados pelo processamento anterior.
dir_entrada <- file.path(
  dir_base,
  "rais_2025_download_bigquery_raw"
)

dir_saida <- file.path(
  dir_base,
  "rais_2025_bases_graficos_percentis"
)

dir_parquet_saida <- file.path(
  dir_saida,
  "base_percentis_salariais_long_parquet"
)

# Base complementar para gráficos KDE/densidade.
# O Stata usa este arquivo para gerar um gráfico separado de distribuição
# para cada contexto dos gráficos de percentis.
dir_parquet_kde_saida <- file.path(
  dir_saida,
  "base_kde_salariais_long_parquet"
)

dir_dta_por_recorte <- file.path(
  dir_saida,
  "dta_por_recorte"
)

arquivo_dta_unico <- file.path(
  dir_saida,
  "base_percentis_salariais_recortes_rais_2025.dta"
)

arquivo_kde_dta_unico <- file.path(
  dir_saida,
  "base_kde_salariais_recortes_rais_2025.dta"
)

arquivo_resumo_parquet <- file.path(
  dir_saida,
  "resumo_grupos_percentis_rais_2025.parquet"
)

arquivo_resumo_dta <- file.path(
  dir_saida,
  "resumo_grupos_percentis_rais_2025.dta"
)

arquivo_catalogo_csv <- file.path(
  dir_saida,
  "catalogo_recortes_percentis_rais_2025.csv"
)

arquivo_catalogo_kde_csv <- file.path(
  dir_saida,
  "catalogo_recortes_kde_rais_2025.csv"
)

arquivo_diagnostico_mapa_escolaridade_csv <- file.path(
  dir_saida,
  "diagnostico_mapa_escolaridade_rais_2025.csv"
)

arquivo_diagnostico_escolaridade_final_csv <- file.path(
  dir_saida,
  "diagnostico_escolaridade_final_rais_2025.csv"
)

arquivo_diagnostico_escolaridade_nao_classificada_csv <- file.path(
  dir_saida,
  "diagnostico_escolaridade_nao_classificada_rais_2025.csv"
)

arquivo_diagnostico_colunas_escolaridade_csv <- file.path(
  dir_saida,
  "diagnostico_colunas_escolaridade_rais_2025.csv"
)

dir.create(dir_saida, recursive = TRUE, showWarnings = FALSE)
dir.create(dir_dta_por_recorte, recursive = TRUE, showWarnings = FALSE)


# ------------------------------------------------------------
# 3. Opções analíticas
# ------------------------------------------------------------

ano_base <- 2025L

usar_apenas_ativos_3112 <- TRUE
usar_apenas_remuneracao_positiva <- TRUE

regimes_mantidos <- c("celetista", "estatutario")

min_n_grupo <- 1L

# Use Inf para não cortar outliers.
# Exemplo: 100000 para cortar acima de R$ 100 mil.
limite_superior_remuneracao <- Inf

# Percentis para o eixo x.
# O ponto 100 usa p99,5, evitando que o último ponto seja o máximo absoluto.
probabilidades <- c(seq(0.01, 0.99, by = 0.01), 0.995)

tabela_percentis <- data.table(
  percentil = seq_along(probabilidades),
  probabilidade_quantil = probabilidades
)

# ------------------------------------------------------------
# 3.0.1. Opções para gráficos KDE/densidade
# ------------------------------------------------------------

# TRUE: além da base de percentis, gera uma base enxuta com pontos de
# densidade kernel para cada mesmo contexto dos gráficos de percentis.
# O Stata usa essa base para fazer gráficos KDE separados, com sombra.
gerar_base_kde <- TRUE

# Número de pontos da curva KDE por grupo/regime.
# 160 a 240 costuma ser suficiente para gráficos suaves sem inflar demais o DTA.
n_pontos_kde <- 200L

# Mínimo de observações para estimar KDE em um grupo.
# Grupos menores continuam nos percentis, mas são omitidos da curva KDE.
min_n_kde <- 10L

# Como o percentil 100 da base de gráficos usa p99,5, a KDE também é
# desenhada até p99,5 para evitar que outliers extremos comprimam o gráfico.
probabilidade_limite_superior_kde <- 0.995


# ------------------------------------------------------------
# 3.1. Opções de memória
# ------------------------------------------------------------

# TRUE: força chamadas mais frequentes de gc(full = TRUE).
limpeza_memoria_agressiva <- TRUE

# TRUE: remove colunas auxiliares após criar os recortes finais.
remover_colunas_auxiliares <- TRUE

# TRUE: remove a base original DT depois que base_percentis for criada.
# Isso reduz bastante o pico de memória na fase de exportação.
remover_DT_apos_base_percentis <- TRUE

# TRUE: remove objetos grandes ao final do script.
remover_objetos_grandes_no_final <- TRUE

# Frequência de limpeza nos loops.
gc_a_cada_n_recortes <- 1L
gc_a_cada_n_dtas <- 1L

# FALSE deixa a limpeza silenciosa. Use TRUE para depuração.
mostrar_gc_verbose <- FALSE


# ------------------------------------------------------------
# 4. Funções auxiliares
# ------------------------------------------------------------

limpar_nome_arquivo <- function(x) {
  x <- iconv(x, from = "", to = "ASCII//TRANSLIT")
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x
}

normalizar_texto <- function(x) {
  x <- as.character(x)
  x <- trimws(x)
  x[is.na(x) | x == ""] <- NA_character_
  x
}

criar_grupo_demografico <- function(sexo_recorte) {

  sexo_recorte <- as.character(sexo_recorte)

  out <- sexo_recorte
  out[is.na(out) | out == ""] <- "Todos"

  out
}



# ------------------------------------------------------------
# 4.1. Barra de progresso
# ------------------------------------------------------------

criar_barra_progresso <- function(total, titulo = "Processando") {

  progress::progress_bar$new(
    format = paste0(
      titulo,
      " [:bar] ",
      ":current/:total ",
      "(:percent) | ",
      "ETA: :eta | ",
      "decorrido: :elapsed | ",
      ":msg"
    ),
    total = total,
    clear = FALSE,
    width = 110,
    show_after = 0
  )
}

tick_barra <- function(pb, msg = "") {

  msg <- as.character(msg)
  msg <- substr(msg, 1L, 70L)

  pb$tick(
    tokens = list(
      msg = msg
    )
  )

  flush.console()
}

formatar_tamanho_objeto <- function(x) {
  format(utils::object.size(x), units = "auto")
}

coletar_lixo <- function(verbose = mostrar_gc_verbose, detalhe = NULL) {

  invisible(gc(verbose = verbose, full = TRUE))

  if (isTRUE(limpeza_memoria_agressiva)) {
    invisible(gc(verbose = FALSE, full = TRUE))
  }

  if (!is.null(detalhe) && nzchar(as.character(detalhe))) {
    cat("\nMemória limpa:", detalhe, "\n")
    flush.console()
  }

  invisible(TRUE)
}

mostrar_tamanho <- function(nome_objeto, env = parent.frame()) {

  if (exists(nome_objeto, envir = env, inherits = TRUE)) {
    obj <- get(nome_objeto, envir = env, inherits = TRUE)

    cat(
      "\nTamanho em memória de",
      nome_objeto,
      ":",
      formatar_tamanho_objeto(obj),
      "\n"
    )

    flush.console()
  }

  invisible(TRUE)
}

remover_objetos <- function(..., env = parent.frame(), detalhe = NULL) {

  objetos <- c(...)

  objetos <- objetos[
    vapply(
      objetos,
      exists,
      logical(1),
      envir = env,
      inherits = FALSE
    )
  ]

  if (length(objetos) > 0L) {
    rm(list = objetos, envir = env)
  }

  coletar_lixo(detalhe = detalhe)

  invisible(TRUE)
}


# ------------------------------------------------------------
# 4.2. Barra geral das etapas principais
# ------------------------------------------------------------

total_etapas_principais <- 12L

pb_geral <- criar_barra_progresso(
  total = total_etapas_principais,
  titulo = "Etapas principais"
)

inicio_processamento <- Sys.time()


# ------------------------------------------------------------
# 5. Conferir Parquets de entrada
# ------------------------------------------------------------

arquivos_parquet <- list.files(
  dir_entrada,
  pattern = "\\.parquet$",
  recursive = TRUE,
  full.names = TRUE
)

if (length(arquivos_parquet) == 0L) {
  stop(
    "Nenhum arquivo parquet encontrado em: ",
    dir_entrada,
    "\nVerifique se o processamento anterior foi concluído."
  )
}

cat("\nParquets de entrada:\n")
cat(dir_entrada, "\n")
cat("\nNúmero de arquivos encontrados: ", length(arquivos_parquet), "\n")

tick_barra(
  pb = pb_geral,
  msg = paste0("Parquets localizados: ", length(arquivos_parquet))
)


# ------------------------------------------------------------
# 6. Abrir Dataset Arrow e coletar colunas necessárias
# ------------------------------------------------------------

ds <- arrow::open_dataset(
  sources = dir_entrada,
  partitioning = arrow::hive_partition()
)

# Diagnóstico das colunas disponíveis com termos ligados à escolaridade.
# Isso ajuda a verificar se há outra coluna de grau de instrução no parquet.
colunas_ds <- names(ds)
colunas_escolaridade_ds <- colunas_ds[
  grepl("grau|instruc|instruç|escolar|educ", colunas_ds, ignore.case = TRUE)
]

if (length(colunas_escolaridade_ds) > 0L) {
  data.table::fwrite(
    data.table::data.table(coluna = colunas_escolaridade_ds),
    arquivo_diagnostico_colunas_escolaridade_csv
  )

  cat("\nColunas candidatas de escolaridade no dataset:\n")
  print(colunas_escolaridade_ds)
  cat("\nDiagnóstico das colunas de escolaridade salvo em:\n")
  cat(arquivo_diagnostico_colunas_escolaridade_csv, "\n")
}

cols_necessarias <- c(
  "ano",
  "sigla_uf",
  "sigla_uf_nome",
  "regime_vinculo",
  "situacao_3112",
  "valor_remuneracao_media",
  "grau_instrucao_apos_2005",
  "sexo"
)

base_arrow <- ds |>
  dplyr::select(dplyr::any_of(cols_necessarias))

if (usar_apenas_ativos_3112) {
  base_arrow <- base_arrow |>
    dplyr::filter(situacao_3112 == "ativo_3112")
}

if (usar_apenas_remuneracao_positiva) {
  base_arrow <- base_arrow |>
    dplyr::filter(valor_remuneracao_media > 0)
}

if (is.finite(limite_superior_remuneracao)) {
  base_arrow <- base_arrow |>
    dplyr::filter(valor_remuneracao_media <= limite_superior_remuneracao)
}

cat("\nColetando colunas necessárias dos Parquets locais...\n")
cat("Esta etapa é monolítica no Arrow; a barra avança ao final da coleta.\n")

inicio_collect <- Sys.time()

DT <- base_arrow |>
  dplyr::collect() |>
  data.table::as.data.table()

tempo_collect <- difftime(
  Sys.time(),
  inicio_collect,
  units = "mins"
)

cat(
  "\nColeta concluída em",
  round(as.numeric(tempo_collect), 2),
  "minutos.\n"
)

cat(
  "Linhas coletadas:",
  format(nrow(DT), big.mark = "."),
  "\n"
)

mostrar_tamanho("DT")

rm(base_arrow, ds)
coletar_lixo(detalhe = "após collect() e remoção de base_arrow/ds")

tick_barra(
  pb = pb_geral,
  msg = paste0("Base coletada: ", format(nrow(DT), big.mark = "."), " linhas")
)


# ------------------------------------------------------------
# 7. Normalização básica
# ------------------------------------------------------------
# Ajuste de memória:
#   - evita criar sexo_l, sexo_l e grau_l na base de 53 milhões de linhas;
#   - normaliza apenas o indispensável;
#   - remove colunas brutas que não serão mais usadas;
#   - cria classificações por meio de tabelas pequenas de dicionário.
# ------------------------------------------------------------

cat("\nNormalizando variáveis básicas...\n")

DT[, ano := as.integer(ano)]

# Normaliza somente as colunas necessárias para filtro e identificação.
DT[
  ,
  `:=`(
    sigla_uf = toupper(normalizar_texto(sigla_uf)),
    sigla_uf_nome = normalizar_texto(sigla_uf_nome),
    regime_vinculo = normalizar_texto(regime_vinculo),
    valor_remuneracao_media = as.numeric(valor_remuneracao_media),
    grau_instrucao_original = normalizar_texto(grau_instrucao_apos_2005),
    sexo_original = normalizar_texto(sexo)
  )
]

# Filtro final de segurança.
DT <- DT[
  ano == ano_base &
    regime_vinculo %in% regimes_mantidos &
    !is.na(valor_remuneracao_media)
]

DT[is.na(sigla_uf), sigla_uf := "UF_AUSENTE"]
DT[is.na(sigla_uf_nome), sigla_uf_nome := "UF ausente"]
DT[is.na(grau_instrucao_original), grau_instrucao_original := "Escolaridade não informada"]
DT[is.na(sexo_original), sexo_original := "Sexo não informado"]

# Remove colunas brutas já transformadas.
# Isso reduz o tamanho de DT antes das próximas classificações.
cols_brutas_remover <- intersect(
  c(
    "grau_instrucao_apos_2005",
    "sexo",
    "situacao_3112"
  ),
  names(DT)
)

if (length(cols_brutas_remover) > 0L) {
  DT[, (cols_brutas_remover) := NULL]
}

cat(
  "Linhas após filtros principais:",
  format(nrow(DT), big.mark = "."),
  "\n"
)

mostrar_tamanho("DT")
coletar_lixo(detalhe = "após normalização básica")

tick_barra(
  pb = pb_geral,
  msg = "Normalização básica concluída"
)


# ------------------------------------------------------------
# 8. Região a partir da UF
# ------------------------------------------------------------

cat("\nCriando variável de região...\n")

DT[
  ,
  regiao := data.table::fcase(
    sigla_uf %in% c("RO", "AC", "AM", "RR", "PA", "AP", "TO"),
    "Norte",

    sigla_uf %in% c("MA", "PI", "CE", "RN", "PB", "PE", "AL", "SE", "BA"),
    "Nordeste",

    sigla_uf %in% c("MG", "ES", "RJ", "SP"),
    "Sudeste",

    sigla_uf %in% c("PR", "SC", "RS"),
    "Sul",

    sigla_uf %in% c("MS", "MT", "GO", "DF"),
    "Centro-Oeste",

    default = "UF ausente"
  )
]

coletar_lixo(detalhe = "após criar região")


# ------------------------------------------------------------
# 9. Recortes de sexo com dicionário pequeno
# ------------------------------------------------------------
# Ajuste de memória:
#   Em vez de criar sexo_l para 53 milhões de linhas,
#   cria-se uma tabela com valores únicos e depois faz-se join.
# ------------------------------------------------------------

cat("\nCriando recortes de sexo com mapeamento econômico...\n")

# ------------------------------
# Sexo
# ------------------------------

map_sexo <- unique(DT[, .(sexo_original)])
map_sexo[, sexo_l_tmp := tolower(sexo_original)]

map_sexo[
  ,
  sexo_grupo_ordem := data.table::fcase(
    grepl("femin", sexo_l_tmp) | sexo_l_tmp %in% c("2", "02"),
    1L,

    grepl("mascul", sexo_l_tmp) | sexo_l_tmp %in% c("1", "01"),
    2L,

    default = 9L
  )
]

map_sexo[, sexo_l_tmp := NULL]

DT[
  map_sexo,
  sexo_grupo_ordem := i.sexo_grupo_ordem,
  on = "sexo_original"
]

DT[is.na(sexo_grupo_ordem), sexo_grupo_ordem := 9L]

DT[
  ,
  sexo_grupo := factor(
    sexo_grupo_ordem,
    levels = c(1L, 2L, 9L),
    labels = c("Mulheres", "Homens", "Sexo não informado")
  )
]

DT[, sexo_grupo_ordem := NULL]

remover_objetos(
  "map_sexo",
  detalhe = "após criar sexo_grupo sem sexo_l na base completa"
)

tick_barra(
  pb = pb_geral,
  msg = "Recortes geográficos e demográficos criados"
)


# ------------------------------------------------------------
# 10. Recortes de escolaridade com dicionário pequeno
# ------------------------------------------------------------
# Ajuste de memória:
#   Em vez de criar grau_l para 53 milhões de linhas,
#   cria-se map_grau com os valores únicos de escolaridade.
#   Depois as classificações são trazidas por join.
# ------------------------------------------------------------

cat("\nCriando recortes de escolaridade com mapeamento econômico...\n")

map_grau <- DT[, .N, by = .(grau_instrucao_original)]
data.table::setorder(map_grau, grau_instrucao_original)

# Normalização robusta:
#   - aceita códigos da RAIS/Base dos Dados: "01"..."11", "1"..."11";
#   - aceita códigos prefixados em labels: "06 - Ensino Médio incompleto";
#   - aceita descrições textuais com ou sem acento;
#   - aceita separadores como underscore, hífen, ponto e barra;
#   - grava um diagnóstico do dicionário de escolaridade antes do join.
#
# Dicionário RAIS após 2005:
#   1  = Analfabeto
#   2  = Até o 5º ano incompleto do Ensino Fundamental
#   3  = 5º ano completo do Ensino Fundamental
#   4  = 6º ao 9º ano do Ensino Fundamental incompleto
#   5  = Ensino Fundamental completo
#   6  = Ensino Médio incompleto
#   7  = Ensino Médio completo
#   8  = Educação Superior incompleta
#   9  = Educação Superior completa
#   10 = Mestrado
#   11 = Doutorado
map_grau[
  ,
  grau_l_tmp := iconv(
    tolower(grau_instrucao_original),
    from = "",
    to = "ASCII//TRANSLIT"
  )
]

map_grau[, grau_l_tmp := trimws(grau_l_tmp)]

# Chave textual ainda mais robusta para regex:
# transforma "ensino_superior_completo", "Superior-Completo",
# "Educação Superior Completa" etc. em uma forma comparável.
map_grau[, grau_key_tmp := gsub("[^a-z0-9]+", " ", grau_l_tmp)]
map_grau[, grau_key_tmp := trimws(gsub("\\s+", " ", grau_key_tmp))]

# Código numérico, quando a escolaridade começa por código RAIS explícito.
#
# Cuidado: os rótulos abreviados da RAIS também podem começar com número,
# como "5.A CO FUND" e "6. A 9. FUND". Esses NÃO são códigos 5 e 6 do
# dicionário; são descrições textuais de série/ano. Por isso, só extraímos
# código quando o valor é exatamente "9"/"09" ou quando o número aparece
# como prefixo seguido de separador claro, como "09 - Superior completo".
map_grau[, grau_codigo_tmp := NA_integer_]

map_grau[
  grepl("^\\s*0*([1-9]|10|11)\\s*$", grau_l_tmp),
  grau_codigo_tmp := suppressWarnings(as.integer(sub("^0+", "", grau_l_tmp)))
]

map_grau[
  grepl("^\\s*0*([1-9]|10|11)\\s*[-_:;]", grau_l_tmp),
  grau_codigo_tmp := suppressWarnings(
    as.integer(
      sub(
        "^0+",
        "",
        sub("^\\s*0*([1-9]|10|11)\\s*[-_:;].*$", "\\1", grau_l_tmp)
      )
    )
  )
]

# Segurança: só códigos válidos do dicionário RAIS pós-2005.
map_grau[!grau_codigo_tmp %in% 1:11, grau_codigo_tmp := NA_integer_]

map_grau[
  ,
  escolaridade_detalhada_ordem := data.table::fcase(
    grau_codigo_tmp %in% 1L,
    1L,

    grau_codigo_tmp %in% 2L,
    2L,

    grau_codigo_tmp %in% 3L,
    3L,

    grau_codigo_tmp %in% 4L,
    4L,

    grau_codigo_tmp %in% 5L,
    5L,

    grau_codigo_tmp %in% 6L,
    6L,

    grau_codigo_tmp %in% 7L,
    7L,

    grau_codigo_tmp %in% 8L,
    8L,

    grau_codigo_tmp %in% 9L,
    9L,

    grau_codigo_tmp %in% 10L,
    10L,

    grau_codigo_tmp %in% 11L,
    11L,

    grepl("analf", grau_key_tmp),
    1L,

    # Abreviação usual nos arquivos: ATE 5.A INC.
    grepl("ate\\s*5\\s*a\\s*inc|ate\\s*o?\\s*5|ate\\s*a?\\s*5|5.*ano.*incomp|5.*serie.*incomp|4.*serie", grau_key_tmp),
    2L,

    # Abreviação usual: 5.A CO FUND.
    grepl("5\\s*a\\s*co\\s*fund|5.*ano.*comp|5.*serie.*comp", grau_key_tmp),
    3L,

    # Abreviação usual: 6. A 9. FUND.
    grepl("6\\s*a\\s*9\\s*fund|6\\s*ao\\s*9\\s*fund|6.*9|fundamental.*incomp|fund\\s*incomp|1o grau.*incomp|1 grau.*incomp", grau_key_tmp),
    4L,

    # Abreviação usual: FUND COMPL.
    grepl("fund\\s*compl|fundamental.*comp|1o grau.*comp|1 grau.*comp", grau_key_tmp),
    5L,

    # Importante: incompleto vem antes de completo, porque "incompleto"
    # contém "completo" como substring.
    grepl("medio.*incomp|med\\s*incomp|2o grau.*incomp|2 grau.*incomp", grau_key_tmp),
    6L,

    grepl("medio.*comp|med\\s*compl|2o grau.*comp|2 grau.*comp", grau_key_tmp),
    7L,

    # Abreviações usuais: SUP. INCOMP e SUP. COMP.
    grepl("sup\\s*incomp|superior.*incomp|graduacao.*incomp|educacao superior.*incomp|ensino superior.*incomp", grau_key_tmp),
    8L,

    grepl("sup\\s*comp|superior.*comp|graduacao.*comp|educacao superior.*comp|ensino superior.*comp", grau_key_tmp),
    9L,

    grepl("mestr", grau_key_tmp),
    10L,

    grepl("dout", grau_key_tmp),
    11L,

    grepl("nao|ign|inform|ausente", grau_key_tmp),
    99L,

    default = 99L
  )
]


# Agregações derivadas da classificação detalhada.
# Na v12, estas duas colunas não estavam sendo recriadas antes do join,
# o que gerava o erro: Object 'escolaridade_etapa_ordem' not found.
map_grau[
  ,
  escolaridade_etapa_ordem := data.table::fcase(
    escolaridade_detalhada_ordem == 1L,
    1L,

    escolaridade_detalhada_ordem %in% c(2L, 3L, 4L),
    2L,

    escolaridade_detalhada_ordem == 5L,
    3L,

    escolaridade_detalhada_ordem == 6L,
    4L,

    escolaridade_detalhada_ordem == 7L,
    5L,

    escolaridade_detalhada_ordem == 8L,
    6L,

    escolaridade_detalhada_ordem == 9L,
    7L,

    escolaridade_detalhada_ordem %in% c(10L, 11L),
    8L,

    default = 99L
  )
]

map_grau[
  ,
  escolaridade_macro_ordem := data.table::fcase(
    escolaridade_detalhada_ordem %in% c(1L, 2L, 3L, 4L, 5L),
    1L,

    escolaridade_detalhada_ordem %in% c(6L, 7L),
    2L,

    escolaridade_detalhada_ordem %in% c(8L, 9L),
    3L,

    escolaridade_detalhada_ordem %in% c(10L, 11L),
    4L,

    default = 99L
  )
]

# Diagnóstico do mapa de escolaridade antes do join.
# Se Ensino Superior completo continuar ausente, este CSV mostra exatamente
# quais valores brutos chegaram em grau_instrucao_apos_2005 e como foram classificados.
map_grau_diagnostico <- data.table::copy(map_grau)
map_grau_diagnostico[
  ,
  escolaridade_detalhada_label := factor(
    escolaridade_detalhada_ordem,
    levels = c(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 99L),
    labels = c(
      "Analfabeto",
      "Fundamental incompleto - até 5ª série",
      "Fundamental incompleto - 5ª série completa",
      "Fundamental incompleto - 6ª a 9ª série",
      "Fundamental completo",
      "Ensino Médio incompleto",
      "Ensino Médio completo",
      "Ensino Superior incompleto",
      "Ensino Superior completo",
      "Mestrado",
      "Doutorado",
      "Escolaridade não informada"
    )
  )
]

data.table::fwrite(
  map_grau_diagnostico,
  arquivo_diagnostico_mapa_escolaridade_csv
)

# Diagnóstico concentrado dos valores que foram para não informada/não classificada.
# Ordene por n_vinculos e veja quais rótulos brutos precisam entrar no dicionário.
diagnostico_nao_classificada <- map_grau_diagnostico[
  escolaridade_detalhada_ordem == 99L,
  .(
    grau_instrucao_original,
    grau_l_tmp,
    grau_key_tmp,
    grau_codigo_tmp,
    n_vinculos = N
  )
][order(-n_vinculos)]

data.table::fwrite(
  diagnostico_nao_classificada,
  arquivo_diagnostico_escolaridade_nao_classificada_csv
)

cat("\nDiagnóstico do mapa de escolaridade salvo em:\n")
cat(arquivo_diagnostico_mapa_escolaridade_csv, "\n")
cat("\nDiagnóstico dos valores não classificados salvo em:\n")
cat(arquivo_diagnostico_escolaridade_nao_classificada_csv, "\n")

cat("\nClassificação dos valores únicos de escolaridade:\n")
print(
  map_grau_diagnostico[
    ,
    .(n_vinculos = sum(N)),
    by = .(escolaridade_detalhada_label, escolaridade_detalhada_ordem)
  ][order(escolaridade_detalhada_ordem)]
)

if (map_grau_diagnostico[escolaridade_detalhada_ordem == 9L, sum(N)] == 0L) {
  warning(
    "Nenhum vínculo foi classificado como Ensino Superior completo. ",
    "Confira diagnostico_mapa_escolaridade_rais_2025.csv para ver os valores brutos."
  )
}

rm(map_grau_diagnostico)

map_grau[, c("grau_l_tmp", "grau_key_tmp", "grau_codigo_tmp") := NULL]

DT[
  map_grau[
    ,
    .(
      grau_instrucao_original,
      escolaridade_detalhada_ordem,
      escolaridade_etapa_ordem,
      escolaridade_macro_ordem
    )
  ],
  `:=`(
    escolaridade_detalhada_ordem = i.escolaridade_detalhada_ordem,
    escolaridade_etapa_ordem = i.escolaridade_etapa_ordem,
    escolaridade_macro_ordem = i.escolaridade_macro_ordem
  ),
  on = "grau_instrucao_original"
]

DT[is.na(escolaridade_detalhada_ordem), escolaridade_detalhada_ordem := 99L]
DT[is.na(escolaridade_etapa_ordem), escolaridade_etapa_ordem := 99L]
DT[is.na(escolaridade_macro_ordem), escolaridade_macro_ordem := 99L]

DT[
  ,
  escolaridade_detalhada := factor(
    escolaridade_detalhada_ordem,
    levels = c(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 9L, 10L, 11L, 99L),
    labels = c(
      "Analfabeto",
      "Fundamental incompleto - até 5ª série",
      "Fundamental incompleto - 5ª série completa",
      "Fundamental incompleto - 6ª a 9ª série",
      "Fundamental completo",
      "Ensino Médio incompleto",
      "Ensino Médio completo",
      "Ensino Superior incompleto",
      "Ensino Superior completo",
      "Mestrado",
      "Doutorado",
      "Escolaridade não informada"
    )
  )
]

DT[
  ,
  escolaridade_etapa := factor(
    escolaridade_etapa_ordem,
    levels = c(1L, 2L, 3L, 4L, 5L, 6L, 7L, 8L, 99L),
    labels = c(
      "Analfabeto",
      "Fundamental incompleto",
      "Fundamental completo",
      "Ensino Médio incompleto",
      "Ensino Médio completo",
      "Ensino Superior incompleto",
      "Ensino Superior completo",
      "Pós-graduação",
      "Escolaridade não informada"
    )
  )
]

DT[
  ,
  escolaridade_macro := factor(
    escolaridade_macro_ordem,
    levels = c(1L, 2L, 3L, 4L, 99L),
    labels = c(
      "Até fundamental completo",
      "Ensino Médio",
      "Ensino superior",
      "Pós-graduação",
      "Escolaridade não informada"
    )
  )
]

# Remove colunas originais usadas apenas para construir os mapeamentos.
cols_originais_remover <- intersect(
  c(
    "sexo_original",
    "grau_instrucao_original"
  ),
  names(DT)
)

if (length(cols_originais_remover) > 0L) {
  DT[, (cols_originais_remover) := NULL]
}

remover_objetos(
  "map_grau",
  detalhe = "após criar recortes de escolaridade sem grau_l na base completa"
)

mostrar_tamanho("DT")
coletar_lixo(detalhe = "após recortes de escolaridade")

tick_barra(
  pb = pb_geral,
  msg = "Recortes de escolaridade criados"
)

cat("\nChecagem da classificação de Ensino Médio:\n")
print(
  DT[
    escolaridade_macro == "Ensino Médio",
    .N,
    by = .(
      escolaridade_detalhada,
      escolaridade_etapa,
      escolaridade_macro
    )
  ][order(escolaridade_detalhada, escolaridade_etapa)]
)


cat("\nChecagem geral da escolaridade classificada no DT:\n")

diagnostico_escolaridade_final <- DT[
  ,
  .N,
  by = .(
    regime_vinculo,
    escolaridade_detalhada_ordem,
    escolaridade_detalhada,
    escolaridade_macro_ordem,
    escolaridade_macro
  )
][order(regime_vinculo, escolaridade_detalhada_ordem)]

print(diagnostico_escolaridade_final)

data.table::fwrite(
  diagnostico_escolaridade_final,
  arquivo_diagnostico_escolaridade_final_csv
)

cat("\nDiagnóstico final de escolaridade salvo em:\n")
cat(arquivo_diagnostico_escolaridade_final_csv, "\n")

if (diagnostico_escolaridade_final[escolaridade_detalhada_ordem == 9L, sum(N)] == 0L) {
  warning(
    "Após o join, nenhum vínculo ficou em Ensino Superior completo. ",
    "O problema está no valor bruto de grau_instrucao_apos_2005 ou em sua classificação."
  )
}

rm(diagnostico_escolaridade_final)
coletar_lixo(detalhe = "após diagnóstico final de escolaridade")

# ------------------------------------------------------------
# 11. Checagens rápidas
# ------------------------------------------------------------

cat("\nChecagem por regime:\n")

print(
  DT[
    ,
    .(
      n_vinculos = .N,
      media = mean(valor_remuneracao_media, na.rm = TRUE),
      mediana = median(valor_remuneracao_media, na.rm = TRUE),
      p90 = as.numeric(quantile(valor_remuneracao_media, 0.90, na.rm = TRUE)),
      p99 = as.numeric(quantile(valor_remuneracao_media, 0.99, na.rm = TRUE))
    ),
    by = .(ano, regime_vinculo)
  ][order(ano, regime_vinculo)]
)

tick_barra(
  pb = pb_geral,
  msg = "Checagens iniciais concluídas"
)


# ------------------------------------------------------------
# 12. Definir recortes
# ------------------------------------------------------------

geo_specs <- list(
  list(
    tipo = "Brasil",
    ordem = 1L,
    cols = character(0)
  ),
  list(
    tipo = "Região",
    ordem = 2L,
    cols = c("regiao")
  ),
  list(
    tipo = "UF",
    ordem = 3L,
    cols = c("regiao", "sigla_uf", "sigla_uf_nome")
  )
)

demo_specs <- list(
  list(
    tipo = "geral",
    ordem = 1L,
    cols = character(0)
  ),
  list(
    tipo = "sexo",
    ordem = 2L,
    cols = c("sexo_grupo")
  )
)

escolaridade_specs <- list(
  list(
    tipo = "geral",
    ordem = 1L,
    cols = character(0),
    ordem_col = NULL,
    label_col = NULL
  ),
  list(
    tipo = "escolaridade_macro",
    ordem = 2L,
    cols = c("escolaridade_macro_ordem", "escolaridade_macro"),
    ordem_col = "escolaridade_macro_ordem",
    label_col = "escolaridade_macro"
  ),
  list(
    tipo = "escolaridade_detalhada",
    ordem = 3L,
    cols = c("escolaridade_detalhada_ordem", "escolaridade_detalhada"),
    ordem_col = "escolaridade_detalhada_ordem",
    label_col = "escolaridade_detalhada"
  )
)



# ------------------------------------------------------------
# 13. Função para calcular percentis por recorte
# ------------------------------------------------------------

calcular_percentis_recorte <- function(DT, geo, demo, esc) {

  group_cols <- c(
    "ano",
    "regime_vinculo",
    geo$cols,
    demo$cols,
    esc$cols
  )

  group_cols <- unique(group_cols)

  res <- DT[
    ,
    {
      x <- valor_remuneracao_media
      x <- x[!is.na(x)]

      q_linha <- as.numeric(
        stats::quantile(
          x,
          probs = probabilidades,
          na.rm = TRUE,
          names = FALSE,
          type = 7
        )
      )

      q_resumo <- as.numeric(
        stats::quantile(
          x,
          probs = c(0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99),
          na.rm = TRUE,
          names = FALSE,
          type = 7
        )
      )

      .(
        percentil = tabela_percentis$percentil,
        probabilidade_quantil = tabela_percentis$probabilidade_quantil,
        remuneracao_percentil = q_linha,

        n_vinculos_grupo = .N,
        remuneracao_media = mean(x, na.rm = TRUE),
        remuneracao_mediana = q_resumo[5],

        p01 = q_resumo[1],
        p05 = q_resumo[2],
        p10 = q_resumo[3],
        p25 = q_resumo[4],
        p75 = q_resumo[6],
        p90 = q_resumo[7],
        p95 = q_resumo[8],
        p99 = q_resumo[9]
      )
    },
    by = group_cols
  ]

  res <- res[n_vinculos_grupo >= min_n_grupo]

  # ------------------------------
  # Geografia
  # ------------------------------

  res[, nivel_geografico := geo$tipo]
  res[, ordem_geografica := geo$ordem]

  if (geo$tipo == "Brasil") {
    res[, regiao := "Brasil"]
    res[, sigla_uf := "BR"]
    res[, sigla_uf_nome := "Brasil"]
    res[, recorte_geografico := "Brasil"]
  }

  if (geo$tipo == "Região") {
    res[, sigla_uf := "REGIAO"]
    res[, sigla_uf_nome := regiao]
    res[, recorte_geografico := regiao]
  }

  if (geo$tipo == "UF") {
    res[, recorte_geografico := sigla_uf_nome]
  }

  # ------------------------------
  # Demografia
  # ------------------------------

  res[, tipo_recorte_demografico := demo$tipo]
  res[, ordem_recorte_demografico := demo$ordem]

  if (!"sexo_grupo" %in% names(res)) {
    res[, sexo_grupo := "Todos"]
  }

  data.table::setnames(res, "sexo_grupo", "sexo_recorte")

  res[
    ,
    grupo_demografico := criar_grupo_demografico(
      sexo_recorte = sexo_recorte
    )
  ]

  # ------------------------------
  # Escolaridade
  # ------------------------------

  res[, tipo_recorte_escolaridade := esc$tipo]
  res[, ordem_recorte_escolaridade := esc$ordem]

  if (esc$tipo == "geral") {
    res[, escolaridade_recorte_ordem := 0L]
    res[, escolaridade_recorte := "Todas as escolaridades"]
  } else {
    data.table::setnames(res, esc$ordem_col, "escolaridade_recorte_ordem")
    data.table::setnames(res, esc$label_col, "escolaridade_recorte")
  }

  res[, escolaridade_ordem := escolaridade_recorte_ordem]
  res[, escolaridade_grupo := escolaridade_recorte]


  res[
    ,
    grupo_demografico_escolaridade := paste(
      as.character(grupo_demografico),
      as.character(escolaridade_recorte),
      sep = " - "
    )
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_demografico_escolaridade := "Todos"
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte != "Todas as escolaridades",
    grupo_demografico_escolaridade := as.character(escolaridade_recorte)
  ]

  res[
    grupo_demografico != "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_demografico_escolaridade := as.character(grupo_demografico)
  ]

  # ------------------------------
  # Regime
  # ------------------------------

  res[, regime_label := as.character(regime_vinculo)]

  res[regime_vinculo == "celetista", regime_label := "Celetistas"]
  res[regime_vinculo == "estatutario", regime_label := "Estatutários"]

  res[
    ,
    ordem_regime := data.table::fcase(
      regime_vinculo == "celetista",
      1L,

      regime_vinculo == "estatutario",
      2L,

      default = 9L
    )
  ]

  # ------------------------------
  # Labels finais para gráfico
  # ------------------------------

  res[
    ,
    grupo_grafico := paste(
      as.character(grupo_demografico),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    grupo_demografico == "Todos",
    grupo_grafico := as.character(regime_label)
  ]

  res[
    ,
    grupo_grafico_completo := paste(
      as.character(grupo_demografico),
      as.character(escolaridade_recorte),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_grafico_completo := as.character(regime_label)
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte != "Todas as escolaridades",
    grupo_grafico_completo := paste(
      as.character(escolaridade_recorte),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    grupo_demografico != "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_grafico_completo := paste(
      as.character(grupo_demografico),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    ,
    id_recorte := paste(
      nivel_geografico,
      recorte_geografico,
      tipo_recorte_demografico,
      sexo_recorte,
      regime_vinculo,
      sep = " | "
    )
  ]

  res[
    ,
    id_recorte_completo := paste(
      nivel_geografico,
      recorte_geografico,
      tipo_recorte_demografico,
      sexo_recorte,
      tipo_recorte_escolaridade,
      escolaridade_recorte,
      regime_vinculo,
      sep = " | "
    )
  ]

  cols_finais <- c(
    "ano",

    "nivel_geografico",
    "ordem_geografica",
    "regiao",
    "sigla_uf",
    "sigla_uf_nome",
    "recorte_geografico",

    "tipo_recorte_demografico",
    "ordem_recorte_demografico",
    "sexo_recorte",
    "grupo_demografico",

    "tipo_recorte_escolaridade",
    "ordem_recorte_escolaridade",
    "escolaridade_recorte_ordem",
    "escolaridade_recorte",
    "escolaridade_ordem",
    "escolaridade_grupo",
    "grupo_demografico_escolaridade",

    "regime_vinculo",
    "regime_label",
    "ordem_regime",

    "grupo_grafico",
    "grupo_grafico_completo",

    "id_recorte",
    "id_recorte_completo",

    "percentil",
    "probabilidade_quantil",
    "remuneracao_percentil",

    "n_vinculos_grupo",
    "remuneracao_media",
    "remuneracao_mediana",
    "p01",
    "p05",
    "p10",
    "p25",
    "p75",
    "p90",
    "p95",
    "p99"
  )

  res <- res[, ..cols_finais]

  res[]
}


# ------------------------------------------------------------
# 13.1. Função para calcular KDE por recorte
# ------------------------------------------------------------

calcular_kde_recorte <- function(DT, geo, demo, esc) {

  group_cols <- c(
    "ano",
    "regime_vinculo",
    geo$cols,
    demo$cols,
    esc$cols
  )

  group_cols <- unique(group_cols)

  res <- DT[
    ,
    {
      x <- valor_remuneracao_media
      x <- x[is.finite(x) & !is.na(x)]

      n_total <- length(x)
      n_unicos <- data.table::uniqueN(x)

      if (n_total < min_n_kde || n_unicos < 2L) {

        data.table::data.table(
          ponto_kde = integer(0),
          remuneracao_kde = numeric(0),
          densidade_kde = numeric(0),
          n_vinculos_grupo = integer(0),
          n_vinculos_kde = integer(0),
          kde_limite_superior = numeric(0),
          kde_bw = numeric(0),
          kde_probabilidade_limite = numeric(0)
        )

      } else {

        limite_kde <- as.numeric(
          stats::quantile(
            x,
            probs = probabilidade_limite_superior_kde,
            na.rm = TRUE,
            names = FALSE,
            type = 7
          )
        )

        if (!is.finite(limite_kde) || limite_kde <= 0) {
          limite_kde <- max(x, na.rm = TRUE)
        }

        x_kde <- x[x >= 0 & x <= limite_kde]

        if (length(x_kde) < min_n_kde || data.table::uniqueN(x_kde) < 2L) {

          data.table::data.table(
            ponto_kde = integer(0),
            remuneracao_kde = numeric(0),
            densidade_kde = numeric(0),
            n_vinculos_grupo = integer(0),
            n_vinculos_kde = integer(0),
            kde_limite_superior = numeric(0),
            kde_bw = numeric(0),
            kde_probabilidade_limite = numeric(0)
          )

        } else {

          dens <- try(
            stats::density(
              x = x_kde,
              n = n_pontos_kde,
              from = 0,
              to = limite_kde
            ),
            silent = TRUE
          )

          if (inherits(dens, "try-error")) {

            data.table::data.table(
              ponto_kde = integer(0),
              remuneracao_kde = numeric(0),
              densidade_kde = numeric(0),
              n_vinculos_grupo = integer(0),
              n_vinculos_kde = integer(0),
              kde_limite_superior = numeric(0),
              kde_bw = numeric(0),
              kde_probabilidade_limite = numeric(0)
            )

          } else {

            data.table::data.table(
              ponto_kde = seq_along(dens$x),
              remuneracao_kde = as.numeric(dens$x),
              densidade_kde = as.numeric(dens$y),
              n_vinculos_grupo = as.integer(n_total),
              n_vinculos_kde = as.integer(length(x_kde)),
              kde_limite_superior = as.numeric(limite_kde),
              kde_bw = as.numeric(dens$bw),
              kde_probabilidade_limite = as.numeric(probabilidade_limite_superior_kde)
            )
          }
        }
      }
    },
    by = group_cols
  ]

  res <- res[n_vinculos_grupo >= min_n_grupo]

  # ------------------------------
  # Geografia
  # ------------------------------

  res[, nivel_geografico := geo$tipo]
  res[, ordem_geografica := geo$ordem]

  if (geo$tipo == "Brasil") {
    res[, regiao := "Brasil"]
    res[, sigla_uf := "BR"]
    res[, sigla_uf_nome := "Brasil"]
    res[, recorte_geografico := "Brasil"]
  }

  if (geo$tipo == "Região") {
    res[, sigla_uf := "REGIAO"]
    res[, sigla_uf_nome := regiao]
    res[, recorte_geografico := regiao]
  }

  if (geo$tipo == "UF") {
    res[, recorte_geografico := sigla_uf_nome]
  }

  # ------------------------------
  # Demografia
  # ------------------------------

  res[, tipo_recorte_demografico := demo$tipo]
  res[, ordem_recorte_demografico := demo$ordem]

  if (!"sexo_grupo" %in% names(res)) {
    res[, sexo_grupo := "Todos"]
  }

  data.table::setnames(res, "sexo_grupo", "sexo_recorte")

  res[
    ,
    grupo_demografico := criar_grupo_demografico(
      sexo_recorte = sexo_recorte
    )
  ]

  # ------------------------------
  # Escolaridade
  # ------------------------------

  res[, tipo_recorte_escolaridade := esc$tipo]
  res[, ordem_recorte_escolaridade := esc$ordem]

  if (esc$tipo == "geral") {
    res[, escolaridade_recorte_ordem := 0L]
    res[, escolaridade_recorte := "Todas as escolaridades"]
  } else {
    data.table::setnames(res, esc$ordem_col, "escolaridade_recorte_ordem")
    data.table::setnames(res, esc$label_col, "escolaridade_recorte")
  }

  res[, escolaridade_ordem := escolaridade_recorte_ordem]
  res[, escolaridade_grupo := escolaridade_recorte]


  res[
    ,
    grupo_demografico_escolaridade := paste(
      as.character(grupo_demografico),
      as.character(escolaridade_recorte),
      sep = " - "
    )
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_demografico_escolaridade := "Todos"
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte != "Todas as escolaridades",
    grupo_demografico_escolaridade := as.character(escolaridade_recorte)
  ]

  res[
    grupo_demografico != "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_demografico_escolaridade := as.character(grupo_demografico)
  ]

  # ------------------------------
  # Regime
  # ------------------------------

  res[, regime_label := as.character(regime_vinculo)]

  res[regime_vinculo == "celetista", regime_label := "Celetistas"]
  res[regime_vinculo == "estatutario", regime_label := "Estatutários"]

  res[
    ,
    ordem_regime := data.table::fcase(
      regime_vinculo == "celetista",
      1L,

      regime_vinculo == "estatutario",
      2L,

      default = 9L
    )
  ]

  # ------------------------------
  # Labels finais para gráfico
  # ------------------------------

  res[
    ,
    grupo_grafico := paste(
      as.character(grupo_demografico),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    grupo_demografico == "Todos",
    grupo_grafico := as.character(regime_label)
  ]

  res[
    ,
    grupo_grafico_completo := paste(
      as.character(grupo_demografico),
      as.character(escolaridade_recorte),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_grafico_completo := as.character(regime_label)
  ]

  res[
    grupo_demografico == "Todos" &
      escolaridade_recorte != "Todas as escolaridades",
    grupo_grafico_completo := paste(
      as.character(escolaridade_recorte),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    grupo_demografico != "Todos" &
      escolaridade_recorte == "Todas as escolaridades",
    grupo_grafico_completo := paste(
      as.character(grupo_demografico),
      as.character(regime_label),
      sep = " - "
    )
  ]

  res[
    ,
    id_recorte := paste(
      nivel_geografico,
      recorte_geografico,
      tipo_recorte_demografico,
      sexo_recorte,
      regime_vinculo,
      sep = " | "
    )
  ]

  res[
    ,
    id_recorte_completo := paste(
      nivel_geografico,
      recorte_geografico,
      tipo_recorte_demografico,
      sexo_recorte,
      tipo_recorte_escolaridade,
      escolaridade_recorte,
      regime_vinculo,
      sep = " | "
    )
  ]

  cols_finais <- c(
    "ano",

    "nivel_geografico",
    "ordem_geografica",
    "regiao",
    "sigla_uf",
    "sigla_uf_nome",
    "recorte_geografico",

    "tipo_recorte_demografico",
    "ordem_recorte_demografico",
    "sexo_recorte",
    "grupo_demografico",

    "tipo_recorte_escolaridade",
    "ordem_recorte_escolaridade",
    "escolaridade_recorte_ordem",
    "escolaridade_recorte",
    "escolaridade_ordem",
    "escolaridade_grupo",
    "grupo_demografico_escolaridade",

    "regime_vinculo",
    "regime_label",
    "ordem_regime",

    "grupo_grafico",
    "grupo_grafico_completo",

    "id_recorte",
    "id_recorte_completo",

    "ponto_kde",
    "remuneracao_kde",
    "densidade_kde",
    "n_vinculos_grupo",
    "n_vinculos_kde",
    "kde_limite_superior",
    "kde_bw",
    "kde_probabilidade_limite"
  )

  res <- res[, ..cols_finais]

  res[]
}


# ------------------------------------------------------------
# 14. Calcular todos os recortes
# ------------------------------------------------------------

total_recortes <- length(geo_specs) *
  length(demo_specs) *
  length(escolaridade_specs)

resultados <- vector("list", total_recortes)

if (isTRUE(gerar_base_kde)) {
  resultados_kde <- vector("list", total_recortes)
} else {
  resultados_kde <- NULL
}

k <- 1L

cat("\nTotal de recortes a calcular:", total_recortes, "\n")

pb_recortes <- criar_barra_progresso(
  total = total_recortes,
  titulo = "Calculando recortes"
)

inicio_recortes <- Sys.time()

for (geo in geo_specs) {
  for (demo in demo_specs) {
    for (esc in escolaridade_specs) {

      msg_atual <- paste(
        geo$tipo,
        demo$tipo,
        esc$tipo,
        sep = " | "
      )

      resultados[[k]] <- calcular_percentis_recorte(
        DT = DT,
        geo = geo,
        demo = demo,
        esc = esc
      )

      if (isTRUE(gerar_base_kde)) {
        resultados_kde[[k]] <- calcular_kde_recorte(
          DT = DT,
          geo = geo,
          demo = demo,
          esc = esc
        )
      }

      tick_barra(
        pb = pb_recortes,
        msg = msg_atual
      )

      k <- k + 1L

      if ((k %% gc_a_cada_n_recortes) == 0L) {
        coletar_lixo(
          detalhe = paste0(
            "após recorte ",
            k - 1L,
            " de ",
            total_recortes
          )
        )
      }
    }
  }
}

tempo_recortes <- difftime(
  Sys.time(),
  inicio_recortes,
  units = "mins"
)

cat(
  "\nCálculo dos recortes concluído em",
  round(as.numeric(tempo_recortes), 2),
  "minutos.\n"
)

cat("\nJuntando resultados dos recortes em uma única base...\n")

coletar_lixo(detalhe = "antes de juntar a lista de resultados")

base_percentis <- data.table::rbindlist(
  resultados,
  use.names = TRUE,
  fill = TRUE
)


if (isTRUE(gerar_base_kde)) {

  cat("\nJuntando resultados KDE em uma única base...\n")

  base_kde <- data.table::rbindlist(
    resultados_kde,
    use.names = TRUE,
    fill = TRUE
  )


} else {
  base_kde <- NULL
}

rm(resultados)

if (exists("resultados_kde", inherits = FALSE)) {
  rm(resultados_kde)
}

coletar_lixo(detalhe = "após criar bases agregadas e remover listas resultados")

mostrar_tamanho("base_percentis")

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {
  mostrar_tamanho("base_kde")
}

if (isTRUE(remover_DT_apos_base_percentis)) {
  rm(DT)
  coletar_lixo(detalhe = "após remover DT original")
}

# Converte fatores da base agregada para texto antes das exportações.
# Como base_percentis é muito menor que DT, essa conversão não gera pico relevante.
cols_texto_saida <- c(
  "nivel_geografico",
  "regiao",
  "sigla_uf",
  "sigla_uf_nome",
  "recorte_geografico",
  "tipo_recorte_demografico",
  "sexo_recorte",
  "grupo_demografico",
  "tipo_recorte_escolaridade",
  "escolaridade_recorte",
  "escolaridade_grupo",
  "grupo_demografico_escolaridade",
  "regime_vinculo",
  "regime_label",
  "grupo_grafico",
  "grupo_grafico_completo",
  "id_recorte",
  "id_recorte_completo"
)

cols_texto_saida <- intersect(cols_texto_saida, names(base_percentis))

for (col in cols_texto_saida) {
  if (is.factor(base_percentis[[col]])) {
    base_percentis[, (col) := as.character(get(col))]
  }
}

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {
  cols_texto_kde <- intersect(cols_texto_saida, names(base_kde))

  for (col in cols_texto_kde) {
    if (is.factor(base_kde[[col]])) {
      base_kde[, (col) := as.character(get(col))]
    }
  }
}

coletar_lixo(detalhe = "após converter fatores das bases agregadas para texto")

data.table::setorder(
  base_percentis,
  ordem_geografica,
  recorte_geografico,
  ordem_recorte_demografico,
  grupo_demografico,
  ordem_recorte_escolaridade,
  escolaridade_recorte_ordem,
  ordem_regime,
  percentil
)

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {
  data.table::setorder(
    base_kde,
    ordem_geografica,
    recorte_geografico,
    ordem_recorte_demografico,
    grupo_demografico,
    ordem_recorte_escolaridade,
    escolaridade_recorte_ordem,
    ordem_regime,
    ponto_kde
  )
}

coletar_lixo(detalhe = "após ordenar base_percentis e base_kde")

tick_barra(
  pb = pb_geral,
  msg = paste0("Recortes calculados: ", total_recortes)
)


# ------------------------------------------------------------
# 15. Checagem da base final
# ------------------------------------------------------------

cat("\nChecagem da base final:\n")

print(
  base_percentis[
    ,
    .(
      n_linhas = .N,
      n_recortes = uniqueN(id_recorte_completo),
      n_grupos_grafico = uniqueN(grupo_grafico_completo),
      n_percentis = uniqueN(percentil)
    )
  ]
)

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {
  cat("\nChecagem da base KDE:\n")

  print(
    base_kde[
      ,
      .(
        n_linhas = .N,
        n_recortes = uniqueN(id_recorte_completo),
        n_grupos_grafico = uniqueN(grupo_grafico_completo),
        n_pontos_kde = uniqueN(ponto_kde)
      )
    ]
  )
}


# ------------------------------------------------------------
# 16. Salvar Parquet particionado
# ------------------------------------------------------------

cat("\nSalvando Parquet particionado...\n")
cat("Esta etapa é monolítica no Arrow; a barra geral avança ao final.\n")

if (dir.exists(dir_parquet_saida)) {
  unlink(dir_parquet_saida, recursive = TRUE, force = TRUE)
}

inicio_parquet <- Sys.time()

arrow::write_dataset(
  dataset = base_percentis,
  path = dir_parquet_saida,
  format = "parquet",
  partitioning = c(
    "ano",
    "nivel_geografico",
    "tipo_recorte_demografico",
    "tipo_recorte_escolaridade"
  ),
  existing_data_behavior = "overwrite"
)

tempo_parquet <- difftime(
  Sys.time(),
  inicio_parquet,
  units = "mins"
)

cat("\nParquet particionado salvo em:\n")
cat(dir_parquet_saida, "\n")

cat(
  "Tempo para salvar Parquet de percentis:",
  round(as.numeric(tempo_parquet), 2),
  "minutos.\n"
)

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {

  cat("\nSalvando Parquet particionado da base KDE...\n")

  if (dir.exists(dir_parquet_kde_saida)) {
    unlink(dir_parquet_kde_saida, recursive = TRUE, force = TRUE)
  }

  inicio_parquet_kde <- Sys.time()

  arrow::write_dataset(
    dataset = base_kde,
    path = dir_parquet_kde_saida,
    format = "parquet",
    partitioning = c(
      "ano",
      "nivel_geografico",
      "tipo_recorte_demografico",
      "tipo_recorte_escolaridade"
    ),
    existing_data_behavior = "overwrite"
  )

  tempo_parquet_kde <- difftime(
    Sys.time(),
    inicio_parquet_kde,
    units = "mins"
  )

  cat("\nParquet KDE salvo em:\n")
  cat(dir_parquet_kde_saida, "\n")

  cat(
    "Tempo para salvar Parquet KDE:",
    round(as.numeric(tempo_parquet_kde), 2),
    "minutos.\n"
  )
}

coletar_lixo(detalhe = "após salvar Parquets particionados")

tick_barra(
  pb = pb_geral,
  msg = "Parquet particionado salvo"
)


# ------------------------------------------------------------
# 17. Salvar DTA único
# ------------------------------------------------------------

cat("\nSalvando DTA único...\n")
cat("Esta etapa é monolítica no haven; a barra geral avança ao final.\n")

inicio_dta_unico <- Sys.time()

haven::write_dta(
  data = base_percentis,
  path = arquivo_dta_unico,
  version = 14
)

tempo_dta_unico <- difftime(
  Sys.time(),
  inicio_dta_unico,
  units = "mins"
)

cat("\nDTA único salvo em:\n")
cat(arquivo_dta_unico, "\n")

cat(
  "Tempo para salvar DTA único de percentis:",
  round(as.numeric(tempo_dta_unico), 2),
  "minutos.\n"
)

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {

  cat("\nSalvando DTA único da base KDE...\n")

  inicio_dta_kde <- Sys.time()

  haven::write_dta(
    data = base_kde,
    path = arquivo_kde_dta_unico,
    version = 14
  )

  tempo_dta_kde <- difftime(
    Sys.time(),
    inicio_dta_kde,
    units = "mins"
  )

  cat("\nDTA KDE salvo em:\n")
  cat(arquivo_kde_dta_unico, "\n")

  cat(
    "Tempo para salvar DTA KDE:",
    round(as.numeric(tempo_dta_kde), 2),
    "minutos.\n"
  )
}

coletar_lixo(detalhe = "após salvar DTAs únicos")

tick_barra(
  pb = pb_geral,
  msg = "DTA único salvo"
)


# ------------------------------------------------------------
# 18. Salvar DTAs por tipo de recorte
# ------------------------------------------------------------

chaves_dta <- unique(
  base_percentis[
    ,
    .(
      nivel_geografico,
      tipo_recorte_demografico,
      tipo_recorte_escolaridade
    )
  ]
)

data.table::setorder(
  chaves_dta,
  nivel_geografico,
  tipo_recorte_demografico,
  tipo_recorte_escolaridade
)

total_dtas <- nrow(chaves_dta)

cat("\nTotal de arquivos DTA por recorte a salvar:", total_dtas, "\n")

pb_dtas <- criar_barra_progresso(
  total = total_dtas,
  titulo = "Salvando DTAs"
)

inicio_dtas <- Sys.time()

for (i in seq_len(nrow(chaves_dta))) {

  nivel_i <- chaves_dta$nivel_geografico[i]
  demo_i <- chaves_dta$tipo_recorte_demografico[i]
  esc_i <- chaves_dta$tipo_recorte_escolaridade[i]

  dt_i <- base_percentis[
    nivel_geografico == nivel_i &
      tipo_recorte_demografico == demo_i &
      tipo_recorte_escolaridade == esc_i
  ]

  nome_i <- paste0(
    "base_percentis_",
    limpar_nome_arquivo(nivel_i),
    "_",
    limpar_nome_arquivo(demo_i),
    "_",
    limpar_nome_arquivo(esc_i),
    ".dta"
  )

  haven::write_dta(
    data = dt_i,
    path = file.path(dir_dta_por_recorte, nome_i),
    version = 14
  )

  tick_barra(
    pb = pb_dtas,
    msg = paste(nivel_i, demo_i, esc_i, sep = " | ")
  )

  rm(dt_i)

  if ((i %% gc_a_cada_n_dtas) == 0L) {
    coletar_lixo(
      detalhe = paste0(
        "após salvar DTA ",
        i,
        " de ",
        total_dtas
      )
    )
  }
}

tempo_dtas <- difftime(
  Sys.time(),
  inicio_dtas,
  units = "mins"
)

cat(
  "\nDTAs por recorte salvos em",
  round(as.numeric(tempo_dtas), 2),
  "minutos.\n"
)

cat("\nDTAs por recorte salvos em:\n")
cat(dir_dta_por_recorte, "\n")

tick_barra(
  pb = pb_geral,
  msg = paste0("DTAs por recorte salvos: ", total_dtas)
)


# ------------------------------------------------------------
# 19. Salvar resumo dos grupos
# ------------------------------------------------------------

cat("\nCriando e salvando resumo dos grupos...\n")

inicio_resumo <- Sys.time()

resumo_grupos <- unique(
  base_percentis[
    ,
    .(
      ano,

      nivel_geografico,
      ordem_geografica,
      regiao,
      sigla_uf,
      sigla_uf_nome,
      recorte_geografico,

      tipo_recorte_demografico,
      ordem_recorte_demografico,
      sexo_recorte,
      grupo_demografico,

      tipo_recorte_escolaridade,
      ordem_recorte_escolaridade,
      escolaridade_recorte_ordem,
      escolaridade_recorte,
      escolaridade_ordem,
      escolaridade_grupo,
      grupo_demografico_escolaridade,

      regime_vinculo,
      regime_label,
      ordem_regime,

      grupo_grafico,
      grupo_grafico_completo,

      id_recorte,
      id_recorte_completo,

      n_vinculos_grupo,
      remuneracao_media,
      remuneracao_mediana,
      p01,
      p05,
      p10,
      p25,
      p75,
      p90,
      p95,
      p99
    )
  ]
)

data.table::setorder(
  resumo_grupos,
  ordem_geografica,
  recorte_geografico,
  ordem_recorte_demografico,
  grupo_demografico,
  ordem_recorte_escolaridade,
  escolaridade_recorte_ordem,
  ordem_regime
)

arrow::write_parquet(
  resumo_grupos,
  sink = arquivo_resumo_parquet,
  compression = "zstd"
)

haven::write_dta(
  data = resumo_grupos,
  path = arquivo_resumo_dta,
  version = 14
)

tempo_resumo <- difftime(
  Sys.time(),
  inicio_resumo,
  units = "mins"
)

cat("\nResumo dos grupos salvo em:\n")
cat(arquivo_resumo_parquet, "\n")
cat(arquivo_resumo_dta, "\n")

cat(
  "Tempo para salvar resumo dos grupos:",
  round(as.numeric(tempo_resumo), 2),
  "minutos.\n"
)

rm(resumo_grupos)
coletar_lixo(detalhe = "após salvar e remover resumo_grupos")

tick_barra(
  pb = pb_geral,
  msg = "Resumo dos grupos salvo"
)


# ------------------------------------------------------------
# 20. Salvar catálogo de recortes
# ------------------------------------------------------------

cat("\nCriando e salvando catálogo de recortes...\n")

inicio_catalogo <- Sys.time()

catalogo_recortes <- unique(
  base_percentis[
    ,
    .(
      ano,

      nivel_geografico,
      ordem_geografica,
      regiao,
      sigla_uf,
      sigla_uf_nome,
      recorte_geografico,

      tipo_recorte_demografico,
      ordem_recorte_demografico,
      sexo_recorte,
      grupo_demografico,

      tipo_recorte_escolaridade,
      ordem_recorte_escolaridade,
      escolaridade_recorte_ordem,
      escolaridade_recorte,
      grupo_demografico_escolaridade,

      regime_vinculo,
      regime_label,
      ordem_regime,

      grupo_grafico,
      grupo_grafico_completo,

      id_recorte,
      id_recorte_completo
    )
  ]
)

data.table::setorder(
  catalogo_recortes,
  ordem_geografica,
  recorte_geografico,
  ordem_recorte_demografico,
  grupo_demografico,
  ordem_recorte_escolaridade,
  escolaridade_recorte_ordem,
  ordem_regime
)

data.table::fwrite(
  catalogo_recortes,
  arquivo_catalogo_csv
)

if (isTRUE(gerar_base_kde) && exists("base_kde", inherits = FALSE) && !is.null(base_kde)) {

  catalogo_kde <- unique(
    base_kde[
      ,
      .(
        ano,

        nivel_geografico,
        ordem_geografica,
        regiao,
        sigla_uf,
        sigla_uf_nome,
        recorte_geografico,

        tipo_recorte_demografico,
        ordem_recorte_demografico,
        sexo_recorte,
        grupo_demografico,

        tipo_recorte_escolaridade,
        ordem_recorte_escolaridade,
        escolaridade_recorte_ordem,
        escolaridade_recorte,
        grupo_demografico_escolaridade,

        regime_vinculo,
        regime_label,
        ordem_regime,

        grupo_grafico,
        grupo_grafico_completo,

        id_recorte,
        id_recorte_completo,

        n_vinculos_grupo,
        n_vinculos_kde,
        kde_limite_superior,
        kde_bw,
        kde_probabilidade_limite
      )
    ]
  )

  data.table::setorder(
    catalogo_kde,
    ordem_geografica,
    recorte_geografico,
    ordem_recorte_demografico,
    grupo_demografico,
    ordem_recorte_escolaridade,
    escolaridade_recorte_ordem,
    ordem_regime
  )

  data.table::fwrite(
    catalogo_kde,
    arquivo_catalogo_kde_csv
  )

  rm(catalogo_kde)
}

tempo_catalogo <- difftime(
  Sys.time(),
  inicio_catalogo,
  units = "mins"
)

cat("\nCatálogo de recortes salvo em:\n")
cat(arquivo_catalogo_csv, "\n")

cat(
  "Tempo para salvar catálogo:",
  round(as.numeric(tempo_catalogo), 2),
  "minutos.\n"
)

rm(catalogo_recortes)
coletar_lixo(detalhe = "após salvar e remover catalogo_recortes")

tick_barra(
  pb = pb_geral,
  msg = "Catálogo de recortes salvo"
)


# ------------------------------------------------------------
# 21. Exemplos de filtros
# ------------------------------------------------------------

cat("\n============================================================\n")
cat("Exemplos de filtros para gráficos\n")
cat("============================================================\n")

cat("
1) Celetistas x Estatutários - Brasil, geral:
   nivel_geografico == 'Brasil'
   tipo_recorte_demografico == 'geral'
   tipo_recorte_escolaridade == 'geral'

2) Mulheres Celetistas x Mulheres Estatutárias:
   nivel_geografico == 'Brasil'
   tipo_recorte_demografico == 'sexo'
   sexo_recorte == 'Mulheres'
   tipo_recorte_escolaridade == 'geral'

3) Mulheres Celetistas x Mulheres Estatutárias por escolaridade detalhada:
   nivel_geografico == 'Brasil'
   tipo_recorte_demografico == 'sexo'
   sexo_recorte == 'Mulheres'
   tipo_recorte_escolaridade == 'escolaridade_detalhada'

4) Brasil, Ensino Médio completo e incompleto:
   nivel_geografico == 'Brasil'
   tipo_recorte_demografico == 'geral'
   tipo_recorte_escolaridade == 'escolaridade_macro'
   escolaridade_recorte == 'Ensino Médio'

5) Mulheres, Ensino Médio completo e incompleto:
   nivel_geografico == 'Brasil'
   tipo_recorte_demografico == 'sexo'
   sexo_recorte == 'Mulheres'
   tipo_recorte_escolaridade == 'escolaridade_macro'
   escolaridade_recorte == 'Ensino Médio'

6) UF São Paulo, Ensino Médio completo e incompleto:
   nivel_geografico == 'UF'
   sigla_uf == 'SP'
   tipo_recorte_demografico == 'geral'
   tipo_recorte_escolaridade == 'escolaridade_macro'
   escolaridade_recorte == 'Ensino Médio'

Variáveis principais para gráfico:
   eixo x  = percentil
   eixo y  = remuneracao_percentil
   linha   = grupo_grafico_completo
   cor     = grupo_grafico_completo
   facet   = escolaridade_recorte ou recorte_geografico
")


# ------------------------------------------------------------
# 21.1. Limpeza final opcional
# ------------------------------------------------------------

if (isTRUE(remover_objetos_grandes_no_final)) {

  objetos_grandes_finais <- c(
    "base_percentis",
    "base_kde",
    "chaves_dta",
    "tabela_percentis"
  )

  objetos_grandes_finais <- objetos_grandes_finais[
    vapply(
      objetos_grandes_finais,
      exists,
      logical(1),
      envir = environment(),
      inherits = FALSE
    )
  ]

  if (length(objetos_grandes_finais) > 0L) {
    rm(list = objetos_grandes_finais)
  }

  rm(objetos_grandes_finais)

  coletar_lixo(detalhe = "limpeza final dos objetos grandes")
}


# ------------------------------------------------------------
# 22. Mensagem final
# ------------------------------------------------------------

tempo_total <- difftime(
  Sys.time(),
  inicio_processamento,
  units = "mins"
)

cat("\nProcesso concluído.\n")

cat(
  "\nTempo total do processamento:",
  round(as.numeric(tempo_total), 2),
  "minutos.\n"
)

cat("\nSaídas principais:\n")
cat("Parquet percentis:    ", dir_parquet_saida, "\n")
cat("DTA percentis:        ", arquivo_dta_unico, "\n")
cat("Parquet KDE:          ", dir_parquet_kde_saida, "\n")
cat("DTA KDE:              ", arquivo_kde_dta_unico, "\n")
cat("DTAs por recorte:     ", dir_dta_por_recorte, "\n")
cat("Resumo Parquet:       ", arquivo_resumo_parquet, "\n")
cat("Resumo DTA:           ", arquivo_resumo_dta, "\n")
cat("Catálogo de recortes: ", arquivo_catalogo_csv, "\n")
cat("Catálogo KDE:         ", arquivo_catalogo_kde_csv, "\n")
