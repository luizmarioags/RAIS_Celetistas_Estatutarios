#!/usr/bin/env bash
# ============================================================
# RAIS 2025 - Execução do pipeline a partir da raiz do repositório
# ============================================================
#
# Uso recomendado após git clone:
#
#   ./Run_All_RAIS.sh graphs
#
# Modos disponíveis:
#   graphs   -> gera apenas os gráficos a partir das bases já incluídas/geradas
#   process  -> processa Parquets locais e depois gera gráficos
#   full     -> baixa/processa a RAIS via BigQuery, processa os Parquets e gera gráficos
#
# Variáveis de ambiente aceitas:
#   RAIS_DIR_BASE          raiz do repositório; por padrão, detectada automaticamente
#   RAIS_BILLING_PROJECT  projeto Google Cloud usado na cobrança do BigQuery
#   USE_STATA             1 para preferir Stata nos gráficos se disponível; 0 para R
#
# Exemplos:
#   RAIS_BILLING_PROJECT="seu-projeto-gcp" ./Run_All_RAIS.sh full
#   USE_STATA=1 ./Run_All_RAIS.sh graphs
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${RAIS_DIR_BASE:-$SCRIPT_DIR}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"

cd "$PROJECT_ROOT"

export RAIS_DIR_BASE="$PROJECT_ROOT"
export RAIS_BILLING_PROJECT="${RAIS_BILLING_PROJECT:-SEU_PROJETO_GOOGLE_CLOUD}"
export USE_STATA="${USE_STATA:-0}"

MODE="${1:-graphs}"

case "$MODE" in
  graphs|process|full)
    ;;
  *)
    echo "Modo inválido: $MODE" >&2
    echo "Use: graphs, process ou full" >&2
    exit 2
    ;;
esac

echo ""
echo "============================================================"
echo "RAIS 2025 - Pipeline"
echo "Modo: $MODE"
echo "Raiz do repositório: $PROJECT_ROOT"
echo "============================================================"
echo ""

resolve_project_file() {
  local file_name="$1"
  local direct_path="$PROJECT_ROOT/$file_name"

  if [ -f "$direct_path" ]; then
    printf '%s\n' "$direct_path"
    return 0
  fi

  local found
  found="$(find "$PROJECT_ROOT" -type f -name "$file_name" 2>/dev/null | head -n 1 || true)"

  if [ -z "$found" ]; then
    echo "Erro: arquivo não encontrado no projeto: $file_name" >&2
    echo "Diretório pesquisado: $PROJECT_ROOT" >&2
    exit 1
  fi

  printf '%s\n' "$found"
}

find_rscript() {
  if command -v Rscript >/dev/null 2>&1; then
    command -v Rscript
    return 0
  fi

  if command -v Rscript.exe >/dev/null 2>&1; then
    command -v Rscript.exe
    return 0
  fi

  echo "Erro: Rscript não encontrado. Instale o R ou adicione Rscript ao PATH." >&2
  exit 1
}

find_stata() {
  local commands=(
    "stata-mp" "stata-se" "stata-be" "stata"
    "xstata-mp" "xstata-se" "xstata"
    "StataMP-64.exe" "StataSE-64.exe" "StataBE-64.exe" "Stata-64.exe"
    "StataMP.exe" "StataSE.exe" "StataBE.exe" "Stata.exe"
  )

  local cmd
  for cmd in "${commands[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
      command -v "$cmd"
      return 0
    fi
  done

  return 1
}

run_r_script() {
  local script_path="$1"

  echo ""
  echo "------------------------------------------------------------"
  echo "Rodando script R: $script_path"
  echo "------------------------------------------------------------"
  echo ""

  "$RSCRIPT_BIN" "$script_path"
}

run_stata_do() {
  local do_path="$1"

  echo ""
  echo "------------------------------------------------------------"
  echo "Rodando script Stata: $do_path"
  echo "------------------------------------------------------------"
  echo ""

  case "$STATA_BIN" in
    *.exe|*.EXE)
      "$STATA_BIN" /e do "$do_path"
      ;;
    *)
      "$STATA_BIN" -b do "$do_path"
      ;;
  esac
}

RSCRIPT_BIN="$(find_rscript)"
echo "Rscript: $RSCRIPT_BIN"

if [ "$MODE" = "full" ]; then
  if [ "$RAIS_BILLING_PROJECT" = "SEU_PROJETO_GOOGLE_CLOUD" ]; then
    echo "Erro: para o modo full, defina RAIS_BILLING_PROJECT." >&2
    echo "Exemplo: RAIS_BILLING_PROJECT='seu-projeto-gcp' ./Run_All_RAIS.sh full" >&2
    exit 1
  fi

  run_r_script "$(resolve_project_file "RAIS_BD.R")"
fi

if [ "$MODE" = "full" ] || [ "$MODE" = "process" ]; then
  run_r_script "$(resolve_project_file "rais_2025_processamento.R")"
fi

if [ "$USE_STATA" = "1" ] && STATA_BIN="$(find_stata)"; then
  echo "Stata encontrado: $STATA_BIN"
  run_stata_do "$(resolve_project_file "Grafico_Escolaridade_Regime.do")"
  run_stata_do "$(resolve_project_file "gap_salarial_regime_escolaridade.do")"
else
  if [ "$USE_STATA" = "1" ]; then
    echo "Stata não encontrado. Usando gráficos em R."
  fi
  run_r_script "$(resolve_project_file "RAIS_BD_Graph.R")"
fi

echo ""
echo "============================================================"
echo "Pipeline concluído."
echo "Resultados em: $PROJECT_ROOT/rais_2025_bases_graficos_percentis"
echo "============================================================"
echo ""
