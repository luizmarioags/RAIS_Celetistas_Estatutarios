# ============================================================
# RAIS 2025 - Gráficos de escolaridade por regime + gap salarial
#
# Entrada:
#   rais_2025_bases_graficos_percentis/base_percentis_salariais_recortes_rais_2025.dta
#
# Este script substitui/corrige o RAIS_BD_Graph(1).R para reproduzir
# a lógica dos scripts Stata:
#   1) Grafico_Escolaridade_Regime.do:
#      - dois gráficos separados, um para celetistas e outro para estatutários;
#      - cada gráfico contém as cinco curvas de escolaridade:
#        Fundamental completo, Ensino Médio completo, Ensino Superior completo,
#        Mestrado e Doutorado.
#
#   2) gap_salarial_regime_escolaridade.do:
#      - calcula o gap estatutários x celetistas no geral e por escolaridade;
#      - plota o gap por percentil;
#      - plota KDE do gap percentual e KDE do log-gap;
#      - salva bases, logs e resumo.
#
# Fórmulas:
#   gap_abs_p     = R_est,p - R_cel,p
#   gap_rel_p     = (R_est,p - R_cel,p) / R_cel,p
#   gap_rel_pct_p = 100 * gap_rel_p
#   gap_log_p     = log(R_est,p) - log(R_cel,p)
# ============================================================


# ------------------------------------------------------------
# 1. Pacotes
# ------------------------------------------------------------

pacotes <- c(
  "data.table",
  "haven",
  "ggplot2",
  "ggthemes",
  "scales",
  "stringi",
  "glue"
)

faltantes <- setdiff(pacotes, rownames(installed.packages()))

if (length(faltantes) > 0L) {
  install.packages(faltantes)
}

invisible(lapply(pacotes, library, character.only = TRUE))


# ------------------------------------------------------------
# 2. Configurações gerais
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

ano_alvo <- 2025L

dir_base <- detectar_raiz_repositorio()

dir_in <- file.path(
  dir_base,
  "rais_2025_bases_graficos_percentis"
)

arquivo_dta <- file.path(
  dir_in,
  "base_percentis_salariais_recortes_rais_2025.dta"
)

# Saídas dos gráficos de escolaridade por regime.
dir_esc <- file.path(
  dir_in,
  "figuras_R_escolaridade_regime"
)

dir_esc_png <- file.path(dir_esc, "png")
dir_esc_pdf <- file.path(dir_esc, "pdf")
dir_esc_base <- file.path(dir_esc, "bases")

# Saídas dos gráficos de gap.
dir_gap <- file.path(
  dir_in,
  "gap_estatutarios_celetistas_geral_escolaridade_R"
)

dir_gap_pct <- file.path(dir_gap, "gap_percentil")
dir_gap_kde <- file.path(dir_gap, "gap_kde")
dir_gap_kde_ln <- file.path(dir_gap, "gap_kde_ln")
dir_gap_base <- file.path(dir_gap, "bases")
dir_gap_log <- file.path(dir_gap, "logs")

dirs_criar <- c(
  dir_esc,
  dir_esc_png,
  dir_esc_pdf,
  dir_esc_base,
  dir_gap,
  dir_gap_pct,
  dir_gap_kde,
  dir_gap_kde_ln,
  dir_gap_base,
  dir_gap_log
)

invisible(lapply(dirs_criar, dir.create, recursive = TRUE, showWarnings = FALSE))

# Opções de saída.
exportar_png <- TRUE
exportar_pdf <- TRUE
exportar_dta <- TRUE

largura_grafico <- 11
altura_grafico_esc <- 7.5
altura_grafico_gap <- 8.6
dpi_grafico <- 300

# Se TRUE, o script para caso falte alguma das cinco categorias
# em algum regime no gráfico de escolaridade.
exigir_todas_categorias <- TRUE

# Tamanho mínimo do grupo para manter a linha.
min_n_linha <- 1L


# ------------------------------------------------------------
# 3. Funções auxiliares
# ------------------------------------------------------------

as_num <- function(x) {
  if (inherits(x, "haven_labelled")) {
    x <- haven::zap_labels(x)
  }

  if (is.factor(x)) {
    x <- as.character(x)
  }

  if (is.character(x)) {
    x <- gsub(",", ".", x, fixed = TRUE)
  }

  suppressWarnings(as.numeric(x))
}

as_chr <- function(x) {
  if (inherits(x, "haven_labelled")) {
    x <- haven::as_factor(x)
  }

  trimws(as.character(x))
}

mean_na <- function(x) {
  x <- x[!is.na(x)]

  if (length(x) == 0L) {
    return(NA_real_)
  }

  mean(x)
}

max_na <- function(x) {
  x <- x[!is.na(x)]

  if (length(x) == 0L) {
    return(NA_real_)
  }

  max(x)
}

first_na <- function(x) {
  x <- x[!is.na(x)]

  if (length(x) == 0L) {
    return(NA_real_)
  }

  x[1L]
}

limpar_nome_arquivo <- function(x) {
  x <- stringi::stri_trans_general(x, "Latin-ASCII")
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x
}

formatar_real <- function(x) {
  scales::label_number(
    big.mark = ".",
    decimal.mark = ",",
    accuracy = 1,
    prefix = "R$ "
  )(x)
}

