# RAIS 2025 — Distribuição Salarial por Regime e Escolaridade

Este repositório reúne scripts em **R**, **Stata** e **Shell** para baixar, processar e visualizar a distribuição salarial da RAIS 2025, com foco na comparação entre vínculos **celetistas** e **estatutários**. O projeto foi organizado para funcionar a partir da pasta local criada pelo `git clone`, sem depender de caminhos absolutos ou diretórios pessoais.

O objetivo central é construir uma base de percentis salariais por recortes geográficos, demográficos e educacionais e, a partir dela, gerar gráficos de distribuição salarial e medidas de diferença salarial entre regimes de vínculo.

## O que o projeto faz

O pipeline está dividido em quatro etapas principais.

1. **Download e preparação inicial da RAIS 2025**  
   O script `RAIS_BD.R` consulta a tabela `basedosdados.br_me_rais.microdados_vinculos` via BigQuery, baixa os dados em chunks por UF e salva os arquivos localmente em formato Parquet. A etapa também junta dicionários da RAIS para classificar tipo de vínculo, situação em 31/12, escolaridade, sexo e raça/cor, embora a versão atual dos gráficos use apenas regime, escolaridade, sexo e geografia.

2. **Processamento local e construção dos recortes**  
   O script `rais_2025_processamento.R` lê os Parquets locais, filtra vínculos ativos em 31/12 com remuneração média positiva, mantém os regimes celetista e estatutário e calcula percentis salariais por grupo. Os grupos combinam geografia, regime, sexo e escolaridade.

3. **Gráficos de distribuição salarial**  
   O script `RAIS_BD_Graph.R` gera gráficos em R para comparar distribuições salariais por escolaridade dentro de cada regime. Os scripts Stata `Grafico_Escolaridade_Regime.do` e `gap_salarial_regime_escolaridade.do` reproduzem a lógica gráfica em Stata, caso o usuário prefira esse ambiente.

4. **Cálculo e visualização do gap estatutário-celetista**  
   O projeto calcula o gap salarial entre estatutários e celetistas por percentil da distribuição, tanto para o recorte geral quanto para cinco níveis educacionais: Fundamental completo, Ensino Médio completo, Ensino Superior completo, Mestrado e Doutorado.

## O que o projeto estima

Este projeto não estima um modelo causal ou uma regressão. Ele estima estatísticas descritivas não paramétricas da distribuição salarial, especialmente **quantis**, **densidades kernel** e **gaps salariais por percentil**.

A unidade de análise é o vínculo da RAIS. Para cada grupo analítico $g$, definido por regime de vínculo, geografia, sexo e escolaridade, seja $w_i$ a remuneração média do vínculo $i$.

A amostra analítica básica é:

```math
\mathcal{S} = \left\{ i : \text{ativo}_{i,31/12}=1,\; w_i > 0,\; \text{regime}_i \in \{\text{celetista}, \text{estatutario}\} \right\}.
```

Para cada grupo $g$, o número de vínculos é:

```math
N_g = \sum_{i \in \mathcal{S}} \mathbf{1}_{\{i \in g\}}.
```

A remuneração média do grupo é:

```math
\bar{w}_g = \frac{1}{N_g}\sum_{i \in g} w_i.
```

A remuneração mediana do grupo é o quantil de ordem 0,50:

```math
\widetilde{w}_g = Q_g(0{,}50).
```

A curva de percentis salariais é dada por:

```math
\widehat{Q}_{g,p} = Q_g(\tau_p),
```

em que:

```math
\tau_p =
\begin{cases}
\frac{p}{100}, & p = 1,2,\ldots,99, \\
0{,}995, & p = 100.
\end{cases}
```

O uso de $0{,}995$ no ponto 100 evita que o último ponto do gráfico seja dominado pelo máximo absoluto da amostra.

A densidade kernel estimada para cada grupo é:

```math
\widehat{f}_g(w) = \frac{1}{N_g h}\sum_{i \in g} K\left(\frac{w - w_i}{h}\right),
```

em que $K(\cdot)$ é o núcleo usado pela função `density()` do R e $h$ é a largura de banda escolhida pelo método padrão da função.

