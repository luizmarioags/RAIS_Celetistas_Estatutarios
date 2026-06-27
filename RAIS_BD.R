# ============================================================
# RAIS Vínculos 2025 - População total da RAIS
# BigQuery -> download local em chunks -> Parquet -> DuckDB
#
# NÃO usa GCS
# NÃO usa EXPORT DATA
# NÃO cria tabela permanente no BigQuery
# NÃO usa bigrquerystorage
#
# População total da RAIS 2025:
#   todos os vínculos declarados no ano-base 2025,
#   incluindo ativos e não ativos em 31/12.
#
# Portanto:
#   - NÃO filtra vinculo_ativo_3112 = 1
#   - NÃO filtra remuneração positiva
#   - NÃO filtra tipo_vinculo
#
# Ajustes incluídos:
#   - gc() antes/depois de cada chunk baixado
#   - reparticionamento final UF por UF
#   - DuckDB com escrita mais conservadora
#   - evita COPY único sobre todos os Parquets brutos
#
# CORREÇÃO APLICADA:
#   - Removida a opção ROW_GROUPS_PER_FILE do COPY PARQUET,
#     que só existe no DuckDB 1.2+. Use version() para checar.
# ============================================================


# ------------------------------------------------------------
# 1. Pacotes
# ------------------------------------------------------------

library(bigrquery)
library(arrow)
library(data.table)
library(DBI)
library(duckdb)


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

billing_project <- Sys.getenv(
  "RAIS_BILLING_PROJECT",
  unset = "SEU_PROJETO_GOOGLE_CLOUD"
)

if (!nzchar(billing_project) || identical(billing_project, "SEU_PROJETO_GOOGLE_CLOUD")) {
  stop(
    "Configure o projeto de cobrança do BigQuery antes de rodar. ",
    "Use, por exemplo: Sys.setenv(RAIS_BILLING_PROJECT = 'seu-projeto-gcp') ",
    "ou export RAIS_BILLING_PROJECT='seu-projeto-gcp'."
  )
}

dir_base <- detectar_raiz_repositorio()

dir_raw <- file.path(
  dir_base,
  "rais_2025_download_bigquery_raw"
)

dir_saida <- file.path(
  dir_base,
  "rais_2025_vinculos_populacao_total"
)

dir_duckdb_temp <- file.path(
  dir_base,
  "duckdb_temp"
)

dir.create(dir_base,        recursive = TRUE, showWarnings = FALSE)
dir.create(dir_raw,         recursive = TRUE, showWarnings = FALSE)
dir.create(dir_duckdb_temp, recursive = TRUE, showWarnings = FALSE)


# ------------------------------------------------------------
# 3. Opções de execução
# ------------------------------------------------------------

# Use chunks pequenos no Windows para evitar estouro de memória
# e problemas com arquivos temporários.
# Se ainda pesar, reduza para 50000L.
# Se estiver rodando bem, pode testar 150000L ou 200000L.
target_rows_por_chunk <- 100000L

# TRUE: apaga os Parquets brutos já baixados e começa do zero.
# FALSE: preserva chunks já baixados, útil para retomar.
limpar_raw_antes <- FALSE

# TRUE: apaga a base final particionada antes de recriar.
limpar_saida_final_antes <- TRUE

# TRUE: se o Parquet do chunk já existe e tem tamanho > 0, pula o download.
pular_chunks_existentes <- TRUE

# Reduz paralelismo no download para evitar conflito em arquivo temporário.
max_connections_download <- 1L


# ------------------------------------------------------------
# 3.1. Opções DuckDB
# ------------------------------------------------------------

duckdb_threads <- 2L

# Ajuste conforme sua RAM:
# - PC com 16 GB: "8GB" ou "10GB"
# - PC com 32 GB: "16GB" ou "20GB"
# - servidor grande: "64GB", "96GB" etc.
duckdb_memory_limit <- "16GB"

# Precisa haver espaço livre nessa pasta.
duckdb_max_temp_size <- "400GB"

# Banco físico temporário, em vez de :memory:.
# Ajuda a evitar pressão excessiva na RAM.
db_duckdb_path <- file.path(dir_base, "rais_2025_reparticionamento.duckdb")


# ------------------------------------------------------------
# 4. Funções auxiliares gerais
# ------------------------------------------------------------

coletar_lixo <- function(verbose = FALSE) {
  invisible(gc(verbose = verbose, full = TRUE))
}

set_duckdb_safe <- function(con, sql) {
  tryCatch(
    {
      DBI::dbExecute(con, sql)
      TRUE
    },
    error = function(e) {
      message("\nAviso: não foi possível executar configuração DuckDB:")
      message(sql)
      message("Motivo: ", conditionMessage(e))
      FALSE
    }
  )
}


# ------------------------------------------------------------
# 5. Limpeza local
# ------------------------------------------------------------

if (limpar_raw_antes && dir.exists(dir_raw)) {
  unlink(dir_raw, recursive = TRUE, force = TRUE)
  dir.create(dir_raw, recursive = TRUE, showWarnings = FALSE)
}