formatar_pct <- function(x) {
  scales::label_number(
    big.mark = ".",
    decimal.mark = ",",
    accuracy = 0.1,
    suffix = "%"
  )(x)
}

formatar_num <- function(x, accuracy = 0.1) {
  scales::label_number(
    big.mark = ".",
    decimal.mark = ",",
    accuracy = accuracy
  )(x)
}

checar_variaveis <- function(dt, vars, contexto = "base") {
  faltantes <- setdiff(vars, names(dt))

  if (length(faltantes) > 0L) {
    stop(
      sprintf(
        "Variáveis obrigatórias ausentes em %s: %s",
        contexto,
        paste(faltantes, collapse = ", ")
      ),
      call. = FALSE
    )
  }

  invisible(TRUE)
}

filtrar_coluna_todos <- function(dt, coluna) {
  if (!coluna %in% names(dt)) {
    return(dt)
  }

  valores <- unique(dt[[coluna]])

  if ("Todos" %in% valores) {
    return(dt[get(coluna) == "Todos"])
  }

  dt
}

salvar_grafico <- function(p, dir_png, dir_pdf, arquivo_base, width, height, dpi = 300) {
  if (exportar_png) {
    ggplot2::ggsave(
      filename = file.path(dir_png, paste0(arquivo_base, ".png")),
      plot = p,
      width = width,
      height = height,
      dpi = dpi
    )
  }

  if (exportar_pdf) {
    ggplot2::ggsave(
      filename = file.path(dir_pdf, paste0(arquivo_base, ".pdf")),
      plot = p,
      width = width,
      height = height
    )
  }

  invisible(TRUE)
}

tema_rais <- function() {
  ggthemes::theme_stata(base_size = 11) +
    theme(
      plot.title = element_text(face = "bold", color = "black"),
      plot.subtitle = element_text(size = 10, color = "grey30"),
      plot.caption = element_text(size = 8.5, hjust = 0, color = "grey35"),
      axis.title = element_text(color = "black"),
      axis.text = element_text(color = "black"),
      legend.title = element_blank(),
      legend.key = element_blank(),
      panel.grid.minor = element_blank()
    )
}

nota_dinamica_gap <- function(valor, percentil_label) {
  if (is.na(valor)) {
    return(paste0("No ", percentil_label, ", não há par celetista/estatutário disponível."))
  }

  valor_abs <- abs(valor)
  valor_fmt <- formatar_num(valor_abs, accuracy = 0.1)

  if (valor > 0) {
    return(paste0("No ", percentil_label, ", estatutários recebem ", valor_fmt, "% a mais que celetistas."))
  }

  if (valor < 0) {
    return(paste0("No ", percentil_label, ", estatutários recebem ", valor_fmt, "% a menos que celetistas."))
  }

  paste0("No ", percentil_label, ", estatutários e celetistas têm a mesma remuneração.")
}


# ------------------------------------------------------------
# 4. Ler base
# ------------------------------------------------------------

if (!file.exists(arquivo_dta)) {
  stop(
    paste0(
      "Base de percentis não encontrada:\n",
      arquivo_dta
    ),
    call. = FALSE
  )
}

base <- haven::read_dta(arquivo_dta)
base <- data.table::as.data.table(base)

vars_obrigatorias <- c(
  "ano",
  "nivel_geografico",
  "recorte_geografico",
  "tipo_recorte_demografico",
  "grupo_demografico",
  "tipo_recorte_escolaridade",
  "escolaridade_recorte_ordem",
  "escolaridade_recorte",
  "regime_vinculo",
  "percentil",
  "probabilidade_quantil",
  "remuneracao_percentil",
  "n_vinculos_grupo"
)

checar_variaveis(base, vars_obrigatorias, "base de percentis")

# Padronização defensiva dos tipos.
cols_char <- intersect(
  c(
    "nivel_geografico",
    "recorte_geografico",
    "tipo_recorte_demografico",
    "sexo_recorte",
    "raca_recorte",
    "grupo_demografico",
    "tipo_recorte_escolaridade",
    "escolaridade_recorte",
    "regime_vinculo"
  ),
  names(base)
)

base[
  ,
  (cols_char) := lapply(.SD, as_chr),
  .SDcols = cols_char
]

cols_num <- intersect(
  c(
    "ano",
    "escolaridade_recorte_ordem",
    "percentil",
    "probabilidade_quantil",
    "remuneracao_percentil",
    "n_vinculos_grupo"
  ),
  names(base)
)

base[
  ,
  (cols_num) := lapply(.SD, as_num),
  .SDcols = cols_num
]


# ============================================================
# PARTE A - Gráficos corrigidos de escolaridade por regime
# ============================================================

# ------------------------------------------------------------
# A.1. Filtro analítico
# ------------------------------------------------------------

base_esc <- data.table::copy(base)

base_esc <- base_esc[
  ano == ano_alvo &
    nivel_geografico == "Brasil" &
    recorte_geografico == "Brasil" &
    tipo_recorte_demografico == "geral" &
    grupo_demografico == "Todos" &
    regime_vinculo %in% c("celetista", "estatutario") &
    tipo_recorte_escolaridade == "escolaridade_detalhada" &
    !is.na(percentil) &
    !is.na(remuneracao_percentil) &
    !is.na(n_vinculos_grupo)
]

