*! reduce_long.do  -  versione 0.1
*! Riduzione e rinomina delle variabili del panel longitudinale prodotto da
*! mergepool_long.do (ultima run certificata), sul modello di
*! DATASET_REDUCTION.do (versione trasversale).
*!
*! Requisito: Stata 16.0 o successivo.
*! Input : <run>/masterH.dta + <run>/masterD.dta   -> famiglie
*!         <run>/panel_person_year.dta              -> persone
*!         <run>/long_weight_windows.dta            -> pesi longitudinali (opzionale)
*! Output: <run>/reduced/HH_long_reduced.dta   famiglia-anno (year hh_uid)
*!         <run>/reduced/PP_long_reduced.dta   persona-anno  (xtset person_num year)
*!         <run>/reduced/reduce_vars_*.csv     variabili richieste: presenti/assenti
*!         <run>/reduced/reduce_coverage_*.csv osservazioni valide per anno
*!         <run>/reduced/reduce_long.log
*! I file della run certificata non vengono modificati.
*!
*! Differenze rispetto alla versione trasversale (motivate):
*!  - nomi in minuscolo (mergepool_long li armonizza cosi');
*!  - year/country/ID vengono dal panel: PB010/PB020/HB010/HB020/DB010/RB010
*!    non sono rinominati (ridondanti);
*!  - nessun "destring, force": conversione solo se tutti i valori sono numerici;
*!  - coalescing HS011/HS021/HS031/HH021 dal 2010 compreso (lo script
*!    trasversale usava > 2010 per HS010 e >= 2010 per gli altri: qui uniformato),
*!    e solo dove la variabile nuova e' valorizzata;
*!  - pesi: nel longitudinale non ci sono DB090 dopo il 2013, RB050, PB040, PB060:
*!    si conservano DB090 (fino al 2013), DB095 (dal 2014), RB060, PB050 con nomi
*!    propri; i pesi longitudinali RB06k si aggiungono con RED_LW;
*!  - una variabile richiesta ma assente nei file longitudinali e' elencata in
*!    reduce_vars_*.csv (status "absent") e non viene creata, salvo quelle che
*!    servono alle armonizzazioni (create vuote e segnalate).

version 16.0
clear all
capture log close redlog
set more off
set varabbrev off

*==============================================================================
* CONFIGURAZIONE
*==============================================================================
global RED_OUTROOT   "/Volumes/ext_blu/EUSILC/OUTPUT"   // cartella con LATEST_CERTIFIED.txt
global RED_RUN       ""     // cartella di una run; vuoto = ultima run certificata
* Pesi longitudinali da aggiungere al file persone: coppie peso:release.
* Es. "rb064:2024" = RB064 calcolato da L-2024 (finestra 2021-2024), solo per le
* persone con finestra completa nel panel e solo negli anni della finestra.
global RED_LW        ""
global RED_YEARSPLIT 2010   // da quest'anno si usano HS011/HS021/HS031/HH021

*==============================================================================
* UTILITA'
*==============================================================================
* Converte in numerico una variabile stringa solo se tutti i valori lo sono.
capture program drop red_num
program define red_num
    args v
    capture confirm string variable `v'
    if _rc exit
    generate double _red_tmp = real(strtrim(`v'))
    quietly count if missing(_red_tmp) & strtrim(`v') != ""
    if r(N) > 0 {
        di as error "`v': `r(N)' valori non numerici: conversione non eseguita"
        exit 459
    }
    drop `v'
    rename _red_tmp `v'
end

* Crea vuota una variabile sorgente assente (necessaria a un'armonizzazione)
* e la registra fra le assenti.
capture program drop red_ensure
program define red_ensure
    args v type
    capture confirm variable `v', exact
    if _rc {
        if "`type'" == "str" quietly generate str3 `v' = ""
        else quietly generate `type' `v' = .
        global RED_CREATED $RED_CREATED `v'
    }
end

* Rende stringa una variabile (per codici LOC/EU/OTH): decodifica i numerici
* etichettati; i numerici senza etichetta diventano il codice in testo.
capture program drop red_str
program define red_str
    args v
    capture confirm string variable `v'
    if !_rc exit
    local lab : value label `v'
    if "`lab'" != "" decode `v', generate(_red_s)
    else generate str _red_s = cond(missing(`v'), "", string(`v', "%12.0g"))
    drop `v'
    rename _red_s `v'
end

* Rinomina secondo una lista "vecchio nuovo etichetta|..."; registra l'esito.
capture program drop red_rename
program define red_rename
    args spec postname
    local rest `"`spec'"'
    while `"`rest'"' != "" {
        gettoken item rest : rest, parse("|")
        if `"`item'"' == "|" continue
        gettoken old item : item
        gettoken new item : item
        local lbl = strtrim(`"`item'"')
        capture confirm variable `old', exact
        if _rc {
            post `postname' ("`old'") ("`new'") ("absent")
            continue
        }
        capture confirm variable `new', exact
        if !_rc {
            di as error "red_rename: `new' esiste gia' (da `old')"
            exit 110
        }
        rename `old' `new'
        if `"`lbl'"' != "" label variable `new' `"`lbl'"'
        post `postname' ("`old'") ("`new'") ("renamed")
    }
end

* Osservazioni valide per anno di tutte le variabili numeriche indicate.
capture program drop red_coverage
program define red_coverage
    args vars outfile
    local num ""
    foreach v of local vars {
        capture confirm numeric variable `v', exact
        if !_rc local num `num' `v'
    }
    if "`num'" == "" exit
    preserve
    generate byte _one = 1
    collapse (sum) n_rows=_one (count) `num', by(year)
    export delimited using "`outfile'", replace
    restore
end

*==============================================================================
* RUN DI INPUT
*==============================================================================
if `"$RED_RUN"' == "" {
    tempname fh
    file open `fh' using "$RED_OUTROOT/LATEST_CERTIFIED.txt", read text
    file read `fh' line
    file close `fh'
    global RED_RUN = strtrim(`"`line'"')
}
confirm file "$RED_RUN/CERTIFIED.txt"
local out "$RED_RUN/reduced"
mata: st_local("ex", strofreal(direxists(st_local("out"))))
if "`ex'" == "0" mkdir "`out'"
log using "`out'/reduce_long.log", text replace name(redlog)
di as text "Run certificata: $RED_RUN"
global RED_CREATED ""

*==============================================================================
* 1. FAMIGLIE: masterH + variabili D
*==============================================================================
use "$RED_RUN/masterH.dta", clear
quietly describe using "$RED_RUN/masterD.dta", varlist
local dvl `r(varlist)'
local dkeep ""
foreach v in db040 db050 db060 db090 db095 db100 src_release {
    local pos : list posof "`v'" in dvl
    if `pos' > 0 local dkeep `dkeep' `v'
}
merge 1:1 year hh_uid using "$RED_RUN/masterD.dta", keepusing(`dkeep') keep(master match)
quietly count if _merge != 3
if r(N) > 0 {
    di as error "`r(N)' famiglie H senza record in masterD"
    exit 459
}
drop _merge

* --- arretrati: HS011/HS021/HS031 (3 categorie) -> 2 categorie, poi coalesce
label define red_yesno 1 "yes" 2 "no", replace
foreach pair in "hs010 hs011" "hs020 hs021" "hs030 hs031" {
    local old : word 1 of `pair'
    local new : word 2 of `pair'
    red_ensure `old' double
    red_ensure `new' double
    red_num `old'
    red_num `new'
    quietly replace `new' = 1 if `new' == 2
    quietly replace `new' = 2 if `new' == 3
    quietly replace `old' = `new' if year >= $RED_YEARSPLIT & !missing(`new')
    label values `old' red_yesno
}

* --- titolo di godimento: HH021 (5 categorie) -> 4 categorie di HH020, poi coalesce
red_ensure hh020 double
red_ensure hh021 double
red_num hh020
red_num hh021
quietly replace hh021 = 1 if hh021 == 2
quietly replace hh021 = 2 if hh021 == 3
quietly replace hh021 = 3 if hh021 == 4
quietly replace hh021 = 4 if hh021 == 5
quietly replace hh020 = hh021 if year >= $RED_YEARSPLIT & !missing(hh021)
label define red_tenure 1 "owner" 2 "tenant or subtenant paying rent at prevailing or market rate" ///
    3 "accommodation is rented at a reduced rate (lower price than market price)" ///
    4 "accommodation is provided free", replace
label values hh020 red_tenure

tempname ph
tempfile rv
postfile `ph' str32 source str32 target str16 status using `rv', replace
local hmap "hb030 id Household ID (DB030/HB030)|hb070 person_id Person responding|hh010 dwelling Dwelling type|hh020 tenure Tenure status (HH021 dal $RED_YEARSPLIT)|hh030 rooms Rooms available to the household|hh031 contract_yr Year of contract|hh040 leak_roof Leaking roof or structural problems|hh050 warm Ability to keep home adequately warm|hh060 rent Current rent|hh061 subj_rent Subjective rent|hh070 house_cost Total housing cost|hs010 arr_rent Arrears on mortgage or rent (HS011 dal $RED_YEARSPLIT)|hs020 arr_bills Arrears on utility bills (HS021 dal $RED_YEARSPLIT)|hs030 arr_loans Arrears on loans (HS031 dal $RED_YEARSPLIT)|hs040 holiday_cap Capacity to afford one week holiday|hs050 meal_cap Capacity to afford a meal with proteins|hs060 unexp_cap Capacity to face unexpected expenses|hs100 wash Washing machine|hs110 car Car|hs120 ends_meet Ability to make ends meet|hs140 house_burden Financial burden of housing cost|hs160 prob_dwell Problems with the dwelling|hs170 noise Noise from neighbours or street|hs180 pollution Pollution or environmental problems|hs190 crime_violence Crime or vandalism in the area|hx010 change_rate Exchange rate|hx040 hh_size Household size|hx050 e_hh_size Equivalised household size|hx060 hh_type Household type|hx070 tenure_state Tenure status (derived)|hx080 poverty At risk of poverty|hx090 e_income Equivalised disposable income|hx120 crowd Overcrowded household|hy010 tot_income Total household gross income|hy010_i tot_income_i Imputation factor HY010|hy020 tot_disp_income Total disposable household income|hy020_i tot_disp_income_i Imputation factor HY020|db040 region Region (NUTS)|db090 hh_weight Household cross-sectional weight (D, fino a L-2013)|db095 hh_weight_l Household weight DB095 (D, da L-2014)|db100 urban Degree of urbanisation|db050 strata Stratum (DB050)|db060 psu Primary sampling unit (DB060)"
red_rename `"`hmap'"' `ph'
postclose `ph'

* --- peso famiglia unico: DB095 (release da L-2014) altrimenti DB090 (fino a L-2013).
*     Il nome cambia con la release da cui proviene la cella, non con l'anno:
*     nello stesso anno possono convivere coorti con DB090 e coorti con DB095.
capture confirm variable hh_weight_l, exact
local has95 = (_rc == 0)
capture confirm variable hh_weight, exact
local has90 = (_rc == 0)
generate double hh_w = .
generate str5 hh_w_src = ""
if `has95' {
    quietly replace hh_w_src = "DB095" if !missing(hh_weight_l)
    quietly replace hh_w = hh_weight_l if !missing(hh_weight_l)
}
if `has90' {
    quietly replace hh_w_src = "DB090" if missing(hh_w) & !missing(hh_weight)
    quietly replace hh_w = hh_weight if missing(hh_w) & !missing(hh_weight)
}
label variable hh_w "Peso familiare del file D (DB095 da L-2014, DB090 fino a L-2013)"
label variable hh_w_src "Variabile d'origine di hh_w"
* diagnostica: somme per anno e release di provenienza
preserve
generate byte _one = 1
generate byte _pos = hh_w > 0 & !missing(hh_w)
collapse (sum) n_hh=_one n_hh_wpos=_pos hh_w_sum=hh_w, by(year src_release hh_w_src)
bysort year: egen double hh_w_sum_year = total(hh_w_sum)
export delimited using "`out'/reduce_hhweight_diag.csv", replace
restore

local hids "country year hh_uid hh_num hid_s cohort_id src_release"
local hnew ""
preserve
use `rv', clear
generate str4 file = "HH"
* nell'ordine della mappa, non alfabetico
local _n = _N
forvalues i = 1/`_n' {
    if status[`i'] == "renamed" local hnew `hnew' `=target[`i']'
}
export delimited using "`out'/reduce_vars_HH.csv", replace
restore
local _ok ""
foreach v of local hids {
    capture confirm variable `v', exact
    if !_rc local _ok `_ok' `v'
}
local hids `_ok'
local hnew `hnew' hh_w hh_w_src
keep `hids' `hnew'
order `hids' `hnew'
compress
label data "EU-SILC longitudinale IT - famiglie, variabili ridotte (reduce_long.do)"
char _dta[red_source] "$RED_RUN"
isid year hh_uid
red_coverage "`hnew'" "`out'/reduce_coverage_HH.csv"
save "`out'/HH_long_reduced.dta", replace
di as result "Famiglie: `=_N' righe -> `out'/HH_long_reduced.dta"

