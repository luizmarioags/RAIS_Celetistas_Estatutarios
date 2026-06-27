#!/usr/bin/env bash
# Remove saídas grandes do índice do Git, sem apagar arquivos locais.
# Use quando arquivos .dta/.parquet/.duckdb/.csv já foram adicionados com git add,
# mas ainda não precisam entrar no repositório.

set -euo pipefail

paths=(
  "rais_2025_bases_graficos_percentis"
  "rais_2025_download_bigquery_raw"
  "rais_2025_vinculos_populacao_total"
)

for p in "${paths[@]}"; do
  if git ls-files --error-unmatch "$p" >/dev/null 2>&1; then
    git rm -r --cached "$p"
  fi
done

git rm --cached -r -- '*.dta' '*.parquet' '*.duckdb' '*.csv' 2>/dev/null || true

echo "Arquivos grandes removidos do índice. Confira com: git status"
echo "Depois rode: git add .gitignore README.md *.R *.do *.sh docs/ && git commit -m 'Remove generated data outputs'"