# Se a base tiver colunas explícitas de sexo/raça com categoria "Todos",
# mantemos o recorte geral para evitar duplicação.
base_esc <- filtrar_coluna_todos(base_esc, "sexo_recorte")
base_esc <- filtrar_coluna_todos(base_esc, "raca_recorte")

base_esc <- base_esc[
  percentil >= 1 &
    percentil <= 100 &
    n_vinculos_grupo >= min_n_linha
]

# ------------------------------------------------------------
# A.2. Categorias finais
# ------------------------------------------------------------
# Códigos usados no processamento R corrigido:
#   5  = Fundamental completo
#   7  = Ensino Médio completo
#   9  = Ensino Superior completo
#   10 = Mestrado
#   11 = Doutorado
# Usar a ordem é mais robusto do que buscar texto do rótulo.

base_esc[
  ,
  cat_ordem := data.table::fcase(
    escolaridade_recorte_ordem == 5, 1L,
    escolaridade_recorte_ordem == 7, 2L,
    escolaridade_recorte_ordem == 9, 3L,
    escolaridade_recorte_ordem == 10, 4L,
    escolaridade_recorte_ordem == 11, 5L,
    default = NA_integer_
  )
]

base_esc[
  ,
  categoria_esc := data.table::fcase(
    cat_ordem == 1L, "Fundamental completo",
    cat_ordem == 2L, "Ensino Médio completo",
    cat_ordem == 3L, "Ensino Superior completo",
    cat_ordem == 4L, "Mestrado",
    cat_ordem == 5L, "Doutorado",
    default = NA_character_
  )
]

base_esc[
  ,
  label_curto := data.table::fcase(
    cat_ordem == 1L, "Fundamental",
    cat_ordem == 2L, "Médio",
    cat_ordem == 3L, "Superior",
    cat_ordem == 4L, "Mestrado",
    cat_ordem == 5L, "Doutorado",
    default = NA_character_
  )
]

base_esc <- base_esc[!is.na(cat_ordem)]

ordem_categorias <- c(
  "Fundamental completo",
  "Ensino Médio completo",
  "Ensino Superior completo",
  "Mestrado",
  "Doutorado"
)

labels_curtos <- c(
  "Fundamental completo" = "Fundamental",
  "Ensino Médio completo" = "Médio",
  "Ensino Superior completo" = "Superior",
  "Mestrado" = "Mestrado",
  "Doutorado" = "Doutorado"
)

cores_escolaridade <- c(
  "Fundamental completo" = "grey45",
  "Ensino Médio completo" = "#3E7CB1",
  "Ensino Superior completo" = "#228B22",
  "Mestrado" = "#D95F02",
  "Doutorado" = "#6A3D9A"
)

base_esc[
  ,
  categoria_esc := factor(
    categoria_esc,
    levels = ordem_categorias
  )
]

# Diagnóstico das categorias detectadas.
diagnostico_esc <- unique(
  base_esc[
    ,
    .(
      regime_vinculo,
      cat_ordem,
      categoria_esc,
      escolaridade_recorte_ordem,
      escolaridade_recorte
    )
  ]
)

data.table::setorder(
  diagnostico_esc,
  regime_vinculo,
  cat_ordem,
  escolaridade_recorte_ordem,
  escolaridade_recorte
)

data.table::fwrite(
  diagnostico_esc,
  file.path(dir_esc_base, "diagnostico_categorias_escolaridade_graficos_R.csv"),
  sep = ";"
)

# Checagem de categorias esperadas por regime.
grid_esperado <- data.table::CJ(
  regime_vinculo = c("celetista", "estatutario"),
  cat_ordem = 1:5
)

categorias_existentes <- unique(
  base_esc[
    ,
    .(regime_vinculo, cat_ordem)
  ]
)

faltantes_cat <- grid_esperado[
  !categorias_existentes,
  on = .(regime_vinculo, cat_ordem)
]

if (nrow(faltantes_cat) > 0L) {
  data.table::fwrite(
    faltantes_cat,
    file.path(dir_esc_base, "categorias_faltantes_escolaridade_regime_R.csv"),
    sep = ";"
  )

  msg_faltantes <- paste(
    apply(faltantes_cat, 1, paste, collapse = " | "),
    collapse = "\n"
  )

  if (isTRUE(exigir_todas_categorias)) {
    stop(
      paste0(
        "Uma ou mais categorias esperadas não existem na base filtrada.\n",
        "Veja: ",
        file.path(dir_esc_base, "categorias_faltantes_escolaridade_regime_R.csv"),
        "\n",
        msg_faltantes
      ),
      call. = FALSE
    )
  } else {
    warning(
      paste0(
        "Uma ou mais categorias esperadas não existem na base filtrada.\n",
        msg_faltantes
      ),
      call. = FALSE
    )
  }
}

# Segurança contra duplicatas residuais:
# deve haver uma linha por regime, categoria e percentil.
base_esc_plot <- base_esc[
  ,
  .(
    remuneracao_percentil = mean_na(remuneracao_percentil),
    n_vinculos_grupo = max_na(n_vinculos_grupo)
  ),
  by = .(
    regime_vinculo,
    cat_ordem,
    categoria_esc,
    label_curto,
    percentil
  )
]

