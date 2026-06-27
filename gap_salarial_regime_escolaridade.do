/********************************************************************
 Gap estatutários x celetistas geral e por nível educacional - RAIS 2025

 Compatível com o processamento R corrigido da escolaridade.

 Objetivo:
   Calcular e graficar o gap salarial entre estatutários e celetistas ao
   longo dos percentis da remuneração média para:
     - recorte geral, sem filtro de escolaridade;
     - cada nível educacional usado nos gráficos anteriores.

 Recortes usados:
   0  = Geral, todas as escolaridades
   5  = Fundamental completo
   7  = Ensino Médio completo
   9  = Ensino Superior completo
   10 = Mestrado
   11 = Doutorado

 Fórmula do gap percentual:
   Gap_p = 100 * (R_est,p - R_cel,p) / R_cel,p

 Interpretação:
   gap > 0  -> estatutários recebem mais que celetistas no percentil p
   gap < 0  -> estatutários recebem menos que celetistas no percentil p

 Saídas:
   gap_estatutarios_celetistas_geral_escolaridade/
   ├── gap_percentil/
   ├── gap_kde/
   ├── gap_kde_ln/
   ├── bases/
   └── logs/

********************************************************************/

clear all
set more off
set varabbrev off
version 15.1

* ================================================================
* 0. Caminhos
* ================================================================

* Diretório dinâmico: usa RAIS_DIR_BASE se existir; caso contrário,
* assume que o do-file está sendo executado a partir da raiz do repositório.
local root_env : environment RAIS_DIR_BASE
if "`root_env'" == "" {
    local root_env "`c(pwd)'"
}
local root_env = subinstr("`root_env'", char(92), "/", .)

global ROOT "`root_env'/rais_2025_bases_graficos_percentis"
global BASE_PERCENTIS "$ROOT/base_percentis_salariais_recortes_rais_2025.dta"

global OUT "$ROOT/gap_estatutarios_celetistas_geral_escolaridade"
global OUT_PCT    "$OUT/gap_percentil"
global OUT_KDE    "$OUT/gap_kde"
global OUT_KDE_LN "$OUT/gap_kde_ln"
global OUT_BASES  "$OUT/bases"
global OUT_LOGS   "$OUT/logs"

* Limpa pasta antiga para evitar arquivos velhos.
capture shell powershell -NoProfile -Command "if (Test-Path '$OUT') { Remove-Item -Path '$OUT' -Recurse -Force }"

capture mkdir "$OUT"
capture mkdir "$OUT_PCT"
capture mkdir "$OUT_KDE"
capture mkdir "$OUT_KDE_LN"
capture mkdir "$OUT_BASES"
capture mkdir "$OUT_LOGS"

capture erase "$ROOT/gap_estatutarios_celetistas_geral_escolaridade.zip"

* ================================================================
* 1. Tema visual e rótulos
* ================================================================

set scheme s1color
capture graph set window fontface "Arial"

local ZERO_LINE ///
    `"lcolor(black) lpattern(dash) lwidth(medthin)"'

local MULT = uchar(183)

local L_GAP_FORMULA ///
    `"{&Delta}{subscript:p} = 100 `MULT' ({it:R}{superscript:est}{subscript:p} - {it:R}{superscript:cel}{subscript:p})/{it:R}{superscript:cel}{subscript:p}"'

local L_LNGAP_FORMULA ///
    `"ln({it:R}{superscript:est}{subscript:p}/{it:R}{superscript:cel}{subscript:p})"'

local NOTE_SOURCE ///
    `"Fonte: RAIS 2025 via Base dos Dados."'

local NOTE_KDE_GAP_INTERP ///
    `"KDE: densidade suavizada dos gaps percentuais calculados ao longo dos percentis."'

local NOTE_KDE_LNGAP_INTERP ///
    `"KDE: densidade suavizada de ln(R_est,p/R_cel,p) ao longo dos percentis."'