if (limpar_saida_final_antes && dir.exists(dir_saida)) {
  unlink(dir_saida, recursive = TRUE, force = TRUE)
}

coletar_lixo()


# ------------------------------------------------------------
# 6. Autenticação BigQuery
# ------------------------------------------------------------

bigrquery::bq_auth()


# ------------------------------------------------------------
# 7. Função auxiliar: baixar uma query do BigQuery
# ------------------------------------------------------------
#
# Compatível com versões antigas do bigrquery:
#   - NÃO usa api =
#   - NÃO usa billing =
#
# O projeto de cobrança entra em bq_project_query().
#
# Ajuste importante:
#   - chama gc() antes e depois de cada tentativa
#   - remove objetos intermediários assim que possível
# ------------------------------------------------------------

baixar_query_bigquery <- function(sql, tentativas = 3L) {

  ultimo_erro <- NULL

  on.exit(coletar_lixo(), add = TRUE)

  for (tentativa in seq_len(tentativas)) {

    coletar_lixo()

    cat("\nTentativa", tentativa, "de", tentativas, "\n")

    resultado <- tryCatch(
      {
        tb <- bigrquery::bq_project_query(
          x              = billing_project,
          query          = sql,
          use_legacy_sql = FALSE
        )

        df <- bigrquery::bq_table_download(
          x               = tb,
          bigint          = "integer64",
          max_connections = max_connections_download
        )

        dt <- data.table::as.data.table(df)

        rm(df)
        coletar_lixo()

        dt
      },
      error = function(e) {
        ultimo_erro <<- e
        NULL
      }
    )

    coletar_lixo()

    if (!is.null(resultado)) {
      return(resultado)
    }

    cat("\nErro na tentativa", tentativa, ":\n")
    print(ultimo_erro)

    coletar_lixo()

    Sys.sleep(5)
  }

  stop(ultimo_erro)
}


# ------------------------------------------------------------
# 8. Contagem de vínculos por UF
# ------------------------------------------------------------

sql_contagem_uf <- "
SELECT
    COALESCE(sigla_uf, '__UF_AUSENTE__') AS sigla_uf_key,
    COUNT(*) AS n_vinculos
FROM `basedosdados.br_me_rais.microdados_vinculos`
WHERE SAFE_CAST(ano AS INT64) = 2025
GROUP BY sigla_uf_key
ORDER BY sigla_uf_key
"

cat("\nBaixando contagem por UF...\n")

contagem_uf <- baixar_query_bigquery(
  sql        = sql_contagem_uf,
  tentativas = 3L
)

contagem_uf[, n_vinculos := as.numeric(n_vinculos)]
contagem_uf[, n_chunks   := pmax(1L, ceiling(n_vinculos / target_rows_por_chunk))]

setorder(contagem_uf, sigla_uf_key)

cat("\nPlano de download por UF:\n")
print(contagem_uf)

data.table::fwrite(
  contagem_uf,
  file.path(dir_base, "plano_download_rais_2025_por_uf.csv")
)

coletar_lixo()


# ------------------------------------------------------------
# 9. Funções auxiliares de filtro SQL
# ------------------------------------------------------------

montar_filtro_uf <- function(sigla_uf_key) {

  if (identical(sigla_uf_key, "__UF_AUSENTE__")) {
    return("dados.sigla_uf IS NULL")
  }

  sigla_uf_sql <- gsub("'", "''", sigla_uf_key)

  sprintf(
    "dados.sigla_uf = '%s'",
    sigla_uf_sql
  )
}

montar_filtro_hash <- function(n_chunks, chunk_id) {

  if (n_chunks <= 1L) {
    return("")
  }

  sprintf(
    "
      AND MOD(
          ABS(
              FARM_FINGERPRINT(
                  CONCAT(
                      COALESCE(CAST(dados.ano AS STRING), ''),
                      '|', COALESCE(CAST(dados.sigla_uf AS STRING), ''),
                      '|', COALESCE(CAST(dados.id_municipio AS STRING), ''),
                      '|', COALESCE(CAST(dados.tipo_vinculo AS STRING), ''),
                      '|', COALESCE(CAST(dados.vinculo_ativo_3112 AS STRING), ''),
                      '|', COALESCE(CAST(dados.valor_remuneracao_media AS STRING), ''),
                      '|', COALESCE(CAST(dados.idade AS STRING), ''),
                      '|', COALESCE(CAST(dados.grau_instrucao_apos_2005 AS STRING), ''),
                      '|', COALESCE(CAST(dados.sexo AS STRING), ''),
                      '|', COALESCE(CAST(dados.raca_cor AS STRING), '')
                  )
              )
          ),
          %d
      ) = %d
    ",
    as.integer(n_chunks),
    as.integer(chunk_id)
  )
}


# ------------------------------------------------------------
# 10. Função para montar a query principal de cada chunk
# ------------------------------------------------------------