# Medianas por regime e categoria.
medianas_esc <- base_esc_plot[
  percentil == 50,
  .(
    mediana_grupo = mean_na(remuneracao_percentil)
  ),
  by = .(
    regime_vinculo,
    cat_ordem,
    categoria_esc,
    label_curto
  )
]

medianas_esc[
  ,
  `:=`(
    mediana_int = round(mediana_grupo, 0),
    mediana_str = formatar_real(mediana_grupo)
  )
]

data.table::fwrite(
  medianas_esc[
    order(regime_vinculo, cat_ordem)
  ],
  file.path(dir_esc_base, "tabela_medianas_escolaridade_regime_R.csv"),
  sep = ";"
)

# Escala comum do eixo Y para os dois gráficos.
ymax_global_esc <- ceiling(max(base_esc_plot$remuneracao_percentil, na.rm = TRUE) / 10000) * 10000

if (!is.finite(ymax_global_esc) || ymax_global_esc < 20000) {
  ymax_global_esc <- 20000
}

# ------------------------------------------------------------
# A.3. Função de gráfico por regime
# ------------------------------------------------------------

gerar_grafico_escolaridade_regime <- function(regime, titulo, arquivo_base) {
  dt <- data.table::copy(base_esc_plot[regime_vinculo == regime])

  data.table::setorder(dt, cat_ordem, percentil)

  med <- medianas_esc[regime_vinculo == regime]

  labels_legenda <- setNames(
    paste0(
      med$label_curto,
      " - mediana ",
      formatar_real(med$mediana_grupo)
    ),
    as.character(med$categoria_esc)
  )

  dt[
    ,
    categoria_esc := factor(
      as.character(categoria_esc),
      levels = ordem_categorias
    )
  ]

  p <- ggplot(
    dt,
    aes(
      x = percentil,
      y = remuneracao_percentil,
      color = categoria_esc,
      group = categoria_esc
    )
  ) +
    geom_line(
      linewidth = 1.05,
      alpha = 0.96,
      na.rm = TRUE
    ) +
    geom_vline(
      xintercept = 50,
      linetype = "dashed",
      color = "grey55",
      linewidth = 0.4
    ) +
    annotate(
      "text",
      x = 50,
      y = ymax_global_esc * 0.96,
      label = "50% (mediana)",
      hjust = -0.05,
      vjust = 0.5,
      size = 3.0,
      color = "grey35"
    ) +
    scale_color_manual(
      values = cores_escolaridade,
      breaks = ordem_categorias,
      labels = labels_legenda[ordem_categorias],
      drop = FALSE
    ) +
    scale_x_continuous(
      breaks = c(0, 25, 50, 75, 100),
      limits = c(0, 100),
      expand = expansion(mult = c(0.01, 0.01))
    ) +
    scale_y_continuous(
      labels = scales::label_number(
        big.mark = ".",
        decimal.mark = ",",
        accuracy = 1
      ),
      breaks = seq(0, ymax_global_esc, by = 10000),
      limits = c(0, ymax_global_esc),
      expand = expansion(mult = c(0, 0.02))
    ) +
    labs(
      title = titulo,
      subtitle = "Percentil da remuneração média - vínculos ativos, RAIS 2025",
      x = "Percentil",
      y = "Remuneração média (R$)",
      color = NULL,
      caption = paste0(
        "Valores na legenda correspondem à mediana de cada curva.\n",
        "Fonte: RAIS 2025 via Base dos Dados."
      )
    ) +
    tema_rais() +
    theme(
      legend.position = "bottom",
      legend.box = "horizontal",
      legend.text = element_text(size = 8.5),
      plot.margin = margin(t = 10, r = 15, b = 10, l = 10)
    ) +
    guides(
      color = guide_legend(
        nrow = 3,
        byrow = TRUE,
        override.aes = list(linewidth = 1.3)
      )
    )

  salvar_grafico(
    p = p,
    dir_png = dir_esc_png,
    dir_pdf = dir_esc_pdf,
    arquivo_base = arquivo_base,
    width = largura_grafico,
    height = altura_grafico_esc,
    dpi = dpi_grafico
  )

  base_export <- dt[
    order(cat_ordem, percentil)
  ]

  data.table::fwrite(
    base_export,
    file.path(dir_esc_base, paste0("base_", arquivo_base, ".csv")),
    sep = ";"
  )

  if (isTRUE(exportar_dta)) {
    haven::write_dta(
      as.data.frame(base_export),
      file.path(dir_esc_base, paste0("base_", arquivo_base, ".dta"))
    )
  }

  invisible(p)
}

grafico_cel <- gerar_grafico_escolaridade_regime(
  regime = "celetista",
  titulo = "Distribuição salarial por escolaridade - Celetistas",
  arquivo_base = "distribuicao_salarial_escolaridade_celetistas_R"
)

grafico_est <- gerar_grafico_escolaridade_regime(
  regime = "estatutario",
  titulo = "Distribuição salarial por escolaridade - Estatutários",
  arquivo_base = "distribuicao_salarial_escolaridade_estatutarios_R"
)