*==============================================================================
* 2. PERSONE: panel_person_year
*==============================================================================
use "$RED_RUN/panel_person_year.dta", clear

* --- istruzione: PE040 (ISCED 1997 / 2011 3 cifre) -> PE041 (dal 2021)
red_ensure pe040 double
red_ensure pe041 double
red_num pe040
red_num pe041
generate double _att = pe040
quietly replace _att = pe041 if missing(_att) & !missing(pe041)
generate byte educ3 = .
quietly replace educ3 = 1 if inrange(_att, 0, 2) | inrange(_att, 100, 299)
quietly replace educ3 = 2 if inrange(_att, 3, 4) | inrange(_att, 300, 499)
quietly replace educ3 = 3 if inrange(_att, 5, 8) | inrange(_att, 500, 899)
label define red_educ3 1 "Low (ISCED 0-2)" 2 "Medium (ISCED 3-4)" 3 "High (ISCED 5-8)", replace
label values educ3 red_educ3
label variable educ3 "Educational attainment armonizzato 2004-2024"
generate byte isced = .
quietly replace isced = _att if inrange(_att, 0, 8)
quietly replace isced = floor(_att / 100) if inrange(_att, 100, 899)
label variable isced "Highest ISCED attained, approx ISCED-2011 (0-8)"
drop _att