montar_query_chunk <- function(sigla_uf_key, n_chunks, chunk_id) {

  filtro_uf   <- montar_filtro_uf(sigla_uf_key)
  filtro_hash <- montar_filtro_hash(n_chunks, chunk_id)

  sprintf(
"
WITH
base_filtrada AS (
    SELECT
        dados.ano,
        dados.sigla_uf,
        dados.id_municipio,
        dados.tipo_vinculo,
        dados.vinculo_ativo_3112,
        dados.valor_remuneracao_media,
        dados.idade,
        dados.grau_instrucao_apos_2005,
        dados.sexo,
        dados.raca_cor
    FROM `basedosdados.br_me_rais.microdados_vinculos` AS dados
    WHERE SAFE_CAST(dados.ano AS INT64) = 2025
      AND %s
      %s
),

dicionario_tipo_vinculo AS (
    SELECT
        chave AS chave_tipo_vinculo,
        valor AS descricao_tipo_vinculo
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE nome_coluna = 'tipo_vinculo'
      AND id_tabela = 'microdados_vinculos'
),

dicionario_vinculo_ativo_3112 AS (
    SELECT
        chave AS chave_vinculo_ativo_3112,
        valor AS descricao_vinculo_ativo_3112
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE nome_coluna = 'vinculo_ativo_3112'
      AND id_tabela = 'microdados_vinculos'
),

dicionario_grau_instrucao_apos_2005 AS (
    SELECT
        chave AS chave_grau_instrucao_apos_2005,
        valor AS descricao_grau_instrucao_apos_2005
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE nome_coluna = 'grau_instrucao_apos_2005'
      AND id_tabela = 'microdados_vinculos'
),

dicionario_sexo AS (
    SELECT
        chave AS chave_sexo,
        valor AS descricao_sexo
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE nome_coluna = 'sexo'
      AND id_tabela = 'microdados_vinculos'
),

dicionario_raca_cor AS (
    SELECT
        chave AS chave_raca_cor,
        valor AS descricao_raca_cor
    FROM `basedosdados.br_me_rais.dicionario`
    WHERE nome_coluna = 'raca_cor'
      AND id_tabela = 'microdados_vinculos'
)

SELECT
    SAFE_CAST(dados.ano AS INT64) AS ano,

    dados.sigla_uf AS sigla_uf,
    diretorio_sigla_uf.nome AS sigla_uf_nome,

    dados.id_municipio AS id_municipio,
    diretorio_id_municipio.nome AS id_municipio_nome,

    SAFE_CAST(dados.tipo_vinculo AS INT64) AS codigo_tipo_vinculo,
    dicionario_tipo_vinculo.descricao_tipo_vinculo AS tipo_vinculo,

    CASE
        WHEN SAFE_CAST(dados.tipo_vinculo AS INT64) IN (10, 15, 20, 25, 60, 65, 70, 75)
            THEN 'celetista'

        WHEN SAFE_CAST(dados.tipo_vinculo AS INT64) IN (30, 31, 35, 95, 96, 97)
            THEN 'estatutario'

        WHEN SAFE_CAST(dados.tipo_vinculo AS INT64) IN (40, 50, 55, 80, 90)
            THEN 'outros'

        WHEN dados.tipo_vinculo IS NULL
            THEN 'tipo_vinculo_ausente'

        ELSE 'tipo_vinculo_nao_mapeado'
    END AS regime_vinculo,

    SAFE_CAST(dados.vinculo_ativo_3112 AS INT64) AS codigo_vinculo_ativo_3112,
    dicionario_vinculo_ativo_3112.descricao_vinculo_ativo_3112 AS vinculo_ativo_3112,

    CASE
        WHEN SAFE_CAST(dados.vinculo_ativo_3112 AS INT64) = 1
            THEN 'ativo_3112'

        WHEN SAFE_CAST(dados.vinculo_ativo_3112 AS INT64) = 0
            THEN 'nao_ativo_3112'

        WHEN dados.vinculo_ativo_3112 IS NULL
            THEN 'vinculo_ativo_3112_ausente'

        ELSE 'vinculo_ativo_3112_nao_mapeado'
    END AS situacao_3112,

    SAFE_CAST(dados.valor_remuneracao_media AS FLOAT64) AS valor_remuneracao_media,

    CASE
        WHEN dados.valor_remuneracao_media IS NULL
            THEN 'remuneracao_ausente'

        WHEN SAFE_CAST(dados.valor_remuneracao_media AS FLOAT64) = 0
            THEN 'remuneracao_zero'

        WHEN SAFE_CAST(dados.valor_remuneracao_media AS FLOAT64) > 0
            THEN 'remuneracao_positiva'

        WHEN SAFE_CAST(dados.valor_remuneracao_media AS FLOAT64) < 0
            THEN 'remuneracao_negativa'

        ELSE 'remuneracao_nao_mapeada'
    END AS status_remuneracao_media,

    SAFE_CAST(dados.idade AS INT64) AS idade,

    dicionario_grau_instrucao_apos_2005.descricao_grau_instrucao_apos_2005 AS grau_instrucao_apos_2005,
    dicionario_sexo.descricao_sexo AS sexo,
    dicionario_raca_cor.descricao_raca_cor AS raca_cor

FROM base_filtrada AS dados

LEFT JOIN (
    SELECT DISTINCT sigla, nome
    FROM `basedosdados.br_bd_diretorios_brasil.uf`
) AS diretorio_sigla_uf
    ON dados.sigla_uf = diretorio_sigla_uf.sigla

LEFT JOIN (
    SELECT DISTINCT id_municipio, nome
    FROM `basedosdados.br_bd_diretorios_brasil.municipio`
) AS diretorio_id_municipio
    ON dados.id_municipio = diretorio_id_municipio.id_municipio

LEFT JOIN dicionario_tipo_vinculo
    ON CAST(dados.tipo_vinculo AS STRING) = CAST(dicionario_tipo_vinculo.chave_tipo_vinculo AS STRING)

LEFT JOIN dicionario_vinculo_ativo_3112
    ON CAST(dados.vinculo_ativo_3112 AS STRING) = CAST(dicionario_vinculo_ativo_3112.chave_vinculo_ativo_3112 AS STRING)

LEFT JOIN dicionario_grau_instrucao_apos_2005
    ON CAST(dados.grau_instrucao_apos_2005 AS STRING) = CAST(dicionario_grau_instrucao_apos_2005.chave_grau_instrucao_apos_2005 AS STRING)

LEFT JOIN dicionario_sexo
    ON CAST(dados.sexo AS STRING) = CAST(dicionario_sexo.chave_sexo AS STRING)

LEFT JOIN dicionario_raca_cor
    ON CAST(dados.raca_cor AS STRING) = CAST(dicionario_raca_cor.chave_raca_cor AS STRING)
",
    filtro_uf,
    filtro_hash
  )
}


