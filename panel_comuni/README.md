# Panel comuni italiani – indicatori elementari di sostenibilità (v3)

Pipeline R che costruisce un panel **comune ISTAT × anno** (7.896 comuni, geografia al 31/12/2024)
da fonti ufficiali. Produce anche dizionario degli indicatori, analisi di completezza, controlli
di qualità, mappe e test automatici. Non costruisce l'indicatore composito: prepara la base empirica.

## Stato della verifica (run reale del 02/11/2026)

- Lo script è stato eseguito per intero con accesso a internet: exit 0, **32/32 indicatori acquisiti, 0 errori**.
- Tutti gli endpoint sono stati verificati: download diretto, struttura dei file, granularità comunale e anni.
- Test: `Rscript tests/run_tests.R` → 12 blocchi, tutti superati. Le fixture riproducono la struttura reale
  dei CSV ISPRA osservata nel run.
- Controlli incrociati tra fonti superati:
  - RD% ISTAT e RD% ISPRA: correlazione 1,000, differenza mediana 0,002 punti, n = 83.477;
  - suolo ISPRA (ha / superficie) contro % ISTAT: correlazione 0,999.

## Esecuzione

```r
setwd("panel_comuni")
source("build_panel_comuni_v3.R")      # -> output_v3/   (~9 min con cache, ~100 MB di download al primo run)
```
oppure
```bash
Rscript build_panel_comuni_v3.R
```

Requisiti:
- R ≥ 4.2, internet, librerie di sistema per `sf` (GDAL, GEOS, PROJ);
- i pacchetti mancanti vengono installati da CRAN in automatico;
- su Linux conviene usare un locale UTF-8 (`LC_ALL=C.UTF-8`).

Opzioni nel blocco `CONFIG`:
- `years`, `waste_years`: anni da coprire;
- `do_*`: attiva o disattiva le singole fonti;
- `redownload`: `TRUE` ignora la cache `raw/`;
- `offline`: `TRUE` usa solo `raw/`, senza download;
- `n_min_comuni`, `max_anomalie_pct`, `cov_soglia`, `soil_field_map`: soglie e mappatura campi.

I file originali sono in `raw/` e vengono riusati se superano la validazione.

Test (dalla cartella `panel_comuni`):
```bash
Rscript tests/run_tests.R
```

## Fonti verificate

| Fonte | Endpoint | Struttura verificata | Geografia | Anni |
|---|---|---|---|---|
| ISTAT A misura di Comune | `istat.it/storage/misura-comune/*.xlsx` (11 file, 22 tavole) | foglio `Tav. X.Y`, titolo, riga anni, codice comune; titoli in `dizionario_indicatori.csv` | armonizzata 31/12/2024 | 2014–2024 (variano per tavola) |
| ISTAT confini generalizzati | `Limiti01012025_g.zip` | shapefile Com/ProvCM/Reg, `PRO_COM_T` | 31/12/2024 | – |
| ISTAT variazioni amministrative | `Variazioni-amministrative-e-territoriali-dal-1991.zip` | tipi CS 319, ES 332, AP 271, CD, AQ, CE… | – | 1991– |
| ISPRA consumo di suolo | ArcGIS `Statistiche_consumo_suolo_2025/FeatureServer/1` (7.896 righe, max 2000 per pagina) | vedi sotto | confini recenti | 2006, 2012, 2015–2024 |
| ISPRA Catasto rifiuti | `get/getDettaglioComunale.csv.php?aa=ANNO` | vedi sotto | **anno corrente** | 2010–2024 (15 file, MD5 tutti distinti) |

**ISPRA rifiuti, struttura reale.** È la stessa nei 15 anni:
- **File:** ASCII con CRLF; una riga titolo con tabulazioni; 25 intestazioni (`IstatComune;Regione;Provincia;Comune;Popolazione;Dato riferito a;…;Totale RD (t);Ingombranti a smaltimento (t);Indifferenziato (t);Totale RU (t);Percentuale RD (%)`).
- **Righe dati:** iniziano con tabulazioni e finiscono con `;`, quindi hanno 26 campi. Le righe `Vedi aggregazione` hanno 21 campi (`-`). In fondo c'è una nota (`Note: (1)…`).
- **Codici:** 8 cifre (2 di regione + 6 di PRO_COM).
- **Numeri:** formato italiano, percentuale scritta `64,79%`. Il pro capite **non è pubblicato**.
- **Colonna `Dato riferito a`:**
  - `Comune`: dato comunale;
  - `Aggregazione: X`: il comune è **capofila** e la riga contiene il **totale dell'aggregazione**. Esempio: ANTEY-SAINT-ANDRE', 553 abitanti, 17.969 t;
  - `Vedi aggregazione: X`: comune membro, senza valori.