* --- variabili rinominate alla rottura IESS 2021 (vecchia <= 2020, nuova >= 2021)
foreach trip in "pl015 pl016 ever_job Person has ever worked" ///
                "pl040 pl040a empl Status in employment (main job)" ///
                "pe020 pe021 isced_curr ISCED currently attended (PE020/PE021)" ///
                "rb210 rb211 basic_act Activity status (RB210/RB211 self-defined)" {
    local old : word 1 of `trip'
    local new : word 2 of `trip'
    local tgt : word 3 of `trip'
    local lbl : list trip - old
    local lbl : list lbl - new
    local lbl : list lbl - tgt
    red_ensure `old' double
    red_ensure `new' double
    red_num `old'
    red_num `new'
    generate double `tgt' = `old'
    quietly replace `tgt' = `new' if missing(`tgt') & !missing(`new')
    label variable `tgt' "`lbl'"
}

* --- paese di nascita e cittadinanza: PB210/PB220A (P, <= 2020) -> RB280/RB290 (R, >= 2021)
*     1 = local, 2 = other EU, 3 = other. VERIFICARE i codici di RB280/RB290
*     nel codebook 2021: qui si accettano LOC/EU/OTH oppure 1/2/3.
label define red_birthc 1 "Local (same country)" 2 "Other EU" 3 "Other", replace
foreach trip in "pb210 rb280 birth_country" "pb220a rb290 citizenship" {
    local old : word 1 of `trip'
    local new : word 2 of `trip'
    local tgt : word 3 of `trip'
    red_ensure `old' str
    red_ensure `new' str
    red_str `old'
    red_str `new'
    generate byte `tgt' = .
    quietly replace `tgt' = 1 if inlist(strtrim(`old'), "LOC", "1")
    quietly replace `tgt' = 2 if inlist(strtrim(`old'), "EU", "2")
    quietly replace `tgt' = 3 if inlist(strtrim(`old'), "OTH", "3")
    quietly replace `tgt' = 1 if missing(`tgt') & inlist(strtrim(`new'), "LOC", "1")
    quietly replace `tgt' = 2 if missing(`tgt') & inlist(strtrim(`new'), "EU", "2")
    quietly replace `tgt' = 3 if missing(`tgt') & inlist(strtrim(`new'), "OTH", "3")
    quietly count if missing(`tgt') & (strtrim(`old') != "" | strtrim(`new') != "")
    if r(N) > 0 di as error "`tgt': `r(N)' valori non riconosciuti in `old'/`new' (verificare i codici)"
    label values `tgt' red_birthc
}
label variable birth_country "Country of birth grouped (PB210<=2020 / RB280>=2021)"
label variable citizenship "Main citizenship grouped (PB220A<=2020 / RB290>=2021)"

tempname ph
tempfile rv
postfile `ph' str32 source str32 target str16 status using `rv', replace
local pmap "pb030 pp_id Personal ID (PB030)|pb040 pp_wieght Personal cross-sectional weight (PB040)|pb050 pp_base_weight Personal base weight (PB050)|pb060 pp_weight_ss Personal weight selected respondent (PB060)|pb140 birth_yr Year of birth (P)|pb150 sex Sex (P)|pb190 marital Marital status|ph010 health General health|ph020 cronic_ill Chronic illness|ph030 limitation Limitation in activities|ph040 no_med_treat Unmet need for medical examination|ph050 reason_no_med_treat Reason for unmet medical need|ph060 no_dental Unmet need for dental examination|ph070 reason_no_dental Reason for unmet dental need|pl020 look_job Actively looking for a job|pl025 ava_job Available for work|pl035 lw_work Worked at least one hour|pd020 replace_cloth Replace worn-out clothes|pd030 shoes Two pairs of shoes|pd050 drink Get-together with friends/family|pd060 leisure Regular leisure activity|pd070 auto_money Spend money on oneself|pd080 internet Internet connection|pt060 father_birth_c Country of birth of father|pt070 father_city Citizenship of father|pt090 mother_birth_c Country of birth of mother|pt100 mother_city Citizenship of mother|pt110 father_edu Education of father|pt120 mother_edu Education of mother|py021g car_comp Company car (gross)|py021g_i car_comp_i Imputation factor PY021G|py021n car_comp2 Company car (net)|py021n_i car_comp2_i Imputation factor PY021N|rb050 r_weight Personal cross-sectional weight (RB050)|rb060 r_base_weight Personal base weight (RB060)|rb080 birth_year Year of birth (R)|rb090 r_sex Sex (R)|rb200 r_residential Residential status|rb245 respondent_status Respondent status|rx010 interview_age Age at the date of the interview|rx030 house_id Household ID (RX030)|rx060 deprived_hh Severely materially deprived household|rx070 poverty_exclusion At risk of poverty or social exclusion|db050 strata Stratum (DB050)|db060 psu Primary sampling unit (DB060)|release_year src_release Release longitudinale di provenienza (riga R)"
red_rename `"`pmap'"' `ph'
postclose `ph'

