# mergepool_long.do — panel cumulato EU-SILC longitudinale (post-2020)

Un solo do-file Stata (≥ 16.0, nessun pacchetto esterno) che parte dai `.dta` già
convertiti ed etichettati (setup GESIS/MISSY) e costruisce un **panel cumulato di
panel brevi**. Estende la logica di `eusilcpanel_2020` (Borst & Wirth 2022) senza
riprodurne le costanti fisse. **Stato: bozza non ancora eseguita in Stata.**
Nell'ambiente di sviluppo non c'erano né Stata né i microdati, quindi nessun test è stato eseguito.

## 1. Decisioni metodologiche

| Problema | Scelta |
|---|---|
| Identità della coorte | Un nodo è un gruppo DB075 dentro una release. Due nodi di release diverse si collegano se condividono famiglie-anno `(year, DB030)`, con quota ≥ `ML_OVERLAP_MIN` **in entrambe le direzioni** e denominatori calcolati sugli anni osservati in entrambi. Una sovrapposizione parziale (≥ `ML_OVERLAP_WEAK`) o uno-a-molti rende il nodo ambiguo. La coorte è la componente connessa; il mapping manuale (`ML_COHORTMAP`) prevale. Niente `minyear+3`, niente durata fissa, niente `max−min+1`. |
| DB076 (interview wave, dal 2021) | Usato solo come **verifica** (anno d'ingresso = year − DB076 + 1): la sua semantica non è verificata sulla fonte primaria. |
| ID | Stringhe esplicite con separatore: `hh_uid = country\|cohort_id\|DB030`, `person_uid = country\|cohort_id\|RB030`. Vengono controllati i float oltre 2^24, i valori non interi e gli zeri iniziali. Gli ID numerici (`hh_num`, `person_num`) e i `cohort_id` si appoggiano a mappe persistenti in `ML_IDMAPDIR`, aggiornate solo dopo una run certificata. |
| Selezione | Registro `(country, year, cohort_id)` con `isid` e `merge m:1`. Le release vanno dalla più recente alla più vecchia, senza lookahead fisso. Ogni cella ha una sola fonte, e non si recuperano record da release vecchie dentro celle già coperte (vengono solo contati in `cell_record_diff`). Le celle *attese ma assenti* in una release più recente vengono escluse (`strict`) oppure recuperate e segnalate (`permissive`). |
| D→H/R/P | Il collegamento avviene entro la stessa release/versione, con cardinalità verificata e con i non-abbinati conteggiati per tipo (`link_stats`). Le relazioni persona-famiglia multiple si conservano (`person_household_year`). Il panel persona-anno assegna una famiglia solo se `n_rel == 1`. |
| Pesi | Tutti conservati. `ML_WEIGHTMODE=legacy` aggiunge `*_legacy` etichettati come shrinkage (identità Σ = Σ_g W_g²/W verificata numericamente). RB06k si propaga solo nella sua finestra; con più finestre non c'è eleggibilità (`why_rb06k`). Nessun `svyset` e nessun raking. |
| Integrità | `isid`/`assert` con diagnostica salvata prima dello stop. Nessun `force`. Ogni run scrive in una cartella propria con `CERTIFIED.txt` o `NOT_CERTIFIED.txt`; `LATEST_CERTIFIED.txt` punta all'ultima run valida. |

### Regole della vecchia implementazione: cosa resta e cosa cambia
- **Resta**: la priorità alla release più recente, l'unità "cella", `yrelease` (qui `src_release`), la ricodifica GR→EL (disattivabile) e le formule di riscalatura, ma solo in `legacy`.
- **Cambia**: `drpout_year`/`urtgrp` sono sostituiti dalla tabella di corrispondenza. L'anti-join `m:m` con tre lookahead lascia il posto al registro `m:1` completo. La soglia 0,5 su `rdups` e il filtro `lgstgrp` sono eliminati (la regola "cella attesa ma assente" li sostituisce in modo esplicito). Al posto di `substr(uhid,1,7)` ci sono componenti esplicite, e `duplicates drop ..., force` diventa la tabella delle relazioni.
- Non è una replica esatta di `eusilcpanel_2020`: `ML_LEGACYDIR` produce il confronto (`compare_legacy_*`).

### Correzioni alla nota HOPPER
1. **§3.6 `merge m:m`**: Stata non assegna `_merge==1` alle righe eccedenti. Dentro una chiave presente in entrambi i file le accoppia in sequenza e, quando il gruppo più corto finisce, **ne ripete l'ultima osservazione**, per cui tutte le righe risultano `_merge==3`. Nell'esempio 1.800 vs 1.500 nessuna delle 300 righe sopravvive al `keep if _merge==1`. `m:m` va comunque sostituito, ma per un'altra ragione: la cardinalità e la provenienza restano implicite e le variabili del using vengono replicate in modo arbitrario.
2. **§3.4 `merge 1:1`**: controlla l'unicità *dentro* ciascun file, ma accetta chiavi condivise fra master e using (le abbina e tiene i valori del master). Non dimostra quindi che due contributi di release siano disgiunti: con `drop _merge` una sovrapposizione verrebbe fusa in silenzio. Qui si usano un registro disgiunto per costruzione, poi `append` e `isid`.
3. Durata osservata ≠ durata prevista (`obs_span`, `obs_nyears`, `duration_expected` sono separati). `w/G` somma a `W/G`, che è la popolazione solo se ogni coorte è calibrata sulla stessa popolazione.

## 2. Fonti e regole: verificate / non verificate

Dall'ambiente di sviluppo i siti Eurostat, ISTAT e GESIS erano **bloccati**. Ho potuto leggere solo gli estratti dei motori di ricerca, non i documenti.

| Regola | Stato | Fonte |
|---|---|---|
| IT: dal 2021 sei gruppi di rotazione, ciascuno per sei anni (prima 4) | estratto, da confermare | ISTAT, scheda EU-SILC / microdati longitudinali |
| Quali coorti italiane (ingressi 2018–2020?) sono state prolungate | **NON verificato** → `ML_DESIGNFILE` / `ML_COHORTMAP` | ISTAT quality report, GESIS MISSY |
| Anni pubblicati per coorte nell'UDB L-2021+ (4 o fino a 6) | **NON verificato**: il codice lo misura | Eurostat Doc65 User Guide 2021 |
| RB062…RB066 = pesi longitudinali di durata 2…6 anni | estratto | DocSILC065, operation 2021 |
| Anno di riferimento della finestra RB06k (`ML_LWIN_ANCHOR`) | **NON verificato** | DocSILC065 |
| DB076 "Interview wave", nuova dal 2021 | estratto; semantica **NON verificata** | GESIS MISSY 2021, DocSILC065 |
| La release UDB e l'anno longitudinale sono diversi (es. "2023 release 2" = longitudinale fino al 2021) | estratto | Eurostat, *EU-SILC microdata with DOIs* |
| Stabilità di DB030/RB030 fra release per l'Italia | **NON verificato**: lo misura `cohort_links` | — |

## 3. Uso
1. Blocco 0 del do-file: imposta `ML_INDIR`, `ML_WORKDIR`, `ML_OUTDIR` (con `/`), `ML_COUNTRIES "IT"` e `ML_RELEASES`. Se hai più versioni della stessa release, aggiungi `global ML_UDBVER_2021 "2023-09"`.
   Configurazione attuale: `ML_INDIR "/Volumes/ext_blu/EUSILC/DATA/LONG"` e `ML_FNAME_INCLUDE "^long_"`. La release si legge dall'anno finale del nome (`long_hh_d_2021.dta`), il tipo D/H/R/P dalle variabili. I file AppleDouble `._*` vengono ignorati.
2. Se i nomi dei file non contengono `L-2021`, `l21D`, `..._2021.dta` o simili, usa un CSV `ML_FILEMAP`:
   ```
   path,release_year,udb_version,ftype
   C:/dati/L2021/it_D.dta,2021,2023-09,D
   ```
3. `ML_MODE "demo"` → `do mergepool_long.do`. Deve terminare con `DEMO SUPERATA`.
4. `ML_MODE "inspect"` → apri `OUTDIR/inspect_*/INSPECT_README.txt`.
5. Mapping opzionali:
   - `ML_COHORTMAP`: `country,release_year,rg,cohort_label,note`
   - `ML_DESIGNFILE`: `country,entry_from,entry_to,duration,source,status`
6. `ML_MODE "build"` → controlla `CERTIFIED.txt` / `NOT_CERTIFIED.txt`, `certification_failures.txt` e `warnings.txt`.

**Output principali**: `masterD` (famiglia-anno), `masterH` (famiglia rispondente-anno), `masterR` (relazione persona-famiglia-anno), `masterP` (persona-anno 16+), `panel_person_year` (`xtset person_num year`).

**Diagnostiche**: `inventory`, `cohort_groups`, `cohort_links`, `cohort_id_map`, `cell_registry`, `cell_decisions`, `cell_record_diff`, `country_release_presence`, `link_stats`, `person_household_year`, `panel_varying_vars`, `weights_diag`, `long_weight_windows`, `diag_*`. Sono tutte in `.dta` e `.csv`.

## 4. Stato per l'Italia e altri paesi
- **Implementato**: l'intera pipeline per un paese qualsiasi, controllata dai dati. Nulla è specifico dell'Italia, a parte la configurazione.
- **Per certificare l'Italia servono** gli output di `inspect` (`inspect_groups`, `cohort_links`, `cohort_groups`, `inspect_files`) e la conferma documentale delle coorti prolungate da inserire in `ML_DESIGNFILE`.
- **Altri paesi**: vanno aggiunti a `ML_COUNTRIES` uno per volta, rilanciando `inspect`. FR/BE/BG (coorti lunghe), ES/FI/PT (riuso di DB030), LU/NO/IS (disegni misti) e SE/IE/HR/SK (release mancanti o anomale) richiedono di leggere `cohort_links` e probabilmente un `ML_COHORTMAP`. Nessuna esclusione storica è ereditata in automatico.

## 5. Italia: risultati dell'inspect (L-2019…L-2024, 2 ottobre 2026)

- **Identità delle coorti risolta dai dati.** I 37 collegamenti fra release sono tutti "strong", con quota ≥ 0,99996 in entrambe le direzioni; non ci sono ambiguità né conflitti. DB030 è stabile fra release.
- **DB076 (dal 2021).** L'anno d'ingresso `year − DB076 + 1` coincide per ogni coorte con il primo anno osservato. La semantica di DB076 resta verificata solo sui dati, non sul documento Eurostat.
- **Disegno.** Le coorti con ingresso 2016–2019 sono osservate per **6 anni**: quella del 2016 va dal 2016 al 2021 ed è quindi presente già nell'operazione 2020 come quinta onda. I valori di DB075 vengono riusati: rg4 nel 2016 e nel 2022, rg1 nel 2017 e nel 2023. Le coppie restano separate perché i loro anni non si sovrappongono.
- **Finestre pubblicate.** Fino a L-2020 sono di 4 anni (la coorte 2016 in L-2020 copre solo 2017–2020); da L-2021 sono di 6 anni. Una coorte non compare nella release del suo anno d'ingresso. La release più recente contiene quindi la storia completa di ogni coorte, e la selezione delle celle prende ogni coorte da una sola release.
- **Copertura.** Con le release 2019–2024 gli anni 2016–2018 hanno solo le coorti entrate dal 2016 in poi. Per coprirli con le coorti 2013–2015 bisogna aggiungere L-2016…L-2018 (o tutte le release dal 2005) a `ML_RELEASES`, dopo un nuovo inspect.
- **Pesi.** `RB060` somma a circa G × popolazione (calibrazione per coorte), con un'eccezione da verificare nell'ultimo anno di L-2023 e L-2024 (≈ 5,9 × pop con 5 coorti). **RB062–RB066 compaiono solo nell'anno finale di ogni release e sommano a ≈ popolazione**: sono pesi della release, calibrati sull'insieme delle coorti che coprono la finestra, non coorte per coorte. Conseguenze:
  - i pesi longitudinali si leggono da tutte le righe R di ogni release (non solo dalle celle selezionate) e vanno in `long_weight_windows.dta` (persona × peso × release, con la completezza della finestra nel panel);
  - nel panel `nwin_rb06k` conta le finestre che coprono la persona-anno, e `wval_rb06k` è valorizzato solo se la finestra è unica;
  - la riscalatura `legacy` di RB064 (W_g/W) non ha giustificazione per pesi già calibrati sull'insieme delle coorti: va tenuta solo come confronto storico.
  - `PB080` è sempre mancante; la `legacy` lo salta con un avviso. Il peso personale disponibile è `PB050`.
- **Regole di disegno documentate** in `config/design_IT.csv`. Si attivano con `ML_DESIGNFILE` e servono solo alla diagnostica (`DESIGN_DURATION_MISMATCH`).
- **Prima onda senza D (L-2023, L-2024).** In queste release i file H, R e P contengono anche la prima onda della coorte entrante, cioè l'anno finale della release, mentre D non la contiene. Esempio: L-2023 ha 10.458 famiglie H, 21.605 righe R e 18.546 record P senza D. Queste righe sono escluse perché non hanno DB075 e quindi una coorte. Non si perde nulla: la stessa coorte compare con il suo D nella release successiva (l'anno 2023 della coorte 2023 viene da L-2024). Il codice lo verifica: avviso `*_FIRSTWAVE_*` se tutte le righe sono dell'anno finale della release, con il numero di quelle ritrovate nel D della release successiva; errore altrimenti. La stessa causa spiega la somma di RB060 ≈ 5,9 × popolazione nell'ultimo anno di L-2023 e L-2024: nell'R ci sono 6 coorti, nel D 5. La coorte entrata nel 2024 non è nel panel finché non esce L-2025.
- **Pesi longitudinali e relazioni multiple.** Se una persona ha più relazioni familiari nello stesso anno e un solo valore non mancante di RB06k, si usa quello. Se i valori sono due e diversi, il peso è posto a missing (avviso `LWEIGHT_CONFLICT_*` con diagnostica).

