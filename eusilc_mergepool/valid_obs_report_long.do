*===============================================================
* valid_obs_report_long.do
*
* Versione longitudinale di valid_obs_report.do: osservazioni VALIDE
* (non mancanti) per variabile x paese x anno sul file finale
* PPHH_long_reduced.dta (persone + famiglie, da reduce_long.do).
*
* Differenza rispetto alla versione trasversale: ogni variabile ha un
* UNIVERSO, cioe' le righe in cui puo' essere valorizzata:
*   P  = persone 16+ con record P          (in_P == 1)
*   H  = persone con famiglia collegata    (hh_linked == 1)
*   R  = tutte le persone-anno del registro
* L'universo si ricava dai dati: una variabile mai valorizzata fuori da
* in_P==1 e' di tipo P; mai fuori da hh_linked==1 e' di tipo H; altrimenti R
* (es. birth_country, che dal 2021 viene da R, risulta R). Le percentuali
* "_univ" e i flag usano l'universo, cosi' i ragazzi sotto i 16 anni o le
* persone con piu' famiglie non appaiono come buchi.
*
* Output (in OUTPUT, prefisso long_):
*   long_valid_obs_tidy.csv      var, paese, anno, universo, conteggi, %
*   long_valid_obs_matrix.csv    % validi sull'universo: var x paese, anni in colonna
*   long_flag_overall_low.csv    variabili con pochi validi in totale (candidate drop)
*   long_flag_absent_year.csv    (var, anno) vuote per tutti i paesi
*   long_flag_country_empty.csv  (var, paese) sempre vuote
*   long_flag_zero_cells.csv     celle (var, paese, anno) a 0 validi
*===============================================================
version 16.0
clear all
set more off

*--- PARAMETRI: modifica solo qui ------------------------------
local outdir "/Volumes/ext_blu/EUSILC/OUTPUT"
local data   "`outdir'/PPHH_long_reduced.dta"
local cvar   country
local yvar   year
* soglia (%) sotto cui una variabile e' segnalata come "quasi vuota"
local lowthr 10
* identificativi, chiavi, flag tecnici e pesi da NON analizzare come contenuto
local idvars person_num person_uid pid_s country year cohort_id hh_uid hh_num ///
             multi_hh multi_cohort_year n_rel in_P hh_linked src_release ///
             pp_id id person_id house_id hh_w_src ///
             pp_base_weight r_base_weight hh_weight hh_weight_l hh_w strata psu
*---------------------------------------------------------------

use "`data'", clear
local src : char _dta[red_source]
display "File: `data'"
display "Run di origine: `src'"

display _n "{hline 60}"
display "Osservazioni per paese x anno:"
table `cvar' `yvar'

* pesi longitudinali eventualmente aggiunti (lw_*) esclusi dal contenuto
local lwv ""
capture ds lw_*
if !_rc local lwv `r(varlist)'
quietly ds
local allvars `r(varlist)'
local vars : list allvars - idvars
local vars : list vars - lwv
display _n "Variabili analizzate: `: word count `vars''"

*--- 1. CONTEGGIO VALIDI per variabile x paese x anno ----------
tempfile master
local first = 1
foreach v of local vars {
    * universo della variabile, ricavato dai dati
    quietly count if !missing(`v') & in_P == 0
    local outP = r(N)
    quietly count if !missing(`v') & hh_linked == 0
    local outH = r(N)
    if `outP' == 0 local univ "P"
    else if `outH' == 0 local univ "H"
    else local univ "R"
    preserve
    generate byte __nm = !missing(`v')
    if "`univ'" == "P" generate byte __u = in_P == 1
    else if "`univ'" == "H" generate byte __u = hh_linked == 1
    else generate byte __u = 1
    generate byte __nmu = __nm & __u
    collapse (count) total=__nm (sum) valid=__nm total_univ=__u valid_univ=__nmu, by(`cvar' `yvar')
    generate str32 variable = "`v'"
    generate str1 universe = "`univ'"
    if `first' {
        quietly save `master', replace
        local first = 0
    }
    else {
        append using `master'
        quietly save `master', replace
    }
    restore
}

use `master', clear
generate double pct_valid = 100 * valid / total
generate double pct_valid_univ = 100 * valid_univ / total_univ if total_univ > 0
generate double pct_miss_univ = 100 - pct_valid_univ
format pct_valid pct_valid_univ pct_miss_univ %5.1f
order variable universe `cvar' `yvar' total valid pct_valid total_univ valid_univ pct_valid_univ pct_miss_univ
sort variable `cvar' `yvar'
export delimited using "`outdir'/long_valid_obs_tidy.csv", replace
display _n "-> salvato long_valid_obs_tidy.csv"

*--- 2. MATRICE: % validi sull'universo, anni in colonna --------
preserve
    keep variable universe `cvar' `yvar' pct_valid_univ
    drop if missing(`yvar') | missing(`cvar')
    replace pct_valid_univ = round(pct_valid_univ)
    reshape wide pct_valid_univ, i(variable universe `cvar') j(`yvar')
    sort variable `cvar'
    export delimited using "`outdir'/long_valid_obs_matrix.csv", replace
    display "-> salvato long_valid_obs_matrix.csv (% validi sull'universo per anno)"
restore

*--- 3. FLAG AUTOMATICI (sull'universo) --------------------------

* 3a. variabili con pochi validi in totale (candidate da scartare)
preserve
    collapse (sum) valid_univ total_univ (first) universe, by(variable)
    generate double pct_valid_univ = 100 * valid_univ / total_univ
    format pct_valid_univ %5.1f
    sort pct_valid_univ
    export delimited using "`outdir'/long_flag_overall_low.csv", replace
    display _n "{hline 60}"
    display "Variabili con < `lowthr'% validi sull'universo (candidate DROP):"
    list variable universe pct_valid_univ if pct_valid_univ < `lowthr', noobs sep(0)
restore

* 3b. (variabile, anno) vuote per tutti i paesi = assenza strutturale
preserve
    collapse (max) maxpct = pct_valid_univ, by(variable `yvar')
    keep if maxpct == 0
    keep variable `yvar'
    sort variable `yvar'
    export delimited using "`outdir'/long_flag_absent_year.csv", replace
    display _n "Assenze strutturali (variabile vuota per tutti i paesi in quell'anno):"
    list, noobs sepby(variable)
restore

* 3c. (variabile, paese) sempre vuote in tutti gli anni
preserve
    collapse (max) maxpct = pct_valid_univ, by(variable `cvar')
    keep if maxpct == 0
    keep variable `cvar'
    sort variable `cvar'
    export delimited using "`outdir'/long_flag_country_empty.csv", replace
    display _n "Variabili sempre vuote per un intero paese:"
    list, noobs sepby(variable)
restore

* 3d. dettaglio: celle a 0 validi sull'universo
preserve
    keep if pct_valid_univ == 0
    keep variable universe `cvar' `yvar'
    sort variable `cvar' `yvar'
    export delimited using "`outdir'/long_flag_zero_cells.csv", replace
restore

display _n "{hline 60}"
display "FATTO. File in: `outdir' (prefisso long_)"
display "Apri long_valid_obs_matrix.csv per la vista d'insieme dei pattern."