**ISPRA suolo, semantica dei campi.** Gli alias ArcGIS non sono informativi (`CSUOLO1_06`…). La semantica
è stata verificata sui valori e **viene ricontrollata numericamente a ogni run**
(`diagnostica/ispra_suolo_verifica_semantica.csv`):
- `csuolo1_YY` = ettari consumati;
- `csuolo4_24` = % consumata, solo per il 2024 (coerente con ha/area nel 99,99% dei comuni);
- `csuolo8_YY` = variazione netta in ha, pari a `csuolo1_YY − csuolo1_precedente` (coerenza 100%):
  - 2012 e 2015 sono **pluriennali** (2006→12, 2012→15) e restano esclusi;
  - il 2024 si calcola sul 2023 **rivisto** (`csuolo1__1`), che è escluso dalla serie stock.
- Nel servizio 166 comuni della provincia di Trento hanno `pro_com_t` vuoto: lo script usa `pro_com` e lo registra nel log.

**Fonti aggiuntive** (GSE, IdroGEO, EUAP/Natura 2000, ACI Autoritratto): non ancora integrate, vanno
verificate una per una. Sono elencate in `fonti_candidate_da_verificare.csv`. `diagnostica/catalogo_tavole_istat.csv`
elenca **tutte** le tavole dei file ISTAT scaricati, con anni e copertura comunale: serve a scegliere altri
indicatori da aggiungere a `SPEC_ISTAT`.

## Errori della v2 corretti

1. **Link ISPRA "non trovato" (2010–2023).** I link della pagina sono generati via JS. Ora si usa l'endpoint parametrico, con controllo di status HTTP, contenuto e dimensione, e confronto MD5 tra anni.
2. **"Campo codice ambiguo".** La regex della v2 non riconosceva `IstatComune`. Ora il codice si identifica da intestazione + contenuto, mai con una scelta arbitraria.
3. **"25 nomi / 26 colonne", stop a riga 1186.** `fread` si fermava alla prima riga `Vedi aggregazione` e **perdeva in silenzio** le righe successive. Ora c'è un parser proprio:
   - ogni record è classificato: `completa`, `capofila_aggregazione`, `rinvio_aggregazione`, `nota`, `anomala`;
   - nel run reale: 0 record anomali in 15 anni.
4. **Capofila di aggregazione.** Il totale dell'aggregazione sarebbe finito sul solo comune capofila. Ora va in `ispra_rifiuti_aggregazioni_sovracomunali.csv`, con il numero di membri e la loro popolazione. Il capofila e i membri restano a NA, con `rifiuti_stato` impostato. In totale ci sono 4.904 osservazioni comune-anno in aggregazione.
5. **Codici a 7 cifre** (zero iniziale perso): prima andavano persi in silenzio, ora vengono recuperati.
6. **Misure rifiuti.** Le regex della v2 erano ambigue. Ora ogni misura ha un esito per anno (`ispra_rifiuti_mappa_colonne.csv`). Il pro capite è `DERIVATO` (t × 1000 / popolazione ISPRA) e il dizionario lo dichiara.
7. **ISTAT: perdita di precisione.** `as.matrix` arrotondava a 7 cifre significative. Ora la lettura è come testo, le intestazioni con celle unite vengono gestite e il "Totale" per sesso deve essere univoco.
8. **ArcGIS:** attributi NULL, paginazione, semantica dei campi assunta, incrementi pluriennali presentati come annuali, `pro_com_t` vuoto (vedi sopra).
9. **Province e regioni assenti:** ora vengono unite da `ProvCM` e `Reg`.
10. **Codici fuori geografia 2024** persi dal `left_join`: ora sono in diagnostica (3.374 osservazioni ISPRA 2010–2024, quasi tutte comuni poi fusi).
11. **Denominatore della completezza.** Nella v2 una fonte fallita usciva dal denominatore. Ora ci sono tre livelli distinti (vedi sotto).
12. **Heatmap:** `reorder` su un carattere non è valido. Corretto.
13. **v3 iniziale:** `validate_file` applicava `tolower()` a byte binari (`invalid multibyte string` in locale UTF-8). Corretto, con test di regressione.

## Stati delle celle e denominatori

Ogni cella (comune, anno, indicatore) ha uno stato (`stato_celle_long.rds`):

| Stato | Significato |
|---|---|
| `ANNO_NON_RILEVATO` | anno fuori dalle annualità della fonte |
| `FONTE_NON_ACQUISITA` | anno teorico, ma download, parsing o colonna non riusciti |
| `COMUNE_NON_ESISTENTE` | comune istituito dopo l'anno (solo fonti `anno_corrente`, dalle variazioni ISTAT) |
| `DATO_AGGREGATO` | valore disponibile solo a livello di aggregazione sovracomunale |
| `ASSENTE_IN_FONTE` | fonte acquisita, comune assente nel file |
| `MANCANTE` | comune presente, valore mancante |
| `OSSERVATO` | valore presente |