local NOTE_KDE_LNGAP_READING ///
    `"Valores acima de zero indicam estatutários acima dos celetistas; abaixo de zero, o inverso."'

* ================================================================
* 2. Conferir base
* ================================================================

capture confirm file "$BASE_PERCENTIS"
if _rc {
    display as error "Base de percentis não encontrada:"
    display as error "$BASE_PERCENTIS"
    exit 601
}

use "$BASE_PERCENTIS", clear

foreach v in ///
    ano ///
    nivel_geografico ///
    recorte_geografico ///
    tipo_recorte_demografico ///
    sexo_recorte ///
    grupo_demografico ///
    tipo_recorte_escolaridade ///
    escolaridade_recorte_ordem ///
    escolaridade_recorte ///
    regime_vinculo ///
    percentil ///
    probabilidade_quantil ///
    remuneracao_percentil ///
    n_vinculos_grupo {

    capture confirm variable `v'
    if _rc {
        display as error "Variável obrigatória não encontrada: `v'"
        exit 111
    }
}

compress

* ================================================================
* 3. Conferência dos recortes disponíveis
* ================================================================

display as text ""
display as text "Recorte geral disponível na base de entrada, após filtros básicos:"
preserve
    keep if ano == 2025
    keep if nivel_geografico == "Brasil"
    keep if recorte_geografico == "Brasil"
    keep if tipo_recorte_demografico == "geral"
    keep if grupo_demografico == "Todos"
    keep if tipo_recorte_escolaridade == "geral"
    keep if inlist(regime_vinculo, "celetista", "estatutario")
    keep regime_vinculo tipo_recorte_escolaridade escolaridade_recorte_ordem escolaridade_recorte
    duplicates drop
    sort regime_vinculo escolaridade_recorte_ordem
    list, noobs abbreviate(36)
restore

display as text ""
display as text "Escolaridades detalhadas disponíveis na base de entrada, após filtros básicos:"
preserve
    keep if ano == 2025
    keep if nivel_geografico == "Brasil"
    keep if recorte_geografico == "Brasil"
    keep if tipo_recorte_demografico == "geral"
    keep if grupo_demografico == "Todos"
    keep if tipo_recorte_escolaridade == "escolaridade_detalhada"
    keep if inlist(regime_vinculo, "celetista", "estatutario")
    keep regime_vinculo escolaridade_recorte_ordem escolaridade_recorte
    duplicates drop
    sort regime_vinculo escolaridade_recorte_ordem
    list, noobs abbreviate(36)
restore

* ================================================================
* 4. Tabela dos níveis educacionais a processar
* ================================================================

tempfile recortes
clear

input ///
str50 grupo_id ///
str80 grupo_titulo ///
byte escolaridade_ordem ///
byte ordem_grafico

"geral"                       "Geral - todas as escolaridades" 0   0
"fundamental_completo"        "Fundamental completo"           5   1
"ensino_medio_completo"       "Ensino Médio completo"          7   2
"ensino_superior_completo"    "Ensino Superior completo"       9   3
"mestrado"                    "Mestrado"                       10  4
"doutorado"                   "Doutorado"                      11  5

end

save `recortes', replace

* ================================================================
* 5. Logs e tabela-resumo do gap
* ================================================================

tempfile log_temp resumo_temp

postfile LOG ///
    str50 grupo_id ///
    str80 grupo_titulo ///
    str30 status ///
    double n_linhas_filtro ///
    double n_percentis_gap ///
    str200 mensagem ///
    using `log_temp', replace

postfile RESUMO ///
    str50 grupo_id ///
    str80 escolaridade ///
    double ordem_grafico ///
    double renda_celetista_p50 ///
    double renda_estatutario_p50 ///
    double gap_abs_p50 ///
    double gap_rel_pct_p50 ///
    double ratio_p50 ///
    double renda_celetista_p100 ///
    double renda_estatutario_p100 ///
    double gap_abs_p100 ///
    double gap_rel_pct_p100 ///
    double ratio_p100 ///
    double gap_rel_pct_medio_percentis ///
    double n_celetistas ///
    double n_estatutarios ///
    using `resumo_temp', replace

* ================================================================
* 6. Loop pelos níveis educacionais
* ================================================================

use `recortes', clear
count
local N = r(N)