# ============================================================
# PARTE B - Cálculo e gráficos do gap salarial
# ============================================================

# ------------------------------------------------------------
# B.1. Tabela dos recortes do gap
# ------------------------------------------------------------

recortes_gap <- data.table::data.table(
  grupo_id = c(
    "geral",
    "fundamental_completo",
    "ensino_medio_completo",
    "ensino_superior_completo",
    "mestrado",
    "doutorado"
  ),
  grupo_titulo = c(
    "Geral - todas as escolaridades",
    "Fundamental completo",
    "Ensino Médio completo",
    "Ensino Superior completo",
    "Mestrado",
    "Doutorado"
  ),
  escolaridade_ordem = c(0L, 5L, 7L, 9L, 10L, 11L),
  ordem_grafico = c(0L, 1L, 2L, 3L, 4L, 5L)
)

data.table::fwrite(
  recortes_gap,
  file.path(dir_gap_base, "recortes_gap_processados_R.csv"),
  sep = ";"
)


# ------------------------------------------------------------
# B.2. Função de cálculo do gap
# ------------------------------------------------------------

calcular_gap_recorte <- function(base, recorte) {
  id <- recorte$grupo_id
  titulo <- recorte$grupo_titulo
  esc_ordem <- recorte$escolaridade_ordem
  ordem <- recorte$ordem_grafico

  dt <- data.table::copy(base)

  dt <- dt[
    ano == ano_alvo &
      nivel_geografico == "Brasil" &
      recorte_geografico == "Brasil" &
      tipo_recorte_demografico == "geral" &
      grupo_demografico == "Todos"
  ]

  dt <- filtrar_coluna_todos(dt, "sexo_recorte")
  dt <- filtrar_coluna_todos(dt, "raca_recorte")

  if (esc_ordem == 0L) {
    dt <- dt[tipo_recorte_escolaridade == "geral"]
  } else {
    dt <- dt[
      tipo_recorte_escolaridade == "escolaridade_detalhada" &
        escolaridade_recorte_ordem == esc_ordem
    ]
  }

  dt <- dt[
    regime_vinculo %in% c("celetista", "estatutario") &
      !is.na(percentil) &
      !is.na(remuneracao_percentil)
  ]

  n_filtro <- nrow(dt)

  if (n_filtro == 0L) {
    return(
      list(
        status = "VAZIO",
        log = data.table::data.table(
          grupo_id = id,
          grupo_titulo = titulo,
          status = "VAZIO",
          n_linhas_filtro = n_filtro,
          n_percentis_gap = 0L,
          mensagem = "Nenhuma observação após filtros"
        ),
        base = NULL,
        resumo = NULL
      )
    )
  }

  dt <- dt[
    percentil >= 1 &
      percentil <= 100
  ]

  dt_collapse <- dt[
    ,
    .(
      remuneracao_percentil = mean_na(remuneracao_percentil),
      n_vinculos_grupo = max_na(n_vinculos_grupo)
    ),
    by = .(
      percentil,
      probabilidade_quantil,
      regime_vinculo
    )
  ]

  regimes <- sort(unique(dt_collapse$regime_vinculo))

  if (!"celetista" %in% regimes) {
    return(
      list(
        status = "SEM_CELETISTA",
        log = data.table::data.table(
          grupo_id = id,
          grupo_titulo = titulo,
          status = "SEM_CELETISTA",
          n_linhas_filtro = n_filtro,
          n_percentis_gap = 0L,
          mensagem = "Sem celetistas no recorte"
        ),
        base = NULL,
        resumo = NULL
      )
    )
  }

  if (!"estatutario" %in% regimes) {
    return(
      list(
        status = "SEM_ESTATUTARIO",
        log = data.table::data.table(
          grupo_id = id,
          grupo_titulo = titulo,
          status = "SEM_ESTATUTARIO",
          n_linhas_filtro = n_filtro,
          n_percentis_gap = 0L,
          mensagem = "Sem estatutários no recorte"
        ),
        base = NULL,
        resumo = NULL
      )
    )
  }

  wide <- data.table::dcast(
    dt_collapse,
    percentil + probabilidade_quantil ~ regime_vinculo,
    value.var = c("remuneracao_percentil", "n_vinculos_grupo")
  )

  nomes_necessarios <- c(
    "remuneracao_percentil_celetista",
    "remuneracao_percentil_estatutario",
    "n_vinculos_grupo_celetista",
    "n_vinculos_grupo_estatutario"
  )

  checar_variaveis(wide, nomes_necessarios, paste0("gap recorte ", id))

  data.table::setnames(
    wide,
    old = nomes_necessarios,
    new = c(
      "renda_celetista",
      "renda_estatutario",
      "n_celetistas",
      "n_estatutarios"
    )
  )

  wide <- wide[
    !is.na(renda_celetista) &
      !is.na(renda_estatutario)
  ]

  n_pares <- nrow(wide)

  if (n_pares == 0L) {
    return(
      list(
        status = "SEM_PARES",
        log = data.table::data.table(
          grupo_id = id,
          grupo_titulo = titulo,
          status = "SEM_PARES",
          n_linhas_filtro = n_filtro,
          n_percentis_gap = 0L,
          mensagem = "Sem percentis com os dois regimes simultaneamente"
        ),
        base = NULL,
        resumo = NULL
      )
    )
  }

  wide[
    ,
    `:=`(
      gap_abs = renda_estatutario - renda_celetista,
      gap_rel = data.table::fifelse(
        renda_celetista > 0,
        (renda_estatutario - renda_celetista) / renda_celetista,
        NA_real_
      ),
      gap_rel_pct = data.table::fifelse(
        renda_celetista > 0,
        100 * (renda_estatutario - renda_celetista) / renda_celetista,
        NA_real_
      ),
      gap_log = data.table::fifelse(
        renda_estatutario > 0 & renda_celetista > 0,
        log(renda_estatutario) - log(renda_celetista),
        NA_real_
      ),
      ratio_estatutario_celetista = data.table::fifelse(
        renda_celetista > 0,
        renda_estatutario / renda_celetista,
        NA_real_
      ),
      grupo_id = id,
      grupo_titulo = titulo,
      escolaridade_recorte_ordem = esc_ordem,
      ordem_grafico = ordem
    )
  ]

  data.table::setcolorder(
    wide,
    c(
      "grupo_id",
      "grupo_titulo",
      "escolaridade_recorte_ordem",
      "ordem_grafico",
      "percentil",
      "probabilidade_quantil",
      "renda_celetista",
      "renda_estatutario",
      "n_celetistas",
      "n_estatutarios",
      "gap_abs",
      "gap_rel",
      "gap_rel_pct",
      "gap_log",
      "ratio_estatutario_celetista"
    )
  )

  data.table::setorder(wide, percentil)

  resumo <- wide[
    ,
    {
      i50 <- percentil == 50
      i100 <- percentil == 100

      .(
        grupo_id = id,
        escolaridade = titulo,
        ordem_grafico = ordem,
        renda_celetista_p50 = first_na(renda_celetista[i50]),
        renda_estatutario_p50 = first_na(renda_estatutario[i50]),
        gap_abs_p50 = first_na(gap_abs[i50]),
        gap_rel_pct_p50 = first_na(gap_rel_pct[i50]),
        ratio_p50 = first_na(ratio_estatutario_celetista[i50]),
        renda_celetista_p100 = first_na(renda_celetista[i100]),
        renda_estatutario_p100 = first_na(renda_estatutario[i100]),
        gap_abs_p100 = first_na(gap_abs[i100]),
        gap_rel_pct_p100 = first_na(gap_rel_pct[i100]),
        ratio_p100 = first_na(ratio_estatutario_celetista[i100]),
        gap_rel_pct_medio_percentis = mean_na(gap_rel_pct),
        n_celetistas = max_na(n_celetistas),
        n_estatutarios = max_na(n_estatutarios)
      )
    }
  ]

  log_dt <- data.table::data.table(
    grupo_id = id,
    grupo_titulo = titulo,
    status = "OK",
    n_linhas_filtro = n_filtro,
    n_percentis_gap = n_pares,
    mensagem = "Processado com sucesso"
  )

  list(
    status = "OK",
    log = log_dt,
    base = wide,
    resumo = resumo
  )
}