O gap salarial absoluto entre estatutários e celetistas no percentil $p$ é:

```math
Gap^{abs}_p = \widehat{Q}_{est,p} - \widehat{Q}_{cel,p}.
```

O gap salarial percentual é:

```math
Gap^{\%}_{p} = 100 \cdot \frac{\widehat{Q}_{est,p} - \widehat{Q}_{cel,p}}{\widehat{Q}_{cel,p}}.
```

A razão salarial entre estatutários e celetistas é:

```math
Ratio_p = \frac{\widehat{Q}_{est,p}}{\widehat{Q}_{cel,p}}.
```

O log-gap é:

```math
Gap^{log}_p = \log(\widehat{Q}_{est,p}) - \log(\widehat{Q}_{cel,p})
= \log\left(\frac{\widehat{Q}_{est,p}}{\widehat{Q}_{cel,p}}\right).
```

Valores positivos de $Gap^{\%}_p$ ou $Gap^{log}_p$ indicam remuneração maior entre estatutários naquele percentil. Valores negativos indicam remuneração maior entre celetistas.

## Classificação de regime de vínculo

A classificação do regime é criada a partir de `tipo_vinculo`:

```math
\text{regime}_i =
\begin{cases}
\text{celetista}, & \text{tipo\_vinculo}_i \in \{10,15,20,25,60,65,70,75\}, \\
\text{estatutario}, & \text{tipo\_vinculo}_i \in \{30,31,35,95,96,97\}, \\
\text{outros}, & \text{tipo\_vinculo}_i \in \{40,50,55,80,90\}, \\
\text{tipo\_vinculo\_ausente}, & \text{tipo\_vinculo}_i = \varnothing, \\
\text{tipo\_vinculo\_nao\_mapeado}, & \text{caso contrário.}
\end{cases}
```

A análise gráfica mantém apenas:

```math
\text{regime}_i \in \{\text{celetista}, \text{estatutario}\}.
```

## Classificação de escolaridade

O processamento usa a variável `grau_instrucao_apos_2005` da RAIS/Base dos Dados e cria três níveis de recorte.

### Escolaridade detalhada

| Código | Categoria |
|---:|---|
| 1 | Analfabeto |
| 2 | Fundamental incompleto — até 5ª série |
| 3 | Fundamental incompleto — 5ª série completa |
| 4 | Fundamental incompleto — 6ª a 9ª série |
| 5 | Fundamental completo |
| 6 | Ensino Médio incompleto |
| 7 | Ensino Médio completo |
| 8 | Ensino Superior incompleto |
| 9 | Ensino Superior completo |
| 10 | Mestrado |
| 11 | Doutorado |
| 99 | Escolaridade não informada |

### Escolaridade por etapa

A variável `escolaridade_etapa` agrega os códigos detalhados em: Analfabeto, Fundamental incompleto, Fundamental completo, Ensino Médio incompleto, Ensino Médio completo, Ensino Superior incompleto, Ensino Superior completo, Pós-graduação e Escolaridade não informada.

### Escolaridade macro

A variável `escolaridade_macro` agrega a escolaridade em: Até fundamental completo, Ensino Médio, Ensino superior, Pós-graduação e Escolaridade não informada.

Nos gráficos de escolaridade por regime e no cálculo principal do gap são usados os códigos:

```math
\{5,7,9,10,11\},
```

isto é: Fundamental completo, Ensino Médio completo, Ensino Superior completo, Mestrado e Doutorado.

## Estrutura dos principais arquivos

```text
.
├── RAIS_BD.R
├── rais_2025_processamento.R
├── RAIS_BD_Graph.R
├── Grafico_Escolaridade_Regime.do
├── gap_salarial_regime_escolaridade.do
├── duck_treat.R
├── Run_All_RAIS.sh
├── README.md
├── .env.example
└── .gitignore
```

As pastas de dados e resultados são criadas localmente durante a execução e não devem ser versionadas no GitHub.

### Scripts