# ------------------------------------------------------------
# 11. Função auxiliar: normalizar tipos do log
# ------------------------------------------------------------

normalizar_log <- function(dt) {

  if (nrow(dt) == 0L || ncol(dt) == 0L) {
    return(dt)
  }

  dt[, sigla_uf_key := as.character(sigla_uf_key)]
  dt[, chunk_id     := as.integer(chunk_id)]
  dt[, n_chunks     := as.integer(n_chunks)]
  dt[, arquivo      := as.character(arquivo)]
  dt[, n_linhas     := as.integer(n_linhas)]
  dt[, status       := as.character(status)]
  dt[, timestamp    := as.character(timestamp)]

  dt
}


# ------------------------------------------------------------
# 12. Download chunk a chunk e salvamento local em Parquet
# ------------------------------------------------------------

log_path <- file.path(dir_base, "log_download_rais_2025_chunks.csv")

if (file.exists(log_path)) {
  log_download <- data.table::fread(log_path)
  log_download <- normalizar_log(log_download)
} else {
  log_download <- data.table::data.table(
    sigla_uf_key = character(),
    chunk_id     = integer(),
    n_chunks     = integer(),
    arquivo      = character(),
    n_linhas     = integer(),
    status       = character(),
    timestamp    = character()
  )
}

