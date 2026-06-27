*******************************************************
* RAIS 2025 - Gráficos separados por regime          *
* Distribuição salarial por escolaridade             *
* V15: valores de salário na legenda, não na ponta   *
*      compatível com processamento R corrigido v15  *
*******************************************************

version 15.1
clear all
set more off
set scheme s2color

* ----------------------------------------------------
* 1. Diretórios
* ----------------------------------------------------

* Diretório dinâmico: usa RAIS_DIR_BASE se existir; caso contrário,
* assume que o do-file está sendo executado a partir da raiz do repositório.
local root_env : environment RAIS_DIR_BASE
if "`root_env'" == "" {
    local root_env "`c(pwd)'"
}
local root_env = subinstr("`root_env'", char(92), "/", .)

global dir_base "`root_env'/rais_2025_bases_graficos_percentis"
global arquivo_dta "$dir_base/base_percentis_salariais_recortes_rais_2025.dta"
global dir_saida "$dir_base/figuras_stata_escolaridade_regime"

cap mkdir "$dir_saida"

* Se = 1, o script para se faltar alguma das 5 categorias esperadas.
* Se = 0, ele apenas avisa e gera os gráficos com as categorias existentes.
local exigir_todas_categorias 1

* ----------------------------------------------------
* 2. Abrir base de percentis gerada pelo R
* ----------------------------------------------------

use "$arquivo_dta", clear

* ----------------------------------------------------
* 3. Filtro analítico
* ----------------------------------------------------

keep if ano == 2025
keep if nivel_geografico == "Brasil"
keep if recorte_geografico == "Brasil"
keep if tipo_recorte_demografico == "geral"
keep if grupo_demografico == "Todos"
keep if inlist(regime_vinculo, "celetista", "estatutario")
keep if tipo_recorte_escolaridade == "escolaridade_detalhada"

* ----------------------------------------------------
* 4. Checagem das escolaridades detalhadas disponíveis
* ----------------------------------------------------

display as text ""
display as text "Escolaridades detalhadas disponíveis na base após filtros iniciais:"
preserve
    keep regime_vinculo escolaridade_recorte_ordem escolaridade_recorte
    duplicates drop
    sort regime_vinculo escolaridade_recorte_ordem escolaridade_recorte
    list, noobs abbreviate(36)
restore

* ----------------------------------------------------
* 5. Categorias finais do gráfico
* ----------------------------------------------------
* Códigos do processamento R corrigido:
*   5  = Fundamental completo
*   7  = Ensino Médio completo
*   9  = Ensino Superior completo
*   10 = Mestrado
*   11 = Doutorado
* ----------------------------------------------------

foreach v in categoria_esc cat_ordem label_curto mediana_grupo mediana_int ///
             mediana_str n_cat_regime {
    capture drop `v'
}

gen byte cat_ordem = .
replace cat_ordem = 1 if escolaridade_recorte_ordem == 5
replace cat_ordem = 2 if escolaridade_recorte_ordem == 7
replace cat_ordem = 3 if escolaridade_recorte_ordem == 9
replace cat_ordem = 4 if escolaridade_recorte_ordem == 10
replace cat_ordem = 5 if escolaridade_recorte_ordem == 11

gen str40 categoria_esc = ""
replace categoria_esc = "Fundamental completo"       if cat_ordem == 1
replace categoria_esc = "Ensino Médio completo"      if cat_ordem == 2
replace categoria_esc = "Ensino Superior completo"   if cat_ordem == 3
replace categoria_esc = "Mestrado"                   if cat_ordem == 4
replace categoria_esc = "Doutorado"                  if cat_ordem == 5

drop if missing(cat_ordem)

label define lbl_cat 1 "Fundamental completo" ///
                     2 "Ensino Médio completo" ///
                     3 "Ensino Superior completo" ///
                     4 "Mestrado" ///
                     5 "Doutorado", replace
label values cat_ordem lbl_cat

gen str30 label_curto = ""
replace label_curto = "Fundamental" if cat_ordem == 1
replace label_curto = "Médio"       if cat_ordem == 2
replace label_curto = "Superior"    if cat_ordem == 3
replace label_curto = "Mestrado"    if cat_ordem == 4
replace label_curto = "Doutorado"   if cat_ordem == 5

* ----------------------------------------------------
* 6. Diagnóstico obrigatório das categorias usadas
* ----------------------------------------------------

display as text ""
display as text "Categorias finais detectadas para os gráficos:"
preserve
    keep regime_vinculo cat_ordem categoria_esc escolaridade_recorte_ordem escolaridade_recorte
    duplicates drop
    sort regime_vinculo cat_ordem
    list, noobs abbreviate(36)
restore

local faltou_categoria 0

foreach reg in celetista estatutario {
    foreach c in 1 2 3 4 5 {
        quietly count if regime_vinculo == "`reg'" & cat_ordem == `c'
        if r(N) == 0 {
            local faltou_categoria 1
            display as error "ATENÇÃO: faltou categoria `c' para regime `reg'."
        }
    }
}

