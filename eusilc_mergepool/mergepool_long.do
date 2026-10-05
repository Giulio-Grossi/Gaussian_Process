*! mergepool_long.do  -  versione 0.1 (bozza non ancora eseguita su Stata)
*! Panel cumulato di panel brevi EU-SILC longitudinale (release UDB L-XXXX)
*! Estensione metodologica di eusilcpanel_2020 (Borst & Wirth, GESIS Papers 2022/10)
*!
*! Requisito: Stata 16.0 o successivo (ustrregexm/ustrregexs, Mata direxists(),
*! strL, postfile con stringhe lunghe). Nessun pacchetto esterno.
*! Portabilita': usare "/" nei percorsi anche su Windows.
*!
*! Modalita':
*!   inspect : inventario e diagnostica dei .dta, nessun output definitivo
*!   build   : costruzione masterD/H/R/P, panel_person_year, registri e diagnostiche
*!   demo    : dati artificiali + test automatici delle regole di selezione
*!
*! Principi (vedi README.md nella stessa cartella):
*!  - l'identita' della coorte NON e' DB075 ne' minyear+3: e' una tabella di
*!    corrispondenza (gruppo DB075 x release) -> cohort_id costruita su regole
*!    esplicite, sovrapposizione di ID famiglia negli stessi anni, mapping manuale;
*!  - una cella (country, observation_year, cohort_id) proviene da UNA sola
*!    release/versione, la piu' recente ammissibile; nessun recupero di singoli
*!    record da release vecchie dentro celle gia' coperte;
*!  - anti-join con merge m:1 contro un registro di celle con isid;
*!  - pesi originali conservati; riscalatura storica solo in modalita' "legacy";
*!  - se una verifica essenziale fallisce, l'output resta nella cartella della
*!    run con NOT_CERTIFIED.txt e non sovrascrive l'ultimo output certificato.

version 16.0
clear all
capture log close mlrun
set more off
set varabbrev off
set linesize 200

*==============================================================================
* 0. CONFIGURAZIONE  (unico blocco da modificare)
*==============================================================================

* --- Percorsi (usare "/" anche su Windows; nessuna "/" finale) ---------------
* ML_INDIR = cartella dei .dta LONGITUDINALI (non DATA_LONG, che contiene i CSV).
* Struttura attesa (ricerca ricorsiva, spazi nei nomi ammessi):
*   DATA/LONG/HOUSEHOLD REGISTER/long_hh_d_AAAA.dta   (D)
*   DATA/LONG/HOUSEHOLD/long_hh_h_AAAA.dta            (H)
*   DATA/LONG/PERSONAL REGISTER/long_rl_AAAA.dta      (R)
*   DATA/LONG/PERSONAL/long_pd_AAAA.dta               (P)
* AAAA = anno della release longitudinale; il tipo e' riconosciuto dalle variabili.
global ML_INDIR    "/Volumes/ext_blu/EUSILC/DATA/LONG"   // sola lettura
global ML_WORKDIR  "/Volumes/ext_blu/EUSILC/WORK_LONG"   // file intermedi (creata se manca)
global ML_OUTDIR   "/Volumes/ext_blu/EUSILC/OUTPUT"      // output (una sottocartella per run)
* Filtri sul nome dei file (espressioni regolari ICU; "" = nessun filtro).
* "^long_" esclude p.es. DATA/LONG/HOUSEHOLD/cross_hh_h_2005.dta (trasversale).
global ML_FNAME_INCLUDE "^long_"
global ML_FNAME_EXCLUDE ""

* --- Modalita': inspect | build | demo ----------------------------------------
global ML_MODE     "inspect"

* --- Paesi e release -----------------------------------------------------------
global ML_COUNTRIES   "IT"
* Release longitudinali (anno dell'operazione L-XXXX) da cui si prelevano celle.
global ML_RELEASES    "2019 2020 2021 2022 2023 2024"
* Release usate SOLO per risolvere l'identita' delle coorti (non forniscono celle).
* Esempio: "2017 2018" per collegare coorti entrate prima del 2019.
global ML_ID_RELEASES ""
* Versione UDB per release: obbligatoria se nell'input esistono piu' versioni
* della stessa release (nessuna scelta implicita). Formato come nel nome file.
* global ML_UDBVER_2021 "2023-09"

* --- Mapping espliciti (CSV, facoltativi) -------------------------------------
* Mappa file:    path,release_year,udb_version,ftype   (ftype = D|H|R|P)
global ML_FILEMAP     ""
* Mappa coorti:  country,release_year,rg,cohort_label,note
*   rg = valore di DB075 come stringa; righe con stesso cohort_label (e paese)
*   vengono fuse; un gruppo mappato manualmente prevale sul collegamento automatico.
global ML_COHORTMAP   ""
* Regole di disegno documentate: country,entry_from,entry_to,duration,source,status
*   usate SOLO come diagnostica (durata prevista vs osservata), mai come chiave.
global ML_DESIGNFILE  ""
* esempio: global ML_DESIGNFILE "/Volumes/ext_blu/EUSILC/SCRIPT/SCRIPT LONG/design_IT.csv"
*          (copia di config/design_IT.csv del repository)

* --- Collegamento coorti fra release -------------------------------------------
* Quota minima di famiglie-anno condivise (entrambe le direzioni) per unire due gruppi.
global ML_OVERLAP_MIN   0.80
* Sovrapposizione "parziale": >= questa soglia ma < ML_OVERLAP_MIN => ambiguita'.
global ML_OVERLAP_WEAK  0.05

* --- Selezione delle celle -------------------------------------------------------
*   strict     : cella attesa ma assente in una release piu' recente => NON recuperata
*   permissive : recuperata dalla release piu' vecchia e segnalata
global ML_CELLPOLICY  "strict"

* --- Pesi ----------------------------------------------------------------------
*   raw    : pesi originali invariati + diagnostiche + finestre longitudinali
*   legacy : in aggiunta, riscalature storiche di eusilcpanel_2020 (solo confronto)
global ML_WEIGHTMODE  "raw"
* Ancoraggio della finestra dei pesi longitudinali RB06k: "end" = il valore
* riportato nell'anno t si riferisce agli anni [t-k+1, t]. DA VERIFICARE nelle
* Methodological guidelines della release (DocSILC065) prima dell'uso inferenziale.
global ML_LWIN_ANCHOR "end"
global ML_WEIGHTVARS  "rb050 rb060 rb062 rb063 rb064 rb065 rb066 pb040 pb050 pb060 pb080"
global ML_DESIGNVARS  "db050 db060 db062 db070 db090 db095"
* Popolazione (facoltativa, .dta con country year pop) per diagnostiche su rb060.
global ML_POPFILE     ""

* --- Altro ---------------------------------------------------------------------
global ML_GR2EL       1     // ricodifica GR -> EL (regola storica eusilcpanel)
global ML_LEGACYDIR   ""    // cartella con masterD.dta di eusilcpanel_2020 per confronto
global ML_IDMAPDIR    ""    // mappe ID persistenti; default: ML_OUTDIR/idmaps

*==============================================================================
* 1. UTILITA'
*==============================================================================

capture program drop ml_mkdir
program define ml_mkdir
    args p
    mata: st_local("ex", strofreal(direxists(st_local("p"))))
    if "`ex'" == "0" mkdir "`p'"
end

capture program drop ml_fexists
program define ml_fexists, rclass
    args p
    mata: st_local("ex", strofreal(fileexists(st_local("p"))))
    return scalar exists = `ex'
end

* Errore che impedisce la certificazione ma non interrompe l'esecuzione.
capture program drop ml_fail
program define ml_fail
    args code msg
    di as error "[NON CERTIFICABILE] `code': `msg'"
    global ML_NFAIL = $ML_NFAIL + 1
    tempname fh
    file open `fh' using "$ML_RUNDIR/certification_failures.txt", write append text
    file write `fh' "`code'" _tab "`msg'" _n
    file close `fh'
end

* Avviso: documentato, non blocca la certificazione.
capture program drop ml_warn
program define ml_warn
    args code msg
    di as text "[AVVISO] `code': `msg'"
    global ML_NWARN = $ML_NWARN + 1
    tempname fh
    file open `fh' using "$ML_RUNDIR/warnings.txt", write append text
    file write `fh' "`code'" _tab "`msg'" _n
    file close `fh'
end

* Interruzione: salva il motivo e termina. Le diagnostiche vanno salvate PRIMA.
capture program drop ml_stop
program define ml_stop
    args code msg
    ml_fail "`code'" "`msg'"
    tempname fh
    file open `fh' using "$ML_RUNDIR/STOPPED.txt", write replace text
    file write `fh' "Esecuzione interrotta: `code' - `msg'" _n
    file write `fh' "Output parziali in questa cartella: NON certificati." _n
    file close `fh'
    di as error "STOP `code': `msg'"
    exit 459
end

* Salvataggio di una tabella diagnostica in .dta e .csv nella cartella della run.
capture program drop ml_savediag
program define ml_savediag
    args name
    save "$ML_RUNDIR/`name'.dta", replace emptyok
    if _N > 0 export delimited using "$ML_RUNDIR/`name'.csv", replace
end

* isid con diagnostica salvata prima di interrompere (o di segnalare con soft).
capture program drop ml_isid
program define ml_isid
    syntax varlist, Code(string) [Soft]
    capture isid `varlist', missok
    if _rc {
        * niente preserve: ml_isid puo' essere chiamato dentro un preserve
        tempfile hold
        quietly save `hold', emptyok
        duplicates tag `varlist', generate(_ml_dup)
        quietly keep if _ml_dup > 0
        save "$ML_RUNDIR/diag_dups_`code'.dta", replace emptyok
        use `hold', clear
        if "`soft'" != "" ml_fail "`code'" "chiave non univoca: `varlist'"
        else ml_stop "`code'" "chiave non univoca: `varlist'"
    }
end

* Nomi in minuscolo con controllo esplicito delle collisioni (niente cap rename).
capture program drop ml_lower
program define ml_lower
    unab all : _all
    local low ""
    foreach v of local all {
        local lv = lower("`v'")
        local low `low' `lv'
    }
    local dups : list dups low
    if "`dups'" != "" {
        di as error "collisione fra nomi di variabile dopo la minuscolizzazione: `dups'"
        exit 110
    }
    rename *, lower
end

* Identificativo come stringa, senza perdita di zeri iniziali e con controllo
* di precisione: un ID gia' troncato in float non e' recuperabile.
capture program drop ml_idstr
program define ml_idstr, rclass
    syntax newvarname, From(varname)
    local t : type `from'
    capture confirm string variable `from'
    if !_rc {
        generate str `varlist' = strtrim(`from')
        quietly count if ustrregexm(`varlist', "^0[0-9]")
        return scalar lead0 = r(N)
    }
    else {
        quietly count if !missing(`from') & `from' != floor(`from')
        if r(N) > 0 {
            di as error "`from': `r(N)' valori non interi in un identificativo"
            exit 459
        }
        if "`t'" == "float" {
            quietly summarize `from'
            if r(max) > 16777216 | r(min) < -16777216 {
                di as error "`from' e' float con valori oltre 2^24: precisione gia' persa"
                exit 459
            }
        }
        generate str `varlist' = string(`from', "%20.0f") if !missing(`from')
        return scalar lead0 = 0
    }
    quietly count if `varlist' == ""
    return scalar nmiss = r(N)
    return local srctype "`t'"
end

* Codice paese come stringa a due lettere; regola esplicita per numerici etichettati.
capture program drop ml_country
program define ml_country
    args cv
    capture confirm string variable `cv'
    if !_rc {
        generate str country = strupper(strtrim(`cv'))
    }
    else {
        local lab : value label `cv'
        if "`lab'" == "" {
            di as error "`cv' numerica senza value label: regola di conversione non definita"
            exit 109
        }
        decode `cv', generate(country)
        replace country = strupper(strtrim(country))
    }
    quietly count if ustrlen(country) != 2
    if r(N) > 0 {
        di as error "`cv': `r(N)' codici paese non a due caratteri"
        exit 459
    }
    generate str country_orig = country
    if $ML_GR2EL == 1 replace country = "EL" if country == "GR"
end

* Tiene i soli paesi configurati.
capture program drop ml_keepcountries
program define ml_keepcountries
    generate byte _ml_keep = 0
    foreach c of global ML_COUNTRIES {
        quietly replace _ml_keep = 1 if country == "`c'"
    }
    quietly keep if _ml_keep == 1
    drop _ml_keep
end