for (i in seq_len(nrow(contagem_uf))) {

  sigla_uf_key  <- contagem_uf$sigla_uf_key[i]
  n_chunks      <- as.integer(contagem_uf$n_chunks[i])
  n_vinculos_uf <- contagem_uf$n_vinculos[i]

  cat("\n============================================================\n")
  cat("UF:", sigla_uf_key, "\n")
  cat("Vínculos estimados:", formatC(n_vinculos_uf, format = "d", big.mark = ","), "\n")
  cat("Chunks:", n_chunks, "\n")
  cat("============================================================\n")

  for (chunk_id in 0:(n_chunks - 1L)) {

    chunk_label <- formatC(chunk_id, width = 5, flag = "0")

    dir_chunk <- file.path(
      dir_raw,
      paste0("sigla_uf_key=", sigla_uf_key)
    )

    dir.create(dir_chunk, recursive = TRUE, showWarnings = FALSE)

    arquivo_parquet <- file.path(
      dir_chunk,
      paste0("chunk_", chunk_label, "_de_", n_chunks, ".parquet")
    )

    if (
      pular_chunks_existentes &&
      file.exists(arquivo_parquet) &&
      file.info(arquivo_parquet)$size > 0
    ) {
      cat("\nPulando chunk já existente:", arquivo_parquet, "\n")

      if ((chunk_id %% 10L) == 0L) {
        coletar_lixo()
      }

      next
    }

    cat("\nBaixando UF", sigla_uf_key, "- chunk", chunk_id + 1L, "de", n_chunks, "\n")

    coletar_lixo()

    sql_chunk <- montar_query_chunk(
      sigla_uf_key = sigla_uf_key,
      n_chunks     = n_chunks,
      chunk_id     = chunk_id
    )

    coletar_lixo()

    dt_chunk <- baixar_query_bigquery(
      sql        = sql_chunk,
      tentativas = 3L
    )

    coletar_lixo()

    n_linhas <- nrow(dt_chunk)

    cat("Linhas baixadas:", formatC(n_linhas, format = "d", big.mark = ","), "\n")

    if (n_linhas > 0) {

      dt_chunk[
        ,
        `:=`(
          ano                       = as.integer(ano),
          sigla_uf                  = as.character(sigla_uf),
          sigla_uf_nome             = as.character(sigla_uf_nome),
          id_municipio              = as.character(id_municipio),
          id_municipio_nome         = as.character(id_municipio_nome),
          codigo_tipo_vinculo       = as.integer(codigo_tipo_vinculo),
          tipo_vinculo              = as.character(tipo_vinculo),
          regime_vinculo            = as.character(regime_vinculo),
          codigo_vinculo_ativo_3112 = as.integer(codigo_vinculo_ativo_3112),
          vinculo_ativo_3112        = as.character(vinculo_ativo_3112),
          situacao_3112             = as.character(situacao_3112),
          valor_remuneracao_media   = as.numeric(valor_remuneracao_media),
          status_remuneracao_media  = as.character(status_remuneracao_media),
          idade                     = as.integer(idade),
          grau_instrucao_apos_2005  = as.character(grau_instrucao_apos_2005),
          sexo                      = as.character(sexo),
          raca_cor                  = as.character(raca_cor)
        )
      ]

      arrow::write_parquet(
        x           = dt_chunk,
        sink        = arquivo_parquet,
        compression = "snappy"
      )

      cat("Parquet salvo:", arquivo_parquet, "\n")

    } else {
      cat("Chunk vazio. Nenhum Parquet salvo.\n")
    }

    nova_linha <- data.table::data.table(
      sigla_uf_key = as.character(sigla_uf_key),
      chunk_id     = as.integer(chunk_id),
      n_chunks     = as.integer(n_chunks),
      arquivo      = as.character(arquivo_parquet),
      n_linhas     = as.integer(n_linhas),
      status       = "baixado",
      timestamp    = as.character(Sys.time())
    )

    log_download <- rbind(log_download, nova_linha, fill = TRUE)

    data.table::fwrite(log_download, log_path)

    rm(dt_chunk, sql_chunk, nova_linha)
    coletar_lixo()
  }

  coletar_lixo()
}

cat("\nDownload completo para Parquets brutos locais.\n")
cat("Diretório bruto:\n", dir_raw, "\n")

coletar_lixo()


# ------------------------------------------------------------
# 13. Abrir DuckDB com configuração conservadora
# ------------------------------------------------------------

if (file.exists(db_duckdb_path)) {
  unlink(db_duckdb_path, force = TRUE)
}

con <- DBI::dbConnect(
  duckdb::duckdb(),
  dbdir     = db_duckdb_path,
  read_only = FALSE
)

set_duckdb_safe(con, "SET preserve_insertion_order = false;")
set_duckdb_safe(con, sprintf("SET threads = %d;", duckdb_threads))
set_duckdb_safe(con, sprintf("SET memory_limit = '%s';", duckdb_memory_limit))

set_duckdb_safe(
  con,
  sprintf(
    "SET temp_directory = '%s';",
    gsub("\\\\", "/", dir_duckdb_temp)
  )
)

set_duckdb_safe(
  con,
  sprintf(
    "SET max_temp_directory_size = '%s';",
    duckdb_max_temp_size
  )
)

set_duckdb_safe(con, "SET partitioned_write_max_open_files = 8;")
set_duckdb_safe(con, "SET partitioned_write_flush_threshold = 131072;")
set_duckdb_safe(con, "SET write_buffer_row_group_count = 1;")
set_duckdb_safe(con, "SET enable_progress_bar = true;")

cat("\nConfigurações DuckDB relevantes:\n")

print(
  tryCatch(
    {
      DBI::dbGetQuery(
        con,
        "
        SELECT name, value
        FROM duckdb_settings()
        WHERE name IN (
          'threads',
          'memory_limit',
          'temp_directory',
          'max_temp_directory_size',
          'partitioned_write_max_open_files',
          'partitioned_write_flush_threshold',
          'write_buffer_row_group_count'
        )
        ORDER BY name;
        "
      )
    },
    error = function(e) {
      data.frame(
        aviso = paste(
          "Não foi possível consultar duckdb_settings():",
          conditionMessage(e)
        )
      )
    }
  )
)

coletar_lixo()


# ------------------------------------------------------------
# 14. Conferir Parquets brutos
# ------------------------------------------------------------

parquet_raw_glob <- file.path(dir_raw, "**", "*.parquet")
parquet_raw_glob <- gsub("\\\\", "/", parquet_raw_glob)

arquivos_raw <- list.files(
  dir_raw,
  pattern    = "\\.parquet$",
  recursive  = TRUE,
  full.names = TRUE
)