| Arquivo | Função |
|---|---|
| `RAIS_BD.R` | Baixa a RAIS 2025 via BigQuery/Base dos Dados, cria Parquets locais e resumos iniciais. |
| `rais_2025_processamento.R` | Processa Parquets locais, cria percentis, KDEs, DTAs por recorte, diagnósticos e catálogos. |
| `RAIS_BD_Graph.R` | Gera gráficos em R de distribuição salarial por escolaridade/regime e calcula/plota o gap estatutário-celetista. |
| `Grafico_Escolaridade_Regime.do` | Gera, em Stata, gráficos separados para celetistas e estatutários por nível educacional. |
| `gap_salarial_regime_escolaridade.do` | Calcula e plota, em Stata, o gap estatutário-celetista geral e por escolaridade. |
| `duck_treat.R` | Utilitário para fechar conexões DuckDB e remover arquivos temporários/travados. |
| `Run_All_RAIS.sh` | Executa o pipeline a partir da raiz do repositório, com caminhos dinâmicos. |


## Observação importante sobre GitHub e arquivos grandes

Este repositório deve versionar **código, documentação e arquivos de configuração**, não as bases `.dta`, `.parquet`, `.duckdb` ou `.csv` geradas pelo processamento. Algumas bases de percentis por recorte ultrapassam 100 MB por arquivo, que é o limite rígido do GitHub para arquivos comuns.

Por isso, a versão preparada para GitHub exclui os dados gerados e mantém a seguinte lógica:

1. o usuário clona o repositório;
2. configura `RAIS_BILLING_PROJECT`, caso vá baixar a RAIS via BigQuery;
3. roda o pipeline;
4. os dados e gráficos são salvos localmente, a partir da raiz do clone;
5. as saídas grandes ficam ignoradas pelo `.gitignore`.

As principais saídas locais ignoradas são:

```text
rais_2025_download_bigquery_raw/
rais_2025_vinculos_populacao_total/
rais_2025_bases_graficos_percentis/
*.parquet
*.dta
*.duckdb
*.csv
```

Se for indispensável versionar bases prontas, use **Git LFS** ou publique os dados como *release asset*, Zenodo, OSF, Google Drive, Dropbox ou outro repositório de dados. Para fins de reprodutibilidade, a solução recomendada é manter no GitHub apenas os scripts que regeneram essas bases.

## Como rodar

Após clonar o repositório:

```bash
git clone <URL_DO_REPOSITORIO>
cd <NOME_DO_REPOSITORIO>
```

Para gerar apenas os gráficos usando bases já geradas localmente:

```bash
./Run_All_RAIS.sh graphs
```

Para processar Parquets locais e depois gerar gráficos:

```bash
./Run_All_RAIS.sh process
```

Para executar o pipeline completo, incluindo download via BigQuery, configure o projeto de cobrança do Google Cloud:

```bash
export RAIS_BILLING_PROJECT="seu-projeto-gcp"
./Run_All_RAIS.sh full
```

No Windows com Git Bash, o comando é o mesmo. No R, também é possível configurar:

```r
Sys.setenv(RAIS_BILLING_PROJECT = "seu-projeto-gcp")
```

O diretório base dos resultados é definido automaticamente como a raiz do repositório. Se necessário, ele pode ser sobrescrito com:

```bash
export RAIS_DIR_BASE="/caminho/para/o/repositorio"
```

## Uso com Stata

Por padrão, o `.sh` usa os gráficos em R. Para preferir Stata, caso ele esteja instalado e disponível no `PATH`, rode:

```bash
USE_STATA=1 ./Run_All_RAIS.sh graphs
```

Os do-files também usam `RAIS_DIR_BASE`. Se essa variável não existir, eles assumem que estão sendo executados a partir da raiz do repositório.

## Pacotes R necessários

Os scripts instalam automaticamente pacotes faltantes quando possível. Os principais pacotes usados são:

```r
bigrquery
arrow
data.table
DBI
duckdb
dplyr
haven
progress
ggplot2
ggthemes
scales
stringi
glue
```

## Bases e saídas principais geradas localmente

### Saídas do download/processamento inicial