# ------------------------------------------------------------
# B.3. Funções de plot do gap
# ------------------------------------------------------------

plotar_gap_percentil <- function(dt) {
  dt <- data.table::copy(dt)

  titulo <- unique(dt$grupo_titulo)[1]
  id <- unique(dt$grupo_id)[1]

  ymin <- floor(min(dt$gap_rel_pct, na.rm = TRUE) / 10) * 10
  ymax <- ceiling(max(dt$gap_rel_pct, na.rm = TRUE) / 10) * 10

  if (!is.finite(ymin)) {
    ymin <- -10
  }

  if (!is.finite(ymax)) {
    ymax <- 10
  }

  if (ymin > -10) {
    ymin <- -10
  }

  if (ymax < 10) {
    ymax <- 10
  }

  gapp50 <- first_na(dt$gap_rel_pct[dt$percentil == 50])
  gapp100 <- first_na(dt$gap_rel_pct[dt$percentil == 100])

  nota_p50 <- nota_dinamica_gap(gapp50, "percentil 50")
  nota_p100 <- nota_dinamica_gap(gapp100, "percentil 100 (p99,5)")

  p <- ggplot(
    dt,
    aes(
      x = percentil,
      y = gap_rel_pct
    )
  ) +
    geom_hline(
      yintercept = 0,
      linetype = "dashed",
      color = "black",
      linewidth = 0.45
    ) +
    geom_line(
      color = "navy",
      linewidth = 1.05,
      na.rm = TRUE
    ) +
    geom_point(
      color = "#9E2A2B",
      size = 1.6,
      alpha = 0.9,
      na.rm = TRUE
    ) +
    scale_x_continuous(
      breaks = c(1, seq(10, 100, by = 10)),
      limits = c(1, 100),
      expand = expansion(mult = c(0.01, 0.01))
    ) +
    scale_y_continuous(
      labels = scales::label_number(
        big.mark = ".",
        decimal.mark = ",",
        accuracy = 0.1
      ),
      limits = c(ymin, ymax),
      expand = expansion(mult = c(0.02, 0.04))
    ) +
    labs(
      title = "Gap estatutários x celetistas",
      subtitle = paste0(
        titulo,
        "\n",
        "Fórmula: \u0394p = 100 \u00b7 (Rest,p - Rcel,p) / Rcel,p"
      ),
      x = "Percentil da remuneração",
      y = "Gap relativo (%)",
      caption = paste0(
        nota_p50,
        "\n",
        nota_p100,
        "\n",
        "Fonte: RAIS 2025 via Base dos Dados."
      )
    ) +
    tema_rais() +
    theme(
      legend.position = "none",
      panel.grid.major = element_line(color = "grey85", linetype = "dashed", linewidth = 0.25),
      plot.margin = margin(t = 12, r = 20, b = 16, l = 20)
    )

  arquivo <- paste0("gap_percentil__", limpar_nome_arquivo(id))

  salvar_grafico(
    p = p,
    dir_png = dir_gap_pct,
    dir_pdf = dir_gap_pct,
    arquivo_base = arquivo,
    width = largura_grafico,
    height = altura_grafico_gap,
    dpi = dpi_grafico
  )

  invisible(p)
}