* Chiavi armonizzate per tipo di file. Le variabili originali restano intatte.
*  D: year country hid_s rg_s     H: year country hid_s
*  R: year country pid_s hid_s    P: year country pid_s
capture program drop ml_keys
program define ml_keys, rclass
    syntax , Ftype(string)
    local f = lower("`ftype'")
    foreach v in year country country_orig hid_s pid_s rg_s release_year udb_version src_file cohort_id hh_uid person_uid {
        capture confirm variable `v', exact
        if !_rc {
            di as error "variabile riservata `v' gia' presente nell'input: rinominarla prima"
            exit 110
        }
    }
    confirm variable `f'b010 `f'b020 `f'b030, exact
    confirm numeric variable `f'b010
    quietly count if missing(`f'b010) | `f'b010 != floor(`f'b010)
    if r(N) > 0 {
        di as error "`f'b010: anni mancanti o non interi (`r(N)')"
        exit 459
    }
    generate int year = `f'b010
    ml_country `f'b020
    if inlist("`f'", "d", "h") {
        ml_idstr hid_s, from(`f'b030)
        return local idtype "`r(srctype)'"
        return scalar lead0 = r(lead0)
        return scalar nmiss = r(nmiss)
    }
    if inlist("`f'", "r", "p") {
        ml_idstr pid_s, from(`f'b030)
        return local idtype "`r(srctype)'"
        return scalar lead0 = r(lead0)
        return scalar nmiss = r(nmiss)
    }
    if "`f'" == "d" {
        confirm variable db075, exact
        ml_idstr rg_s, from(db075)
        return scalar rg_nmiss = r(nmiss)
    }
    if "`f'" == "r" {
        confirm variable rb040, exact
        ml_idstr hid_s, from(rb040)
        return scalar hid_nmiss = r(nmiss)
    }
end

*==============================================================================
* 2. SETUP DELLA RUN, INVENTARIO, CARICAMENTO
*==============================================================================

* Cartelle uniche per ogni run: output_dir/<mode>_<data>_<ora>[_k].
capture program drop ml_setup
program define ml_setup
    args mode
    foreach g in ML_INDIR ML_WORKDIR ML_OUTDIR ML_IDMAPDIR ML_FILEMAP ML_COHORTMAP ML_DESIGNFILE ML_POPFILE ML_LEGACYDIR {
        local x `"${`g'}"'
        local x : subinstr local x "\" "/", all
        global `g' `"`x'"'
    }
    if `"$ML_IDMAPDIR"' == "" global ML_IDMAPDIR "$ML_OUTDIR/idmaps"
    ml_mkdir "$ML_WORKDIR"
    ml_mkdir "$ML_OUTDIR"
    ml_mkdir "$ML_IDMAPDIR"
    local d = string(date(c(current_date), "DMY"), "%tdCCYYNNDD")
    local t = subinstr(c(current_time), ":", "", .)
    local base "`mode'_`d'_`t'"
    local run "$ML_OUTDIR/`base'"
    local k 1
    mata: st_local("ex", strofreal(direxists(st_local("run"))))
    while "`ex'" == "1" {
        local ++k
        local run "$ML_OUTDIR/`base'_`k'"
        mata: st_local("ex", strofreal(direxists(st_local("run"))))
    }
    local sfx = cond(`k' > 1, "_`k'", "")
    global ML_RUNDIR "`run'"
    global ML_TMPDIR "$ML_WORKDIR/`base'`sfx'"
    ml_mkdir "$ML_RUNDIR"
    ml_mkdir "$ML_TMPDIR"
    global ML_NFAIL 0
    global ML_NWARN 0
    tempname fh
    file open `fh' using "$ML_RUNDIR/certification_failures.txt", write replace text
    file write `fh' "code" _tab "message" _n
    file close `fh'
    file open `fh' using "$ML_RUNDIR/warnings.txt", write replace text
    file write `fh' "code" _tab "message" _n
    file close `fh'
    file open `fh' using "$ML_RUNDIR/run_config.txt", write replace text
    file write `fh' "mergepool_long.do v0.1 - Stata `c(stata_version)' - `c(os)' - `c(current_date)' `c(current_time)'" _n
    foreach g in ML_MODE ML_INDIR ML_WORKDIR ML_OUTDIR ML_FNAME_INCLUDE ML_FNAME_EXCLUDE ML_COUNTRIES ML_RELEASES ML_ID_RELEASES ML_FILEMAP ML_COHORTMAP ML_DESIGNFILE ML_OVERLAP_MIN ML_OVERLAP_WEAK ML_CELLPOLICY ML_WEIGHTMODE ML_LWIN_ANCHOR ML_WEIGHTVARS ML_DESIGNVARS ML_POPFILE ML_GR2EL ML_LEGACYDIR ML_IDMAPDIR {
        file write `fh' "`g' = ${`g'}" _n
    }
    foreach r in $ML_RELEASES $ML_ID_RELEASES {
        if "${ML_UDBVER_`r'}" != "" file write `fh' "ML_UDBVER_`r' = ${ML_UDBVER_`r'}" _n
    }
    file close `fh'
    di as text "Run: $ML_RUNDIR"
end

* Elenco ricorsivo dei .dta (nessuna struttura di cartelle imposta).
* Esclusi: file AppleDouble di macOS ("._nome.dta"), file temporanei ("~"),
* cartelle nascoste; poi filtri ML_FNAME_INCLUDE / ML_FNAME_EXCLUDE sul nome.
capture program drop ml_listdta
program define ml_listdta
    args dir postname
    local fl : dir "`dir'" files "*.dta"
    foreach f of local fl {
        if substr("`f'", 1, 2) == "._" | substr("`f'", 1, 1) == "~" continue
        if `"$ML_FNAME_INCLUDE"' != "" {
            if !ustrregexm("`f'", `"$ML_FNAME_INCLUDE"') continue
        }
        if `"$ML_FNAME_EXCLUDE"' != "" {
            if ustrregexm("`f'", `"$ML_FNAME_EXCLUDE"') continue
        }
        post `postname' (`"`dir'/`f'"') (`"`f'"')
    }
    local dl : dir "`dir'" dirs "*"
    foreach d of local dl {
        if substr("`d'", 1, 1) == "." continue
        ml_listdta "`dir'/`d'" `postname'
    }
end

* Release e versione dal nome file. Tre pattern per la release:
*   rel_a: "L-2019", "L_2019", "l2019"      rel_b: "l19D", "L19R" (formato breve)
*   rel_c: anno finale "..._2019.dta" (es. long_hh_d_2019.dta, long_rl_2019.dta)
* Versione: primo "AAAA-MM" / "AAAA_MM" / "AAAA.MM" con mese valido.
* Se i pattern trovati non concordano il file non viene assegnato: usare ML_FILEMAP.
capture program drop ml_parsefname
program define ml_parsefname
    generate int rel_a = real(ustrregexs(1)) if ustrregexm(fname, "[Ll][-_ ]?(20[0-9][0-9])")
    generate int rel_b = 2000 + real(ustrregexs(1)) if ustrregexm(fname, "[Ll]([0-2][0-9])[DHRPdhrp]")
    generate int rel_c = real(ustrregexs(1)) if ustrregexm(fname, "[-_ ](20[0-9][0-9])\.[Dd][Tt][Aa]$")
    generate str udb_version = ustrregexs(1) + "-" + ustrregexs(2) if ustrregexm(fname, "(20[0-9][0-9])[-_.](0[1-9]|1[0-2])([^0-9]|$)")
    generate int release_year = cond(!missing(rel_a), rel_a, cond(!missing(rel_b), rel_b, rel_c))
    generate str parse_status = "ok"
    replace parse_status = "release_not_parsed" if missing(release_year)
    replace parse_status = "release_ambiguous" if !missing(rel_a) & !missing(rel_b) & rel_a != rel_b
    replace parse_status = "release_ambiguous" if !missing(rel_c) & !missing(release_year) & rel_c != release_year
    drop rel_a rel_b rel_c
end

* Carica un file tenendo solo i paesi configurati gia' in lettura (i .dta
* possono contenere tutti i paesi). Se il codice paese non e' stringa
* (errore 109) il file viene caricato per intero e filtrato dopo.
capture program drop ml_usecty
program define ml_usecty
    args p ftype
    local f = lower("`ftype'")
    quietly describe using `"`p'"', varlist
    local rvl `r(varlist)'
    local cv ""
    foreach v of local rvl {
        if lower("`v'") == "`f'b020" local cv `v'
    }
    if "`cv'" != "" {
        local cond ""
        foreach c of global ML_COUNTRIES {
            local cond `"`cond' | strtrim(`cv') == "`c'""'
            if "`c'" == "EL" & $ML_GR2EL == 1 local cond `"`cond' | strtrim(`cv') == "GR""'
        }
        local cond = substr(`"`cond'"', 4, .)
        capture use if `cond' using `"`p'"', clear
        local rc = _rc
        if `rc' == 0 exit
        if `rc' != 109 {
            di as error "lettura non riuscita: `p' (rc=`rc')"
            exit `rc'
        }
    }
    use `"`p'"', clear
end

* Inventario: $ML_RUNDIR/inventory.dta e inventory_releases.dta
capture program drop ml_inventory
program define ml_inventory
    tempname ph
    tempfile raw
    if `"$ML_FILEMAP"' != "" {
        import delimited using `"$ML_FILEMAP"', clear varnames(1) stringcols(_all) encoding("utf-8")
        ml_lower
        confirm variable path release_year udb_version ftype, exact
        replace path = subinstr(strtrim(path), "\", "/", .)
        generate str fname = ustrregexra(path, "^.*/", "")
        generate int rel_n = real(release_year)
        drop release_year
        rename rel_n release_year
        replace ftype = strupper(strtrim(ftype))
        replace udb_version = strtrim(udb_version)
        generate str src_detect = "filemap"
        generate str parse_status = cond(missing(release_year), "release_invalid", "ok")
        local nmap = _N
        forvalues i = 1/`nmap' {
            local p = path[`i']
            ml_fexists `"`p'"'
            if r(exists) == 0 {
                di as error "file in ML_FILEMAP inesistente: `p'"
                exit 601
            }
        }
    }
    else {
        postfile `ph' str2045 path str244 fname using `raw', replace
        ml_listdta "$ML_INDIR" `ph'
        postclose `ph'
        use `raw', clear
        if _N == 0 {
            di as error "nessun .dta trovato in $ML_INDIR"
            exit 601
        }
        ml_parsefname
        generate str src_detect = "filename"
        generate str ftype = ""
    }
    * Tipo del file dalle variabili (describe using: non carica i dati).
    generate double n_obs = .
    generate int n_vars = .
    generate str ftype_vars = ""
    local N = _N
    forvalues i = 1/`N' {
        local p = path[`i']
        quietly describe using `"`p'"', varlist
        local rN = r(N)
        local rk = r(k)
        local rvl `r(varlist)'
        quietly replace n_obs = `rN' in `i'
        quietly replace n_vars = `rk' in `i'
        local vl ""
        foreach v of local rvl {
            local lv = lower("`v'")
            local vl `vl' `lv'
        }
        local t ""
        foreach x in d h r p {
            local pos : list posof "`x'b030" in vl
            if `pos' > 0 {
                local ux = upper("`x'")
                local t `t' `ux'
            }
        }
        quietly replace ftype_vars = "`t'" in `i'
    }
    generate str type_status = "ok"
    if `"$ML_FILEMAP"' != "" {
        replace type_status = "type_mismatch_filemap" if ftype != ftype_vars
    }
    else {
        replace type_status = "type_unknown" if ftype_vars == ""
        replace type_status = "type_ambiguous" if wordcount(ftype_vars) > 1
        replace ftype = ftype_vars if type_status == "ok"
    }
    replace udb_version = "unknown" if udb_version == ""
    * Selezione release/versione: mai il primo risultato di un wildcard.
    generate byte in_build = 0
    foreach r of global ML_RELEASES {
        replace in_build = 1 if release_year == `r'
    }
    generate byte in_idonly = 0
    foreach r of global ML_ID_RELEASES {
        replace in_idonly = 1 if release_year == `r' & in_build == 0
    }
    generate byte usable = type_status == "ok" & parse_status == "ok" & (in_build | in_idonly)
    generate byte selected = 0
    generate str sel_status = ""
    local rels ""
    quietly count if usable
    if r(N) > 0 quietly levelsof release_year if usable, local(rels)
    foreach r of local rels {
        quietly levelsof udb_version if release_year == `r' & usable, local(vers) clean
        local nv : word count `vers'
        local want "${ML_UDBVER_`r'}"
        if "`want'" != "" {
            quietly count if release_year == `r' & usable & udb_version == "`want'"
            if r(N) == 0 replace sel_status = "configured_version_absent" if release_year == `r' & usable
            else {
                replace selected = 1 if release_year == `r' & usable & udb_version == "`want'"
                replace sel_status = "selected_by_config" if selected == 1 & release_year == `r'
                replace sel_status = "other_version" if selected == 0 & release_year == `r' & usable
            }
        }
        else if `nv' == 1 {
            replace selected = 1 if release_year == `r' & usable
            replace sel_status = "single_version" if release_year == `r' & usable
        }
        else {
            replace sel_status = "multiple_versions_unresolved" if release_year == `r' & usable
        }
    }
    replace sel_status = "not_configured_release" if usable == 0 & type_status == "ok" & parse_status == "ok"
    replace sel_status = "unusable" if type_status != "ok" | parse_status != "ok"
    order path fname ftype release_year udb_version selected sel_status type_status parse_status n_obs n_vars
    sort release_year ftype udb_version fname
    ml_savediag "inventory"
    * Compatibilita' D/H/R/P per release selezionata (stessa versione per i 4 tipi).
    preserve
    quietly keep if selected == 1
    if _N > 0 {
        generate byte isD = ftype == "D"
        generate byte isH = ftype == "H"
        generate byte isR = ftype == "R"
        generate byte isP = ftype == "P"
        collapse (sum) nD=isD nH=isH nR=isR nP=isP (first) udb_version (max) in_build in_idonly, by(release_year)
        generate str rel_status = "ok"
        replace rel_status = "missing_required_D_or_R" if nD == 0 | nR == 0
        replace rel_status = "missing_H_or_P" if rel_status == "ok" & (nH == 0 | nP == 0)
    }
    ml_savediag "inventory_releases"
    restore
end

* Controllo dei tipi (stringa/numerico) e delle value label prima dell'append.
* Nessun "append, force": un conflitto di tipo interrompe con diagnostica.
capture program drop ml_appendsafe
program define ml_appendsafe
    syntax , Files(string asis) Diag(string)
    local nfiles : word count `files'
    if `nfiles' > 1 {
        tempname ph
        tempfile types labs
        postfile `ph' int fileno str32 varname byte isstr using `types', replace
        local i 0
        foreach f of local files {
            local ++i
            use if 0 using `"`f'"', clear
            foreach v of varlist _all {
                local t : type `v'
                post `ph' (`i') ("`v'") (substr("`t'", 1, 3) == "str")
            }
        }
        postclose `ph'
        use `types', clear
        bysort varname (isstr): generate byte conflict = isstr[1] != isstr[_N]
        quietly count if conflict
        if r(N) > 0 {
            keep if conflict
            ml_savediag "diag_typeconflict_`diag'"
            ml_stop "TYPE_CONFLICT_`diag'" "variabili stringa in un file e numeriche in un altro"
        }
        * Value label omonime con codifiche diverse: in append prevale la
        * definizione del primo file; il conflitto viene documentato.
        clear
        generate str32 lname = ""
        quietly save `labs', emptyok
        local i 0
        foreach f of local files {
            local ++i
            capture uselabel using `"`f'"', clear
            local rc = _rc
            if `rc' == 0 {
                if _N > 0 {
                    generate int fileno = `i'
                    generate str2045 labtxt = substr(label, 1, 2045)
                    keep lname value labtxt fileno
                    append using `labs'
                    quietly save `labs', replace emptyok
                }
            }
            else ml_warn "LABEL_READ_`diag'" "uselabel non riuscito sul file `i' (rc=`rc')"
        }
        use `labs', clear
        if _N > 0 {
            bysort lname value (labtxt): generate byte lconf = labtxt[1] != labtxt[_N]
            bysort lname: egen byte anyconf = max(lconf)
            quietly keep if anyconf == 1
            if _N > 0 {
                ml_savediag "diag_labelconflict_`diag'"
                ml_warn "VALUE_LABEL_CONFLICT_`diag'" "value label omonime con testi diversi: prevale il primo file"
            }
        }
    }
    local i 0
    foreach f of local files {
        local ++i
        if `i' == 1 use `"`f'"', clear
        else append using `"`f'"'
    }
end

* Carica tutti i file selezionati di un tipo per una release, con chiavi armonizzate.
capture program drop ml_loadtype
program define ml_loadtype, rclass
    syntax , Rel(integer) Ftype(string)
    use "$ML_RUNDIR/inventory.dta", clear
    quietly keep if selected == 1 & release_year == `rel' & ftype == "`ftype'"
    local nf = _N
    if `nf' == 0 {
        clear
        return scalar nfiles = 0
        exit
    }
    local ver = udb_version[1]
    forvalues i = 1/`nf' {
        local p`i' = path[`i']
    }
    local flist ""
    forvalues i = 1/`nf' {
        ml_usecty `"`p`i''"' `ftype'
        ml_lower
        ml_keys, ftype(`ftype')
        local k_nmiss = r(nmiss)
        local k_rgmiss = cond("`ftype'" == "D", r(rg_nmiss), 0)
        local k_hidmiss = cond("`ftype'" == "R", r(hid_nmiss), 0)
        if `k_nmiss' > 0 ml_fail "KEY_MISSING_`ftype'_`rel'" "`k_nmiss' righe con ID mancante nel file `i'"
        if `k_rgmiss' > 0 ml_fail "DB075_MISSING_`rel'" "`k_rgmiss' famiglie senza DB075"
        if `k_hidmiss' > 0 ml_warn "RB040_MISSING_`rel'" "`k_hidmiss' righe R senza RB040"
        ml_keepcountries
        generate int release_year = `rel'
        generate str udb_version = "`ver'"
        generate str src_file = `"`p`i''"'
        tempfile f`i'
        quietly save `f`i'', emptyok
        local flist `"`flist' "`f`i''""'
    }
    ml_appendsafe, files(`flist') diag(`ftype'_`rel')
    if `nf' > 1 & _N > 0 {
        bysort country (src_file): generate byte _ml_x = src_file[1] != src_file[_N]
        quietly count if _ml_x
        if r(N) > 0 {
            preserve
            quietly keep if _ml_x
            contract country src_file
            ml_savediag "diag_country_in_multiple_files_`ftype'_`rel'"
            restore
            ml_stop "FILES_OVERLAP_`ftype'_`rel'" "stesso paese in piu' file della stessa release/versione"
        }
        drop _ml_x
    }
    return scalar nfiles = `nf'
    return local udb_version "`ver'"
end