if `faltou_categoria' == 1 {
    preserve
        keep regime_vinculo escolaridade_recorte_ordem escolaridade_recorte tipo_recorte_escolaridade
        duplicates drop
        sort regime_vinculo escolaridade_recorte_ordem escolaridade_recorte
        export delimited using "$dir_saida/diagnostico_categorias_escolaridade_graficos_v15.csv", ///
            replace delimiter(";")
    restore

    display as error ""
    display as error "Uma ou mais categorias esperadas não existem na base filtrada."
    display as error "Foi salvo o diagnóstico em: $dir_saida/diagnostico_categorias_escolaridade_graficos_v15.csv"

    if `exigir_todas_categorias' == 1 {
        error 459
    }
}

* Checagem de duplicidade: deve haver uma linha por regime, categoria e percentil.
duplicates report regime_vinculo cat_ordem percentil

* ----------------------------------------------------
* 7. Medianas e tabela auxiliar
* ----------------------------------------------------

bysort regime_vinculo cat_ordem: egen mediana_grupo = ///
    max(cond(percentil == 50, remuneracao_percentil, .))

gen long mediana_int = round(mediana_grupo, 1)
gen str20 mediana_str = string(mediana_int, "%15.0fc")
replace mediana_str = strtrim(mediana_str)
replace mediana_str = subinstr(mediana_str, ",", ".", .)

* Exporta uma tabela de medianas para conferência e uso em relatório.
preserve
    keep regime_vinculo categoria_esc cat_ordem mediana_grupo mediana_int mediana_str
    duplicates drop
    sort regime_vinculo cat_ordem
    export delimited using "$dir_saida/tabela_medianas_escolaridade_regime_v15.csv", ///
        replace delimiter(";")
restore

* ----------------------------------------------------
* 8. Escala comum do eixo Y para os dois gráficos
* ----------------------------------------------------