plotar_kde_gap <- function(dt, variavel, titulo_plot, subtitulo, eixo_x, arquivo_prefixo, dir_saida) {
  dt <- data.table::copy(dt)

  id <- unique(dt$grupo_id)[1]
  x <- dt[[variavel]]
  x <- x[!is.na(x)]

  if (length(x) < 5L || max(x) <= min(x)) {
    warning(
      paste0(
        "KDE não gerado para ",
        id,
        ": poucos pontos ou variância zero em ",
        variavel,
        "."
      ),
      call. = FALSE
    )

    return(invisible(NULL))
  }

  dens <- stats::density(
    x,
    n = 300,
    na.rm = TRUE
  )

  dens_dt <- data.table::data.table(
    x = dens$x,
    densidade = dens$y
  )

  p <- ggplot(
    dens_dt,
    aes(
      x = x,
      y = densidade
    )
  ) +
    geom_vline(
      xintercept = 0,
      linetype = "dashed",
      color = "black",
      linewidth = 0.45
    ) +
    geom_line(
      color = "navy",
      linewidth = 1.05,
      na.rm = TRUE
    ) +
    scale_x_continuous(
      labels = scales::label_number(
        big.mark = ".",
        decimal.mark = ",",
        accuracy = 0.1
      )
    ) +
    scale_y_continuous(
      labels = scales::label_number(
        big.mark = ".",
        decimal.mark = ",",
        accuracy = 0.001
      ),
      expand = expansion(mult = c(0, 0.05))
    ) +
    labs(
      title = titulo_plot,
      subtitle = subtitulo,
      x = eixo_x,
      y = "Densidade",
      caption = paste0(
        "KDE: densidade suavizada calculada ao longo dos percentis do recorte.\n",
        "Valores acima de zero indicam estatutários acima dos celetistas; abaixo de zero, o inverso.\n",
        "Fonte: RAIS 2025 via Base dos Dados."
      )
    ) +
    tema_rais() +
    theme(
      legend.position = "none",
      panel.grid.major = element_line(color = "grey85", linetype = "dashed", linewidth = 0.25),
      plot.margin = margin(t = 12, r = 20, b = 16, l = 20)
    )

  arquivo <- paste0(arquivo_prefixo, "__", limpar_nome_arquivo(id))

  salvar_grafico(
    p = p,
    dir_png = dir_saida,
    dir_pdf = dir_saida,
    arquivo_base = arquivo,
    width = largura_grafico,
    height = altura_grafico_gap,
    dpi = dpi_grafico
  )

  invisible(p)
}


# ------------------------------------------------------------
# B.4. Loop de cálculo e geração dos gráficos
# ------------------------------------------------------------

logs_gap <- list()
bases_gap <- list()
resumos_gap <- list()

for (i in seq_len(nrow(recortes_gap))) {
  rec <- recortes_gap[i]

  cat(
    "\nProcessando gap ",
    i,
    " de ",
    nrow(recortes_gap),
    " | ",
    rec$grupo_id,
    "\n",
    sep = ""
  )

  res <- calcular_gap_recorte(
    base = base,
    recorte = rec
  )

  logs_gap[[length(logs_gap) + 1L]] <- res$log

  if (identical(res$status, "OK")) {
    dt_gap <- res$base
    bases_gap[[length(bases_gap) + 1L]] <- dt_gap
    resumos_gap[[length(resumos_gap) + 1L]] <- res$resumo

    arquivo_id <- limpar_nome_arquivo(rec$grupo_id)

    data.table::fwrite(
      dt_gap,
      file.path(dir_gap_base, paste0("gap_percentis__", arquivo_id, ".csv")),
      sep = ";"
    )

    if (isTRUE(exportar_dta)) {
      haven::write_dta(
        as.data.frame(dt_gap),
        file.path(dir_gap_base, paste0("gap_percentis__", arquivo_id, ".dta"))
      )
    }

    plotar_gap_percentil(dt_gap)

    plotar_kde_gap(
      dt = dt_gap,
      variavel = "gap_rel_pct",
      titulo_plot = "KDE do gap estatutários x celetistas",
      subtitulo = rec$grupo_titulo,
      eixo_x = "Gap relativo (%)",
      arquivo_prefixo = "gap_kde",
      dir_saida = dir_gap_kde
    )

    plotar_kde_gap(
      dt = dt_gap,
      variavel = "gap_log",
      titulo_plot = "KDE do log-gap estatutários x celetistas",
      subtitulo = rec$grupo_titulo,
      eixo_x = "ln(Rest,p/Rcel,p)",
      arquivo_prefixo = "gap_kde_ln",
      dir_saida = dir_gap_kde_ln
    )
  }

  gc()
}