forvalues i = 1/`N' {

    use `recortes', clear

    local id        = grupo_id[`i']
    local titulo    = grupo_titulo[`i']
    local esc_ordem = escolaridade_ordem[`i']
    local ordem     = ordem_grafico[`i']

    display as result "============================================================"
    display as result "Processando `i' de `N': `titulo'"
    if `esc_ordem' == 0 {
        display as result "ID: `id' | recorte geral, sem filtro de escolaridade"
    }
    else {
        display as result "ID: `id' | escolaridade_recorte_ordem = `esc_ordem'"
    }
    display as result "============================================================"

    use "$BASE_PERCENTIS", clear

    * ------------------------------------------------------------
    * Filtros do recorte
    * ------------------------------------------------------------

    keep if ano == 2025
    keep if nivel_geografico == "Brasil"
    keep if recorte_geografico == "Brasil"
    keep if tipo_recorte_demografico == "geral"
    keep if grupo_demografico == "Todos"
    keep if sexo_recorte == "Todos"
    if `esc_ordem' == 0 {
        keep if tipo_recorte_escolaridade == "geral"
    }
    else {
        keep if tipo_recorte_escolaridade == "escolaridade_detalhada"
        keep if escolaridade_recorte_ordem == `esc_ordem'
    }
    keep if inlist(regime_vinculo, "celetista", "estatutario")

    count
    local n_filtro = r(N)

    if `n_filtro' == 0 {
        display as error "Sem observações para: `id'"

        post LOG ///
            ("`id'") ///
            ("`titulo'") ///
            ("VAZIO") ///
            (`n_filtro') ///
            (0) ///
            ("Nenhuma observação após filtros")

        continue
    }

    * ------------------------------------------------------------
    * Preparar regime para reshape
    * ------------------------------------------------------------

    gen byte regime_num = .
    replace regime_num = 1 if regime_vinculo == "celetista"
    replace regime_num = 2 if regime_vinculo == "estatutario"

    keep if inlist(regime_num, 1, 2)

    keep ///
        percentil ///
        probabilidade_quantil ///
        regime_num ///
        remuneracao_percentil ///
        n_vinculos_grupo

    destring percentil, replace force
    destring probabilidade_quantil, replace force
    destring remuneracao_percentil, replace force
    destring n_vinculos_grupo, replace force

    keep if !missing(percentil)
    keep if !missing(remuneracao_percentil)
    keep if percentil >= 1 & percentil <= 100

    * Segurança contra duplicata residual.
    collapse ///
        (mean) remuneracao_percentil ///
        (max) n_vinculos_grupo, ///
        by(percentil probabilidade_quantil regime_num)

    reshape wide ///
        remuneracao_percentil ///
        n_vinculos_grupo, ///
        i(percentil probabilidade_quantil) ///
        j(regime_num)

    capture confirm variable remuneracao_percentil1
    if _rc {
        display as error "Sem celetistas para: `id'"

        post LOG ///
            ("`id'") ///
            ("`titulo'") ///
            ("SEM_CELETISTA") ///
            (`n_filtro') ///
            (0) ///
            ("Sem celetistas no recorte")

        continue
    }

    capture confirm variable remuneracao_percentil2
    if _rc {
        display as error "Sem estatutários para: `id'"

        post LOG ///
            ("`id'") ///
            ("`titulo'") ///
            ("SEM_ESTATUTARIO") ///
            (`n_filtro') ///
            (0) ///
            ("Sem estatutários no recorte")

        continue
    }

    rename remuneracao_percentil1 renda_celetista
    rename remuneracao_percentil2 renda_estatutario
    rename n_vinculos_grupo1 n_celetistas
    rename n_vinculos_grupo2 n_estatutarios

    keep if !missing(renda_celetista, renda_estatutario)

    count
    local n_pares = r(N)

    if `n_pares' == 0 {
        display as error "Sem pares celetista/estatutário para: `id'"

        post LOG ///
            ("`id'") ///
            ("`titulo'") ///
            ("SEM_PARES") ///
            (`n_filtro') ///
            (0) ///
            ("Sem percentis com os dois regimes simultaneamente")

        continue
    }

    * ------------------------------------------------------------
    * Calcular gaps
    * ------------------------------------------------------------

    gen double gap_abs = renda_estatutario - renda_celetista

    gen double gap_rel = .
    replace gap_rel = gap_abs / renda_celetista if renda_celetista > 0

    gen double gap_rel_pct = 100 * gap_rel

    gen double gap_log = .
    replace gap_log = ln(renda_estatutario) - ln(renda_celetista) ///
        if renda_estatutario > 0 & renda_celetista > 0

    gen double ratio_estatutario_celetista = .
    replace ratio_estatutario_celetista = renda_estatutario / renda_celetista ///
        if renda_celetista > 0

    gen str50 grupo_id = "`id'"
    gen str80 grupo_titulo = "`titulo'"
    gen byte escolaridade_recorte_ordem = `esc_ordem'
    gen byte ordem_grafico = `ordem'

    order ///
        grupo_id ///
        grupo_titulo ///
        escolaridade_recorte_ordem ///
        percentil ///
        probabilidade_quantil ///
        renda_celetista ///
        renda_estatutario ///
        n_celetistas ///
        n_estatutarios ///
        gap_abs ///
        gap_rel ///
        gap_rel_pct ///
        gap_log ///
        ratio_estatutario_celetista

    sort percentil

    * ------------------------------------------------------------
    * Estatísticas de resumo: p50 e p100/p99,5
    * ------------------------------------------------------------

    foreach s in cel_p50 est_p50 gapabs_p50 gappct_p50 ratio_p50 ///
               cel_p100 est_p100 gapabs_p100 gappct_p100 ratio_p100 ///
               gap_medio ncel nest {
        local `s' = .
    }

    quietly summarize renda_celetista if percentil == 50, meanonly
    if r(N) > 0 local cel_p50 = r(mean)

    quietly summarize renda_estatutario if percentil == 50, meanonly
    if r(N) > 0 local est_p50 = r(mean)

    quietly summarize gap_abs if percentil == 50, meanonly
    if r(N) > 0 local gapabs_p50 = r(mean)

    quietly summarize gap_rel_pct if percentil == 50, meanonly
    if r(N) > 0 local gappct_p50 = r(mean)

    quietly summarize ratio_estatutario_celetista if percentil == 50, meanonly
    if r(N) > 0 local ratio_p50 = r(mean)

    quietly summarize renda_celetista if percentil == 100, meanonly
    if r(N) > 0 local cel_p100 = r(mean)

    quietly summarize renda_estatutario if percentil == 100, meanonly
    if r(N) > 0 local est_p100 = r(mean)

    quietly summarize gap_abs if percentil == 100, meanonly
    if r(N) > 0 local gapabs_p100 = r(mean)

    quietly summarize gap_rel_pct if percentil == 100, meanonly
    if r(N) > 0 local gappct_p100 = r(mean)

    quietly summarize ratio_estatutario_celetista if percentil == 100, meanonly
    if r(N) > 0 local ratio_p100 = r(mean)

    quietly summarize gap_rel_pct, meanonly
    if r(N) > 0 local gap_medio = r(mean)

    quietly summarize n_celetistas, meanonly
    if r(N) > 0 local ncel = r(max)

    quietly summarize n_estatutarios, meanonly
    if r(N) > 0 local nest = r(max)

    post RESUMO ///
        ("`id'") ///
        ("`titulo'") ///
        (`ordem') ///
        (`cel_p50') ///
        (`est_p50') ///
        (`gapabs_p50') ///
        (`gappct_p50') ///
        (`ratio_p50') ///
        (`cel_p100') ///
        (`est_p100') ///
        (`gapabs_p100') ///
        (`gappct_p100') ///
        (`ratio_p100') ///
        (`gap_medio') ///
        (`ncel') ///
        (`nest')

    * ------------------------------------------------------------
    * Nota dinâmica para p50 e p100
    * ------------------------------------------------------------

    local gapp50_abs = abs(`gappct_p50')
    local gapp50_fmt : display %9.1f `gapp50_abs'
    local gapp50_fmt = strtrim("`gapp50_fmt'")

    local gapp100_abs = abs(`gappct_p100')
    local gapp100_fmt : display %9.1f `gapp100_abs'
    local gapp100_fmt = strtrim("`gapp100_fmt'")

    if `gappct_p50' > 0 {
        local NOTE_P50 ///
            `"Na mediana, estatutários recebem `gapp50_fmt'% a mais que celetistas."'
    }
    else if `gappct_p50' < 0 {
        local NOTE_P50 ///
            `"Na mediana, estatutários recebem `gapp50_fmt'% a menos que celetistas."'
    }
    else {
        local NOTE_P50 ///
            `"Na mediana, estatutários e celetistas têm a mesma remuneração."'
    }

    if `gappct_p100' > 0 {
        local NOTE_P100 ///
            `"No percentil 100 (p99,5), estatutários recebem `gapp100_fmt'% a mais que celetistas."'
    }
    else if `gappct_p100' < 0 {
        local NOTE_P100 ///
            `"No percentil 100 (p99,5), estatutários recebem `gapp100_fmt'% a menos que celetistas."'
    }
    else {
        local NOTE_P100 ///
            `"No percentil 100 (p99,5), estatutários e celetistas têm a mesma remuneração."'
    }

    * ------------------------------------------------------------
    * Salvar base do grupo
    * ------------------------------------------------------------

    save "$OUT_BASES/gap_percentis__`id'.dta", replace

    export delimited using "$OUT_BASES/gap_percentis__`id'.csv", ///
        replace delimiter(";")

    tempfile grupo_gap
    save `grupo_gap', replace

    * ------------------------------------------------------------
    * Atualizar base consolidada
    * ------------------------------------------------------------

    capture confirm file "$OUT_BASES/gap_percentis_geral_e_niveis.dta"

    if _rc {
        save "$OUT_BASES/gap_percentis_geral_e_niveis.dta", replace
    }
    else {
        use "$OUT_BASES/gap_percentis_geral_e_niveis.dta", clear
        append using `grupo_gap'
        save "$OUT_BASES/gap_percentis_geral_e_niveis.dta", replace
    }

    use `grupo_gap', clear

    * ------------------------------------------------------------
    * Gráfico 1: gap percentual por percentil
    * ------------------------------------------------------------

    quietly summarize gap_rel_pct, meanonly
    local ymin = floor(r(min) / 10) * 10
    local ymax = ceil(r(max) / 10) * 10
    if `ymin' > -10 local ymin = -10
    if `ymax' < 10  local ymax = 10

    twoway ///
        (line gap_rel_pct percentil, ///
            sort ///
            lcolor(navy) ///
            lwidth(medthick)) ///
        (scatter gap_rel_pct percentil, ///
            msymbol(circle) ///
            msize(vsmall) ///
            mcolor(cranberry)), ///
        yline(0, `ZERO_LINE') ///
        title("Gap estatutários x celetistas", size(medsmall) color(black) margin(b+2)) ///
        subtitle("`titulo'" "Fórmula: `L_GAP_FORMULA'", size(vsmall) color(black) margin(b+4)) ///
        note("`NOTE_P50'" ///
             "`NOTE_P100'" ///
             "`NOTE_SOURCE'", ///
             size(small) span) ///
        xtitle("Percentil da remuneração", size(small)) ///
        ytitle("Gap relativo (%)", size(small) margin(medium)) ///
        xlabel(1 10(10)100, labsize(small) grid glcolor(gs14) glpattern(dash)) ///
        ylabel(, angle(horizontal) labsize(small) format(%9.1f) grid glcolor(gs14) glpattern(dash)) ///
        yscale(range(`ymin' `ymax')) ///
        legend(off) ///
        graphregion(color(white) margin(l+7 r+8 t+8 b+16)) ///
        plotregion(color(white) margin(l+3 r+3 t+3 b+3)) ///
        bgcolor(white) ///
        xsize(11) ///
        ysize(8.6) ///
        name(gap_pct, replace)

    graph export "$OUT_PCT/gap_percentil__`id'.png", replace width(3200)
    graph export "$OUT_PCT/gap_percentil__`id'.pdf", replace

    * ------------------------------------------------------------
    * Gráfico 2: KDE do gap percentual
    * ------------------------------------------------------------

    quietly count if !missing(gap_rel_pct)
    local n_kde = r(N)

    quietly summarize gap_rel_pct if !missing(gap_rel_pct), meanonly
    local min_kde = r(min)
    local max_kde = r(max)

    if `n_kde' >= 5 & `max_kde' > `min_kde' {

        capture drop __x_gap __d_gap

        kdensity gap_rel_pct if !missing(gap_rel_pct), ///
            generate(__x_gap __d_gap) ///
            n(300) ///
            nograph

        twoway ///
            (line __d_gap __x_gap, sort lcolor(navy) lwidth(medthick)), ///
            xline(0, `ZERO_LINE') ///
            title("KDE do gap estatutários x celetistas", size(medsmall) color(black) margin(b+2)) ///
            subtitle("`titulo'", size(small) color(black) margin(b+3)) ///
            note("`NOTE_KDE_GAP_INTERP'" ///
                 "`NOTE_SOURCE'", ///
                 size(small) span) ///
            xtitle("Gap relativo (%)", size(small)) ///
            ytitle("Densidade", size(small) margin(medium)) ///
            xlabel(, labsize(small) grid glcolor(gs14) glpattern(dash)) ///
            ylabel(, angle(horizontal) labsize(small) grid glcolor(gs14) glpattern(dash)) ///
            legend(off) ///
            graphregion(color(white) margin(l+7 r+8 t+7 b+16)) ///
            plotregion(color(white) margin(l+3 r+3 t+3 b+3)) ///
            bgcolor(white) ///
            xsize(11) ///
            ysize(8.6) ///
            name(gap_kde, replace)

        graph export "$OUT_KDE/gap_kde__`id'.png", replace width(3200)
        graph export "$OUT_KDE/gap_kde__`id'.pdf", replace
    }
    else {
        display as error "KDE do gap não gerado para `id': poucos pontos ou variância zero."
    }

    * ------------------------------------------------------------
    * Gráfico 3: KDE do log-gap
    * ------------------------------------------------------------

    quietly count if !missing(gap_log)
    local n_kde_ln = r(N)

    quietly summarize gap_log if !missing(gap_log), meanonly
    local min_kde_ln = r(min)
    local max_kde_ln = r(max)

    if `n_kde_ln' >= 5 & `max_kde_ln' > `min_kde_ln' {

        capture drop __x_lngap __d_lngap

        kdensity gap_log if !missing(gap_log), ///
            generate(__x_lngap __d_lngap) ///
            n(300) ///
            nograph

        twoway ///
            (line __d_lngap __x_lngap, sort lcolor(navy) lwidth(medthick)), ///
            xline(0, `ZERO_LINE') ///
            title("KDE do log-gap estatutários x celetistas", size(medsmall) color(black) margin(b+2)) ///
            subtitle("`titulo'", size(small) color(black) margin(b+3)) ///
            note("`NOTE_KDE_LNGAP_INTERP'" ///
                 "`NOTE_KDE_LNGAP_READING'" ///
                 "`NOTE_SOURCE'", ///
                 size(small) span) ///
            xtitle("`L_LNGAP_FORMULA'", size(small)) ///
            ytitle("Densidade", size(small) margin(medium)) ///
            xlabel(, labsize(small) grid glcolor(gs14) glpattern(dash)) ///
            ylabel(, angle(horizontal) labsize(small) grid glcolor(gs14) glpattern(dash)) ///
            legend(off) ///
            graphregion(color(white) margin(l+7 r+8 t+7 b+16)) ///
            plotregion(color(white) margin(l+3 r+3 t+3 b+3)) ///
            bgcolor(white) ///
            xsize(11) ///
            ysize(8.6) ///
            name(gap_kde_ln, replace)

        graph export "$OUT_KDE_LN/gap_kde_ln__`id'.png", replace width(3200)
        graph export "$OUT_KDE_LN/gap_kde_ln__`id'.pdf", replace
    }
    else {
        display as error "KDE do log-gap não gerado para `id': poucos pontos ou renda não positiva."
    }

    post LOG ///
        ("`id'") ///
        ("`titulo'") ///
        ("OK") ///
        (`n_filtro') ///
        (`n_pares') ///
        ("Processado com sucesso")
}

* ================================================================
* 7. Fechar logs e salvar tabela-resumo
* ================================================================

postclose LOG
postclose RESUMO

use `log_temp', clear
save "$OUT_LOGS/log_gap_estatutarios_celetistas_geral_escolaridade.dta", replace
export delimited using "$OUT_LOGS/log_gap_estatutarios_celetistas_geral_escolaridade.csv", ///
    replace delimiter(";")

list, abbrev(30)

use `resumo_temp', clear

format renda_celetista_p50 renda_estatutario_p50 gap_abs_p50 ///
       renda_celetista_p100 renda_estatutario_p100 gap_abs_p100 %15.2fc
format gap_rel_pct_p50 gap_rel_pct_p100 gap_rel_pct_medio_percentis %9.2f
format ratio_p50 ratio_p100 %9.3f
format n_celetistas n_estatutarios %15.0fc

sort ordem_grafico grupo_id

save "$OUT_BASES/resumo_gap_geral_escolaridade_regime.dta", replace
export delimited using "$OUT_BASES/resumo_gap_geral_escolaridade_regime.csv", ///
    replace delimiter(";")

list grupo_id escolaridade renda_celetista_p50 renda_estatutario_p50 ///
     gap_abs_p50 gap_rel_pct_p50 ratio_p50, noobs abbreviate(28)

* ================================================================
* 8. Exportar base consolidada em CSV
* ================================================================

capture confirm file "$OUT_BASES/gap_percentis_geral_e_niveis.dta"
if !_rc {
    use "$OUT_BASES/gap_percentis_geral_e_niveis.dta", clear
    sort ordem_grafico grupo_id percentil
    export delimited using "$OUT_BASES/gap_percentis_geral_e_niveis.csv", ///
        replace delimiter(";")
}

* ================================================================
* 9. Zipar saída
* ================================================================

capture erase "$ROOT/gap_estatutarios_celetistas_geral_escolaridade.zip"
capture shell powershell -NoProfile -Command "Compress-Archive -Path '$OUT/*' -DestinationPath '$ROOT/gap_estatutarios_celetistas_geral_escolaridade.zip' -Force"

display as result "============================================================"
display as result "Processo concluído."
display as result "Pasta de saída:"
display as result "$OUT"
display as result "ZIP:"
display as result "$ROOT/gap_estatutarios_celetistas_geral_escolaridade.zip"
display as result "Tabela principal:"
display as result "$OUT_BASES/resumo_gap_geral_escolaridade_regime.csv"
display as result "============================================================"