| Arquivo ou pasta | Conteúdo |
|---|---|
| `rais_2025_download_bigquery_raw/` | Parquets brutos baixados em chunks por UF. |
| `rais_2025_vinculos_populacao_total/` | Base final reparticionada por ano, regime e situação em 31/12. |
| `checagem_total_rais_2025.csv` | Checagem do total de vínculos e distribuição por regime/situação. |
| `resumo_regime_situacao_rais_2025.csv` | Estatísticas salariais por regime e situação em 31/12. |
| `resumo_tipo_vinculo_rais_2025.csv` | Contagens por tipo de vínculo e regime. |

### Saídas do processamento de percentis

| Arquivo ou pasta | Conteúdo |
|---|---|
| `rais_2025_bases_graficos_percentis/base_percentis_salariais_long_parquet/` | Percentis salariais em Parquet particionado. |
| `rais_2025_bases_graficos_percentis/base_percentis_salariais_recortes_rais_2025.dta` | Base única de percentis para R/Stata. |
| `rais_2025_bases_graficos_percentis/dta_por_recorte/` | Bases `.dta` separadas por recorte. |
| `rais_2025_bases_graficos_percentis/base_kde_salariais_long_parquet/` | Pontos de densidade kernel por grupo. |
| `catalogo_recortes_percentis_rais_2025.csv` | Catálogo dos recortes de percentis. |
| `catalogo_recortes_kde_rais_2025.csv` | Catálogo dos recortes KDE. |

### Saídas dos gráficos

| Pasta | Conteúdo |
|---|---|
| `figuras_R_escolaridade_regime/` | Gráficos R por regime e escolaridade, em PNG/PDF, além das bases auxiliares. |
| `gap_estatutarios_celetistas_geral_escolaridade_R/` | Gráficos e bases do gap salarial calculado em R. |
| `figuras_stata_escolaridade_regime/` | Gráficos Stata de distribuição salarial por escolaridade e regime. |
| `gap_estatutarios_celetistas_geral_escolaridade/` | Gráficos Stata do gap salarial geral e por escolaridade. |

## Mini dicionário de variáveis

### Variáveis de entrada usadas diretamente

| Variável | Origem | Uso |
|---|---|---|
| `ano` | RAIS/Base dos Dados | Filtra o ano-base 2025 e identifica a partição temporal. |
| `sigla_uf` | RAIS/Base dos Dados | Identifica a UF do vínculo e permite criar recortes por UF e região. |
| `sigla_uf_nome` | Diretório de UF da Base dos Dados | Nome da UF usado em rótulos e recortes geográficos. |
| `tipo_vinculo` | RAIS/Base dos Dados | Variável usada para classificar o vínculo como celetista, estatutário, outros ou não mapeado. |
| `vinculo_ativo_3112` | RAIS/Base dos Dados | Indica se o vínculo estava ativo em 31 de dezembro. |
| `valor_remuneracao_media` | RAIS/Base dos Dados | Remuneração média usada para calcular médias, medianas, percentis, KDE e gaps. |
| `grau_instrucao_apos_2005` | RAIS/Base dos Dados | Escolaridade original usada para construir os recortes educacionais. |
| `sexo` | RAIS/Base dos Dados | Variável original usada para construir o recorte `sexo_grupo`. |

### Variáveis derivadas usadas nos recortes

