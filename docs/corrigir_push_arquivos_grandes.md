# Como corrigir erro de push por arquivo maior que 100 MB

O GitHub rejeita arquivos comuns com mais de 100 MB. Se o erro aparecer mesmo depois de apagar o arquivo da pasta, isso significa que ele ainda está no histórico do Git.

## Caso o commit ainda não tenha sido enviado

Remova os arquivos grandes do índice, mantendo-os no disco local:

```bash
git rm -r --cached rais_2025_bases_graficos_percentis
git rm -r --cached rais_2025_download_bigquery_raw
git rm -r --cached rais_2025_vinculos_populacao_total
```

Depois confirme que o `.gitignore` está atualizado e faça novo commit:

```bash
git add .gitignore README.md *.R *.do *.sh docs/
git commit -m "Remove generated data from repository"
git push
```

## Caso os arquivos grandes já estejam no histórico local

Use `git filter-repo` para remover as pastas grandes do histórico:

```bash
pip install git-filter-repo

git filter-repo \
  --path rais_2025_bases_graficos_percentis \
  --path rais_2025_download_bigquery_raw \
  --path rais_2025_vinculos_populacao_total \
  --invert-paths
```

Em seguida:

```bash
git add .gitignore README.md docs/
git commit -m "Ignore generated data outputs" || true
git push --force-with-lease
```

Use `--force-with-lease` apenas se você entende que está reescrevendo o histórico remoto. Em repositório compartilhado, avise os colaboradores.

## Alternativa com Git LFS

Se for necessário versionar bases grandes, use Git LFS:

```bash
git lfs install
git lfs track "*.dta"
git lfs track "*.parquet"
git add .gitattributes
git add caminho/do/arquivo_grande.dta
git commit -m "Track large data files with Git LFS"
git push
```

Mesmo com LFS, avalie custos e limites de armazenamento. Para repositórios reprodutíveis, costuma ser melhor deixar o GitHub apenas com os scripts e publicar bases em um repositório de dados.
