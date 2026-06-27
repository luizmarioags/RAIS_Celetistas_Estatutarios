# ------------------------------------------------------------
# Forçar liberação de conexões DuckDB travadas
# ------------------------------------------------------------

library(DBI)
library(duckdb)

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

db_duckdb_path <- file.path(dir_base, "rais_2025_reparticionamento.duckdb")

# 1. Tenta desconectar qualquer conexão ativa no ambiente atual
for (nm in ls(envir = .GlobalEnv)) {
  obj <- get(nm, envir = .GlobalEnv)
  if (inherits(obj, "DBIConnection")) {
    tryCatch(DBI::dbDisconnect(obj, shutdown = TRUE), error = function(e) NULL)
    cat("Desconectado:", nm, "\n")
  }
}

# 2. Força o garbage collector para liberar referências soltas
gc(full = TRUE)

# 3. Apaga o arquivo .duckdb travado (e arquivos auxiliares)
arquivos_duckdb <- c(
  db_duckdb_path,
  paste0(db_duckdb_path, ".wal"),
  paste0(db_duckdb_path, ".tmp")
)

for (f in arquivos_duckdb) {
  if (file.exists(f)) {
    ok <- tryCatch({ unlink(f, force = TRUE); TRUE }, error = function(e) FALSE)
    cat(if (ok) "Apagado: " else "FALHOU ao apagar: ", f, "\n")
  }
}