log_gap <- data.table::rbindlist(
  logs_gap,
  fill = TRUE
)

data.table::fwrite(
  log_gap,
  file.path(dir_gap_log, "log_gap_estatutarios_celetistas_geral_escolaridade_R.csv"),
  sep = ";"
)

if (length(resumos_gap) > 0L) {
  resumo_gap <- data.table::rbindlist(
    resumos_gap,
    fill = TRUE
  )

  data.table::setorder(
    resumo_gap,
    ordem_grafico,
    grupo_id
  )

  data.table::fwrite(
    resumo_gap,
    file.path(dir_gap_base, "resumo_gap_geral_escolaridade_regime_R.csv"),
    sep = ";"
  )

  if (isTRUE(exportar_dta)) {
    haven::write_dta(
      as.data.frame(resumo_gap),
      file.path(dir_gap_base, "resumo_gap_geral_escolaridade_regime_R.dta")
    )
  }
}

if (length(bases_gap) > 0L) {
  gap_consolidado <- data.table::rbindlist(
    bases_gap,
    fill = TRUE
  )

  data.table::setorder(
    gap_consolidado,
    ordem_grafico,
    grupo_id,
    percentil
  )

  data.table::fwrite(
    gap_consolidado,
    file.path(dir_gap_base, "gap_percentis_geral_e_niveis_R.csv"),
    sep = ";"
  )

  if (isTRUE(exportar_dta)) {
    haven::write_dta(
      as.data.frame(gap_consolidado),
      file.path(dir_gap_base, "gap_percentis_geral_e_niveis_R.dta")
    )
  }

  # Gráfico consolidado opcional: linhas do gap para todos os recortes.
  gap_consolidado[
    ,
    grupo_titulo := factor(
      grupo_titulo,
      levels = recortes_gap$grupo_titulo[order(recortes_gap$ordem_grafico)]
    )
  ]

  p_gap_todos <- ggplot(
    gap_consolidado,
    aes(
      x = percentil,
      y = gap_rel_pct,
      color = grupo_titulo,
      group = grupo_titulo
    )
  ) +
    geom_hline(
      yintercept = 0,
      linetype = "dashed",
      color = "black",
      linewidth = 0.45
    ) +
    geom_line(
      linewidth = 0.9,
      alpha = 0.95,
      na.rm = TRUE
    ) +
    scale_x_continuous(
      breaks = c(1, seq(10, 100, by = 10)),
      limits = c(1, 100),
      expand = expansion(mult = c(0.01, 0.01))
    ) +
    scale_y_continuous(
      labels = scales::label_number(
        big.mark = ".",
        decimal.mark = ",",
        accuracy = 0.1
      )
    ) +
    labs(
      title = "Gap estatutários x celetistas por recorte",
      subtitle = "Gap relativo ao longo dos percentis da remuneração média - RAIS 2025",
      x = "Percentil da remuneração",
      y = "Gap relativo (%)",
      color = NULL,
      caption = paste0(
        "Fórmula: 100 · (Rest,p - Rcel,p) / Rcel,p.\n",
        "Fonte: RAIS 2025 via Base dos Dados."
      )
    ) +
    tema_rais() +
    theme(
      legend.position = "bottom",
      legend.text = element_text(size = 8.5),
      panel.grid.major = element_line(color = "grey85", linetype = "dashed", linewidth = 0.25)
    ) +
    guides(
      color = guide_legend(nrow = 2, byrow = TRUE)
    )

  salvar_grafico(
    p = p_gap_todos,
    dir_png = dir_gap_pct,
    dir_pdf = dir_gap_pct,
    arquivo_base = "gap_percentil__todos_recortes",
    width = largura_grafico,
    height = altura_grafico_gap,
    dpi = dpi_grafico
  )
}


# ------------------------------------------------------------
# 5. Mensagem final
# ------------------------------------------------------------

cat("\nProcesso concluído.\n")
cat("\nGráficos de escolaridade por regime:\n")
cat("PNG:   ", dir_esc_png, "\n", sep = "")
cat("PDF:   ", dir_esc_pdf, "\n", sep = "")
cat("Bases: ", dir_esc_base, "\n", sep = "")

cat("\nGráficos e bases do gap:\n")
cat("Gap por percentil: ", dir_gap_pct, "\n", sep = "")
cat("KDE gap:           ", dir_gap_kde, "\n", sep = "")
cat("KDE log-gap:       ", dir_gap_kde_ln, "\n", sep = "")
cat("Bases:             ", dir_gap_base, "\n", sep = "")
cat("Logs:              ", dir_gap_log, "\n", sep = "")