if (length(arquivos_raw) == 0L) {
  stop("Nenhum arquivo Parquet bruto foi encontrado em: ", dir_raw)
}

cat("\nConferindo Parquets brutos:\n", parquet_raw_glob, "\n")

checagem_raw <- DBI::dbGetQuery(
  con,
  sprintf(
    "
    SELECT
        COUNT(*) AS total_linhas_raw,
        COUNT(DISTINCT sigla_uf) AS n_ufs_com_dados
    FROM read_parquet('%s', union_by_name = true);
    ",
    parquet_raw_glob
  )
)

data.table::setDT(checagem_raw)

cat("\nChecagem dos Parquets brutos:\n")
print(checagem_raw)

coletar_lixo()


# ------------------------------------------------------------
# 15. Reparticionar localmente com DuckDB, UF por UF
# ------------------------------------------------------------
#
# CORREÇÃO: ROW_GROUPS_PER_FILE removido — só existe no DuckDB 1.2+.
# Para checar sua versão: DBI::dbGetQuery(con, "SELECT version();")
# ------------------------------------------------------------

if (dir.exists(dir_saida)) {
  unlink(dir_saida, recursive = TRUE, force = TRUE)
}

cat("\nReparticionando Parquets finais UF por UF...\n")

dirs_uf_raw <- list.dirs(
  dir_raw,
  recursive  = FALSE,
  full.names = TRUE
)

dirs_uf_raw <- dirs_uf_raw[
  grepl("^sigla_uf_key=", basename(dirs_uf_raw))
]

if (length(dirs_uf_raw) == 0L) {
  stop("Nenhum diretório sigla_uf_key=... encontrado em: ", dir_raw)
}

dirs_uf_raw <- sort(dirs_uf_raw)

log_reparticionamento_path <- file.path(
  dir_base,
  "log_reparticionamento_rais_2025_por_uf.csv"
)

log_reparticionamento <- data.table::data.table(
  sigla_uf_key = character(),
  n_arquivos   = integer(),
  n_linhas     = numeric(),
  status       = character(),
  timestamp    = character()
)

for (dir_uf in dirs_uf_raw) {

  sigla_uf_key_atual <- sub("^sigla_uf_key=", "", basename(dir_uf))

  arquivos_uf <- list.files(
    dir_uf,
    pattern    = "\\.parquet$",
    recursive  = FALSE,
    full.names = TRUE
  )

  if (length(arquivos_uf) == 0L) {
    cat("\nUF", sigla_uf_key_atual, "sem arquivos Parquet. Pulando.\n")
    next
  }

  parquet_uf_glob <- file.path(dir_uf, "*.parquet")
  parquet_uf_glob <- gsub("\\\\", "/", parquet_uf_glob)

  cat("\n============================================================\n")
  cat("Reparticionando UF:", sigla_uf_key_atual, "\n")
  cat("Arquivos:", length(arquivos_uf), "\n")
  cat("============================================================\n")

  coletar_lixo()

  n_linhas_uf <- DBI::dbGetQuery(
    con,
    sprintf(
      "
      SELECT COUNT(*) AS n_linhas
      FROM read_parquet('%s', union_by_name = true);
      ",
      parquet_uf_glob
    )
  )$n_linhas[1]

  cat("Linhas da UF:", formatC(n_linhas_uf, format = "d", big.mark = ","), "\n")

  # -----------------------------------------------------------
  # ROW_GROUPS_PER_FILE e APPEND removidos — só existem no DuckDB 1.2+.
  # Com PARTITION_BY, o DuckDB grava cada UF em subpastas próprias
  # (part_{uuid}.parquet), sem risco de colisão entre UFs.
  # -----------------------------------------------------------
  sql_copy_uf <- sprintf(
    "
    COPY (
        SELECT
            CAST(ano AS INTEGER) AS ano,

            CAST(sigla_uf AS VARCHAR) AS sigla_uf,
            CAST(sigla_uf_nome AS VARCHAR) AS sigla_uf_nome,

            CAST(id_municipio AS VARCHAR) AS id_municipio,
            CAST(id_municipio_nome AS VARCHAR) AS id_municipio_nome,

            CAST(codigo_tipo_vinculo AS INTEGER) AS codigo_tipo_vinculo,
            CAST(tipo_vinculo AS VARCHAR) AS tipo_vinculo,

            CAST(regime_vinculo AS VARCHAR) AS regime_vinculo,

            CAST(codigo_vinculo_ativo_3112 AS INTEGER) AS codigo_vinculo_ativo_3112,
            CAST(vinculo_ativo_3112 AS VARCHAR) AS vinculo_ativo_3112,

            CAST(situacao_3112 AS VARCHAR) AS situacao_3112,

            CAST(valor_remuneracao_media AS DOUBLE) AS valor_remuneracao_media,
            CAST(status_remuneracao_media AS VARCHAR) AS status_remuneracao_media,

            CAST(idade AS INTEGER) AS idade,

            CAST(grau_instrucao_apos_2005 AS VARCHAR) AS grau_instrucao_apos_2005,
            CAST(sexo AS VARCHAR) AS sexo,
            CAST(raca_cor AS VARCHAR) AS raca_cor

        FROM read_parquet('%s', union_by_name = true)
    )
    TO '%s'
    (
        FORMAT PARQUET,
        PARTITION_BY (ano, regime_vinculo, situacao_3112),
        OVERWRITE_OR_IGNORE TRUE,
        COMPRESSION SNAPPY,
        ROW_GROUP_SIZE 65536,
        FILENAME_PATTERN 'part_{uuid}'
    );
    ",
    parquet_uf_glob,
    gsub("\\\\", "/", dir_saida)
  )

  tryCatch(
    {
      DBI::dbExecute(con, sql_copy_uf)

      log_reparticionamento <- rbind(
        log_reparticionamento,
        data.table::data.table(
          sigla_uf_key = as.character(sigla_uf_key_atual),
          n_arquivos   = as.integer(length(arquivos_uf)),
          n_linhas     = as.numeric(n_linhas_uf),
          status       = "ok",
          timestamp    = as.character(Sys.time())
        ),
        fill = TRUE
      )

      data.table::fwrite(
        log_reparticionamento,
        log_reparticionamento_path
      )

      cat("UF reparticionada com sucesso:", sigla_uf_key_atual, "\n")
    },
    error = function(e) {

      log_reparticionamento <<- rbind(
        log_reparticionamento,
        data.table::data.table(
          sigla_uf_key = as.character(sigla_uf_key_atual),
          n_arquivos   = as.integer(length(arquivos_uf)),
          n_linhas     = as.numeric(n_linhas_uf),
          status       = paste0("erro: ", conditionMessage(e)),
          timestamp    = as.character(Sys.time())
        ),
        fill = TRUE
      )

      data.table::fwrite(
        log_reparticionamento,
        log_reparticionamento_path
      )

      stop(e)
    }
  )

  rm(sql_copy_uf, arquivos_uf, parquet_uf_glob)
  coletar_lixo()
}