quietly summarize remuneracao_percentil, meanonly
local ymax_global = ceil(r(max) / 10000) * 10000
if `ymax_global' < 20000 local ymax_global = 20000

* ----------------------------------------------------
* 9. Programa auxiliar para desenhar um gráfico
* ----------------------------------------------------

capture program drop faz_grafico_regime
program define faz_grafico_regime
    syntax , REGIME(string) TITULO(string) NOME(name) ARQBASE(string) YMAX(real)

    preserve
        keep if regime_vinculo == "`regime'"
        sort cat_ordem percentil

        local ytexto = `ymax' * 0.96

        * Medianas do regime atual para inserir na legenda.
        * Evitamos levelsof para string porque ele pode devolver aspas
        * embutidas no macro local e quebrar a opção legend().
        quietly summarize mediana_int if cat_ordem == 1, meanonly
        local med1 : display %15.0fc r(mean)
        local med1 = strtrim("`med1'")
        local med1 = subinstr("`med1'", ",", ".", .)

        quietly summarize mediana_int if cat_ordem == 2, meanonly
        local med2 : display %15.0fc r(mean)
        local med2 = strtrim("`med2'")
        local med2 = subinstr("`med2'", ",", ".", .)

        quietly summarize mediana_int if cat_ordem == 3, meanonly
        local med3 : display %15.0fc r(mean)
        local med3 = strtrim("`med3'")
        local med3 = subinstr("`med3'", ",", ".", .)

        quietly summarize mediana_int if cat_ordem == 4, meanonly
        local med4 : display %15.0fc r(mean)
        local med4 = strtrim("`med4'")
        local med4 = subinstr("`med4'", ",", ".", .)

        quietly summarize mediana_int if cat_ordem == 5, meanonly
        local med5 : display %15.0fc r(mean)
        local med5 = strtrim("`med5'")
        local med5 = subinstr("`med5'", ",", ".", .)

        #delimit ;
        twoway
            (line remuneracao_percentil percentil if cat_ordem == 1,
                sort lcolor(gs8) lwidth(medthick) lpattern(solid))
            (line remuneracao_percentil percentil if cat_ordem == 2,
                sort lcolor(eltblue) lwidth(medthick) lpattern(solid))
            (line remuneracao_percentil percentil if cat_ordem == 3,
                sort lcolor(forest_green) lwidth(medthick) lpattern(solid))
            (line remuneracao_percentil percentil if cat_ordem == 4,
                sort lcolor(orange_red) lwidth(medthick) lpattern(solid))
            (line remuneracao_percentil percentil if cat_ordem == 5,
                sort lcolor(purple) lwidth(medthick) lpattern(solid))
        ,
            title("`titulo'", size(large) color(black))
            subtitle("Percentil da remuneração média - vínculos ativos, RAIS 2025",
                size(medsmall) color(gs6))
            xtitle("Percentil", size(medlarge))
            ytitle("Remuneração média (R$)", size(medsmall))
            xlabel(0(25)100, labsize(medsmall))
            ylabel(0(10000)`ymax', angle(horizontal) format(%12.0fc) labsize(medsmall))
            xscale(range(0 100))
            yscale(range(0 `ymax'))
            xline(50, lpattern(dash) lcolor(gs10))
            text(`ytexto' 50 "50% (mediana)", size(vsmall) color(gs8) placement(e))
            legend(order(1 "Fundamental - mediana R$ `med1'"
                         2 "Médio - mediana R$ `med2'"
                         3 "Superior - mediana R$ `med3'"
                         4 "Mestrado - mediana R$ `med4'"
                         5 "Doutorado - mediana R$ `med5'")
                   rows(3) size(vsmall) position(6) region(lcolor(none)))
            graphregion(color(white) margin(medium))
            plotregion(color(white) margin(small))
            note("Valores na legenda correspondem à mediana de cada curva."
                 "Fonte: RAIS 2025 via Base dos Dados", size(small) color(gs6))
            name(`nome', replace)
            xsize(11) ysize(7.5)
        ;
        #delimit cr

        graph export "$dir_saida/`arqbase'.png", replace width(2200)
        graph export "$dir_saida/`arqbase'.pdf", replace
        graph save   "$dir_saida/`arqbase'.gph", replace

        save "$dir_saida/base_`arqbase'.dta", replace
        export delimited using "$dir_saida/base_`arqbase'.csv", replace delimiter(";")
    restore
end

* ----------------------------------------------------
* 10. Gerar gráficos separados
* ----------------------------------------------------

faz_grafico_regime, ///
    regime("celetista") ///
    titulo("Distribuição salarial por escolaridade - Celetistas") ///
    nome(g_esc_cel14) ///
    arqbase("distribuicao_salarial_escolaridade_celetistas_v15") ///
    ymax(`ymax_global')

faz_grafico_regime, ///
    regime("estatutario") ///
    titulo("Distribuição salarial por escolaridade - Estatutários") ///
    nome(g_esc_est14) ///
    arqbase("distribuicao_salarial_escolaridade_estatutarios_v15") ///
    ymax(`ymax_global')

* ----------------------------------------------------
* 11. Diagnóstico final das categorias usadas
* ----------------------------------------------------

display as text ""
display as text "Categorias finais usadas nos gráficos V15:"
preserve
    keep regime_vinculo cat_ordem categoria_esc escolaridade_recorte_ordem escolaridade_recorte mediana_str
    duplicates drop
    sort regime_vinculo cat_ordem
    list, noobs abbreviate(36)
restore

display as text ""
display as result "Concluído. Gráficos separados V15 salvos em: $dir_saida"