- `completezza_teorica` = osservati / indicatori teorici. Le fonti fallite contano come mancanti. È la misura usata nelle mappe.
- `completezza_acquisita` = osservati / indicatori acquisiti.
- `quota_acquisita` = acquisiti / teorici.
- Le celle `COMUNE_NON_ESISTENTE` sono escluse da tutti i denominatori.

## Risultati principali del run reale

| Anno | Indicatori teorici | Completezza media |
|---|---|---|
| 2006 | 1 | 100% |
| 2010–2011 | 6 | 95–96% |
| 2012–2013 | 6–7 | 83–85% |
| 2014–2017 | 22–25 | 89–92% |
| 2018–2023 | 27–30 | 92–95% |
| 2024 | 20 | 93% |

- La finestra con più indicatori è il **2018–2023**.
- **2012–2013, rifiuti:** la copertura scende (82–84%) perché molte più gestioni sono riportate come aggregazioni (circa 1.100 comuni in `Vedi aggregazione` contro circa 150 negli altri anni).
- **Turismo:** arrivi, presenze e densità turistica sono disponibili per il 40–62% dei comuni. ISTAT pubblica il dato solo dove ci sono esercizi ricettivi o dove il segreto statistico lo consente. È segnalato in QC; prima di usarli nell'indicatore composito va deciso come trattarli.
- **Incidentalità:** è presente per circa il 78% dei comuni. Il dato mancante non viene imputato.
- **`auto_pre_euro4_pct`:** 4 valori oltre 100% nel 2015 (file ISTAT). Sono conservati e segnalati in `diagnostica/qc_valori_fuori_intervallo.csv`.

## Output (`output_v3/`)

| File | Contenuto |
|---|---|
| `panel_comuni.csv` / `.rds` | panel wide: codice (stringa a 6 cifre), comune, provincia, sigla, regione, anno, indicatori, `rifiuti_stato`, `rifiuti_aggregazione`, `rifiuti_codice_fonte`, `rifiuti_ricodificato`, `comune_esistente`, `istituito_nell_anno` |
| `panel_comuni_2023.csv`, `_2024.csv` | sezioni trasversali |
| `dizionario_indicatori.csv` | definizione, unità, polarità, dimensione, fonte, URL, geografia, anni teorici/acquisiti/con dati, titolo della tavola letto dal file |
| `completezza_indicatore_anno.csv` | A. % comuni con dato per indicatore × anno |
| `completezza_comune_anno.csv` | B. completezza per comune × anno (teorica, acquisita, ambientale) |
| `completezza_comune_anno_dimensione.csv`, `completezza_dimensione_anno.csv`, `completezza_anno.csv` | C. per dimensione e per anno |
| `mappa_completezza_{totale,ambientale}_{2023,2024}.png`, `completezza_{2023,2024}.gpkg` | D. mappe |
| `heatmap_copertura_indicatore_anno.png`, `serie_copertura_*.png`, `finestre_temporali.{png,csv}` | E. analisi temporale |
| `comuni_geometrie_2024.gpkg`, `contiguita_comuni.{csv,rds}` | geometrie, contiguità queen e rook |
| `ispra_rifiuti_aggregazioni_sovracomunali.csv`, `ispra_rifiuti_membri_aggregazioni.csv` | aggregazioni ISPRA (non attribuite ai comuni) |
| `controlli_qualita.csv`, `pipeline_log.txt`, `errori_pipeline.csv`, `download_log.csv` | QC e log (URL, status HTTP, byte, MD5, cache) |
| `diagnostica/` | struttura dei file ISPRA, mappa delle colonne, record segnalati, codici fuori geografia, nomi incoerenti, verifica semantica suolo, colonne ISTAT scelte, catalogo tavole ISTAT, verifica endpoint, copertura per regione |

Nel repository `panel_comuni.csv` è compresso (`.csv.gz`). I GeoPackage di completezza non sono inclusi: si rigenerano con lo script.

Lettura del CSV mantenendo i codici come stringhe:
```r
readr::read_csv("output_v3/panel_comuni.csv.gz", col_types = readr::cols(codice_istat = "c", .default = "?"))
```

## Geografie storiche

- ISTAT AMdC e servizio suolo usano confini recenti: unione diretta.
- ISPRA rifiuti usa i confini dell'anno:
  - le ricodifiche **1:1** (tipo `AP`) vengono applicate e marcate;
  - fusioni e soppressioni **non** vengono ricostruite: le osservazioni dei comuni soppressi restano in `diagnostica/ispra_rifiuti_codici_fuori_geografia_2024.csv`, con la data di soppressione e il codice confluito;
  - i comuni nati da fusione risultano `COMUNE_NON_ESISTENTE` negli anni precedenti;
  - esempio: Sovizzo, soppresso il 22/01/2024, compare ancora nel file ISPRA 2024 e non viene attribuito.
- `diagnostica/ispra_rifiuti_nomi_incoerenti.csv` (~170 per anno) contiene quasi solo cambi di denominazione (es. LONATO → Lonato del Garda).