| Variável | Definição | Uso |
|---|---|---|
| `regime_vinculo` | Classificação de `tipo_vinculo` em celetista, estatutário, outros, ausente ou não mapeado. | Define a comparação central do projeto. |
| `situacao_3112` | Classificação de `vinculo_ativo_3112` em ativo, não ativo, ausente ou não mapeado. | Filtra vínculos ativos em 31/12 no processamento dos gráficos. |
| `status_remuneracao_media` | Classificação da remuneração como ausente, zero, positiva, negativa ou não mapeada. | Diagnóstico da base de remuneração. |
| `regiao` | Região geográfica derivada de `sigla_uf`. | Recortes Brasil/Região/UF. |
| `sexo_grupo` | Recodificação de `sexo` em Feminino, Masculino ou Sexo não informado. | Recorte demográfico por sexo. |
| `escolaridade_detalhada` | Recodificação detalhada de `grau_instrucao_apos_2005`. | Recorte educacional principal dos gráficos por escolaridade. |
| `escolaridade_detalhada_ordem` | Código numérico da escolaridade detalhada. | Ordena categorias educacionais e seleciona os níveis usados nos gráficos. |
| `escolaridade_etapa` | Agregação intermediária da escolaridade detalhada. | Recortes alternativos de escolaridade. |
| `escolaridade_macro` | Agregação ampla da escolaridade detalhada. | Recortes agregados de escolaridade. |
| `nivel_geografico` | Brasil, Região ou UF. | Identifica o nível do recorte geográfico. |
| `recorte_geografico` | Nome do recorte geográfico específico. | Rótulos e agrupamentos dos gráficos. |
| `tipo_recorte_demografico` | Geral ou sexo. | Identifica se há recorte demográfico. |
| `grupo_demografico` | Todos, Masculino, Feminino ou Sexo não informado. | Rótulos e agrupamentos demográficos. |
| `tipo_recorte_escolaridade` | Geral, escolaridade macro ou escolaridade detalhada. | Identifica o tipo de recorte educacional. |
| `escolaridade_recorte` | Categoria de escolaridade dentro do recorte. | Rótulos e agrupamentos educacionais. |
| `regime_label` | Rótulo legível de `regime_vinculo`. | Legendas dos gráficos. |

### Variáveis estimadas no processamento de percentis

| Variável | Definição | Uso |
|---|---|---|
| `n_vinculos_grupo` | Número de vínculos no grupo analítico. | Diagnóstico e filtro mínimo de grupo. |
| `percentil` | Índice do percentil, de 1 a 100. | Eixo horizontal dos gráficos de distribuição. |
| `probabilidade_quantil` | Probabilidade associada ao percentil. | Define o quantil estimado. |
| `remuneracao_percentil` | Quantil estimado da remuneração média no grupo. | Principal série dos gráficos. |
| `remuneracao_media` | Média da remuneração no grupo. | Estatística descritiva. |
| `remuneracao_mediana` | Mediana da remuneração no grupo. | Estatística descritiva e legenda. |
| `p01`, `p05`, `p10`, `p25`, `p75`, `p90`, `p95`, `p99` | Quantis auxiliares da remuneração. | Diagnósticos e resumos. |
| `remuneracao_kde` | Ponto do eixo salarial usado na KDE. | Gráficos de densidade. |
| `densidade_kde` | Densidade estimada por kernel. | Gráficos de densidade. |

### Variáveis estimadas no cálculo do gap

| Variável | Definição | Uso |
|---|---|---|
| `renda_celetista` | Percentil salarial dos celetistas no percentil $p$. | Base do cálculo do gap. |
| `renda_estatutario` | Percentil salarial dos estatutários no percentil $p$. | Base do cálculo do gap. |
| `gap_abs` | Diferença absoluta entre estatutários e celetistas. | Mede diferença em reais. |
| `gap_rel` | Diferença relativa em proporção. | Forma proporcional do gap. |
| `gap_rel_pct` | Diferença relativa em percentual. | Principal medida dos gráficos de gap. |
| `gap_log` | Diferença entre log dos percentis salariais. | Aproxima diferença percentual para valores pequenos. |
| `ratio_estatutario_celetista` | Razão entre percentil estatutário e percentil celetista. | Mede quantas vezes a remuneração estatutária equivale à celetista. |
| `gap_rel_pct_p50` | Gap percentual na mediana. | Resumo interpretável do centro da distribuição. |
| `gap_rel_pct_p100` | Gap percentual no ponto p99,5. | Resumo do topo da distribuição. |
| `gap_rel_pct_medio_percentis` | Média dos gaps percentuais ao longo dos percentis. | Síntese da diferença ao longo da curva. |

## Observações de reprodutibilidade

- O projeto foi ajustado para não conter caminhos locais pessoais.
- O `billing_id`/projeto de cobrança do BigQuery deve ser configurado pelo usuário via `RAIS_BILLING_PROJECT`.
- Os scripts salvam resultados a partir da raiz local do repositório, isto é, da pasta criada pelo `git clone`.
- Os arquivos de saída podem ser grandes e estão ignorados no `.gitignore`; não versione Parquets, DTAs, DuckDBs, CSVs ou gráficos gerados diretamente no GitHub.