*==============================================================================
* 3. IDENTITA' DELLE COORTI: tabella (country, release, DB075) -> cohort_id
*==============================================================================
* Nodo  = gruppo DB075 in una release (country, release_year, rg_s).
* Arco  = due nodi di release diverse che condividono famiglie-anno (year, DB030).
*   Denominatori: famiglie-anno di ciascun gruppo negli anni osservati in ENTRAMBI.
*   share_a = m/n_a, share_b = m/n_b.
*   "strong"     : min(share_a, share_b) >= ML_OVERLAP_MIN
*   "weak"       : max(share_a, share_b) >= ML_OVERLAP_WEAK ma non strong
*   "negligible" : il resto (ID riutilizzati per caso; registrato, non usato)
*   Uno-a-molti: un nodo con >1 arco strong verso la stessa release => ambiguo.
*   Un nodo con un arco weak => ambiguo (una fusione parziale non e' decidibile).
* Coorte = componente connessa sugli archi strong non ambigui, poi sovrascritta
* dal mapping manuale (ML_COHORTMAP). DB075 uguale NON basta a unire; DB075
* diverso con sovrapposizione forte = "overlap_recoded".
* Controlli: al piu' un gruppo per release in ogni coorte; coerenza di DB076
* (se presente, usato solo come verifica); stesso DB075 nello stesso anno in
* coorti diverse provenienti da release diverse => possibile collegamento mancato.
* Le etichette cohort_id sono persistenti (ML_IDMAPDIR/cohort_idmap.dta).

capture program drop ml_cohort_link
program define ml_cohort_link
    tempfile dk gy grp grpb tb edges nodes lab emap nflag keys ckeys newids taken
    keep country release_year udb_version year hid_s rg_s entry_db076
    if _N > 0 quietly duplicates drop

    * (a) coerenza entro release
    bysort country release_year year hid_s: generate int _n_rg = _N
    quietly count if _n_rg > 1
    local nbad = r(N)
    if `nbad' > 0 {
        preserve
        quietly keep if _n_rg > 1
        ml_savediag "diag_hid_multi_group_same_release_year"
        restore
        ml_fail "HID_NOT_UNIQUE_RELEASE_YEAR" "`nbad' righe famiglia-anno con piu' DB075 nella stessa release"
    }
    bysort country release_year hid_s (rg_s): generate byte _chg = rg_s[1] != rg_s[_N]
    quietly count if _chg
    local nbad = r(N)
    if `nbad' > 0 {
        preserve
        quietly keep if _chg
        ml_savediag "diag_hid_rg_change_within_release"
        restore
        ml_fail "HID_RG_CHANGE" "`nbad' righe: famiglie che cambiano DB075 entro la stessa release"
    }
    drop _n_rg _chg
    quietly save `dk', emptyok

    * (b) tabella dei gruppi
    contract country release_year rg_s year, freq(n_gy)
    quietly save `gy', emptyok
    use `dk', clear
    bysort country release_year rg_s year: generate byte _fy = _n == 1
    collapse (min) ymin=year entry_db076_min=entry_db076 (max) ymax=year entry_db076_max=entry_db076 (sum) nyears=_fy (count) n_hh_years=year (first) udb_version, by(country release_year rg_s)
    generate int gaps = (ymax - ymin + 1) - nyears
    sort country release_year rg_s
    generate long node = _n
    local nnodes = _N
    quietly save `grp', emptyok
    rename (release_year rg_s node) (rel_b rg_b node_b)
    keep country rel_b rg_b node_b
    quietly save `grpb', emptyok

    * (c) archi: famiglie-anno condivise fra gruppi di release diverse
    use `dk', clear
    keep country release_year year hid_s rg_s
    rename (release_year rg_s) (rel_b rg_b)
    quietly save `tb', emptyok
    use `dk', clear
    keep country release_year year hid_s rg_s
    joinby country year hid_s using `tb'
    quietly keep if rel_b > release_year
    local nedges = 0
    if _N > 0 {
        contract country release_year rg_s rel_b rg_b, freq(m)
        joinby country release_year rg_s using `gy'
        rename (year n_gy) (cy n_a)
        preserve
        use `gy', clear
        rename (release_year rg_s year n_gy) (rel_b rg_b cy n_b)
        tempfile gyb
        quietly save `gyb', emptyok
        restore
        merge m:1 country rel_b rg_b cy using `gyb', keep(match) nogenerate
        collapse (sum) n_a n_b (first) m, by(country release_year rg_s rel_b rg_b)
        generate double share_a = m / n_a
        generate double share_b = m / n_b
        generate str edge_class = "negligible"
        replace edge_class = "weak" if max(share_a, share_b) >= $ML_OVERLAP_WEAK
        replace edge_class = "strong" if min(share_a, share_b) >= $ML_OVERLAP_MIN
        generate byte rg_recoded = rg_s != rg_b
        generate byte strong = edge_class == "strong"
        generate byte weak = edge_class == "weak"
        bysort country release_year rg_s rel_b: egen int ns_a = total(strong)
        bysort country rel_b rg_b release_year: egen int ns_b = total(strong)
        generate byte edge_ambig = strong & (ns_a > 1 | ns_b > 1)
        generate byte accepted = strong & !edge_ambig
        merge m:1 country release_year rg_s using `grp', keepusing(node) keep(match) nogenerate
        rename node node_a
        merge m:1 country rel_b rg_b using `grpb', keepusing(node_b) keep(match) nogenerate
        local nedges = _N
    }
    else {
        foreach v in m n_a n_b node_a node_b {
            generate long `v' = .
        }
        foreach v in share_a share_b {
            generate double `v' = .
        }
        foreach v in rg_recoded strong weak edge_ambig accepted {
            generate byte `v' = .
        }
        generate str edge_class = ""
    }
    label variable m "famiglie-anno condivise (stessi year, country, DB030)"
    label variable n_a "famiglie-anno del gruppo A negli anni comuni"
    label variable n_b "famiglie-anno del gruppo B negli anni comuni"
    order country release_year rg_s rel_b rg_b m n_a n_b share_a share_b edge_class accepted edge_ambig rg_recoded
    quietly save `edges', emptyok
    ml_savediag "cohort_links"

    * flag per nodo
    use `edges', clear
    if _N > 0 {
        generate byte amb = weak | edge_ambig
        preserve
        keep node_a amb accepted rg_recoded
        rename node_a node
        tempfile na
        quietly save `na', emptyok
        restore
        keep node_b amb accepted rg_recoded
        rename node_b node
        append using `na'
        generate byte recacc = accepted & rg_recoded
        collapse (max) node_ambig=amb has_link=accepted link_recoded=recacc, by(node)
    }
    else {
        clear
        generate long node = .
        generate byte node_ambig = .
        generate byte has_link = .
        generate byte link_recoded = .
    }
    quietly save `nflag', emptyok

    * (d) componenti connesse (propagazione dell'etichetta minima)
    use `grp', clear
    keep node
    generate long comp = node
    quietly save `nodes', emptyok
    use `edges', clear
    quietly keep if accepted == 1
    keep node_a node_b
    quietly save `emap', emptyok
    local changed = _N
    local it 0
    while `changed' > 0 {
        local ++it
        if `it' > `nnodes' + 1 ml_stop "COMPONENTS_NO_CONVERGENCE" "propagazione delle etichette non convergente"
        use `emap', clear
        rename node_a node
        quietly merge m:1 node using `nodes', keep(match) nogenerate
        rename (node comp) (node_a comp_a)
        rename node_b node
        quietly merge m:1 node using `nodes', keep(match) nogenerate
        rename (node comp) (node_b comp_b)
        generate long cmin = min(comp_a, comp_b)
        preserve
        keep node_a cmin
        rename node_a node
        quietly save `lab', replace emptyok
        restore
        keep node_b cmin
        rename node_b node
        append using `lab'
        collapse (min) cmin, by(node)
        quietly merge 1:1 node using `nodes', nogenerate
        generate long newc = min(comp, cmin)
        quietly count if newc != comp
        local changed = r(N)
        quietly replace comp = newc
        keep node comp
        quietly save `nodes', replace emptyok
    }

    * (e) tabella dei gruppi con componente e flag
    use `grp', clear
    quietly merge 1:1 node using `nodes', nogenerate
    if `nedges' > 0 {
        quietly merge 1:1 node using `nflag', keep(master match) nogenerate
        foreach v in node_ambig has_link link_recoded {
            quietly replace `v' = 0 if missing(`v')
        }
    }
    else {
        foreach v in node_ambig has_link link_recoded {
            generate byte `v' = 0
        }
    }

    * (f) mapping manuale
    if `"$ML_COHORTMAP"' != "" {
        preserve
        import delimited using `"$ML_COHORTMAP"', clear varnames(1) stringcols(_all) encoding("utf-8")
        ml_lower
        confirm variable country release_year rg cohort_label, exact
        generate int rel_n = real(release_year)
        drop release_year
        rename (rel_n rg) (release_year rg_s)
        replace country = strupper(strtrim(country))
        replace rg_s = strtrim(rg_s)
        replace cohort_label = strtrim(cohort_label)
        capture confirm variable note, exact
        if _rc generate str note = ""
        keep country release_year rg_s cohort_label note
        ml_isid country release_year rg_s, code(COHORTMAP_KEYS)
        tempfile mm
        quietly save `mm', emptyok
        restore
        merge 1:1 country release_year rg_s using `mm'
        quietly count if _merge == 2
        if r(N) > 0 ml_warn "COHORTMAP_UNUSED" "`r(N)' righe di ML_COHORTMAP senza gruppo corrispondente nei dati"
        quietly drop if _merge == 2
        drop _merge
        rename note manual_note
        replace cohort_label = "" if missing(cohort_label)
    }
    else {
        generate str cohort_label = ""
        generate str manual_note = ""
    }
    generate byte manual = cohort_label != ""
    generate str final_key = cond(manual, "M|" + country + "|" + cohort_label, "C|" + string(comp, "%12.0f"))
    bysort comp: egen byte _anyman = max(manual)
    bysort comp: egen byte _allman = min(manual)
    quietly count if _anyman & !_allman
    if r(N) > 0 ml_warn "MANUAL_SPLITS_COMPONENT" "il mapping manuale separa gruppi collegati automaticamente: verificare"
    drop _anyman _allman

    * (g) verifiche sulla coorte finale
    bysort final_key release_year: generate int _ndup = _N
    bysort final_key: egen byte comp_conflict = max(_ndup > 1)
    drop _ndup
    quietly count if comp_conflict & manual
    if r(N) > 0 {
        preserve
        quietly keep if comp_conflict & manual
        ml_savediag "diag_cohortmap_conflict"
        restore
        ml_stop "COHORTMAP_CONFLICT" "ML_COHORTMAP assegna due gruppi della stessa release alla stessa coorte"
    }
    bysort final_key: egen int e_min = min(entry_db076_min)
    bysort final_key: egen int e_max = max(entry_db076_max)
    generate byte db076_conflict = !missing(e_min) & e_min != e_max
    generate byte db076_group_incons = !missing(entry_db076_min) & entry_db076_min != entry_db076_max
    bysort final_key: egen int obs_first_year = min(ymin)
    bysort final_key: egen int obs_last_year = max(ymax)
    bysort final_key: generate int n_releases = _N
    bysort final_key (release_year): generate str _rg0 = rg_s[1]

    * stato della verifica e regola usata
    generate str link_rule = "singleton"
    replace link_rule = "overlap" if has_link
    replace link_rule = "overlap_recoded" if has_link & link_recoded
    replace link_rule = "manual" if manual
    generate str cohort_status = "unlinked_single_group"
    replace cohort_status = "verified_overlap" if has_link
    replace cohort_status = "ambiguous" if node_ambig & !manual
    replace cohort_status = "conflict" if (comp_conflict | db076_conflict) & !manual
    replace cohort_status = "manual" if manual
    generate str source = "DB030 overlap, soglia $ML_OVERLAP_MIN (weak $ML_OVERLAP_WEAK)"
    replace source = "nessun arco accettato" if !has_link
    replace source = "ML_COHORTMAP: " + manual_note if manual
    quietly save `grp', replace emptyok

    * (h) stesso DB075 nello stesso anno in coorti diverse da release diverse
    use `dk', clear
    quietly merge m:1 country release_year rg_s using `grp', keepusing(final_key manual) assert(match) nogenerate
    contract country year rg_s release_year final_key manual
    bysort country year rg_s final_key: generate byte _fk = _n == 1
    bysort country year rg_s: egen int _nk = total(_fk)
    bysort country year rg_s: egen byte _allm = min(manual)
    quietly keep if _nk > 1 & !_allm
    if _N > 0 {
        ml_savediag "diag_possible_unlinked"
        ml_fail "POSSIBLE_UNLINKED" "stesso DB075 nello stesso anno assegnato a coorti diverse (release diverse): ID non stabili o collegamento mancato"
    }

    * anni distinti osservati per coorte (estensione != numero di onde osservate)
    use `dk', clear
    quietly merge m:1 country release_year rg_s using `grp', keepusing(final_key) assert(match) nogenerate
    contract final_key year
    contract final_key, freq(obs_nyears)
    quietly save `ckeys', emptyok

    * (i) cohort_id persistenti
    use `grp', clear
    quietly merge m:1 final_key using `ckeys', assert(match) nogenerate
    generate int obs_gaps = (obs_last_year - obs_first_year + 1) - obs_nyears
    local idmap "$ML_IDMAPDIR/cohort_idmap.dta"
    ml_fexists "`idmap'"
    local hasmap = r(exists)
    if `hasmap' {
        quietly merge 1:1 country release_year rg_s using "`idmap'", keepusing(cohort_id) keep(master match) nogenerate
        rename cohort_id old_id
    }
    else generate str old_id = ""
    bysort final_key old_id: generate byte _f = _n == 1 & old_id != ""
    bysort final_key: egen int _nid = total(_f)
    quietly count if _nid > 1
    if r(N) > 0 {
        preserve
        quietly keep if _nid > 1
        ml_savediag "diag_idmap_conflict"
        restore
        ml_stop "IDMAP_MERGE" "una coorte eredita piu' cohort_id dalla mappa persistente: risolvere con ML_COHORTMAP"
    }
    bysort final_key (old_id): generate str cohort_id = old_id[_N]
    generate byte id_new = cohort_id == ""
    generate str prop = country + "-rg" + _rg0 + "-y" + string(obs_first_year, "%4.0f")
    preserve
    keep cohort_id
    quietly drop if cohort_id == ""
    if `hasmap' {
        append using "`idmap'", keep(cohort_id)
    }
    if _N > 0 quietly duplicates drop
    rename cohort_id prop
    generate byte taken = 1
    local ntaken = _N
    quietly save `taken', emptyok
    restore
    preserve
    quietly keep if id_new
    keep final_key prop
    if _N > 0 quietly duplicates drop
    if _N > 0 {
        bysort prop (final_key): generate int _k = _n
        bysort prop: generate int _nk = _N
        if `ntaken' > 0 {
            quietly merge m:1 prop using `taken', keep(master match) nogenerate
            quietly replace taken = 0 if missing(taken)
        }
        else generate byte taken = 0
        generate str newid = prop if _nk == 1 & !taken
        quietly replace newid = prop + "-" + string(_k) if newid == ""
        keep final_key newid
    }
    else generate str newid = ""
    local nnew = _N
    quietly save `newids', emptyok
    restore
    if `nnew' > 0 {
        quietly merge m:1 final_key using `newids', keep(master match) nogenerate
        quietly replace cohort_id = newid if id_new
        drop newid
    }
    drop prop _f _nid
    bysort cohort_id (final_key): generate byte _split = final_key[1] != final_key[_N]
    quietly count if _split
    if r(N) > 0 {
        preserve
        quietly keep if _split
        ml_savediag "diag_idmap_split"
        restore
        ml_stop "IDMAP_SPLIT" "lo stesso cohort_id persistente copre coorti ora distinte: risolvere con ML_COHORTMAP"
    }
    drop _split

    * (j) ingresso e durata previsti (solo diagnostica)
    generate int entry_expected = e_min if !missing(e_min) & e_min == e_max
    generate str entry_source = cond(!missing(entry_expected), "DB076 (year - DB076 + 1)", "non noto")
    generate int duration_expected = .
    generate str duration_source = ""
    generate str duration_status = ""
    generate int _ndr = 0
    if `"$ML_DESIGNFILE"' != "" {
        preserve
        import delimited using `"$ML_DESIGNFILE"', clear varnames(1) stringcols(_all) encoding("utf-8")
        ml_lower
        confirm variable country entry_from entry_to duration source status, exact
        local nd = _N
        forvalues i = 1/`nd' {
            local dc`i' = strupper(strtrim(country[`i']))
            local df`i' = real(entry_from[`i'])
            local dt`i' = real(entry_to[`i'])
            local dd`i' = real(duration[`i'])
            local ds`i' = source[`i']
            local dst`i' = status[`i']
        }
        restore
        forvalues i = 1/`nd' {
            quietly replace _ndr = _ndr + 1 if country == "`dc`i''" & inrange(entry_expected, `df`i'', `dt`i'')
            quietly replace duration_expected = `dd`i'' if country == "`dc`i''" & inrange(entry_expected, `df`i'', `dt`i'')
            quietly replace duration_source = "`ds`i''" if country == "`dc`i''" & inrange(entry_expected, `df`i'', `dt`i'')
            quietly replace duration_status = "`dst`i''" if country == "`dc`i''" & inrange(entry_expected, `df`i'', `dt`i'')
        }
        quietly count if _ndr > 1
        if r(N) > 0 ml_fail "DESIGNFILE_OVERLAP" "regole di disegno sovrapposte per la stessa coorte"
    }
    drop _ndr
    * coorte conclusa (ultimo anno < ultimo anno dei dati) con durata diversa dalla regola
    quietly summarize obs_last_year
    local ylast = r(max)
    quietly count if !missing(duration_expected) & obs_last_year < `ylast' & obs_nyears != duration_expected
    if r(N) > 0 ml_warn "DESIGN_DURATION_MISMATCH" "`r(N)' gruppi di coorti concluse con anni osservati diversi dalla durata in ML_DESIGNFILE"
    generate int obs_span = obs_last_year - obs_first_year + 1
    label variable obs_span "estensione osservata (ultimo-primo anno+1): NON e' la durata prevista"
    label variable obs_nyears "anni distinti osservati sull'insieme delle release"
    label variable entry_expected "anno di ingresso da DB076, se coerente"
    label variable duration_expected "durata prevista da ML_DESIGNFILE (solo diagnostica)"

    order country release_year udb_version rg_s cohort_id link_rule cohort_status source ymin ymax nyears gaps n_hh_years obs_first_year obs_last_year obs_span obs_nyears obs_gaps n_releases entry_expected entry_source duration_expected duration_source duration_status final_key comp manual manual_note id_new
    sort country cohort_id release_year
    ml_savediag "cohort_groups"

    * esito per paese
    quietly levelsof country, local(cc) clean
    foreach c of local cc {
        quietly count if country == "`c'" & inlist(cohort_status, "ambiguous", "conflict")
        if r(N) > 0 ml_fail "COHORT_UNRESOLVED_`c'" "`r(N)' gruppi ambigui o in conflitto: vedi cohort_groups e cohort_links"
    }
    quietly count if db076_group_incons
    if r(N) > 0 ml_warn "DB076_GROUP_INCONSISTENT" "`r(N)' gruppi con anno d'ingresso DB076 non uniforme"

    * mappa per il resto della pipeline e candidata per la mappa persistente
    preserve
    keep country release_year rg_s cohort_id cohort_status
    quietly save "$ML_TMPDIR/cohort_map.dta", replace emptyok
    if `hasmap' {
        keep country release_year rg_s cohort_id
        tempfile cur
        quietly save `cur', emptyok
        use "`idmap'", clear
        quietly merge 1:1 country release_year rg_s using `cur', nogenerate update replace
    }
    else keep country release_year rg_s cohort_id
    quietly save "$ML_TMPDIR/cohort_idmap_candidate.dta", replace emptyok
    restore
end

*==============================================================================
* 4. SELEZIONE DELLE CELLE (country, observation_year, cohort_id)
*==============================================================================
* Release dalla piu' recente alla piu' vecchia. Per ogni cella candidata:
*   - gia' nel registro                         -> esclusa (covered_by_newer_release)
*   - paese assente da tutte le release piu' recenti -> accettata
*   - per ciascuna release piu' recente s in cui il paese e' presente:
*       cat 1: anno fuori dalla finestra pubblicata di s
*       cat 4: anno nella finestra, coorte assente da s perche' conclusa prima
*              dell'ultimo anno di s -> accettata (cohort_ended_before_newer)
*       cat 2: anno nella finestra, coorte attiva ma assente da s -> accettata con avviso
*       cat 3: anno nella finestra, coorte presente in s, cella assente in s
*              = cella ATTESA ma assente -> strict: esclusa; permissive: recuperata
*       cat 0: cella presente in s ma non selezionata da s (solo per policy)
* Le celle accettate entrano nel registro (isid). Nessun lookahead fisso: il
* confronto e' con TUTTE le release gia' processate.

capture program drop ml_select_cells
program define ml_select_cells
    tempfile reg dec cand flags win_s cpres_s cells_s clast
    * ultimo anno osservato di ogni coorte (su tutte le release)
    use "$ML_TMPDIR/cells_all.dta", clear
    collapse (max) coh_last=year, by(country cohort_id)
    quietly save `clast', emptyok
    numlist "$ML_RELS_AVAIL", sort
    local asc `r(numlist)'
    local desc ""
    foreach r of local asc {
        local desc `r' `desc'
    }
    clear
    generate str2 country = ""
    generate int year = .
    generate str cohort_id = ""
    generate int src_release = .
    generate str src_version = ""
    generate long n_hh = .
    generate str sel_reason = ""
    quietly save `reg', emptyok
    quietly save `dec', emptyok
    local done ""
    foreach r of local desc {
        use "$ML_TMPDIR/cells_all.dta", clear
        quietly keep if release_year == `r'
        if _N == 0 {
            ml_warn "RELEASE_NO_CELLS_`r'" "nessuna cella nella release `r' per i paesi configurati"
            continue
        }
        ml_isid country year cohort_id, code(CELLS_`r')
        if "`done'" != "" {
            merge m:1 country year cohort_id using `reg', keepusing(src_release) keep(master match)
            generate byte covered = _merge == 3
            drop _merge
            rename src_release covered_by
        }
        else {
            generate byte covered = 0
            generate int covered_by = .
        }
        generate byte f_cty = 0
        generate byte f_ea = 0
        generate byte f_cabs = 0
        generate byte f_out = 0
        generate byte f_pres = 0
        generate byte f_end = 0
        if "`done'" != "" {
            quietly save `cand', replace emptyok
            use "$ML_TMPDIR/windows.dta", clear
            generate byte _d = 0
            foreach s of local done {
                quietly replace _d = 1 if release_year == `s'
            }
            quietly keep if _d
            drop _d
            rename (release_year ymin ymax) (rel_s ymin_s ymax_s)
            quietly save `win_s', replace emptyok
            use "$ML_TMPDIR/cpres.dta", clear
            rename release_year rel_s
            quietly save `cpres_s', replace emptyok
            use "$ML_TMPDIR/cells_all.dta", clear
            keep country release_year year cohort_id
            rename release_year rel_s
            generate byte cell_in_s = 1
            quietly save `cells_s', replace emptyok
            use `cand', clear
            keep country year cohort_id
            joinby country using `win_s'
            if _N > 0 {
                generate byte inwin = inrange(year, ymin_s, ymax_s)
                merge m:1 country rel_s cohort_id using `cpres_s', keep(master match)
                generate byte coh_in_s = _merge == 3
                drop _merge
                merge m:1 country rel_s year cohort_id using `cells_s', keep(master match) nogenerate
                quietly replace cell_in_s = 0 if missing(cell_in_s)
                quietly merge m:1 country cohort_id using `clast', keep(master match) nogenerate
                * 4 = coorte assente da s perche' conclusa prima dell'ultimo anno di s
                generate byte cat = cond(!inwin, 1, cond(!coh_in_s, cond(coh_last < ymax_s, 4, 2), cond(!cell_in_s, 3, 0)))
                generate byte n_end = cat == 4
                generate byte n_ea = cat == 3
                generate byte n_cabs = cat == 2
                generate byte n_out = cat == 1
                generate byte n_pres = cat == 0
                generate byte one = 1
                collapse (max) g_cty=one g_ea=n_ea g_cabs=n_cabs g_out=n_out g_pres=n_pres g_end=n_end, by(country year cohort_id)
                quietly save `flags', replace emptyok
                use `cand', clear
                merge 1:1 country year cohort_id using `flags', keep(master match) nogenerate
                foreach x in cty ea cabs out pres end {
                    quietly replace f_`x' = 1 if g_`x' == 1
                }
                drop g_*
            }
            else use `cand', clear
        }
        generate str decision = ""
        generate str reason = ""
        quietly {
            replace decision = "excluded" if covered
            replace reason = "covered_by_newer_release" if covered
            if "`done'" == "" {
                replace decision = "accepted" if !covered
                replace reason = "most_recent_release" if !covered
            }
            else {
                replace reason = "country_absent_in_newer_releases" if !covered & !f_cty
                replace reason = "outside_newer_windows" if !covered & f_cty & f_out & !f_end & !f_cabs & !f_ea & !f_pres
                replace reason = "cohort_ended_before_newer" if !covered & f_cty & f_end & !f_cabs & !f_ea & !f_pres
                replace reason = "cohort_absent_in_newer_window" if !covered & f_cty & f_cabs & !f_ea & !f_pres
                replace reason = "present_in_newer_not_selected" if !covered & f_pres & !f_ea
                replace reason = "expected_absent_in_newer" if !covered & f_ea
                replace decision = "accepted" if inlist(reason, "country_absent_in_newer_releases", "outside_newer_windows", "cohort_ended_before_newer", "cohort_absent_in_newer_window")
                replace decision = "excluded" if reason == "present_in_newer_not_selected"
                if "$ML_CELLPOLICY" == "permissive" {
                    replace decision = "accepted" if reason == "expected_absent_in_newer"
                    replace reason = "expected_absent_recovered" if reason == "expected_absent_in_newer"
                }
                else replace decision = "excluded" if reason == "expected_absent_in_newer"
            }
        }
        quietly count if decision == ""
        if r(N) > 0 ml_stop "CELL_DECISION_UNDEFINED" "celle senza decisione nella release `r'"
        preserve
        append using `dec'
        quietly save `dec', replace emptyok
        restore
        quietly keep if decision == "accepted"
        rename (release_year udb_version reason) (src_release src_version sel_reason)
        keep country year cohort_id src_release src_version n_hh sel_reason
        append using `reg'
        ml_isid country year cohort_id, code(REGISTRY_AFTER_`r')
        quietly save `reg', replace emptyok
        local done `done' `r'
    }
    use `dec', clear
    order country year cohort_id release_year udb_version n_hh decision reason covered_by
    sort country cohort_id year release_year
    ml_savediag "cell_decisions"
    quietly count if inlist(reason, "expected_absent_in_newer", "expected_absent_recovered")
    if r(N) > 0 ml_warn "CELLS_EXPECTED_ABSENT" "`r(N)' celle attese ma assenti in release piu' recenti (policy $ML_CELLPOLICY): vedi cell_decisions"
    quietly count if reason == "cohort_absent_in_newer_window"
    if r(N) > 0 ml_warn "CELLS_COHORT_ABSENT_IN_WINDOW" "`r(N)' celle di coorti assenti da release piu' recenti che coprono l'anno: verificare cohort_groups"
    quietly count if reason == "present_in_newer_not_selected"
    if r(N) > 0 ml_warn "CELLS_PRESENT_NOT_SELECTED" "`r(N)' celle presenti in release piu' recenti ma escluse"
    use `reg', clear
    ml_isid country year cohort_id, code(REGISTRY_FINAL)
    sort country cohort_id year
    ml_savediag "cell_registry"
    quietly save "$ML_TMPDIR/cell_registry.dta", replace emptyok
end

*==============================================================================
* 5. COLLEGAMENTO D -> H, R, P ENTRO LA STESSA RELEASE/VERSIONE
*==============================================================================
* D: (year, country, DB030) 1 riga per famiglia-anno nella release
* H: (year, country, HB030) 1:1 con D;  D senza H = famiglia non rispondente (atteso)
* R: (year, country, RB030, RB040) m:1 con D su RB040; una persona puo' avere piu'
*    righe nello stesso anno (piu' famiglie): si conserva la relazione, non si
*    sceglie una famiglia.
* P: (year, country, PB030) 1:1 con la tabella persona-anno ricavata da R;
*    persone R senza P = fuori dall'universo P (atteso).

capture program drop ml_linkstat
program define ml_linkstat
    args rel step n_match n_master_only n_using_only n_kept note
    preserve
    clear
    quietly set obs 1
    generate int release_year = `rel'
    generate str step = "`step'"
    generate double n_match = `n_match'
    generate double n_master_only = `n_master_only'
    generate double n_using_only = `n_using_only'
    generate double n_kept = `n_kept'
    generate str note = "`note'"
    ml_fexists "$ML_TMPDIR/link_stats.dta"
    if r(exists) append using "$ML_TMPDIR/link_stats.dta"
    quietly save "$ML_TMPDIR/link_stats.dta", replace emptyok
    restore