cat("\nParquet final particionado salvo em:\n", dir_saida, "\n")

coletar_lixo()


# ------------------------------------------------------------
# 16. Conferências finais
# ------------------------------------------------------------

parquet_final_glob <- file.path(dir_saida, "**", "*.parquet")
parquet_final_glob <- gsub("\\\\", "/", parquet_final_glob)

arquivos_finais <- list.files(
  dir_saida,
  pattern    = "\\.parquet$",
  recursive  = TRUE,
  full.names = TRUE
)

if (length(arquivos_finais) == 0L) {
  stop("Nenhum arquivo Parquet final foi encontrado em: ", dir_saida)
}


# ------------------------------------------------------------
# 16.1. Checagem total
# ------------------------------------------------------------

checagem_total <- DBI::dbGetQuery(
  con,
  sprintf(
    "
    SELECT
        ano,

        COUNT(*) AS total_vinculos_rais_2025,

        SUM(CASE WHEN situacao_3112 = 'ativo_3112' THEN 1 ELSE 0 END)
            AS total_ativos_3112,

        SUM(CASE WHEN situacao_3112 = 'nao_ativo_3112' THEN 1 ELSE 0 END)
            AS total_nao_ativos_3112,

        SUM(
            CASE
                WHEN situacao_3112 NOT IN ('ativo_3112', 'nao_ativo_3112')
                    THEN 1
                ELSE 0
            END
        ) AS total_situacao_3112_nao_mapeada,

        SUM(CASE WHEN regime_vinculo = 'celetista' THEN 1 ELSE 0 END)
            AS total_celetistas,

        SUM(CASE WHEN regime_vinculo = 'estatutario' THEN 1 ELSE 0 END)
            AS total_estatutarios,

        SUM(CASE WHEN regime_vinculo = 'outros' THEN 1 ELSE 0 END)
            AS total_outros,

        SUM(CASE WHEN regime_vinculo = 'tipo_vinculo_ausente' THEN 1 ELSE 0 END)
            AS total_tipo_vinculo_ausente,

        SUM(CASE WHEN regime_vinculo = 'tipo_vinculo_nao_mapeado' THEN 1 ELSE 0 END)
            AS total_tipo_vinculo_nao_mapeado

    FROM read_parquet('%s', hive_partitioning = true, union_by_name = true)
    GROUP BY ano
    ORDER BY ano;
    ",
    parquet_final_glob
  )
)

data.table::setDT(checagem_total)

cat("\nChecagem da população total da RAIS 2025:\n")
print(checagem_total)

coletar_lixo()


# ------------------------------------------------------------
# 16.2. Resumo por regime e situação em 31/12
# ------------------------------------------------------------

