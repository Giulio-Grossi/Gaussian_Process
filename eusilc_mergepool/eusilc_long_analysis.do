*! eusilc_long_analysis.do  -  versione 0.1
*! Nomi brevi ed etichette EU-SILC per l'output certificato di mergepool_long.do
*! e analisi descrittiva dell'affidabilita' delle stime nel tempo.
*!
*! Requisito: Stata 16.0 o successivo (frames). Nessun pacchetto esterno.
*!
*! PARTE A - NOMI ED ETICHETTE
*!  Input : ultima run certificata (OUTPUT/LATEST_CERTIFIED.txt) oppure NM_RUN
*!          panel_person_year.dta, masterH.dta, masterD.dta
*!  Output: <NM_OUTDIR>/EUSILC_long_persons.dta      persona-anno (xtset person_num year)
*!          <NM_OUTDIR>/EUSILC_long_households.dta   famiglia-anno (year hh_uid)
*!          <NM_OUTDIR>/EUSILC_long_persons_hh.dta   persona-anno + variabili familiari
*!          <NM_OUTDIR>/variable_dictionary.csv      codice -> nome, etichetta vecchia/nuova
*!  Regole: nome breve inglese dal dizionario sotto (codici e significati secondo
*!  le "Methodological guidelines and description of EU-SILC target variables",
*!  DocSILC065); flag "_f" e fattori di imputazione "_i" seguono il nome della
*!  variabile; l'etichetta riporta sempre il codice originale tra [ ]. Le variabili
*!  non presenti nel dizionario restano col codice e con l'etichetta originale
*!  (status "not_mapped" nel dizionario prodotto). Le chiavi grezze xB010/xB020
*!  sono eliminate solo se coincidono con year/country.
*!
*! PARTE B - ANALISI (per ogni variabile numerica di contenuto, persone e famiglie)
*!  Output in <AN_OUTDIR>:
*!   stability_summary.csv     una riga per variabile: caratteristiche, metriche,
*!                             giudizio (affidabile / da verificare / instabile) e motivi
*!   desc_by_year.csv          copertura e stime per anno (media pesata e non, SE)
*!   cat_shares_by_year.csv    quote pesate per categoria e anno (variabili categoriali)
*!   cohort_heterogeneity.csv  test di omogeneita' fra coorti nello stesso anno
*!   within_person.csv         stabilita' intra-unita' (t vs t-1)
*!   graphs/*.png              andamento delle variabili non affidabili
*!   README_analysis.txt       definizione delle metriche e delle soglie
*!  Metriche (soglie configurabili):
*!   - salto di livello: |z| > AN_ZTHR fra anni consecutivi e variazione rilevante
*!     (relativa > AN_RELTHR per continue, > AN_PPTHR in quota per categoriali);
*!     i salti negli anni AN_KNOWN (rotture note, es. IESS 2021) sono riportati
*!     a parte e non contano nel giudizio;
*!   - picco isolato: scarto dalla media dei due anni vicini, |z| > AN_ZTHR;
*!   - rumore: radice della media dei quadrati degli scarti standardizzati dalla
*!     media dei vicini (= 1 se l'andamento e' liscio e la variazione e' solo
*!     campionaria; > 2 la serie oscilla piu' di quanto il campione spieghi);
*!   - eterogeneita' fra coorti: quota di anni in cui le coorti presenti danno
*!     stime significativamente diverse (p < 0.001): segnala bias da rotazione,
*!     attrito o selezione delle celle;
*!   - copertura: salti della quota di validi > AN_COVTHR punti;
*!   - stabilita' intra-unita': correlazione t/t-1 (continue) o quota di cambi
*!     (categoriali) anomala in un anno rispetto agli altri (ricodifiche);
*!   - attributi fissi (sesso, anno/paese di nascita): quota di persone con
*!     valori diversi nel tempo.
*!  Gli errori standard sono approssimati: varianza pesata / numerosita' efficace
*!  (Kish) moltiplicata per AN_DEFF (effetto del disegno a grappoli, non stimato).

version 16.0
clear all
capture log close nmlog
set more off
set varabbrev off
set graphics off

*==============================================================================
* CONFIGURAZIONE
*==============================================================================
global NM_OUTROOT  "/Volumes/ext_blu/EUSILC/OUTPUT"   // con LATEST_CERTIFIED.txt
global NM_RUN      ""      // cartella di una run; vuoto = ultima run certificata
global NM_OUTDIR   ""      // dataset rinominati; vuoto = NM_OUTROOT/LONG_NAMED
global AN_OUTDIR   ""      // risultati analisi; vuoto = NM_OUTROOT/LONG_ANALYSIS
global AN_RUN      1       // 0 = solo rinomina, senza analisi
global AN_MAXCAT   12      // interi con al piu' tante modalita' = categoriali
global AN_ZTHR     4       // soglia |z| per salti e picchi
global AN_RELTHR   0.05    // variazione relativa minima per un salto (continue)
global AN_PPTHR    0.03    // variazione minima di quota per un salto (categoriali)
global AN_MINSHARE 0.02    // categorie con quota media inferiore non giudicate
global AN_COVTHR   20      // salto di copertura (punti percentuali di validi)
global AN_DEFF     2       // effetto del disegno assunto per gli SE
global AN_KNOWN    "2014 2021"   // rotture note (2014 codifica ISCED in PE040; 2021 IESS)
global AN_FIXED    "sex sex_p birth_year birth_year_p birth_month birth_month_p birth_ctry birth_ctry_p"
global AN_GRAPHS   1
global AN_MAXGRAPHS 60

*==============================================================================
* DIZIONARIO EU-SILC: codice, nome breve, etichetta, file di origine
*==============================================================================
clear
input str8 code str28 name str80 label str1 file
"db030" "hh_id" "Household ID" "D"
"db040" "region" "Region (NUTS)" "D"
"db050" "strata" "Stratum" "D"
"db060" "psu" "Primary sampling unit (PSU)" "D"
"db062" "ssu" "Secondary sampling unit (SSU)" "D"
"db070" "psu_order" "Order of selection of PSU" "D"
"db075" "rot_group" "Rotation group" "D"
"db076" "int_wave" "Interview wave" "D"
"db090" "hh_wgt_cs" "Household cross-sectional weight" "D"
"db095" "hh_wgt_lg" "Household longitudinal weight" "D"
"db100" "urban" "Degree of urbanisation" "D"
"db110" "hh_status" "Household status" "D"
"db120" "contact_addr" "Contact at address" "D"
"db130" "hh_quest_res" "Household questionnaire result" "D"
"db135" "hh_int_accept" "Household interview acceptance" "D"
"hb030" "hh_id" "Household ID" "H"
"hb050" "int_month" "Month of household interview" "H"
"hb060" "int_year" "Year of household interview" "H"
"hb070" "resp_hhq_id" "Person responding the household questionnaire" "H"
"hb080" "resp_acc1_id" "Person 1 responsible for the accommodation" "H"
"hb090" "resp_acc2_id" "Person 2 responsible for the accommodation" "H"
"hb100" "int_minutes" "Minutes to complete the household questionnaire" "H"
"hh010" "dwelling_type" "Dwelling type" "H"
"hh020" "tenure" "Tenure status" "H"
"hh021" "tenure_5c" "Tenure status (5 categories)" "H"
"hh030" "rooms" "Number of rooms available to the household" "H"
"hh031" "contract_year" "Year of contract or purchasing or installation" "H"
"hh040" "leak_damp" "Leaking roof, damp walls/floors/foundation, or rot" "H"
"hh050" "keep_warm" "Ability to keep home adequately warm" "H"
"hh060" "rent" "Current rent related to occupied dwelling" "H"
"hh061" "rent_subj" "Subjective rent" "H"
"hh070" "housing_cost" "Total housing cost" "H"
"hh071" "mortgage_princ" "Mortgage principal repayment" "H"
"hh080" "bath_shower" "Bath or shower in dwelling" "H"
"hh090" "toilet" "Indoor flushing toilet for sole use of household" "H"
"hs010" "arr_mort_rent" "Arrears on mortgage or rent payments" "H"
"hs011" "arr_mort_rent_3c" "Arrears on mortgage or rent payments (3 categories)" "H"
"hs020" "arr_utility" "Arrears on utility bills" "H"
"hs021" "arr_utility_3c" "Arrears on utility bills (3 categories)" "H"
"hs030" "arr_loans" "Arrears on hire purchase instalments or other loans" "H"
"hs031" "arr_loans_3c" "Arrears on hire purchase instalments or loans (3 categories)" "H"
"hs040" "afford_holiday" "Capacity to afford one week annual holiday away from home" "H"
"hs050" "afford_meal" "Capacity to afford a meal with meat, chicken, fish every second day" "H"
"hs060" "afford_unexp" "Capacity to face unexpected financial expenses" "H"
"hs070" "has_phone" "Do you have a telephone" "H"
"hs080" "has_tv" "Do you have a colour TV" "H"
"hs090" "has_pc" "Do you have a computer" "H"
"hs100" "has_washmach" "Do you have a washing machine" "H"
"hs110" "has_car" "Do you have a car" "H"
"hs120" "ends_meet" "Ability to make ends meet" "H"
"hs130" "min_inc_ends" "Lowest monthly income to make ends meet" "H"
"hs140" "housing_burden" "Financial burden of the total housing cost" "H"
"hs150" "debt_burden" "Financial burden of repayment of debts from hire purchases or loans" "H"
"hs160" "too_dark" "Problems with the dwelling: too dark, not enough light" "H"
"hs170" "noise" "Noise from neighbours or from the street" "H"
"hs180" "pollution" "Pollution, grime or other environmental problems" "H"
"hs190" "crime" "Crime, violence or vandalism in the area" "H"
"hy010" "inc_hh_gross" "Total household gross income" "H"
"hy020" "inc_hh_disp" "Total disposable household income" "H"
"hy022" "inc_disp_pre_st" "Disposable income before social transfers other than old-age and survivor's" "H"
"hy023" "inc_disp_pre_all" "Disposable income before social transfers including old-age and survivor's" "H"
"hy145n" "tax_adjust_n" "Repayments/receipts for tax adjustment (net)" "H"
"hx010" "exch_rate" "Exchange rate" "H"
"hx040" "hh_size" "Household size" "H"
"hx050" "eq_size" "Equivalised household size" "H"
"hx060" "hh_type" "Household type" "H"
"hx070" "tenure_hx" "Tenure status (derived)" "H"
"hx080" "poverty" "At risk of poverty indicator" "H"
"hx090" "eq_disp_inc" "Equivalised disposable income" "H"
"hx120" "overcrowd" "Overcrowded household" "H"
"hy030g" "imp_rent_g" "Imputed rent (gross)" "H"
"hy030n" "imp_rent_n" "Imputed rent (net)" "H"
"hy040g" "rental_inc_g" "Income from rental of a property or land (gross)" "H"
"hy040n" "rental_inc_n" "Income from rental of a property or land (net)" "H"
"hy050g" "family_allow_g" "Family/children related allowances (gross)" "H"
"hy050n" "family_allow_n" "Family/children related allowances (net)" "H"
"hy060g" "soc_excl_g" "Social exclusion not elsewhere classified (gross)" "H"
"hy060n" "soc_excl_n" "Social exclusion not elsewhere classified (net)" "H"
"hy070g" "housing_allow_g" "Housing allowances (gross)" "H"
"hy070n" "housing_allow_n" "Housing allowances (net)" "H"
"hy080g" "transf_recv_g" "Regular inter-household cash transfers received (gross)" "H"
"hy080n" "transf_recv_n" "Regular inter-household cash transfers received (net)" "H"
"hy081g" "alimony_recv_g" "Alimonies received (gross)" "H"
"hy081n" "alimony_recv_n" "Alimonies received (net)" "H"
"hy090g" "invest_inc_g" "Interests, dividends, profit from capital investments (gross)" "H"
"hy090n" "invest_inc_n" "Interests, dividends, profit from capital investments (net)" "H"
"hy100g" "mort_interest_g" "Interest repayments on mortgage (gross)" "H"
"hy100n" "mort_interest_n" "Interest repayments on mortgage (net)" "H"
"hy110g" "inc_under16_g" "Income received by people aged under 16 (gross)" "H"
"hy110n" "inc_under16_n" "Income received by people aged under 16 (net)" "H"
"hy120g" "wealth_tax_g" "Regular taxes on wealth (gross)" "H"
"hy120n" "wealth_tax_n" "Regular taxes on wealth (net)" "H"
"hy130g" "transf_paid_g" "Regular inter-household cash transfers paid (gross)" "H"
"hy130n" "transf_paid_n" "Regular inter-household cash transfers paid (net)" "H"
"hy131g" "alimony_paid_g" "Alimonies paid (gross)" "H"
"hy131n" "alimony_paid_n" "Alimonies paid (net)" "H"
"hy140g" "tax_ssc_g" "Tax on income and social insurance contributions (gross)" "H"
"hy140n" "tax_ssc_n" "Tax on income and social insurance contributions (net)" "H"
"hy170g" "own_prod_g" "Value of goods produced for own consumption (gross)" "H"
"hy170n" "own_prod_n" "Value of goods produced for own consumption (net)" "H"
"rb030" "pers_id" "Personal ID" "R"
"rb040" "hh_id_cur" "Current household ID" "R"
"rb050" "pers_wgt_cs" "Personal cross-sectional weight" "R"
"rb060" "pers_base_wgt" "Personal base weight" "R"
"rb062" "lw2" "Longitudinal weight (two-year duration)" "R"
"rb063" "lw3" "Longitudinal weight (three-year duration)" "R"
"rb064" "lw4" "Longitudinal weight (four-year duration)" "R"
"rb065" "lw5" "Longitudinal weight (five-year duration)" "R"
"rb066" "lw6" "Longitudinal weight (six-year duration)" "R"
"rb070" "birth_month" "Month of birth" "R"
"rb080" "birth_year" "Year of birth" "R"
"rb090" "sex" "Sex" "R"
"rb100" "sample_pers" "Sample person or co-resident" "R"
"rb110" "member_status" "Membership status" "R"
"rb120" "moved_to" "Where the person moved to" "R"
"rb140" "moved_out_month" "Month moved out or died" "R"
"rb150" "moved_out_year" "Year moved out or died" "R"
"rb160" "months_in_hh" "Months spent in the household during income reference period" "R"
"rb170" "main_act_inc" "Main activity status during the income reference period" "R"
"rb180" "moved_in_month" "Month moved in" "R"
"rb190" "moved_in_year" "Year moved in" "R"
"rb200" "resid_status" "Residential status" "R"
"rb210" "basic_act" "Basic activity status" "R"
"rb211" "main_act_self" "Main activity status (self-defined)" "R"
"rb220" "father_id" "Father ID" "R"
"rb230" "mother_id" "Mother ID" "R"
"rb240" "partner_id" "Spouse/partner ID" "R"
"rb245" "resp_status" "Respondent status" "R"
"rb250" "data_status" "Data status" "R"
"rb260" "int_type" "Type of interview" "R"
"rb270" "proxy_id" "Personal ID of proxy" "R"
"rb280" "birth_ctry" "Country of birth" "R"
"rb290" "citizenship" "Citizenship" "R"
"rx010" "age_int" "Age at the date of the interview" "R"
"rx020" "age_inc_end" "Age at the end of the income reference period" "R"
"rx030" "hh_id_rx" "Household ID (derived)" "R"
"pb030" "pers_id_p" "Personal ID (P file)" "P"
"pb040" "pers_wgt_cs_p" "Personal cross-sectional weight (P file)" "P"
"pb050" "pers_base_wgt_p" "Personal base weight (P file)" "P"
"pb060" "pers_wgt_sel" "Personal cross-sectional weight for selected respondent" "P"
"pb070" "pers_dwgt_sel" "Personal design weight for selected respondent" "P"
"pb080" "pers_base_wgt_sel" "Personal base weight for selected respondent" "P"
"pb100" "int_month_p" "Month of the personal interview" "P"
"pb110" "int_year_p" "Year of the personal interview" "P"
"pb120" "int_minutes_p" "Minutes to complete the personal questionnaire" "P"
"pb130" "birth_month_p" "Month of birth (P file)" "P"
"pb140" "birth_year_p" "Year of birth (P file)" "P"
"pb150" "sex_p" "Sex (P file)" "P"
"pb160" "father_id_p" "Father ID (P file)" "P"
"pb170" "mother_id_p" "Mother ID (P file)" "P"
"pb180" "partner_id_p" "Spouse/partner ID (P file)" "P"
"pb190" "marital" "Marital status" "P"
"pb200" "cons_union" "Consensual union" "P"
"pb210" "birth_ctry_p" "Country of birth (P file)" "P"
"pb220a" "citizen1" "Citizenship 1" "P"
"pb220b" "citizen2" "Citizenship 2" "P"
"pe010" "in_educ" "Current education activity" "P"
"pe020" "isced_cur" "ISCED level currently attended" "P"
"pe021" "isced_cur21" "Level of the study programme currently attended" "P"
"pe030" "isced_att_year" "Year when highest level of education was attained" "P"
"pe040" "isced_att" "Highest ISCED level attained" "P"
"pe041" "isced_att21" "Educational attainment level" "P"
"pl015" "ever_worked" "Person has ever worked" "P"
"pl016" "ever_worked21" "Existence of previous work experience" "P"
"pl020" "job_search" "Actively looking for a job" "P"
"pl025" "avail_work" "Available for work" "P"
"pl030" "econ_status" "Self-defined current economic status" "P"
"pl031" "econ_status31" "Self-defined current economic status (PL031)" "P"
"pl035" "worked_1h" "Worked at least 1 hour during the previous week" "P"
"pl040" "empl_status" "Status in employment" "P"
"pl040a" "empl_status21" "Status in employment in the main job" "P"
"pl040b" "empl_status_last" "Status in employment in the last job" "P"
"pl050" "occ_isco88" "Occupation (ISCO-88)" "P"
"pl051" "occ_isco08" "Occupation (ISCO-08)" "P"
"pl060" "hours_main" "Hours usually worked per week in main job" "P"
"pl070" "m_ft" "Months spent at full-time work" "P"
"pl072" "m_pt" "Months spent at part-time work" "P"
"pl073" "m_ft_emp" "Months at full-time work as employee" "P"
"pl074" "m_pt_emp" "Months at part-time work as employee" "P"
"pl075" "m_ft_self" "Months at full-time work as self-employed" "P"
"pl076" "m_pt_self" "Months at part-time work as self-employed" "P"
"pl080" "m_unemp" "Months spent in unemployment" "P"
"pl085" "m_retired" "Months spent in retirement" "P"
"pl086" "m_disabled" "Months spent as disabled or unfit to work" "P"
"pl087" "m_student" "Months spent studying" "P"
"pl088" "m_military" "Months spent in compulsory military service" "P"
"pl089" "m_domestic" "Months spent fulfilling domestic tasks" "P"
"pl090" "m_inactive" "Months spent in other inactivity" "P"
"pl100" "hours_other" "Total hours usually worked in second, third... jobs" "P"
"pl110" "nace" "Economic activity of the local unit (NACE)" "P"
"pl111" "nace2" "Economic activity of the local unit (NACE Rev. 2)" "P"
"pl120" "reason_pt" "Reason for working less than 30 hours" "P"
"pl130" "firm_size" "Number of persons working at the local unit" "P"
"pl140" "contract" "Type of contract" "P"
"pl150" "manager" "Managerial position" "P"
"pl160" "job_change" "Change of job since last year" "P"
"pl170" "job_change_why" "Reason for change of job" "P"
"pl180" "status_change" "Most recent change in the activity status" "P"
"pl190" "age_first_job" "When began first regular job" "P"
"pl200" "years_work" "Number of years spent in paid work" "P"
"ph010" "health" "General health" "P"
"ph020" "chronic" "Suffer from any chronic illness or condition" "P"
"ph030" "limitation" "Limitation in activities because of health problems" "P"
"ph040" "unmet_med" "Unmet need for medical examination or treatment" "P"
"ph050" "unmet_med_why" "Main reason for unmet need for medical examination" "P"
"ph060" "unmet_dent" "Unmet need for dental examination or treatment" "P"
"ph070" "unmet_dent_why" "Main reason for unmet need for dental examination" "P"
"py030g" "empl_ssc_g" "Employer's social insurance contribution (gross)" "P"
"py031g" "empl_ssc_opt_g" "Optional employer's social insurance contributions (gross)" "P"
"py035g" "priv_pens_contr_g" "Contributions to individual private pension plans (gross)" "P"
"py200g" "gross_month_earn" "Gross monthly earnings for employees" "P"
"pd020" "replace_clothes" "Replacing worn-out clothes by some new ones" "P"
"pd030" "two_shoes" "Two pairs of properly fitting shoes" "P"
"pd050" "meet_friends" "Get-together with friends/family for a drink/meal monthly" "P"
"pd060" "leisure" "Regularly participate in a leisure activity" "P"
"pd070" "pocket_money" "Spend a small amount of money each week on yourself" "P"
"pd080" "internet" "Internet connection for personal use at home" "P"
"py010g" "emp_inc_g" "Employee cash or near cash income (gross)" "P"
"py010n" "emp_inc_n" "Employee cash or near cash income (net)" "P"
"py020g" "emp_noncash_g" "Non-cash employee income (gross)" "P"
"py020n" "emp_noncash_n" "Non-cash employee income (net)" "P"
"py021g" "comp_car_g" "Company car (gross)" "P"
"py021n" "comp_car_n" "Company car (net)" "P"
"py050g" "self_emp_inc_g" "Cash benefits or losses from self-employment (gross)" "P"
"py050n" "self_emp_inc_n" "Cash benefits or losses from self-employment (net)" "P"
"py070g" "own_prod_p_g" "Value of goods produced for own consumption (P file) (gross)" "P"
"py070n" "own_prod_p_n" "Value of goods produced for own consumption (P file) (net)" "P"
"py080g" "priv_pens_g" "Pensions received from individual private plans (gross)" "P"
"py080n" "priv_pens_n" "Pensions received from individual private plans (net)" "P"
"py090g" "unemp_ben_g" "Unemployment benefits (gross)" "P"
"py090n" "unemp_ben_n" "Unemployment benefits (net)" "P"
"py100g" "oldage_ben_g" "Old-age benefits (gross)" "P"
"py100n" "oldage_ben_n" "Old-age benefits (net)" "P"
"py110g" "survivor_ben_g" "Survivor's benefits (gross)" "P"
"py110n" "survivor_ben_n" "Survivor's benefits (net)" "P"
"py120g" "sickness_ben_g" "Sickness benefits (gross)" "P"
"py120n" "sickness_ben_n" "Sickness benefits (net)" "P"
"py130g" "disab_ben_g" "Disability benefits (gross)" "P"
"py130n" "disab_ben_n" "Disability benefits (net)" "P"
"py140g" "educ_allow_g" "Education-related allowances (gross)" "P"
"py140n" "educ_allow_n" "Education-related allowances (net)" "P"
"pl210a" "act_old_m01" "Main activity in January (PL210, until 2008)" "P"
"pl211a" "act_m01" "Main activity in January (PL211)" "P"
"pl210b" "act_old_m02" "Main activity in February (PL210, until 2008)" "P"
"pl211b" "act_m02" "Main activity in February (PL211)" "P"
"pl210c" "act_old_m03" "Main activity in March (PL210, until 2008)" "P"
"pl211c" "act_m03" "Main activity in March (PL211)" "P"
"pl210d" "act_old_m04" "Main activity in April (PL210, until 2008)" "P"
"pl211d" "act_m04" "Main activity in April (PL211)" "P"
"pl210e" "act_old_m05" "Main activity in May (PL210, until 2008)" "P"
"pl211e" "act_m05" "Main activity in May (PL211)" "P"
"pl210f" "act_old_m06" "Main activity in June (PL210, until 2008)" "P"
"pl211f" "act_m06" "Main activity in June (PL211)" "P"
"pl210g" "act_old_m07" "Main activity in July (PL210, until 2008)" "P"
"pl211g" "act_m07" "Main activity in July (PL211)" "P"
"pl210h" "act_old_m08" "Main activity in August (PL210, until 2008)" "P"
"pl211h" "act_m08" "Main activity in August (PL211)" "P"
"pl210i" "act_old_m09" "Main activity in September (PL210, until 2008)" "P"
"pl211i" "act_m09" "Main activity in September (PL211)" "P"
"pl210j" "act_old_m10" "Main activity in October (PL210, until 2008)" "P"
"pl211j" "act_m10" "Main activity in October (PL211)" "P"
"pl210k" "act_old_m11" "Main activity in November (PL210, until 2008)" "P"
"pl211k" "act_m11" "Main activity in November (PL211)" "P"
"pl210l" "act_old_m12" "Main activity in December (PL210, until 2008)" "P"
"pl211l" "act_m12" "Main activity in December (PL211)" "P"
end
quietly isid code
tempfile dict
quietly save `dict'

*==============================================================================
* PROGRAMMI - PARTE A
*==============================================================================
* Elimina le chiavi grezze ridondanti (xB010 = year, xB020 = country).
capture program drop nm_dropkeys
program define nm_dropkeys
    foreach k in db010 hb010 rb010 pb010 {
        capture confirm numeric variable `k', exact
        if _rc continue
        quietly count if !missing(`k') & `k' != year
        if r(N) > 0 di as error "`k' diverso da year in `r(N)' righe: conservato"
        else {
            drop `k'
            capture confirm variable `k'_f, exact
            if !_rc drop `k'_f
        }
    }
    foreach k in db020 hb020 rb020 pb020 {
        capture confirm variable `k', exact
        if _rc continue
        drop `k'
        capture confirm variable `k'_f, exact
        if !_rc drop `k'_f
    }
end

* Applica il dizionario ai dati in memoria e registra l'esito di ogni variabile.
capture program drop nm_apply
program define nm_apply
    args dictfile ph dsname
    preserve
    use "`dictfile'", clear
    local nd = _N
    forvalues i = 1/`nd' {
        local c`i' = code[`i']
        local n`i' = name[`i']
        local l`i' = label[`i']
    }
    restore
    forvalues i = 1/`nd' {
        foreach s in base _f _i {
            local sfx = cond("`s'" == "base", "", "`s'")
            local old `c`i''`sfx'
            local new `n`i''`sfx'
            capture confirm variable `old', exact
            if _rc continue
            local olab : variable label `old'
            capture confirm variable `new', exact
            if !_rc {
                post `ph' ("`dsname'") ("`old'") ("`new'") ("collision") (`"`olab'"') ("")
                continue
            }
            rename `old' `new'
            if "`s'" == "base" local lab "`l`i''"
            if "`s'" == "_f" local lab "Flag: `l`i''"
            if "`s'" == "_i" local lab "Imputation factor: `l`i''"
            local cu = upper("`old'")
            local lab = substr("`lab' [`cu']", 1, 80)
            label variable `new' "`lab'"
            post `ph' ("`dsname'") ("`old'") ("`new'") ("renamed") (`"`olab'"') ("`lab'")
        }
    }
    foreach v of varlist _all {
        if ustrregexm("`v'", "^[dhrp][a-z][0-9][0-9][0-9]") {
            local olab : variable label `v'
            post `ph' ("`dsname'") ("`v'") ("`v'") ("not_mapped") (`"`olab'"') (`"`olab'"')
        }
    }
end

*==============================================================================
* PROGRAMMI - PARTE B
*==============================================================================
* Accoda il dataset in memoria a un file di risultati.
capture program drop an_store
program define an_store
    args file
    capture confirm file "`file'"
    if !_rc append using "`file'"
    quietly save "`file'", replace emptyok
end

* Calcoli per una variabile. Frame corrente: year cohort_id _id _w x
* (x = variabile, _w = peso, _id = persona o famiglia), solo righe dell'universo.
capture program drop an_compute
program define an_compute
    syntax , V(string) Type(string) Univ(string) Ds(string) [Lab(string)]
    local deff = $AN_DEFF
    generate byte _val = !missing(x)
    generate double _we = _w if _val & _w > 0 & !missing(_w)
    generate double _w2 = _we^2
    generate byte _one = 1
    tempfile yl ser
    local vlab : value label x

    * --- 1. livello anno: copertura, numerosita' efficace, stime (continue)
    preserve
    if "`type'" == "cont" {
        generate double _wx = _we * x
        generate double _wx2 = _we * x^2
        collapse (sum) n_univ=_one n_valid=_val sw=_we sw2=_w2 swx=_wx swx2=_wx2 ///
                 (mean) mean_u=x (sd) sd_u=x (p50) p50_u=x (max) w_fallback=_wfb, by(year)
        generate double est = swx / sw if sw > 0
        generate double var_w = swx2 / sw - est^2 if sw > 0
        quietly replace var_w = 0 if var_w < 0
        generate double neff = sw^2 / sw2 if sw2 > 0
        generate double se = sqrt(`deff' * var_w / neff) if neff > 0
        drop swx swx2 var_w
    }
    else {
        collapse (sum) n_univ=_one n_valid=_val sw=_we sw2=_w2 (max) w_fallback=_wfb, by(year)
        generate double neff = sw^2 / sw2 if sw2 > 0
    }
    generate double pct_valid = 100 * n_valid / n_univ
    generate str32 variable = "`v'"
    generate str10 dataset = "`ds'"
    quietly save `yl'
    an_store "$AN_RYEAR"
    restore

    * copertura
    preserve
    use `yl', clear
    sort year
    generate double dcov = pct_valid - pct_valid[_n-1] if year == year[_n-1] + 1
    quietly count if abs(dcov) > $AN_COVTHR & !missing(dcov)
    local covbreak = r(N)
    local covyears ""
    local nn = _N
    forvalues i = 1/`nn' {
        if abs(dcov[`i']) > $AN_COVTHR & !missing(dcov[`i']) local covyears `covyears' `=year[`i']'
    }
    quietly summarize year if n_valid > 0
    local y0 = r(min)
    local y1 = r(max)
    quietly count if n_valid > 0
    local nyears = r(N)
    quietly summarize pct_valid if n_valid > 0
    local pctv = r(mean)
    local est_first = .
    local est_last = .
    if "`type'" == "cont" {
        quietly summarize est if year == `y0'
        local est_first = r(mean)
        quietly summarize est if year == `y1'
        local est_last = r(mean)
    }
    restore

    * --- 2. serie da giudicare: media (continue) o quota per categoria
    preserve
    if "`type'" == "cont" {
        use `yl', clear
        keep year est se neff
        generate double cat = .
        generate str40 cat_lab = ""
    }
    else {
        quietly keep if _val
        quietly levelsof x, local(cats)
        collapse (sum) sw_c=_we, by(year x)
        rename x cat
        fillin year cat
        quietly replace sw_c = 0 if _fillin
        drop _fillin
        bysort year: egen double sw_t = total(sw_c)
        generate double est = sw_c / sw_t if sw_t > 0
        quietly merge m:1 year using `yl', keepusing(neff) keep(match master) nogenerate
        generate double se = sqrt(`deff' * max(est, 1/neff) * (1 - est) / neff) if neff > 0
        generate str40 cat_lab = ""
        if "`vlab'" != "" {
            foreach c of local cats {
                local t : label `vlab' `c'
                quietly replace cat_lab = substr(`"`t'"', 1, 40) if cat == `c'
            }
        }
        keep year cat cat_lab est se neff
        * (niente preserve annidato) copia in file temporaneo e accodamento
        quietly save `ser', replace
        generate str32 variable = "`v'"
        generate str10 dataset = "`ds'"
        an_store "$AN_RCAT"
        use `ser', clear
    }
    sort cat year
    by cat: generate double d = est - est[_n-1] if year == year[_n-1] + 1
    if "`type'" == "cont" {
        by cat: generate double sed = sqrt(se^2 + se[_n-1]^2) if !missing(d)
        by cat: generate double rel = d / abs(est[_n-1]) if !missing(d)
    }
    else {
        by cat: generate double pbar = (est + est[_n-1]) / 2 if !missing(d)
        by cat: generate double sed = sqrt(`deff' * max(pbar, 1/neff) * (1 - pbar) * (1/neff + 1/neff[_n-1])) if !missing(d)
        generate double rel = d
    }
    generate double z = d / sed if sed > 0 & !missing(sed)
    * scarto dalla media dei vicini (picchi, rumore)
    by cat: generate double r3 = est - (est[_n-1] + est[_n+1]) / 2 if year == year[_n-1] + 1 & year == year[_n+1] - 1
    by cat: generate double ser3 = sqrt(se^2 + (se[_n-1]^2 + se[_n+1]^2) / 4) if !missing(r3)
    generate double zr = r3 / ser3 if ser3 > 0 & !missing(ser3)
    generate byte known = 0
    generate byte known_near = 0
    foreach k of global AN_KNOWN {
        quietly replace known = 1 if year == `k'
        quietly replace known_near = 1 if year == `k' | year == `k' - 1
    }
    * categorie giudicate
    by cat: egen double mshare = mean(est)
    generate byte judged = 1
    if "`type'" == "cat" quietly replace judged = mshare >= $AN_MINSHARE
    local thr = cond("`type'" == "cont", $AN_RELTHR, $AN_PPTHR)
    generate byte jump = abs(z) > $AN_ZTHR & !missing(z) & abs(rel) > `thr' & judged
    generate byte spike = abs(zr) > $AN_ZTHR & !missing(zr) & judged & !known_near
    * un picco produce due salti (andata e ritorno): non contati come salti di livello
    by cat: generate byte inspike = spike | spike[_n-1] == 1
    generate byte shift = jump & !known & !inspike
    generate byte kjump = jump & known
    * categorie che compaiono o spariscono (codici cambiati)
    by cat: egen double maxsh = max(est)
    generate byte zero_cat = est == 0 & maxsh >= $AN_MINSHARE & "`type'" == "cat"
    quietly count if zero_cat
    local catchg = r(N)
    * rumore: per categoria, poi il massimo
    generate double zr2 = zr^2 if !known_near & judged
    by cat: egen double noise_c = mean(zr2)
    quietly replace noise_c = sqrt(noise_c)
    quietly summarize noise_c
    local noise = r(max)
    local shyears ""
    local spyears ""
    local kjyears ""
    local nn = _N
    forvalues i = 1/`nn' {
        local yy = year[`i']
        if shift[`i'] == 1 {
            local hit : list yy in shyears
            if !`hit' local shyears `shyears' `yy'
        }
        if spike[`i'] == 1 {
            local hit : list yy in spyears
            if !`hit' local spyears `spyears' `yy'
        }
        if kjump[`i'] == 1 {
            local hit : list yy in kjyears
            if !`hit' local kjyears `kjyears' `yy'
        }
    }
    local nshift : word count `shyears'
    local nspike : word count `spyears'
    local ncat = .
    local modal = .
    if "`type'" == "cat" {
        quietly levelsof cat, local(cl)
        local ncat : word count `cl'
        quietly summarize mshare
        local mxs = r(max)
        quietly levelsof cat if mshare == `mxs', local(modal)
        local modal : word 1 of `modal'
        if "`modal'" == "" local modal .
    }
    restore

    * --- 3. eterogeneita' fra coorti nello stesso anno
    local cohshare = .
    preserve
    quietly keep if _val & !missing(_we)
    if _N == 0 local skipcoh 1
    else local skipcoh 0
    if `skipcoh' == 0 & "`type'" == "cont" {
        generate double _wx = _we * x
        generate double _wx2 = _we * x^2
        collapse (sum) sw=_we sw2=_w2 swx=_wx swx2=_wx2, by(year cohort_id)
        generate double m = swx / sw
        generate double vv = max(swx2 / sw - m^2, 0)
        generate double neffg = sw^2 / sw2
        generate double seg = sqrt(`deff' * vv / neffg)
        quietly keep if neffg >= 30 & !missing(neffg) & seg > 0 & !missing(seg)
        if _N == 0 local skipcoh 1
    }
    if `skipcoh' == 0 & "`type'" == "cont" {
        generate double pw = 1 / seg^2
        bysort year: egen double spw = total(pw)
        generate double pwm = pw * m
        bysort year: egen double spm = total(pwm)
        generate double q = pw * (m - spm / spw)^2
        generate byte one = 1
        collapse (sum) Q=q G=one, by(year)
        generate double df = G - 1
    }
    else if `skipcoh' == 0 {
        collapse (sum) sw=_we sw2=_w2, by(year cohort_id x)
        * celle vuote (categoria assente in una coorte) = osservato 0
        fillin year cohort_id x
        quietly replace sw = 0 if _fillin
        quietly replace sw2 = 0 if _fillin
        drop _fillin
        bysort year cohort_id: egen double swg = total(sw)
        bysort year cohort_id: egen double sw2g = total(sw2)
        generate double neffg = swg^2 / sw2g / `deff' if sw2g > 0
        quietly keep if neffg >= 30 & !missing(neffg)
        if _N == 0 local skipcoh 1
    }
    if `skipcoh' == 0 & "`type'" == "cat" {
        generate double O = neffg * sw / swg
        bysort year x: egen double Oc = total(O)
        bysort year: egen double Ot = total(O)
        generate double E = neffg * Oc / Ot
        generate double chi = (O - E)^2 / E if E > 0
        egen byte tg = tag(year cohort_id)
        egen byte tc = tag(year x) if Oc > 0
        collapse (sum) Q=chi G=tg C=tc, by(year)
        generate double df = (G - 1) * (C - 1)
    }
    if `skipcoh' == 0 {
        generate double p = chi2tail(df, Q) if df > 0
        quietly count if df > 0
        local ncoh = r(N)
        quietly count if df > 0 & p < 0.001
        local cohshare = cond(`ncoh' > 0, r(N) / `ncoh', .)
        generate str32 variable = "`v'"
        generate str10 dataset = "`ds'"
        an_store "$AN_RCOH"
    }
    restore

    * --- 4. stabilita' intra-unita' (t vs t-1)
    preserve
    quietly keep if _val
    keep _id year x
    sort _id year
    by _id: generate double lagx = x[_n-1] if year == year[_n-1] + 1
    quietly keep if !missing(lagx)
    local wpidx = .
    local wpyears ""
    if _N > 0 {
        if "`type'" == "cont" {
            generate double xx = x * x
            generate double yy = lagx * lagx
            generate double xy = x * lagx
            generate byte ext = x > 0 & lagx > 0 & (x / lagx > 10 | x / lagx < 0.1)
            collapse (count) n_pairs=x (sum) sx=x sy=lagx sxx=xx syy=yy sxy=xy (mean) ext_share=ext, by(year)
            generate double wp = (n_pairs * sxy - sx * sy) / sqrt((n_pairs * sxx - sx^2) * (n_pairs * syy - sy^2))
            drop sx sy sxx syy sxy
            local wpthr 0.25
        }
        else {
            generate byte chg = x != lagx
            collapse (count) n_pairs=x (mean) wp=chg, by(year)
            generate double ext_share = .
            local wpthr 0.15
        }
        quietly keep if n_pairs >= 100
        if _N > 0 {
            quietly summarize wp, detail
            local wpidx = r(p50)
            local nn = _N
            forvalues i = 1/`nn' {
                if abs(wp[`i'] - `wpidx') > `wpthr' & !missing(wp[`i']) local wpyears `wpyears' `=year[`i']'
            }
            generate str32 variable = "`v'"
            generate str10 dataset = "`ds'"
            generate str4 measure = cond("`type'" == "cont", "corr", "chg")
            an_store "$AN_RWP"
        }
    }
    restore

    * --- 5. attributi fissi: valori diversi nel tempo per la stessa persona
    local fixinc = .
    local fixl $AN_FIXED
    local isfix : list v in fixl
    if `isfix' {
        preserve
        quietly keep if _val
        bysort _id (x): generate byte _d = x[1] != x[_N]
        bysort _id: keep if _n == 1
        quietly summarize _d
        local fixinc = r(mean)
        restore
    }

    * --- 6. giudizio
    local reasons ""
    local sev 0
    if `nshift' > 0 {
        local reasons "`reasons'salti di livello: `shyears'; "
        local sev = max(`sev', cond(`nshift' >= 2, 2, 1))
    }
    if `nspike' > 0 {
        local reasons "`reasons'picchi isolati: `spyears'; "
        local sev = max(`sev', cond(`nspike' >= 2, 2, 1))
    }
    if `nshift' + `nspike' >= 2 local sev 2
    if `noise' > 2 & !missing(`noise') {
        local reasons "`reasons'rumore oltre il campionamento (`: display %4.1f `noise''); "
        local sev = max(`sev', cond(`noise' > 3, 2, 1))
    }
    if `cohshare' > 0.25 & !missing(`cohshare') {
        local reasons "`reasons'coorti diverse nello stesso anno (`: display %3.0f 100*`cohshare''% anni); "
        local sev = max(`sev', cond(`cohshare' > 0.5, 2, 1))
    }
    if `covbreak' > 0 {
        local reasons "`reasons'copertura discontinua: `covyears'; "
        local sev = max(`sev', 2)
    }
    if `catchg' > 0 {
        local reasons "`reasons'categorie che compaiono/spariscono; "
        local sev = max(`sev', 1)
    }
    if "`wpyears'" != "" {
        local reasons "`reasons'stabilita' intra-unita' anomala: `wpyears'; "
        local sev = max(`sev', 1)
    }
    if `fixinc' > 0.01 & !missing(`fixinc') {
        local reasons "`reasons'attributo fisso non costante (`: display %4.1f 100*`fixinc''% persone); "
        local sev = max(`sev', 1)
    }
    local verdict = cond(`sev' == 0, "affidabile", cond(`sev' == 1, "da verificare", "instabile"))
    post $AN_PH ("`ds'") ("`v'") (substr(`"`lab'"', 1, 80)) ("`univ'") ("`type'") ///
        (`y0') (`y1') (`nyears') (`pctv') (`est_first') (`est_last') (`ncat') (`modal') ///
        (`nshift') ("`shyears'") (`nspike') ("`spyears'") ("`kjyears'") (`noise') ///
        (`cohshare') (`wpidx') ("`wpyears'") (`covbreak') (`catchg') (`fixinc') ///
        ("`verdict'") (substr("`reasons'", 1, 244))
end

* Analisi di tutte le variabili di contenuto di un dataset.
capture program drop an_dataset
program define an_dataset
    syntax , File(string) Ds(string) Unit(string) Wr(string) [Wp(string) WRf(string) WPf(string)]
    use "`file'", clear
    local excl "person_num person_uid pid_s country country_orig year cohort_id cohort_status hh_uid hh_num hid_s release_year udb_version src_file src_release src_version sel_reason rg_s n_rel multi_hh multi_cohort multi_cohort_year p_cohort p_amb rel_other_cohort in_P hh_linked entry_db076 selected pers_base_wgt pers_base_wgt_p pers_wgt_cs pers_wgt_cs_p pers_wgt_sel pers_dwgt_sel pers_base_wgt_sel hh_wgt hh_wgt_src hh_wgt_cs hh_wgt_lg lw2 lw3 lw4 lw5 lw6 strata psu ssu psu_order rot_group int_wave int_year int_year_p int_month int_month_p int_minutes int_minutes_p exch_rate"
    confirm numeric variable `wr', exact
    if "`wp'" == "" local wp `wr'
    capture confirm numeric variable `wp', exact
    if _rc {
        local wp `wr'
        local wpf `wrf'
    }
    * pesi di riserva, usati solo negli anni senza alcun peso principale positivo
    * (RB060/PB050 non esistono nelle release 2004-2005)
    foreach f in wrf wpf {
        if "``f''" != "" {
            capture confirm numeric variable ``f'', exact
            if _rc local `f' ""
        }
    }
    local hasP 0
    capture confirm variable in_P, exact
    if !_rc local hasP 1
    local cand ""
    foreach v of varlist _all {
        capture confirm numeric variable `v', exact
        if _rc continue
        local isx : list v in excl
        if `isx' continue
        if ustrregexm("`v'", "(_f|_i)$") | ustrregexm("`v'", "_id(_|$)") | ustrregexm("`v'", "^(nwin|wval)_") continue
        local cand `cand' `v'
    }
    local nv : word count `cand'
    di as text _n "`ds': `nv' variabili da analizzare (peso `wr'; universo P: `wp')"
    local i 0
    foreach v of local cand {
        local ++i
        local lab : variable label `v'
        quietly count if !missing(`v')
        if r(N) == 0 {
            post $AN_PH ("`ds'") ("`v'") (substr(`"`lab'"', 1, 80)) ("") ("") (.) (.) (0) (0) (.) (.) (.) (.) ///
                (.) ("") (.) ("") ("") (.) (.) (.) ("") (.) (.) (.) ("vuota") ("nessun valore valido")
            continue
        }
        local univ = cond("`ds'" == "households", "H", "R")
        if `hasP' {
            quietly count if !missing(`v') & in_P == 0
            if r(N) == 0 local univ "P"
        }
        local w = cond("`univ'" == "P", "`wp'", "`wr'")
        local wf = cond("`univ'" == "P", "`wpf'", "`wrf'")
        local type "cont"
        quietly count if !missing(`v') & `v' != floor(`v')
        if r(N) == 0 {
            capture quietly tabulate `v'
            if _rc == 0 {
                if r(r) >= 2 & r(r) <= $AN_MAXCAT local type "cat"
            }
        }
        local keepv year cohort_id `unit' `w' `v'
        if "`wf'" != "" local keepv `keepv' `wf'
        if "`univ'" == "P" local keepv `keepv' in_P
        local keepv : list uniq keepv
        capture frame drop fv
        frame put `keepv', into(fv)
        frame fv {
            rename `v' x
            rename `w' _w
            rename `unit' _id
            if "`univ'" == "P" quietly keep if in_P == 1
            generate byte _wfb = 0
            if "`wf'" != "" {
                bysort year: egen long _wpos = total(_w > 0 & !missing(_w))
                quietly replace _wfb = 1 if _wpos == 0
                quietly replace _w = `wf' if _wpos == 0
                drop _wpos
            }
            an_compute, v(`v') type(`type') univ(`univ') ds(`ds') lab(`"`lab'"')
        }
        frame drop fv
        if mod(`i', 25) == 0 di as text "  ... `i'/`nv'"
    }
end

* Esporta un file di risultati accumulati, se esiste.
capture program drop an_export
program define an_export
    args file csv
    capture confirm file "`file'"
    if _rc exit
    use "`file'", clear
    order dataset variable
    sort dataset variable year
    export delimited using "`csv'", replace
end

*==============================================================================
* PARTE A - DATASET CON NOMI ED ETICHETTE
*==============================================================================
if `"$NM_RUN"' == "" {
    tempname fh
    file open `fh' using "$NM_OUTROOT/LATEST_CERTIFIED.txt", read text
    file read `fh' line
    file close `fh'
    global NM_RUN = strtrim(`"`line'"')
}
confirm file "$NM_RUN/CERTIFIED.txt"
if `"$NM_OUTDIR"' == "" global NM_OUTDIR "$NM_OUTROOT/LONG_NAMED"
if `"$AN_OUTDIR"' == "" global AN_OUTDIR "$NM_OUTROOT/LONG_ANALYSIS"
foreach d in "$NM_OUTDIR" "$AN_OUTDIR" "$AN_OUTDIR/graphs" {
    mata: st_local("ex", strofreal(direxists(st_local("d"))))
    if "`ex'" == "0" mkdir "`d'"
}
log using "$AN_OUTDIR/eusilc_long_analysis.log", text replace name(nmlog)
di as text "Run certificata: $NM_RUN"

tempname ph
tempfile dictout
postfile `ph' str10 dataset str32 source str32 target str12 status str244 orig_label str244 new_label using `dictout', replace

* --- persone
use "$NM_RUN/panel_person_year.dta", clear
nm_dropkeys
nm_apply "`dict'" `ph' persons
forvalues k = 2/6 {
    capture confirm variable nwin_rb06`k', exact
    if !_rc rename nwin_rb06`k' nwin_lw`k'
    capture confirm variable wval_rb06`k', exact
    if !_rc rename wval_rb06`k' wval_lw`k'
}
label variable person_num "Person: persistent numeric ID (panel)"
label variable person_uid "Person: harmonised ID country|cohort|RB030"
label variable hh_uid "Household: harmonised ID country|cohort|DB030 (empty if several households)"
label variable cohort_id "Rotation cohort (harmonised)"
label variable release_year "Longitudinal release the record comes from"
quietly isid person_num year
xtset person_num year
char _dta[nm_source] "$NM_RUN"
label data "EU-SILC longitudinal - persons (named)"
compress
save "$NM_OUTDIR/EUSILC_long_persons.dta", replace

* --- famiglie: masterH + variabili D
use "$NM_RUN/masterH.dta", clear
quietly describe using "$NM_RUN/masterD.dta", varlist
local dvl `r(varlist)'
local dkeep src_release
foreach v of local dvl {
    if ustrregexm("`v'", "^db[0-9]") & !inlist("`v'", "db010", "db020", "db030", "db010_f", "db020_f", "db030_f") local dkeep `dkeep' `v'
}
merge 1:1 year hh_uid using "$NM_RUN/masterD.dta", keepusing(`dkeep') keep(master match)
quietly count if _merge != 3
if r(N) > 0 {
    di as error "`r(N)' famiglie H senza record in masterD"
    exit 459
}
drop _merge
nm_dropkeys
nm_apply "`dict'" `ph' households
generate double hh_wgt = .
generate str5 hh_wgt_src = ""
capture confirm variable hh_wgt_lg, exact
if !_rc {
    quietly replace hh_wgt_src = "DB095" if !missing(hh_wgt_lg)
    quietly replace hh_wgt = hh_wgt_lg if !missing(hh_wgt_lg)
}
capture confirm variable hh_wgt_cs, exact
if !_rc {
    quietly replace hh_wgt_src = "DB090" if missing(hh_wgt) & !missing(hh_wgt_cs)
    quietly replace hh_wgt = hh_wgt_cs if missing(hh_wgt) & !missing(hh_wgt_cs)
}
label variable hh_wgt "Household weight (DB095 from L-2014 releases, DB090 up to L-2013)"
label variable hh_wgt_src "Source variable of hh_wgt"
label variable hh_uid "Household: harmonised ID country|cohort|DB030"
quietly isid year hh_uid
char _dta[nm_source] "$NM_RUN"
label data "EU-SILC longitudinal - households (named)"
compress
save "$NM_OUTDIR/EUSILC_long_households.dta", replace

* --- persone + famiglie (persona-anno)
use "$NM_OUTDIR/EUSILC_long_persons.dta", clear
quietly describe using "$NM_OUTDIR/EUSILC_long_households.dta", varlist
local hvl `r(varlist)'
unab pvl : _all
local hadd : list hvl - pvl
merge m:1 year hh_uid using "$NM_OUTDIR/EUSILC_long_households.dta", keepusing(`hadd') keep(master match)
generate byte hh_linked = _merge == 3
drop _merge
label variable hh_linked "Household variables attached (single responding household in the year)"
quietly isid person_num year
xtset person_num year
label data "EU-SILC longitudinal - persons with household variables (named)"
save "$NM_OUTDIR/EUSILC_long_persons_hh.dta", replace

postclose `ph'
use `dictout', clear
export delimited using "$NM_OUTDIR/variable_dictionary.csv", replace
quietly count if status == "not_mapped"
di as text "Dizionario: " _N " righe; non mappate: " r(N) " (codice e etichetta originali)"
quietly count if status == "collision"
if r(N) > 0 di as error "Collisioni di nome: `r(N)' (vedi variable_dictionary.csv)"

*==============================================================================
* PARTE B - ANALISI DI AFFIDABILITA' NEL TEMPO
*==============================================================================
if $AN_RUN == 1 {
    tempfile ryear rcat rcoh rwp summ
    global AN_RYEAR "`ryear'"
    global AN_RCAT "`rcat'"
    global AN_RCOH "`rcoh'"
    global AN_RWP "`rwp'"
    tempname aph
    global AN_PH "`aph'"
    postfile `aph' str10 dataset str32 variable str80 label str1 universe str4 type ///
        int(first_year last_year n_years) double(pct_valid est_first est_last) int(n_cat) double(modal_cat) ///
        int(n_shift) str100 shift_years int(n_spike) str100 spike_years str60 known_break_jumps ///
        double(noise cohort_het_share wp_index) str100 wp_anomaly_years int(cov_break cat_change) ///
        double(fixed_inconsistency) str14 verdict str244 reasons using `summ', replace

    an_dataset, file("$NM_OUTDIR/EUSILC_long_persons.dta") ds(persons) unit(person_num) ///
        wr(pers_base_wgt) wp(pers_base_wgt_p) wrf(pers_wgt_cs) wpf(pers_wgt_cs_p)
    an_dataset, file("$NM_OUTDIR/EUSILC_long_households.dta") ds(households) unit(hh_num) wr(hh_wgt)
    postclose `aph'

    an_export "$AN_RYEAR" "$AN_OUTDIR/desc_by_year.csv"
    an_export "$AN_RCAT" "$AN_OUTDIR/cat_shares_by_year.csv"
    an_export "$AN_RCOH" "$AN_OUTDIR/cohort_heterogeneity.csv"
    an_export "$AN_RWP" "$AN_OUTDIR/within_person.csv"

    use `summ', clear
    generate byte severity = cond(verdict == "instabile", 3, cond(verdict == "da verificare", 2, cond(verdict == "affidabile", 1, 0)))
    gsort -severity dataset variable
    label variable noise "RMS of standardised deviations from neighbours' mean (1 = sampling noise only)"
    label variable cohort_het_share "Share of years with cohorts significantly different (p<0.001)"
    label variable wp_index "Within-unit index: median corr(t,t-1) or median share changing category"
    quietly save "$AN_OUTDIR/stability_summary.dta", replace
    export delimited using "$AN_OUTDIR/stability_summary.csv", replace
    di as text _n "{hline 70}"
    di as text "Giudizio per dataset:"
    tabulate dataset verdict
    di as text _n "Variabili instabili:"
    list dataset variable label reasons if verdict == "instabile", noobs abbreviate(12) sepby(dataset)

    * --- grafici delle variabili non affidabili
    if $AN_GRAPHS == 1 {
        quietly keep if inlist(verdict, "instabile", "da verificare")
        if _N > $AN_MAXGRAPHS quietly keep in 1/$AN_MAXGRAPHS
        local ng = _N
        forvalues g = 1/`ng' {
            local gds = dataset[`g']
            local gv = variable[`g']
            local gt = type[`g']
            local glab = label[`g']
            local grs = reasons[`g']
            local gvd = verdict[`g']
            preserve
            if "`gt'" == "cont" {
                use if dataset == "`gds'" & variable == "`gv'" using "$AN_RYEAR", clear
                sort year
                generate double lo = est - 1.96 * se
                generate double hi = est + 1.96 * se
                capture noisily twoway (rcap lo hi year, lcolor(gs10)) (connected est year, msymbol(O)), ///
                    xline($AN_KNOWN, lpattern(dash) lcolor(cranberry)) legend(off) ///
                    title(`"`glab'"', size(medsmall)) subtitle("`gds': `gv' - `gvd'", size(small)) ///
                    ytitle("Media pesata (IC 95%)") xtitle("") note(`"`grs'"', size(vsmall))
            }
            else {
                use if dataset == "`gds'" & variable == "`gv'" using "$AN_RCAT", clear
                bysort cat: egen double msh = mean(est)
                quietly keep if msh >= $AN_MINSHARE & !missing(msh)
                sort cat year
                local nk 0
                local prev = .
                local no = _N
                forvalues o = 1/`no' {
                    if cat[`o'] != `prev' {
                        local ++nk
                        local prev = cat[`o']
                        local c`nk' = cat[`o']
                        local l`nk' = cat_lab[`o']
                    }
                }
                forvalues j = 1/`nk' {
                    quietly generate double sh_`j' = est if cat == `c`j''
                }
                if `nk' > 0 {
                    collapse (max) sh_*, by(year)
                    forvalues j = 1/`nk' {
                        label variable sh_`j' `"`c`j'' `l`j''"'
                    }
                }
                local shv ""
                forvalues j = 1/`nk' {
                    local shv `shv' sh_`j'
                }
                if `nk' > 0 capture noisily twoway connected `shv' year, xline($AN_KNOWN, lpattern(dash) lcolor(cranberry)) ///
                    title(`"`glab'"', size(medsmall)) subtitle("`gds': `gv' - `gvd'", size(small)) ///
                    ytitle("Quota pesata") xtitle("") legend(size(vsmall) cols(3)) note(`"`grs'"', size(vsmall))
            }
            if _N > 0 capture noisily graph export "$AN_OUTDIR/graphs/`gds'_`gv'.png", replace width(1400)
            capture graph drop _all
            restore
        }
    }

    tempname rf
    file open `rf' using "$AN_OUTDIR/README_analysis.txt", write replace text
    file write `rf' "Analisi di affidabilita' nel tempo - eusilc_long_analysis.do" _n
    file write `rf' "Run: $NM_RUN" _n
    file write `rf' "Soglie: |z|>$AN_ZTHR; var. relativa>$AN_RELTHR (continue); var. quota>$AN_PPTHR (categoriali);" _n
    file write `rf' "        copertura>$AN_COVTHR punti; DEFF=$AN_DEFF; rotture note: $AN_KNOWN" _n
    file write `rf' "Pesi: persone RB060 (universo R) o PB050 (universo P); famiglie DB095/DB090." _n
    file write `rf' "      Anni senza RB060/PB050 (2004-2005): RB050/PB040, colonna w_fallback=1 in desc_by_year." _n
    file write `rf' "Giudizio: affidabile = nessun segnale; da verificare = un segnale lieve;" _n
    file write `rf' "          instabile = >=2 salti/picchi, rumore>3, coorti diverse in >50% anni, copertura discontinua." _n
    file write `rf' "Colonne di stability_summary: n_shift/shift_years salti di livello non spiegati;" _n
    file write `rf' "  n_spike/spike_years picchi isolati; known_break_jumps salti negli anni di rottura nota;" _n
    file write `rf' "  noise rumore (1 = solo campionamento); cohort_het_share quota anni con coorti diverse;" _n
    file write `rf' "  wp_index stabilita' intra-unita' mediana; wp_anomaly_years anni anomali;" _n
    file write `rf' "  fixed_inconsistency quota persone con attributo fisso variabile." _n
    file write `rf' "Avvertenza: SE approssimati (Kish x DEFF), non design-based; utili per confronti relativi." _n
    file close `rf'
}
di as result "FATTO. Dataset: $NM_OUTDIR  -  Analisi: $AN_OUTDIR"
log close nmlog