end

* Righe senza D nella release r: le famiglie (hid_s) sono presenti nel D della
* release r+1? Usato per riconoscere la prima onda della coorte entrante, che
* alcune release (IT: L-2023, L-2024) pubblicano in H/R/P ma non in D.
capture program drop ml_nextd
program define ml_nextd, rclass
    args r
    local rn = `r' + 1
    ml_fexists "$ML_TMPDIR/D_`rn'.dta"
    if r(exists) {
        merge m:1 country year hid_s using "$ML_TMPDIR/D_`rn'.dta", keepusing(cohort_id) keep(master match)
        generate byte in_next_D = _merge == 3
        drop _merge cohort_id
        quietly count if in_next_D
        return scalar n_next = r(N)
        return scalar checked = 1
    }
    else {
        generate byte in_next_D = .
        return scalar n_next = .
        return scalar checked = 0
    }
end

* Esito per righe senza D: avviso se sono tutte dell'anno finale della release
* (prima onda pubblicata senza D), errore altrimenti.
capture program drop ml_firstwave
program define ml_firstwave
    args r what n nother nnext code
    if `nother' == 0 {
        local nx = cond(missing(`nnext'), "non verificabile (release successiva assente)", "`nnext' di `n'")
        ml_warn "`code'_FIRSTWAVE_`r'" "`n' `what' solo nell'anno `r' senza D (prima onda della coorte entrante): esclusi; presenti nel D della release successiva: `nx'"
    }
    else ml_fail "`code'_WITHOUT_D_`r'" "`n' `what' senza D, di cui `nother' in anni diversi da `r'"
end