resumo_regime_situacao <- DBI::dbGetQuery(
  con,
  sprintf(
    "
    SELECT
        ano,
        regime_vinculo,
        situacao_3112,

        COUNT(*) AS n_vinculos,

        COUNT(valor_remuneracao_media) AS n_com_remuneracao_media,

        SUM(CASE WHEN valor_remuneracao_media IS NULL THEN 1 ELSE 0 END)
            AS n_remuneracao_ausente,

        SUM(CASE WHEN valor_remuneracao_media = 0 THEN 1 ELSE 0 END)
            AS n_remuneracao_zero,

        AVG(valor_remuneracao_media) AS remuneracao_media,
        MEDIAN(valor_remuneracao_media) AS remuneracao_mediana,
        QUANTILE_CONT(valor_remuneracao_media, 0.90) AS p90,
        QUANTILE_CONT(valor_remuneracao_media, 0.99) AS p99

    FROM read_parquet('%s', hive_partitioning = true, union_by_name = true)
    GROUP BY ano, regime_vinculo, situacao_3112
    ORDER BY ano, regime_vinculo, situacao_3112;
    ",
    parquet_final_glob
  )
)

data.table::setDT(resumo_regime_situacao)

cat("\nResumo por regime de vínculo e situação em 31/12:\n")
print(resumo_regime_situacao)

coletar_lixo()


# ------------------------------------------------------------
# 16.3. Resumo por código de tipo de vínculo
# ------------------------------------------------------------

resumo_tipo_vinculo <- DBI::dbGetQuery(
  con,
  sprintf(
    "
    SELECT
        ano,
        regime_vinculo,
        codigo_tipo_vinculo,
        tipo_vinculo,

        COUNT(*) AS n_vinculos,

        SUM(CASE WHEN situacao_3112 = 'ativo_3112' THEN 1 ELSE 0 END)
            AS n_ativos_3112,

        SUM(CASE WHEN situacao_3112 = 'nao_ativo_3112' THEN 1 ELSE 0 END)
            AS n_nao_ativos_3112,

        SUM(
            CASE
                WHEN situacao_3112 NOT IN ('ativo_3112', 'nao_ativo_3112')
                    THEN 1
                ELSE 0
            END
        ) AS n_situacao_3112_nao_mapeada

    FROM read_parquet('%s', hive_partitioning = true, union_by_name = true)
    GROUP BY ano, regime_vinculo, codigo_tipo_vinculo, tipo_vinculo
    ORDER BY regime_vinculo, codigo_tipo_vinculo;
    ",
    parquet_final_glob
  )
)

data.table::setDT(resumo_tipo_vinculo)

cat("\nResumo por código de tipo de vínculo:\n")
print(resumo_tipo_vinculo)

coletar_lixo()


# ------------------------------------------------------------
# 16.4. Base agregada para gráfico celetistas x estatutários
# ------------------------------------------------------------

base_grafico_celetista_estatutario <- DBI::dbGetQuery(
  con,
  sprintf(
    "
    SELECT
        ano,
        regime_vinculo,
        situacao_3112,

        COUNT(*) AS n_vinculos,

        AVG(valor_remuneracao_media) AS remuneracao_media,
        MEDIAN(valor_remuneracao_media) AS remuneracao_mediana

    FROM read_parquet('%s', hive_partitioning = true, union_by_name = true)
    WHERE regime_vinculo IN ('celetista', 'estatutario')
    GROUP BY ano, regime_vinculo, situacao_3112
    ORDER BY ano, regime_vinculo, situacao_3112;
    ",
    parquet_final_glob
  )
)

data.table::setDT(base_grafico_celetista_estatutario)

cat("\nBase agregada para gráfico celetistas x estatutários:\n")
print(base_grafico_celetista_estatutario)

coletar_lixo()


# ------------------------------------------------------------
# 17. Salvar resumos em CSV
# ------------------------------------------------------------

data.table::fwrite(
  checagem_total,
  file.path(dir_base, "checagem_total_rais_2025.csv")
)

data.table::fwrite(
  resumo_regime_situacao,
  file.path(dir_base, "resumo_regime_situacao_rais_2025.csv")
)

data.table::fwrite(
  resumo_tipo_vinculo,
  file.path(dir_base, "resumo_tipo_vinculo_rais_2025.csv")
)

data.table::fwrite(
  base_grafico_celetista_estatutario,
  file.path(dir_base, "base_grafico_celetista_estatutario_rais_2025.csv")
)

data.table::fwrite(
  log_download,
  log_path
)

data.table::fwrite(
  log_reparticionamento,
  log_reparticionamento_path
)

coletar_lixo()


# ------------------------------------------------------------
# 18. Fechar DuckDB
# ------------------------------------------------------------

DBI::dbDisconnect(con, shutdown = TRUE)

coletar_lixo()


# ------------------------------------------------------------
# 19. Mensagem final
# ------------------------------------------------------------

cat("\nProcesso concluído.\n")
cat("\nParquets brutos baixados diretamente do BigQuery em:\n", dir_raw, "\n")
cat("\nParquet final particionado salvo em:\n", dir_saida, "\n")
cat("\nResumos salvos em:\n", dir_base, "\n")