* --- pesi longitudinali scelti (RED_LW), solo negli anni della finestra
local lwnew ""
foreach pair of global RED_LW {
    local pair : subinstr local pair ":" " "
    local wv : word 1 of `pair'
    local wr : word 2 of `pair'
    tempfile lw
    preserve
    use person_uid w_start w_end w_value weight_var w_release window_complete_in_panel ///
        if weight_var == "`wv'" & w_release == `wr' & window_complete_in_panel == 1 ///
        using "$RED_RUN/long_weight_windows.dta", clear
    if _N == 0 {
        di as error "RED_LW: nessuna finestra completa per `wv' nella release `wr'"
        exit 2000
    }
    isid person_uid
    keep person_uid w_start w_end w_value
    quietly save `lw', emptyok
    restore
    merge m:1 person_uid using `lw', keep(master match) nogenerate
    generate double lw_`wv'_`wr' = w_value if inrange(year, w_start, w_end)
    label variable lw_`wv'_`wr' "`wv' di L-`wr' (finestra completa nel panel), solo anni della finestra"
    drop w_start w_end w_value
    local lwnew `lwnew' lw_`wv'_`wr'
}

local pids "person_num person_uid pid_s country year cohort_id hh_uid hh_num multi_hh multi_cohort_year n_rel in_P"
local pharm "educ3 isced ever_job empl isced_curr basic_act birth_country citizenship"
local pnew ""
preserve
use `rv', clear
generate str4 file = "PP"
* nell'ordine della mappa, non alfabetico
local _n = _N
forvalues i = 1/`_n' {
    if status[`i'] == "renamed" local pnew `pnew' `=target[`i']'
}
local nsrc : word count $RED_CREATED
quietly set obs `=_N + `nsrc''
local i = _N - `nsrc'
foreach v of global RED_CREATED {
    local ++i
    quietly replace source = "`v'" in `i'
    quietly replace target = "(armonizzazione)" in `i'
    quietly replace status = "absent_created" in `i'
    quietly replace file = "both" in `i'
}
export delimited using "`out'/reduce_vars_PP.csv", replace
restore
local _ok ""
foreach v of local pids {
    capture confirm variable `v', exact
    if !_rc local _ok `_ok' `v'
}
local pids `_ok'
keep `pids' `pharm' `pnew' `lwnew'
order `pids' `pharm' `pnew' `lwnew'
compress
label data "EU-SILC longitudinale IT - persone, variabili ridotte (reduce_long.do)"
char _dta[red_source] "$RED_RUN"
isid person_num year
xtset person_num year
red_coverage "`pharm' `pnew' `lwnew'" "`out'/reduce_coverage_PP.csv"
save "`out'/PP_long_reduced.dta", replace
di as result "Persone: `=_N' righe -> `out'/PP_long_reduced.dta"
if "$RED_CREATED" != "" di as text "Sorgenti assenti create vuote per le armonizzazioni: $RED_CREATED"