capture program drop ml_link_release
program define ml_link_release
    args r
    tempfile dk pers
    use country year hid_s cohort_id hh_uid selected using "$ML_TMPDIR/D_`r'.dta", clear
    ml_isid country year hid_s, code(D_HIDKEY_`r')
    quietly save `dk', emptyok

    * --- H ---
    ml_loadtype, rel(`r') ftype(H)
    if r(nfiles) == 0 ml_warn "H_MISSING_`r'" "nessun file H selezionato per la release `r'"
    else {
        ml_isid country year hid_s, code(H_KEY_`r')
        merge 1:1 country year hid_s using `dk'
        quietly count if _merge == 3
        local a = r(N)
        quietly count if _merge == 1
        local b = r(N)
        quietly count if _merge == 2
        local c = r(N)
        if `b' > 0 {
            preserve
            quietly keep if _merge == 1
            keep country year hid_s
            quietly count if year != `r'
            local bo = r(N)
            ml_nextd `r'
            local nn = r(n_next)
            ml_savediag "diag_H_without_D_`r'"
            restore
            ml_firstwave `r' "famiglie H" `b' `bo' `nn' H
        }
        quietly keep if _merge == 3 & selected == 1
        drop _merge selected
        ml_linkstat `r' "H-D" `a' `b' `c' `=_N' "using-only = D senza H (non risposta, atteso)"
        quietly save "$ML_TMPDIR/Hsel_`r'.dta", replace emptyok
    }

    * --- R ---
    ml_loadtype, rel(`r') ftype(R)
    if r(nfiles) == 0 ml_stop "R_MISSING_`r'" "nessun file R selezionato per la release `r'"
    ml_isid country year pid_s hid_s, code(R_KEY_`r')
    merge m:1 country year hid_s using `dk'
    quietly count if _merge == 3
    local a = r(N)
    quietly count if _merge == 1 & hid_s != ""
    local b = r(N)
    quietly count if _merge == 1 & hid_s == ""
    local b0 = r(N)
    quietly count if _merge == 2
    local c = r(N)
    if `b' > 0 {
        preserve
        quietly keep if _merge == 1 & hid_s != ""
        keep country year pid_s hid_s
        quietly count if year != `r'
        local bo = r(N)
        ml_nextd `r'
        local nn = r(n_next)
        ml_savediag "diag_R_without_D_`r'"
        keep country year pid_s
        quietly duplicates drop
        quietly save "$ML_TMPDIR/r_without_d_`r'.dta", replace emptyok
        restore
        ml_firstwave `r' "righe R" `b' `bo' `nn' R
    }
    if `c' > 0 ml_warn "D_WITHOUT_R_`r'" "`c' famiglie D senza membri in R"
    quietly keep if _merge == 3
    drop _merge
    bysort country year pid_s (cohort_id): generate byte multi_cohort = cohort_id[1] != cohort_id[_N]
    quietly count if multi_cohort
    local mc = r(N)
    if `mc' > 0 {
        preserve
        quietly keep if multi_cohort
        keep country year pid_s hid_s cohort_id
        ml_savediag "diag_person_multi_cohort_`r'"
        restore
        ml_fail "PERSON_MULTI_COHORT_`r'" "`mc' righe: persona collegata nello stesso anno a famiglie di coorti diverse"
    }
    * pesi longitudinali RB06k da TUTTE le righe della release (anche celle non
    * selezionate): sono pesi della release, riportati nel suo anno finale.
    local lwv ""
    foreach v in rb062 rb063 rb064 rb065 rb066 {
        capture confirm numeric variable `v', exact
        if !_rc local lwv `lwv' `v'
    }
    if "`lwv'" != "" {
        preserve
        egen byte _anylw = rownonmiss(`lwv')
        quietly keep if _anylw > 0
        if _N > 0 {
            generate str person_uid = country + "|" + cond(multi_cohort, "AMBIGUOUS", cohort_id) + "|" + pid_s
            keep person_uid country cohort_id year release_year `lwv'
            * piu' relazioni familiari: il peso e' personale. Regola: se fra le
            * relazioni c'e' un solo valore non mancante lo si usa; se ce ne sono
            * due diversi il peso e' posto a missing (nessuna scelta arbitraria).
            foreach v of local lwv {
                bysort person_uid year: egen double _mn = min(`v')
                bysort person_uid year: egen double _mx = max(`v')
                generate byte _d = !missing(_mn) & _mn != _mx
                quietly count if _d
                if r(N) > 0 {
                    local nd = r(N)
                    tempfile hold
                    quietly save `hold', replace emptyok
                    quietly keep if _d
                    keep person_uid year `v'
                    ml_savediag "diag_lweight_conflict_`v'_`r'"
                    use `hold', clear
                    ml_warn "LWEIGHT_CONFLICT_`v'_`r'" "`nd' righe: `v' con valori diversi fra relazioni della stessa persona-anno, posto a missing (vedi diag)"
                }
                quietly replace `v' = cond(_d, ., _mx)
                drop _mn _mx _d
            }
            bysort person_uid year: keep if _n == 1
            quietly save "$ML_TMPDIR/lw_src_`r'.dta", replace emptyok
        }
        restore
    }
    preserve
    collapse (max) psel=selected multi_cohort (min) pselmin=selected (first) cohort_id, by(country year pid_s)
    quietly save `pers', emptyok
    restore
    quietly keep if selected == 1
    drop selected
    generate str person_uid = country + "|" + cond(multi_cohort, "AMBIGUOUS", cohort_id) + "|" + pid_s
    ml_linkstat `r' "R-D" `a' `=`b'+`b0'' `c' `=_N' "master-only con RB040 vuoto: `b0'"
    quietly save "$ML_TMPDIR/Rsel_`r'.dta", replace emptyok

    * --- P ---
    ml_loadtype, rel(`r') ftype(P)
    if r(nfiles) == 0 ml_warn "P_MISSING_`r'" "nessun file P selezionato per la release `r'"
    else {
        ml_isid country year pid_s, code(P_KEY_`r')
        merge 1:1 country year pid_s using `pers'
        quietly count if _merge == 3
        local a = r(N)
        quietly count if _merge == 1
        local b = r(N)
        quietly count if _merge == 2
        local c = r(N)
        if `b' > 0 {
            preserve
            quietly keep if _merge == 1
            keep country year pid_s
            quietly count if year != `r'
            local bo = r(N)
            * spiegati se la persona e' fra le righe R senza D della stessa release
            local nexp = 0
            ml_fexists "$ML_TMPDIR/r_without_d_`r'.dta"
            if r(exists) {
                merge 1:1 country year pid_s using "$ML_TMPDIR/r_without_d_`r'.dta", keep(master match)
                generate byte r_without_d = _merge == 3
                drop _merge
                quietly count if r_without_d
                local nexp = r(N)
            }
            ml_savediag "diag_P_without_R_`r'"
            restore
            if `bo' == 0 & `nexp' == `b' ml_warn "P_FIRSTWAVE_`r'" "`b' record P solo nell'anno `r', tutti di persone R senza D (prima onda della coorte entrante): esclusi"
            else ml_fail "P_WITHOUT_R_`r'" "`b' record P senza persona in R collegata a D (`nexp' spiegati da R senza D, `bo' in anni diversi da `r')"
        }
        quietly keep if _merge == 3 & psel == 1
        quietly count if pselmin == 0
        if r(N) > 0 ml_warn "P_PARTIAL_SELECTION_`r'" "`r(N)' persone-anno con relazioni in celle selezionate e non selezionate"
        generate str person_uid = country + "|" + cond(multi_cohort, "AMBIGUOUS", cohort_id) + "|" + pid_s
        drop _merge psel pselmin
        ml_linkstat `r' "P-R" `a' `b' `c' `=_N' "using-only = persone R fuori dall'universo P (atteso)"
        quietly save "$ML_TMPDIR/Psel_`r'.dta", replace emptyok
    }
end

* Identificativi numerici da una mappa persistente comune (mai egen group()
* indipendenti). Gli ID gia' assegnati non cambiano; i nuovi seguono il massimo.
capture program drop ml_numid
program define ml_numid
    args key num mapname
    local map "$ML_IDMAPDIR/`mapname'.dta"
    local cand "$ML_TMPDIR/`mapname'_candidate.dta"
    preserve
    keep `key'
    quietly drop if `key' == ""
    if _N > 0 quietly duplicates drop
    ml_fexists "`map'"
    if r(exists) {
        quietly merge 1:1 `key' using "`map'", nogenerate
    }
    else generate long `num' = .
    quietly summarize `num'
    local mx = cond(missing(r(max)), 0, r(max))
    sort `key'
    generate long _new = sum(missing(`num'))
    quietly replace `num' = `mx' + _new if missing(`num')
    drop _new
    ml_isid `num', code(IDMAP_NUM_`mapname')
    ml_isid `key', code(IDMAP_KEY_`mapname')
    quietly save "`cand'", replace emptyok
    restore
    merge m:1 `key' using "`cand'", keepusing(`num') keep(master match)
    quietly count if _merge == 1 & `key' != ""
    if r(N) > 0 ml_stop "IDMAP_UNMATCHED_`mapname'" "chiavi senza ID numerico"
    drop _merge
end

*==============================================================================
* 6. PANEL PERSONA-ANNO
*==============================================================================
* Una riga per persona-anno SOLO dove non servono scelte arbitrarie:
*  - variabili R costanti fra le relazioni della persona-anno: conservate;
*  - variabili R che differiscono fra relazioni: poste a missing (elenco in
*    panel_varying_vars); famiglia (hh_uid, design) solo se n_rel == 1;
*  - variabili P aggiunte 1:1 (P e' gia' unico per persona-anno).

capture program drop ml_panel
program define ml_panel
    use "$ML_RUNDIR/masterR.dta", clear
    bysort person_uid year: generate int n_rel = _N
    local skip "person_uid year country pid_s hid_s hh_uid hh_num rb040 cohort_id cohort_status release_year udb_version src_file country_orig n_rel multi_cohort"
    unab allv : _all
    local chk : list allv - skip
    tempname ph
    postfile `ph' str32 varname double n_rows str24 action using "$ML_TMPDIR/panel_varying.dta", replace
    foreach v of local chk {
        local t : type `v'
        if "`t'" == "strL" {
            quietly replace `v' = "" if n_rel > 1
            post `ph' ("`v'") (.) ("strL_missing_if_multi")
            continue
        }
        bysort person_uid year (`v'): generate byte _vr = `v'[1] != `v'[_N]
        quietly count if _vr
        if r(N) > 0 {
            post `ph' ("`v'") (r(N)) ("set_missing")
            capture confirm string variable `v'
            if !_rc quietly replace `v' = "" if _vr
            else quietly replace `v' = . if _vr
        }
        drop _vr
    }
    postclose `ph'
    bysort person_uid year (hh_uid): keep if _n == 1
    generate byte multi_hh = n_rel > 1
    label variable multi_hh "persona collegata a piu' famiglie nell'anno: famiglia non assegnata"
    quietly replace hh_uid = "" if multi_hh
    quietly replace hid_s = "" if multi_hh
    capture confirm string variable rb040
    if !_rc quietly replace rb040 = "" if multi_hh
    else quietly replace rb040 = . if multi_hh
    capture confirm variable hh_num, exact
    if !_rc drop hh_num
    * dati personali P
    ml_fexists "$ML_RUNDIR/masterP.dta"
    if r(exists) {
        unab have : _all
        quietly describe using "$ML_RUNDIR/masterP.dta", varlist
        local pvl `r(varlist)'
        local pv : list pvl - have
        merge 1:1 person_uid year using "$ML_RUNDIR/masterP.dta", keepusing(`pv')
        quietly count if _merge == 2
        if r(N) > 0 ml_stop "PANEL_P_WITHOUT_R" "record P senza persona-anno in masterR"
        generate byte in_P = _merge == 3
        drop _merge
    }
    else generate byte in_P = 0
    * variabili di disegno e ID famiglia da masterD (solo famiglia univoca)
    quietly describe using "$ML_RUNDIR/masterD.dta", varlist
    local dvl `r(varlist)'
    local dv ""
    foreach v of global ML_DESIGNVARS {
        local pos : list posof "`v'" in dvl
        if `pos' > 0 local dv `dv' `v'
    }
    merge m:1 year hh_uid using "$ML_RUNDIR/masterD.dta", keepusing(`dv' hh_num) keep(master match)
    quietly count if _merge == 1 & hh_uid != ""
    if r(N) > 0 ml_stop "PANEL_HH_UNMATCHED" "famiglie del panel assenti da masterD"
    drop _merge
    ml_numid person_uid person_num person_idmap
    ml_isid person_num year, code(PANEL_PERSON_YEAR)
    xtset person_num year
end

*==============================================================================
* 7. PESI: diagnostiche, finestre longitudinali, modalita' legacy
*==============================================================================
* Nessun peso viene sovrascritto. In "legacy" si aggiungono, etichettati:
*   rscale_legacy = Wg/W,  rb060s_legacy = rscale_legacy * rb060
*   pscale_legacy, pb080s_legacy (formula analoga)
*   lrb064_legacy = valore RB064 della UNICA finestra che copre l'anno
*   lrscale_legacy, rb064s_legacy (formula analoga su lrb064_legacy)
* Somma dei pesi riscalati = sum_g(Wg^2)/W (verificata numericamente):
* e' uno shrinkage, non una calibrazione.

capture program drop ml_weights
program define ml_weights
    tempfile wd pk wtmp cov elig wins
    local wv ""
    foreach v of global ML_WEIGHTVARS {
        capture confirm numeric variable `v', exact
        if !_rc local wv `wv' `v'
    }
    di as text "Pesi presenti nel panel: `wv'"
    * --- diagnostiche per paese-anno-coorte
    local first 1
    foreach v of local wv {
        preserve
        generate byte _m = missing(`v')
        generate byte _z = `v' == 0
        generate byte _ng = `v' < 0 & !missing(`v')
        generate byte _one = 1
        collapse (sum) n_rows=_one (count) n_valid=`v' (sum) n_missing=_m n_zero=_z n_negative=_ng w_sum=`v', by(country year cohort_id)
        generate str weight_var = "`v'"
        bysort country year: egen double W_country = total(w_sum)
        bysort country year: egen int G_pos = total(w_sum > 0)
        generate double _wpos = w_sum if w_sum > 0
        bysort country year: egen double Wg_mean = mean(_wpos)
        bysort country year: egen double Wg_sd = sd(_wpos)
        generate double CV_pop = Wg_sd * sqrt((G_pos - 1) / G_pos) / Wg_mean if G_pos > 1
        generate double W_over_G = W_country / G_pos if G_pos > 0
        generate byte denom_zero = W_country == 0
        drop _wpos Wg_sd
        if !`first' append using `wd'
        quietly save `wd', replace emptyok
        local first 0
        restore
    }
    if "`wv'" != "" {
        preserve
        use `wd', clear
        order weight_var country year cohort_id
        sort weight_var country year cohort_id
        ml_savediag "weights_diag"
        quietly count if denom_zero & weight_var == "rb060"
        if r(N) > 0 ml_warn "RB060_ALL_MISSING_OR_ZERO" "`r(N)' celle in paesi-anno con somma di rb060 nulla: vedi weights_diag"
        restore
    }
    else ml_warn "NO_WEIGHTS" "nessuna delle variabili in ML_WEIGHTVARS e' presente"

    * --- finestre dei pesi longitudinali RB06k (k = 2..6)
    * Nei dati UDB i RB06k sono riportati nell'anno finale della release che li
    * calcola (year == release_year) e sommano circa alla popolazione: sono pesi
    * della release, non delle celle. Si leggono quindi da TUTTE le righe R di
    * ogni release ($ML_TMPDIR/lw_src.dta, costruito in ml_link_release) e si
    * collegano al panel tramite person_uid, stabile fra release.
    * Output: long_weight_windows (persona x peso x release) e, nel panel,
    * nwin_rb06k = numero di finestre che coprono la persona-anno,
    * wval_rb06k = valore solo se la finestra e' unica (altrimenti scelta dell'analista).
    preserve
    keep person_uid year release_year
    quietly save `pk', emptyok
    restore
    local haslw 0
    ml_fexists "$ML_TMPDIR/lw_src.dta"
    if r(exists) local haslw 1
    local firstw 1
    foreach v in rb062 rb063 rb064 rb065 rb066 {
        local k = real(substr("`v'", 5, 1))
        if !`haslw' continue
        preserve
        use "$ML_TMPDIR/lw_src.dta", clear
        capture confirm numeric variable `v', exact
        if _rc {
            restore
            continue
        }
        keep person_uid country cohort_id year release_year `v'
        quietly keep if `v' > 0 & !missing(`v')
        if _N == 0 {
            restore
            generate int nwin_`v' = 0
            generate double wval_`v' = .
            continue
        }
        rename (year release_year `v') (w_anchor w_release w_value)
        if "$ML_LWIN_ANCHOR" == "end" {
            generate int w_end = w_anchor
            generate int w_start = w_anchor - `k' + 1
        }
        else {
            generate int w_start = w_anchor
            generate int w_end = w_anchor + `k' - 1
        }
        generate str weight_var = "`v'"
        generate byte k = `k'
        generate long win_id = _n
        quietly save `wtmp', replace emptyok
        keep person_uid win_id w_start w_end w_release w_value
        joinby person_uid using `pk'
        quietly keep if inrange(year, w_start, w_end)
        generate byte _oth = release_year != w_release
        quietly save `cov', replace emptyok
        if _N > 0 {
            collapse (count) n_years_in_panel=year (sum) n_years_other_src=_oth, by(win_id)
            quietly merge 1:1 win_id using `wtmp', nogenerate
        }
        else {
            use `wtmp', clear
            generate long n_years_in_panel = 0
            generate long n_years_other_src = 0
        }
        quietly replace n_years_in_panel = 0 if missing(n_years_in_panel)
        quietly replace n_years_other_src = 0 if missing(n_years_other_src)
        generate byte window_complete_in_panel = n_years_in_panel == `k'
        if !`firstw' append using `wins'
        quietly save `wins', replace emptyok
        local firstw 0
        use `cov', clear
        if _N > 0 {
            collapse (count) nwin_`v'=win_id (min) wval_`v'=w_value (max) _wmax=w_value, by(person_uid year)
            quietly replace wval_`v' = . if nwin_`v' != 1
            drop _wmax
        }
        else {
            generate int nwin_`v' = .
            generate double wval_`v' = .
            keep person_uid year nwin_`v' wval_`v'
        }
        quietly save `elig', replace emptyok
        local nel = _N
        restore
        if `nel' > 0 quietly merge 1:1 person_uid year using `elig', keep(master match) nogenerate
        else {
            generate int nwin_`v' = .
            generate double wval_`v' = .
        }
        quietly replace nwin_`v' = 0 if missing(nwin_`v')
        label variable nwin_`v' "finestre di `v' (tutte le release) che coprono la persona-anno"
        label variable wval_`v' "valore di `v' se una sola finestra copre l'anno; altrimenti vedi long_weight_windows"
    }
    if !`firstw' {
        preserve
        use `wins', clear
        order weight_var k person_uid country cohort_id w_release w_start w_end w_anchor w_value n_years_in_panel n_years_other_src window_complete_in_panel
        sort weight_var person_uid w_release
        label variable w_release "release che ha calcolato il peso (anno finale della finestra se ancoraggio end)"
        label variable n_years_other_src "anni della finestra presenti nel panel ma prelevati da un'altra release"
        quietly save "$ML_RUNDIR/long_weight_windows.dta", replace emptyok
        * riepilogo per peso x release (le righe complete sono troppe per il csv)
        generate byte _one = 1
        collapse (sum) n_windows=_one n_complete=window_complete_in_panel (sum) w_sum=w_value, by(weight_var k country w_release)
        ml_savediag "long_weight_windows_summary"
        restore
    }

    * --- modalita' legacy (solo confronto con eusilcpanel_2020)
    if "$ML_WEIGHTMODE" == "legacy" {
        foreach trip in "rb060 rscale rb060s" "pb080 pscale pb080s" "wval_rb064 lrscale rb064s" {
            local src : word 1 of `trip'
            local sc : word 2 of `trip'
            local out : word 3 of `trip'
            capture confirm numeric variable `src', exact
            if _rc continue
            quietly count if !missing(`src') & `src' > 0
            if r(N) == 0 {
                ml_warn "LEGACY_SKIP_`src'" "`src' assente o sempre mancante/nullo: `out'_legacy non calcolato"
                continue
            }
            if "`src'" == "wval_rb064" {
                generate double lrb064_legacy = wval_rb064
                label variable lrb064_legacy "LEGACY: RB064 propagato solo nella sua unica finestra"
                local src lrb064_legacy
            }
            bysort country year: egen double _W = total(`src')
            bysort country year cohort_id: egen double _Wg = total(`src')
            generate double `sc'_legacy = _Wg / _W if _W > 0
            generate double `out'_legacy = `sc'_legacy * `src'
            label variable `sc'_legacy "LEGACY eusilcpanel_2020: Wg/W per paese-anno-coorte"
            label variable `out'_legacy "LEGACY: `sc'*`src' - shrinkage, NON calibrazione"
            quietly count if _W == 0
            if r(N) > 0 {
                preserve
                quietly keep if _W == 0
                contract country year
                ml_savediag "diag_legacy_denom_zero_`out'"
                restore
                ml_fail "LEGACY_DENOM_ZERO_`out'" "somma di `src' nulla in alcuni paesi-anno: `out'_legacy mancante"
            }
            * verifica dell'identita' sum(pesi riscalati) = sum_g Wg^2 / W
            preserve
            quietly keep if _W > 0 & !missing(_W)
            if _N > 0 {
                collapse (sum) sc_sum=`out'_legacy (first) Wg=_Wg W=_W, by(country year cohort_id)
                generate double wg2 = Wg^2 / W
                collapse (sum) sc_sum wg2 (first) W, by(country year)
                generate double reldiff = reldif(sc_sum, wg2)
                generate str weight_var = "`out'_legacy"
                quietly count if reldiff > 1e-6
                if r(N) > 0 ml_fail "LEGACY_IDENTITY_`out'" "somma dei pesi riscalati diversa da sum Wg^2/W"
                ml_savediag "weights_legacy_identity_`out'"
            }
            restore
            drop _W _Wg
        }
        if `"$ML_POPFILE"' != "" {
            capture confirm numeric variable rb060s_legacy, exact
            if !_rc {
                preserve
                collapse (sum) W=rb060 Ws=rb060s_legacy, by(country year)
                merge 1:1 country year using `"$ML_POPFILE"', keepusing(pop) keep(master match)
                quietly count if _merge == 1
                if r(N) > 0 ml_warn "POP_MISSING" "`r(N)' paesi-anno senza popolazione"
                drop _merge
                generate double smwrate60 = (Ws - pop) / pop
                generate double w_over_pop = W / pop
                ml_savediag "weights_legacy_population"
                restore
            }
        }
    }
end

*==============================================================================
* 8. CONFRONTO CON eusilcpanel_2020 (facoltativo)
*==============================================================================
capture program drop ml_compare_legacy
program define ml_compare_legacy
    local f "$ML_LEGACYDIR/masterD.dta"
    ml_fexists "`f'"
    if !r(exists) {
        ml_warn "LEGACY_NOT_FOUND" "masterD.dta di eusilcpanel_2020 non trovato in ML_LEGACYDIR"
        exit
    }
    tempfile lg nw
    use "`f'", clear
    ml_lower
    capture confirm variable country year, exact
    if _rc {
        ml_warn "LEGACY_VARS" "masterD legacy senza country/year"
        exit
    }
    ml_keepcountries
    local hv ""
    foreach cand in hid db030 {
        capture confirm variable `cand', exact
        if !_rc & "`hv'" == "" local hv `cand'
    }
    capture confirm variable yrelease, exact
    local hasyr = (_rc == 0)
    preserve
    if `hasyr' contract country year yrelease, freq(n_hh_legacy)
    else contract country year, freq(n_hh_legacy)
    quietly save `lg', emptyok
    use "$ML_RUNDIR/masterD.dta", clear
    if `hasyr' {
        rename src_release yrelease
        contract country year yrelease, freq(n_hh_new)
        merge 1:1 country year yrelease using `lg'
    }
    else {
        contract country year, freq(n_hh_new)
        merge 1:1 country year using `lg'
    }
    ml_savediag "compare_legacy_counts"
    restore
    if "`hv'" != "" {
        ml_idstr hid_s, from(`hv')
        contract country year hid_s
        drop _freq
        quietly save `lg', replace emptyok
        use country year hid_s using "$ML_RUNDIR/masterD.dta", clear
        contract country year hid_s
        drop _freq
        merge 1:1 country year hid_s using `lg'
        generate byte only_new = _merge == 1
        generate byte only_legacy = _merge == 2
        generate byte both = _merge == 3
        collapse (sum) only_new only_legacy both, by(country year)
        ml_savediag "compare_legacy_households"
    }
end

*==============================================================================
* 9. CERTIFICAZIONE
*==============================================================================
capture program drop ml_finalize
program define ml_finalize
    tempname fh
    global ML_LAST_RUNDIR "$ML_RUNDIR"
    if $ML_NFAIL == 0 {
        file open `fh' using "$ML_RUNDIR/CERTIFIED.txt", write replace text
        file write `fh' "Tutte le verifiche essenziali superate. Avvisi: $ML_NWARN (vedi warnings.txt)." _n
        file close `fh'
        * mappe persistenti: backup delle precedenti e aggiornamento
        foreach m in cohort_idmap hh_idmap person_idmap {
            ml_fexists "$ML_IDMAPDIR/`m'.dta"
            if r(exists) copy "$ML_IDMAPDIR/`m'.dta" "$ML_RUNDIR/previous_`m'.dta", replace
            ml_fexists "$ML_TMPDIR/`m'_candidate.dta"
            if r(exists) copy "$ML_TMPDIR/`m'_candidate.dta" "$ML_IDMAPDIR/`m'.dta", replace
        }
        file open `fh' using "$ML_OUTDIR/LATEST_CERTIFIED.txt", write replace text
        file write `fh' "$ML_RUNDIR" _n
        file close `fh'
        global ML_LAST_CERT 1
        di as result "RUN CERTIFICATA: $ML_RUNDIR"
    }
    else {
        file open `fh' using "$ML_RUNDIR/NOT_CERTIFIED.txt", write replace text
        file write `fh' "Output NON certificato: $ML_NFAIL verifiche fallite (certification_failures.txt)." _n
        file write `fh' "Mappe ID persistenti non aggiornate; LATEST_CERTIFIED.txt invariato." _n
        file close `fh'
        global ML_LAST_CERT 0
        di as error "RUN NON CERTIFICATA ($ML_NFAIL verifiche fallite): $ML_RUNDIR"
    }
end

*==============================================================================
* 10. BUILD
*==============================================================================
capture program drop ml_build
program define ml_build
    ml_setup "build"
    capture log close mlrun
    log using "$ML_RUNDIR/mergepool_long.log", text replace name(mlrun)
    di as text "mergepool_long build - paesi: $ML_COUNTRIES - release: $ML_RELEASES"
    ml_inventory

    * --- release disponibili e complete
    use "$ML_RUNDIR/inventory.dta", clear
    quietly count if type_status != "ok" | parse_status != "ok"
    if r(N) > 0 ml_warn "UNUSABLE_FILES" "`r(N)' file senza tipo o release riconoscibile: vedi inventory (usare ML_FILEMAP)"
    foreach r in $ML_RELEASES $ML_ID_RELEASES {
        quietly count if release_year == `r' & inlist(sel_status, "multiple_versions_unresolved", "configured_version_absent")
        if r(N) > 0 ml_stop "VERSION_UNRESOLVED_`r'" "piu' versioni UDB per la release `r': impostare ML_UDBVER_`r'"
    }
    use "$ML_RUNDIR/inventory_releases.dta", clear
    global ML_RELS_AVAIL ""
    global ML_RELS_ID ""
    foreach r of global ML_RELEASES {
        quietly count if release_year == `r'
        if r(N) == 0 {
            ml_warn "RELEASE_NOT_FOUND_`r'" "release `r' non trovata nell'input"
            continue
        }
        quietly count if release_year == `r' & rel_status == "missing_required_D_or_R"
        if r(N) > 0 ml_stop "RELEASE_INCOMPLETE_`r'" "release `r' senza file D o R"
        global ML_RELS_AVAIL $ML_RELS_AVAIL `r'
    }
    if "$ML_RELS_AVAIL" == "" ml_stop "NO_RELEASES" "nessuna release configurata disponibile"
    foreach r of global ML_ID_RELEASES {
        quietly count if release_year == `r' & nD > 0
        if r(N) > 0 global ML_RELS_ID $ML_RELS_ID `r'
        else ml_warn "ID_RELEASE_NOT_FOUND_`r'" "release `r' (solo identita') senza file D"
    }

    * --- D: caricamento, DB076 (solo verifica), chiavi per il collegamento
    tempfile keys
    local firstk 1
    foreach r in $ML_RELS_AVAIL $ML_RELS_ID {
        ml_loadtype, rel(`r') ftype(D)
        capture confirm numeric variable db076, exact
        if !_rc generate int entry_db076 = year - db076 + 1 if db076 >= 1 & !missing(db076)
        else generate int entry_db076 = .
        quietly save "$ML_TMPDIR/D_`r'.dta", replace emptyok
        keep country release_year udb_version year hid_s rg_s entry_db076
        if !`firstk' append using `keys'
        quietly save `keys', replace emptyok
        local firstk 0
    }
    use `keys', clear
    ml_cohort_link

    * --- cohort_id sui D, celle, finestre osservate, presenza delle coorti
    tempfile cells
    local firstc 1
    foreach r of global ML_RELS_AVAIL {
        use "$ML_TMPDIR/D_`r'.dta", clear
        merge m:1 country release_year rg_s using "$ML_TMPDIR/cohort_map.dta", keepusing(cohort_id cohort_status) keep(master match)
        quietly count if _merge == 1
        if r(N) > 0 ml_stop "D_WITHOUT_COHORT_`r'" "famiglie D senza cohort_id"
        drop _merge
        generate str hh_uid = country + "|" + cohort_id + "|" + hid_s
        quietly save "$ML_TMPDIR/D_`r'.dta", replace emptyok
        contract country release_year udb_version year cohort_id, freq(n_hh)
        if !`firstc' append using `cells'
        quietly save `cells', replace emptyok
        local firstc 0
    }
    use `cells', clear
    quietly save "$ML_TMPDIR/cells_all.dta", replace emptyok
    collapse (min) ymin=year (max) ymax=year, by(country release_year)
    quietly save "$ML_TMPDIR/windows.dta", replace emptyok
    * presenza paese x release (paese assente da una release)
    preserve
    generate byte present = 1
    keep country release_year present ymin ymax
    fillin country release_year
    quietly replace present = 0 if _fillin
    drop _fillin
    ml_savediag "country_release_presence"
    restore
    use "$ML_TMPDIR/cells_all.dta", clear
    contract country release_year cohort_id
    drop _freq
    quietly save "$ML_TMPDIR/cpres.dta", replace emptyok

    ml_select_cells

    * --- masterD: una sola release per cella
    local mfiles ""
    foreach r of global ML_RELS_AVAIL {
        use "$ML_TMPDIR/D_`r'.dta", clear
        merge m:1 country year cohort_id using "$ML_TMPDIR/cell_registry.dta", keepusing(src_release src_version sel_reason) keep(master match)
        generate byte selected = _merge == 3 & src_release == release_year
        drop _merge
        quietly save "$ML_TMPDIR/D_`r'.dta", replace emptyok
        quietly keep if selected
        drop selected
        quietly save "$ML_TMPDIR/Dsel_`r'.dta", replace emptyok
        local mfiles `"`mfiles' "$ML_TMPDIR/Dsel_`r'.dta""'
    }
    ml_appendsafe, files(`mfiles') diag(masterD)
    ml_isid country year cohort_id hid_s, code(MASTERD_KEY)
    ml_isid year hh_uid, code(MASTERD_UID)
    preserve
    contract country year cohort_id src_release, freq(n_chk)
    merge 1:1 country year cohort_id using "$ML_TMPDIR/cell_registry.dta", keepusing(n_hh src_release)
    quietly count if _merge != 3 | n_chk != n_hh
    if r(N) > 0 {
        ml_savediag "diag_masterD_cell_counts"
        ml_stop "MASTERD_CELL_COUNTS" "conteggi di masterD diversi dal registro delle celle"
    }
    restore
    bysort country year hid_s: generate int _nc = _N
    quietly count if _nc > 1
    if r(N) > 0 ml_warn "HID_REUSED_ACROSS_COHORTS" "`r(N)' famiglie-anno con DB030 riutilizzato fra coorti (distinte da hh_uid)"
    drop _nc
    ml_numid hh_uid hh_num hh_idmap
    label variable hh_uid "famiglia: country|cohort_id|DB030"
    label variable cohort_id "coorte armonizzata (vedi cohort_groups)"
    label variable src_release "release longitudinale da cui proviene la cella"
    label variable year "observation_year"
    char _dta[ml_unit] "famiglia-anno (D)"
    quietly save "$ML_RUNDIR/masterD.dta", replace emptyok
    keep country year cohort_id hid_s src_release
    quietly save "$ML_TMPDIR/masterD_keys.dta", replace emptyok

    * --- record presenti in release vecchie dentro celle coperte da release nuove
    tempfile rd
    local firstd 1
    foreach r of global ML_RELS_AVAIL {
        use country year cohort_id hid_s release_year selected src_release using "$ML_TMPDIR/D_`r'.dta", clear
        quietly keep if !selected & !missing(src_release)
        if _N == 0 continue
        drop src_release
        merge m:1 country year cohort_id hid_s using "$ML_TMPDIR/masterD_keys.dta", keep(master match)
        generate byte absent_in_selected = _merge == 1
        generate byte one = 1
        collapse (sum) n_hh_old=one n_absent_in_selected=absent_in_selected (max) src_release, by(country year cohort_id release_year)
        if !`firstd' append using `rd'
        quietly save `rd', replace emptyok
        local firstd 0
    }
    if !`firstd' {
        use `rd', clear
        order country year cohort_id release_year src_release n_hh_old n_absent_in_selected
        ml_savediag "cell_record_diff"
        quietly summarize n_absent_in_selected
        if r(sum) > 0 ml_warn "RECORDS_NOT_RECOVERED" "`r(sum)' famiglie-anno di release vecchie assenti dalla cella selezionata: non recuperate (vedi cell_record_diff)"
    }

    * --- H, R, P entro release
    foreach r of global ML_RELS_AVAIL {
        ml_link_release `r'
    }
    foreach t in H R P {
        local tf ""
        foreach r of global ML_RELS_AVAIL {
            ml_fexists "$ML_TMPDIR/`t'sel_`r'.dta"
            if r(exists) local tf `"`tf' "$ML_TMPDIR/`t'sel_`r'.dta""'
        }
        if `"`tf'"' == "" continue
        ml_appendsafe, files(`tf') diag(master`t')
        if "`t'" == "H" {
            ml_isid year hh_uid, code(MASTERH_KEY)
            merge m:1 hh_uid using "$ML_TMPDIR/hh_idmap_candidate.dta", keepusing(hh_num) keep(master match) nogenerate
            char _dta[ml_unit] "famiglia rispondente-anno (H)"
        }
        if "`t'" == "R" {
            ml_isid person_uid year hh_uid, code(MASTERR_KEY)
            merge m:1 hh_uid using "$ML_TMPDIR/hh_idmap_candidate.dta", keepusing(hh_num) keep(master match) nogenerate
            char _dta[ml_unit] "relazione persona-famiglia-anno (R)"
        }
        if "`t'" == "P" {
            ml_isid person_uid year, code(MASTERP_KEY)
            char _dta[ml_unit] "persona-anno 16+ (P)"
        }
        quietly save "$ML_RUNDIR/master`t'.dta", replace emptyok
    }
    * pesi longitudinali di tutte le release
    local lwf ""
    foreach r of global ML_RELS_AVAIL {
        ml_fexists "$ML_TMPDIR/lw_src_`r'.dta"
        if r(exists) local lwf `"`lwf' "$ML_TMPDIR/lw_src_`r'.dta""'
    }
    if `"`lwf'"' != "" {
        ml_appendsafe, files(`lwf') diag(lw_src)
        ml_isid person_uid year release_year, code(LW_SRC_KEY)
        quietly save "$ML_TMPDIR/lw_src.dta", replace emptyok
    }
    use "$ML_TMPDIR/link_stats.dta", clear
    sort release_year step
    ml_savediag "link_stats"

    * --- relazioni persona-famiglia-anno
    use person_uid year hh_uid country cohort_id pid_s hid_s release_year using "$ML_RUNDIR/masterR.dta", clear
    bysort person_uid year: generate int n_rel = _N
    ml_savediag "person_household_year"
    preserve
    keep person_uid country cohort_id pid_s
    if _N > 0 quietly duplicates drop
    ml_isid person_uid, code(PERSON_UID_MAP)
    ml_savediag "person_id_map"
    restore

    * --- panel persona-anno e pesi
    ml_panel
    ml_weights
    char _dta[ml_unit] "persona-anno (xtset person_num year)"
    quietly save "$ML_RUNDIR/panel_person_year.dta", replace emptyok
    use "$ML_TMPDIR/panel_varying.dta", clear
    ml_savediag "panel_varying_vars"
    use "$ML_TMPDIR/cohort_idmap_candidate.dta", clear
    ml_savediag "cohort_id_map"

    if `"$ML_LEGACYDIR"' != "" ml_compare_legacy
    ml_finalize
    log close mlrun
end

*==============================================================================
* 11. INSPECT
*==============================================================================
* Produce, senza costruire il panel:
*   inventory / inventory_releases   file, tipo, release, versione, selezione
*   inspect_files                    righe, paesi, anni, variabili essenziali,
*                                    tipo delle chiavi, zeri iniziali, duplicati
*   inspect_groups                   famiglie per (release, DB075, anno)
*   inspect_weights                  pesi e variabili di disegno per paese-anno
*   inspect_relations                persone con piu' famiglie nello stesso anno (R)
*   cohort_links / cohort_groups     collegamento dei gruppi fra release

capture program drop ml_inspect
program define ml_inspect
    ml_setup "inspect"
    capture log close mlrun
    log using "$ML_RUNDIR/inspect.log", text replace name(mlrun)
    ml_inventory
    use "$ML_RUNDIR/inventory.dta", clear
    list fname ftype release_year udb_version selected sel_status type_status parse_status n_obs, noobs abbreviate(16) sepby(release_year)
    use "$ML_RUNDIR/inventory_releases.dta", clear
    if _N > 0 list, noobs abbreviate(16)
    use "$ML_RUNDIR/inventory.dta", clear
    quietly keep if usable
    local nf = _N
    if `nf' == 0 {
        di as error "nessun file utilizzabile per le release configurate: vedi inventory.csv"
        log close mlrun
        exit
    }
    forvalues i = 1/`nf' {
        local p`i' = path[`i']
        local t`i' = ftype[`i']
        local r`i' = release_year[`i']
        local v`i' = udb_version[`i']
        local s`i' = selected[`i']
    }
    tempname ph pw
    tempfile fstat wstat grp rel
    postfile `ph' str2045 path str1 ftype int release_year str20 udb_version byte selected double n_rows str244 countries int ymin int ymax str244 years str244 essential_missing str20 id_type double id_lead0 double key_dups double pid_multi_rel int n_rg_groups byte has_db076 str244 weights_present int rc using `fstat', replace
    postfile `pw' str1 ftype int release_year str20 udb_version str2 country int year str32 variable double n double n_missing double n_zero double n_negative double v_sum using `wstat', replace
    local firstg 1
    local firstr 1
    forvalues i = 1/`nf' {
        local t = "`t`i''"
        local f = lower("`t'")
        ml_usecty `"`p`i''"' `t'
        capture noisily ml_lower
        local rc = _rc
        if `rc' == 0 {
            capture noisily ml_keys, ftype(`t')
            local rc = _rc
        }
        if `rc' != 0 {
            post `ph' (`"`p`i''"') ("`t'") (`r`i'') ("`v`i''") (`s`i'') (.) ("") (.) (.) ("") ("chiavi non armonizzabili") ("") (.) (.) (.) (.) (.) ("") (`rc')
            continue
        }
        local idtype "`r(idtype)'"
        local lead0 = r(lead0)
        ml_keepcountries
        local n = _N
        local cl ""
        local yl ""
        if `n' > 0 {
            quietly levelsof country, local(cl) clean
            quietly levelsof year, local(yl) clean
        }
        quietly summarize year
        local ymin = r(min)
        local ymax = r(max)
        if "`t'" == "D" local ess "db010 db020 db030 db075 db040 db050 db060 db095"
        if "`t'" == "H" local ess "hb010 hb020 hb030"
        if "`t'" == "R" local ess "rb010 rb020 rb030 rb040 rb060 rb062 rb063 rb064 rb065 rb066 rb110"
        if "`t'" == "P" local ess "pb010 pb020 pb030 pb050"
        local miss ""
        foreach v of local ess {
            capture confirm variable `v', exact
            if _rc local miss `miss' `v'
        }
        if inlist("`t'", "D", "H") local key "country year hid_s"
        if "`t'" == "R" local key "country year pid_s hid_s"
        if "`t'" == "P" local key "country year pid_s"
        local kd = .
        local pm = .
        local ng = .
        local h76 = 0
        if `n' > 0 {
            bysort `key': generate int _dk = _N
            quietly count if _dk > 1
            local kd = r(N)
            drop _dk
            if "`t'" == "R" {
                bysort country year pid_s: generate int _nr = _N
                quietly count if _nr > 1
                local pm = r(N)
                preserve
                bysort country year pid_s: keep if _n == 1
                generate byte multi = _nr > 1
                generate byte _one = 1
                collapse (sum) n_persons=_one n_multi_rel=multi, by(country year)
                generate int release_year = `r`i''
                generate str udb_version = "`v`i''"
                if !`firstr' append using `rel'
                quietly save `rel', replace emptyok
                local firstr 0
                restore
                drop _nr
            }
            if "`t'" == "D" {
                capture confirm variable db076, exact
                local h76 = (_rc == 0)
                preserve
                if `h76' {
                    capture confirm numeric variable db076, exact
                    if !_rc generate int entry_db076 = year - db076 + 1 if db076 >= 1 & !missing(db076)
                    else generate int entry_db076 = .
                }
                else generate int entry_db076 = .
                generate byte one = 1
                collapse (sum) n_hh=one (min) entry_db076_min=entry_db076 (max) entry_db076_max=entry_db076, by(country rg_s year)
                generate int release_year = `r`i''
                generate str udb_version = "`v`i''"
                generate byte selected = `s`i''
                quietly levelsof rg_s, local(gl)
                if !`firstg' append using `grp'
                quietly save `grp', replace emptyok
                local firstg 0
                restore
                quietly levelsof rg_s, local(gl)
                local ng : word count `gl'
            }
        }
        local wp ""
        foreach v in $ML_WEIGHTVARS $ML_DESIGNVARS {
            capture confirm numeric variable `v', exact
            if _rc continue
            local wp `wp' `v'
            if `n' == 0 continue
            preserve
            generate byte _m = missing(`v')
            generate byte _z = `v' == 0
            generate byte _ng = `v' < 0 & !missing(`v')
            generate byte _one = 1
            collapse (sum) n=_one nm=_m nz=_z nn=_ng s=`v', by(country year)
            local nr = _N
            forvalues j = 1/`nr' {
                post `pw' ("`t'") (`r`i'') ("`v`i''") (country[`j']) (year[`j']) ("`v'") (n[`j']) (nm[`j']) (nz[`j']) (nn[`j']) (s[`j'])
            }
            restore
        }
        post `ph' (`"`p`i''"') ("`t'") (`r`i'') ("`v`i''") (`s`i'') (`n') (substr("`cl'", 1, 244)) (`ymin') (`ymax') (substr("`yl'", 1, 244)) (substr("`miss'", 1, 244)) ("`idtype'") (`lead0') (`kd') (`pm') (`ng') (`h76') (substr("`wp'", 1, 244)) (0)
    }
    postclose `ph'
    postclose `pw'
    use `fstat', clear
    ml_savediag "inspect_files"
    list ftype release_year udb_version n_rows countries years id_type id_lead0 key_dups pid_multi_rel n_rg_groups has_db076, noobs abbreviate(12) sepby(release_year)
    use `wstat', clear
    ml_savediag "inspect_weights"
    if !`firstg' {
        use `grp', clear
        order country release_year udb_version selected rg_s year n_hh
        sort country release_year rg_s year
        ml_savediag "inspect_groups"
        * tabella leggibile: famiglie per gruppo DB075 e anno, per release
        quietly levelsof release_year, local(rl)
        foreach r of local rl {
            di as text _n "Release `r' - famiglie per DB075 (righe) e anno (colonne):"
            tabulate rg_s year if release_year == `r' & selected == 1 [fweight = n_hh]
        }
    }
    if !`firstr' {
        use `rel', clear
        ml_savediag "inspect_relations"
    }
    * collegamento dei gruppi fra le release selezionate
    use "$ML_RUNDIR/inventory.dta", clear
    local drels ""
    quietly count if selected == 1 & ftype == "D"
    if r(N) > 0 quietly levelsof release_year if selected == 1 & ftype == "D", local(drels)
    tempfile keys
    local firstk 1
    foreach r of local drels {
        capture noisily ml_loadtype, rel(`r') ftype(D)
        if _rc continue
        capture confirm numeric variable db076, exact
        if !_rc generate int entry_db076 = year - db076 + 1 if db076 >= 1 & !missing(db076)
        else generate int entry_db076 = .
        keep country release_year udb_version year hid_s rg_s entry_db076
        if !`firstk' append using `keys'
        quietly save `keys', replace emptyok
        local firstk 0
    }
    if !`firstk' {
        use `keys', clear
        capture noisily ml_cohort_link
        local rc = _rc
        if `rc' di as error "ml_cohort_link interrotto (rc=`rc'): vedi file diag_* nella cartella"
    }
    tempname fh
    file open `fh' using "$ML_RUNDIR/INSPECT_README.txt", write replace text
    file write `fh' "Inspect completato. Da inviare per la configurazione (niente microdati):" _n
    file write `fh' " - inventory.csv, inventory_releases.csv" _n
    file write `fh' " - inspect_files.csv, inspect_groups.csv, inspect_relations.csv" _n
    file write `fh' " - cohort_links.csv, cohort_groups.csv, warnings.txt, certification_failures.txt" _n
    file write `fh' " - inspect_weights.csv (solo somme e conteggi per paese-anno)" _n
    file close `fh'
    di as result "INSPECT completato: $ML_RUNDIR"
    log close mlrun
end

*==============================================================================
* 12. DEMO: dati artificiali (paesi fittizi XA, XB, XC) e test automatici
*==============================================================================
* Regola di pubblicazione simulata: una coorte con ingresso e e durata L compare
* nella release r se e+1 <= r <= e+L-1, con anni max(e, r-3)..r (finestra
* pubblicata di 4 anni anche per coorti di 6 anni => troncamento a sinistra).
* Run 1 (XA, XB; release 2019-2022, legacy, strict) deve risultare CERTIFICATA:
*   T1 coorte di 4 anni in release sovrapposte: ogni cella una sola volta
*   T2 famiglia presente solo nella release vecchia dentro una cella coperta: non recuperata
*   T3 coorte di 6 anni con finestre troncate: un solo cohort_id
*   T4 DB075 e DB030 riutilizzati da una coorte successiva: storie non fuse
*   T5 paese assente da una release (XB 2020) e cella attesa ma assente (strict)
*   T6 persona con cambio di famiglia e due relazioni nello stesso anno
* Run 2 (XC; release 2020-2021) deve risultare NON certificata:
*   T7 mapping ambiguo (gruppi rimescolati al 50%) e rb060 interamente mancante

capture program drop ml_demo_hh
program define ml_demo_hh
    args acc country rg entry L h0 h1 rels
    preserve
    local pairs ""
    local k 0
    foreach r of local rels {
        if `r' >= `entry' + 1 & `r' <= `entry' + `L' - 1 {
            local y0 = max(`entry', `r' - 3)
            local y1 = min(`r', `entry' + `L' - 1)
            forvalues y = `y0'/`y1' {
                local ++k
                local pairs `pairs' `r'_`y'
            }
        }
    }
    if `k' > 0 {
        clear
        quietly set obs `=`h1' - `h0' + 1'
        generate long hid = `h0' + _n - 1
        quietly expand `k'
        bysort hid: generate int idx = _n
        generate int release = .
        generate int year = .
        forvalues j = 1/`k' {
            local pr : word `j' of `pairs'
            quietly replace release = real(substr("`pr'", 1, 4)) if idx == `j'
            quietly replace year = real(substr("`pr'", 6, 4)) if idx == `j'
        }
        drop idx
        generate str2 country = "`country'"
        generate int rg = `rg'
        generate int entry = `entry'
        generate int dur = `L'
        append using "`acc'"
        quietly save "`acc'", replace emptyok
    }
    restore
end

capture program drop ml_demo_row
program define ml_demo_row
    args acc country rg entry L hid release year
    preserve
    clear
    quietly set obs 1
    generate long hid = `hid'
    generate int release = `release'
    generate int year = `year'
    generate str2 country = "`country'"
    generate int rg = `rg'
    generate int entry = `entry'
    generate int dur = `L'
    append using "`acc'"
    quietly save "`acc'", replace emptyok
    restore
end

* Scrive i file D/H/R/P per release a partire dalle famiglie-anno (acc) e dalle
* relazioni persona-famiglia (racc).
capture program drop ml_demo_write
program define ml_demo_write
    args acc racc outdir rels
    foreach r of local rels {
        local v = `r' + 2
        use "`acc'", clear
        quietly keep if release == `r'
        if _N == 0 continue
        generate int db010 = year
        generate str2 db020 = country
        generate long db030 = hid
        generate int db075 = rg
        generate double db090 = 500
        generate int db050 = 1
        generate int db060 = mod(hid, 5) + 1
        keep db010 db020 db030 db075 db090 db050 db060
        label variable db075 "Rotation group"
        quietly save "`outdir'/DEMO_L`r'_v`v'-01_D.dta", replace emptyok
        use "`acc'", clear
        quietly keep if release == `r'
        generate int hb010 = year
        generate str2 hb020 = country
        generate long hb030 = hid
        generate double hy020 = 30000
        keep hb010 hb020 hb030 hy020
        quietly save "`outdir'/DEMO_L`r'_v`v'-01_H.dta", replace emptyok
        use "`racc'", clear
        quietly keep if release == `r'
        generate int rb010 = year
        generate str2 rb020 = country
        generate long rb030 = pid
        generate long rb040 = hid
        generate double rb060 = cond(country == "XC" & year == 2020, ., 1000 + mod(pid, 7) * 10)
        generate double rb064 = cond(dur == 4 & year == entry + 3, 800 + mod(pid, 5), .)
        generate int rb080 = 1970 + mod(pid, 30)
        keep rb010 rb020 rb030 rb040 rb060 rb064 rb080
        quietly save "`outdir'/DEMO_L`r'_v`v'-01_R.dta", replace emptyok
        use "`racc'", clear
        quietly keep if release == `r'
        bysort country year pid: keep if _n == 1
        generate int pb010 = year
        generate str2 pb020 = country
        generate long pb030 = pid
        generate double pb040 = 1000 + mod(pid, 7) * 10
        generate double py010g = 20000 + mod(pid, 13) * 1000
        keep pb010 pb020 pb030 pb040 py010g
        quietly save "`outdir'/DEMO_L`r'_v`v'-01_P.dta", replace emptyok
    }
end

capture program drop ml_demo_assert
program define ml_demo_assert
    args ok label
    if `ok' di as result "  OK       `label'"
    else {
        di as error "  FALLITO  `label'"
        global ML_DEMO_NFAIL = $ML_DEMO_NFAIL + 1
        global ML_DEMO_FAILED `"$ML_DEMO_FAILED | `label'"'
    }
end

capture program drop ml_demo
program define ml_demo
    local saved "ML_INDIR ML_WORKDIR ML_OUTDIR ML_FNAME_INCLUDE ML_FNAME_EXCLUDE ML_COUNTRIES ML_RELEASES ML_ID_RELEASES ML_FILEMAP ML_COHORTMAP ML_DESIGNFILE ML_CELLPOLICY ML_WEIGHTMODE ML_IDMAPDIR ML_POPFILE ML_LEGACYDIR ML_LWIN_ANCHOR"
    foreach g of local saved {
        local sv_`g' `"${`g'}"'
    }
    local wd `"$ML_WORKDIR"'
    local wd : subinstr local wd "\" "/", all
    ml_mkdir "`wd'"
    local d = string(date(c(current_date), "DMY"), "%tdCCYYNNDD")
    local t = subinstr(c(current_time), ":", "", .)
    local base "`wd'/demo_`d'_`t'"
    foreach sub in "" "/input_run1" "/input_run2" "/out" "/work" "/idmaps_run1" "/idmaps_run2" {
        ml_mkdir "`base'`sub'"
    }
    global ML_DEMO_NFAIL 0
    global ML_DEMO_FAILED ""
    tempfile acc racc

    * ---------------------------------------------------------------- dati run 1
    clear
    generate long hid = .
    generate int release = .
    generate int year = .
    generate str2 country = ""
    generate int rg = .
    generate int entry = .
    generate int dur = .
    quietly save `acc', emptyok
    local relA "2019 2020 2021 2022"
    ml_demo_hh "`acc'" XA 1 2017 4 101 120 "`relA'"
    ml_demo_hh "`acc'" XA 2 2018 6 201 220 "`relA'"
    ml_demo_hh "`acc'" XA 1 2021 6 101 120 "`relA'"
    ml_demo_hh "`acc'" XA 3 2019 4 301 320 "`relA'"
    ml_demo_hh "`acc'" XA 4 2020 6 401 420 "`relA'"
    * T2: famiglia 199 solo nella release 2019 (cella 2018 della coorte A)
    ml_demo_row "`acc'" XA 1 2017 4 199 2019 2018
    * T6: famiglia 150 (split-off della 105, stessa coorte A)
    ml_demo_row "`acc'" XA 1 2017 4 150 2019 2019
    ml_demo_row "`acc'" XA 1 2017 4 150 2020 2019
    ml_demo_row "`acc'" XA 1 2017 4 150 2020 2020
    * T5: XB assente dalla release 2020
    local relB "2019 2021"
    ml_demo_hh "`acc'" XB 1 2016 4 701 715 "`relB'"
    ml_demo_hh "`acc'" XB 2 2018 4 801 815 "`relB'"
    ml_demo_hh "`acc'" XB 4 2018 4 951 960 "`relB'"
    use `acc', clear
    * T5: coorte G senza l'anno 2018 nella release 2021 (cella attesa ma assente)
    quietly drop if country == "XB" & rg == 2 & release == 2021 & year == 2018
    quietly save `acc', replace emptyok
    * persone: due per famiglia (pid = hid*100 + 1, 2)
    quietly expand 2
    bysort release year country hid: generate long pid = hid * 100 + _n
    * T6: la persona 10501 e' in 105 e 150 nel 2019, solo in 150 nel 2020
    quietly drop if country == "XA" & pid == 10501 & hid == 105 & year == 2020
    quietly expand 2 if country == "XA" & pid == 15001, generate(_dup)
    quietly replace pid = 10501 if _dup == 1
    drop _dup
    quietly save `racc', emptyok
    ml_demo_write "`acc'" "`racc'" "`base'/input_run1" "`relA'"

    * ---------------------------------------------------------------- run 1
    global ML_INDIR "`base'/input_run1"
    global ML_WORKDIR "`base'/work"
    global ML_OUTDIR "`base'/out"
    global ML_IDMAPDIR "`base'/idmaps_run1"
    global ML_FNAME_INCLUDE "^DEMO_"
    global ML_FNAME_EXCLUDE ""
    global ML_COUNTRIES "XA XB"
    global ML_RELEASES "2019 2020 2021 2022"
    global ML_ID_RELEASES ""
    global ML_FILEMAP ""
    global ML_COHORTMAP ""
    global ML_DESIGNFILE ""
    global ML_POPFILE ""
    global ML_LEGACYDIR ""
    global ML_CELLPOLICY "strict"
    global ML_WEIGHTMODE "legacy"
    global ML_LWIN_ANCHOR "end"
    ml_build
    local run1 "$ML_LAST_RUNDIR"
    di as text _n "DEMO run 1: `run1'"
    ml_demo_assert `=$ML_LAST_CERT == 1' "run 1 certificata"

    use "`run1'/cohort_groups.dta", clear
    quietly keep if country == "XA" & release_year == 2020 & rg_s == "1"
    local cA = cohort_id[1]
    use "`run1'/cohort_groups.dta", clear
    quietly keep if country == "XA" & release_year == 2022 & rg_s == "1"
    local cC = cohort_id[1]
    use "`run1'/cohort_groups.dta", clear
    quietly keep if country == "XB" & release_year == 2019 & rg_s == "2"
    local cG = cohort_id[1]
    use "`run1'/cohort_groups.dta", clear
    quietly keep if country == "XB" & release_year == 2019 & rg_s == "1"
    local cF = cohort_id[1]
    use "`run1'/cohort_groups.dta", clear
    quietly keep if country == "XA" & rg_s == "2"
    quietly levelsof cohort_id, local(cB)
    local nB : word count `cB'
    ml_demo_assert `=`nB' == 1 & _N == 4' "T3 coorte di 6 anni: un solo cohort_id in 4 release"
    local cB : word 1 of `cB'

    use "`run1'/cell_registry.dta", clear
    quietly count if cohort_id == "`cA'"
    local n1 = r(N)
    quietly count if cohort_id == "`cA'" & src_release == 2020
    ml_demo_assert `=`n1' == 4 & r(N) == 4' "T1 coorte A: 4 celle, tutte dalla release 2020"
    use "`run1'/masterD.dta", clear
    quietly count if cohort_id == "`cA'"
    ml_demo_assert `=r(N) == 82' "T1 coorte A: 82 famiglie-anno (20x4 + famiglia 150 x2), nessun duplicato"
    quietly count if country == "XA" & hid_s == "199"
    ml_demo_assert `=r(N) == 0' "T2 famiglia 199 (solo release vecchia) non recuperata"
    use "`run1'/cell_record_diff.dta", clear
    quietly count if country == "XA" & year == 2018 & cohort_id == "`cA'" & release_year == 2019 & n_absent_in_selected == 1
    ml_demo_assert `=r(N) == 1' "T2 record assente nella cella selezionata documentato"
    use "`run1'/masterD.dta", clear
    quietly count if cohort_id == "`cB'"
    local nbrows = r(N)
    quietly count if cohort_id == "`cB'" & year == 2018 & src_release == 2021
    local nb18 = r(N)
    quietly count if cohort_id == "`cB'" & year >= 2019 & src_release == 2022
    ml_demo_assert `=`nbrows' == 100 & `nb18' == 20 & r(N) == 80' "T3 coorte B: anni 2018-2022, 2018 dalla release 2021"
    ml_demo_assert `="`cA'" != "`cC'"' "T4 stesso DB075 e stessi DB030: coorti A e C distinte"
    use "`run1'/panel_person_year.dta", clear
    quietly keep if country == "XA" & pid_s == "10101"
    quietly levelsof person_uid, local(pu)
    local npu : word count `pu'
    bysort person_uid: egen int _yl = min(year)
    bysort person_uid: egen int _yh = max(year)
    quietly count if (_yl <= 2020 & _yh >= 2021)
    ml_demo_assert `=`npu' == 2 & r(N) == 0' "T4 pid 10101 in due coorti: due person_uid, storie non fuse"
    use "`run1'/cell_registry.dta", clear
    quietly count if cohort_id == "`cF'" & src_release == 2019
    ml_demo_assert `=r(N) == 4' "T5 XB assente nel 2020: coorte F 2016-2019 presa dalla release 2019"
    use "`run1'/cell_decisions.dta", clear
    quietly count if cohort_id == "`cG'" & year == 2018 & release_year == 2019 & reason == "expected_absent_in_newer" & decision == "excluded"
    ml_demo_assert `=r(N) == 1' "T5 cella attesa ma assente: esclusa e documentata (strict)"
    use "`run1'/masterD.dta", clear
    quietly count if cohort_id == "`cG'" & year == 2018
    ml_demo_assert `=r(N) == 0' "T5 nessuna riga 2018 della coorte G nel masterD"
    use "`run1'/panel_person_year.dta", clear
    quietly count if country == "XA" & pid_s == "10501" & year == 2019
    local np = r(N)
    quietly count if country == "XA" & pid_s == "10501" & year == 2019 & multi_hh == 1 & hh_uid == ""
    ml_demo_assert `=`np' == 1 & r(N) == 1' "T6 una riga persona-anno, famiglia non scelta arbitrariamente"
    use "`run1'/person_household_year.dta", clear
    quietly count if country == "XA" & pid_s == "10501" & year == 2019
    ml_demo_assert `=r(N) == 2' "T6 due relazioni persona-famiglia conservate"
    use "`run1'/masterP.dta", clear
    quietly count if country == "XA" & pid_s == "10501" & year == 2019
    ml_demo_assert `=r(N) == 1' "T6 dati P non duplicati"
    use "`run1'/panel_person_year.dta", clear
    * la coorte C riusa i DB030 101-120, quindi esiste un altro pid 10501 (T4):
    * il controllo riguarda la sola coorte A
    quietly count if country == "XA" & pid_s == "10501" & cohort_id == "`cA'"
    local n10501 = r(N)
    quietly levelsof person_uid if country == "XA" & pid_s == "10501" & cohort_id == "`cA'", local(pu)
    local npu : word count `pu'
    ml_demo_assert `=`n10501' == 4 & `npu' == 1' "T6 identita' personale stabile dopo il cambio di famiglia (coorte A, 2017-2020)"
    quietly levelsof person_uid if country == "XA" & pid_s == "10501", local(pu)
    local npu : word count `pu'
    ml_demo_assert `=`npu' == 2' "T4/T6 pid 10501 riusato dalla coorte C: due persone distinte"

    * ---------------------------------------------------------------- run 2
    clear
    generate long hid = .
    generate int release = .
    generate int year = .
    generate str2 country = ""
    generate int rg = .
    generate int entry = .
    generate int dur = .
    quietly save `acc', replace emptyok
    local relC "2020 2021"
    ml_demo_hh "`acc'" XC 5 2019 4 501 520 "`relC'"
    ml_demo_hh "`acc'" XC 6 2019 4 601 620 "`relC'"
    use `acc', clear
    * T7: nella release 2021 i gruppi sono rimescolati al 50%
    quietly replace rg = 6 if release == 2021 & inrange(hid, 511, 520)
    quietly replace rg = 5 if release == 2021 & inrange(hid, 601, 610)
    quietly save `acc', replace emptyok
    quietly expand 2
    bysort release year country hid: generate long pid = hid * 100 + _n
    quietly save `racc', replace emptyok
    ml_demo_write "`acc'" "`racc'" "`base'/input_run2" "`relC'"
    global ML_INDIR "`base'/input_run2"
    global ML_IDMAPDIR "`base'/idmaps_run2"
    global ML_COUNTRIES "XC"
    global ML_RELEASES "2020 2021"
    ml_build
    local run2 "$ML_LAST_RUNDIR"
    di as text _n "DEMO run 2: `run2'"
    ml_demo_assert `=$ML_LAST_CERT == 0' "T7 run 2 NON certificata"
    ml_fexists "`run2'/NOT_CERTIFIED.txt"
    local e1 = r(exists)
    ml_fexists "`run2'/CERTIFIED.txt"
    ml_demo_assert `=`e1' == 1 & r(exists) == 0' "T7 cartella marcata NOT_CERTIFIED"
    use "`run2'/cohort_groups.dta", clear
    quietly count if cohort_status == "ambiguous"
    ml_demo_assert `=r(N) >= 2' "T7 gruppi ambigui diagnosticati (cohort_groups/cohort_links)"
    ml_fexists "`run2'/diag_legacy_denom_zero_rb060s.dta"
    ml_demo_assert `=r(exists) == 1' "T7 rb060 interamente mancante: diagnostica esplicita"
    use "`run2'/weights_diag.dta", clear
    quietly count if weight_var == "rb060" & year == 2020 & denom_zero == 1
    ml_demo_assert `=r(N) >= 1' "T7 weights_diag segnala denominatore nullo"
    ml_fexists "`base'/idmaps_run2/cohort_idmap.dta"
    ml_demo_assert `=r(exists) == 0' "T7 mappe ID persistenti non aggiornate"

    * ripristino della configurazione
    foreach g of local saved {
        global `g' `"`sv_`g''"'
    }
    if $ML_DEMO_NFAIL > 0 {
        di as error "DEMO: $ML_DEMO_NFAIL test falliti. Cartelle: `run1'  `run2'"
        di as error `"Test falliti: $ML_DEMO_FAILED"'
        di as error "Vedi anche `run1'/certification_failures.txt e warnings.txt"
        exit 9
    }
    di as result "DEMO SUPERATA: tutti i test OK. Cartelle: `run1'  `run2'"
end

*==============================================================================
* 13. ESECUZIONE
*==============================================================================
if "$ML_MODE" == "inspect" ml_inspect
else if "$ML_MODE" == "build" ml_build
else if "$ML_MODE" == "demo" ml_demo
else {
    di as error "ML_MODE deve essere inspect, build o demo"
    exit 198
}