*==============================================================================
* 3. FILE UNICO PERSONE + FAMIGLIE (persona-anno)
*==============================================================================
* Le variabili familiari si attaccano alla persona tramite la sua famiglia
* nell'anno (hh_uid). Restano mancanti, con hh_linked = 0, se la persona ha piu'
* famiglie nell'anno (multi_hh = 1) o se la famiglia non ha record H (non
* rispondente). Per stime a livello famiglia usare HH_long_reduced.dta: qui
* ogni famiglia compare una volta per ogni suo componente.
quietly describe using "`out'/HH_long_reduced.dta", varlist
local hvl `r(varlist)'
unab pvl : _all
local hadd : list hvl - pvl
local hadd : list hadd - hids
local hclash : list hvl & pvl
local hclash : list hclash - hids
if "`hclash'" != "" di as text "Variabili familiari gia' presenti nel file persone (si tengono quelle delle persone): `hclash'"
merge m:1 year hh_uid using "`out'/HH_long_reduced.dta", keepusing(`hadd') keep(master match)
generate byte hh_linked = _merge == 3
drop _merge
label variable hh_linked "variabili familiari attaccate (famiglia unica e rispondente nell'anno)"
quietly count if hh_linked == 0 & multi_hh == 0 & hh_uid != ""
local nonresp = r(N)
quietly count if multi_hh == 1
di as text "File unico: `nonresp' persone-anno con famiglia senza record H; `r(N)' persone-anno con piu' famiglie (variabili familiari mancanti)"
order `pids' hh_linked
isid person_num year
xtset person_num year
label data "EU-SILC longitudinale IT - persone con variabili familiari (reduce_long.do)"
save "`out'/PPHH_long_reduced.dta", replace
di as result "File unico: `=_N' righe -> `out'/PPHH_long_reduced.dta"
log close redlog
