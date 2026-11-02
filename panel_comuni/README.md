# Panel comuni italiani – indicatori elementari di sostenibilità (v3)

Pipeline R che costruisce un panel **comune ISTAT × anno** da fonti ufficiali, con
dizionario degli indicatori, analisi di completezza, controlli di qualità e test automatici.
Non costruisce l'indicatore composito: prepara la base empirica.

> **Stato della verifica.** Lo script e i test sono stati eseguiti in un container senza
> accesso a `istat.it`, `isprambiente.it`, `gse.it`, `aci.it`. I domini erano bloccati sia dal
> container sia dal fetch esterno. Per questo:
> - **nessun endpoint è stato verificato** e **nessun dato reale è stato scaricato**;
> - il panel CSV/RDS, le mappe e le tabelle reali **si ottengono solo eseguendo lo script** su una macchina con internet;
> - i test (11 blocchi, 94 asserzioni, tutti superati) girano su **fixture sintetiche**. Le fixture
>   riproducono i sintomi segnalati (25 intestazioni e 26 campi, `;` finale, righe `Vedi aggregazione`,
>   codici a 8 cifre, CP1252). Non sono la struttura reale verificata.
>
> Al primo run reale controlla `output_v3/diagnostica/` (vedi sotto, "Primo run: cosa controllare").

## Esecuzione

```r
setwd("panel_comuni")
source("build_panel_comuni_v3.R")      # esegue tutta la pipeline -> output_v3/
```
oppure
```bash
Rscript build_panel_comuni_v3.R
```
Requisiti: R ≥ 4.2, internet, librerie di sistema per `sf` (GDAL, GEOS, PROJ). I pacchetti mancanti
vengono installati da CRAN in automatico. Opzioni nel blocco `CONFIG` in testa allo script:
`years`, `waste_years`, `do_*` (attiva/disattiva le fonti), `redownload`, `n_min_comuni`,
`max_anomalie_pct`, `cov_soglia`, `soil_field_map`.

I file originali sono in `raw/` e vengono riusati se superano la validazione. Con `CONFIG$redownload <- TRUE` si scaricano di nuovo.

Test:
```bash
cd panel_comuni
```
```bash
Rscript tests/run_tests.R
```
Solo funzioni, senza eseguire la pipeline: `options(panel.run = FALSE); source("build_panel_comuni_v3.R")`.

## Fonti

| Fonte | Endpoint nello script | Geografia | Anni teorici | Stato |
|---|---|---|---|---|
| ISTAT A misura di Comune | `istat.it/storage/misura-comune/*.xlsx` (11 file) | armonizzata 31/12/2024 | per tavola (vedi dizionario); anni extra trovati nel file aggiunti | da v2, non verificato qui |
| ISTAT confini generalizzati | `Limiti01012025_g.zip` | 31/12/2024 | – | da v2, non verificato qui |
| ISTAT variazioni amministrative | `Variazioni-amministrative-e-territoriali-dal-1991.zip` | – | – | **URL da verificare**; se fallisce: avviso, esistenza dei comuni "non determinabile" |
| ISPRA consumo di suolo | ArcGIS `Statistiche_consumo_suolo_2025/FeatureServer/1` | confini recenti | 2006, 2012, 2015–2024 | da v2; semantica dei campi letta dagli **alias** |
| ISPRA Catasto rifiuti | `get/getDettaglioComunale.csv.php?aa=ANNO` | **anno corrente** (non armonizzata) | 2010–2024 | endpoint attestato dal log v2 per il 2024; 2010–2023 da verificare con il run |

Fonti aggiuntive (GSE, IdroGEO, EUAP/Natura 2000, ACI Autoritratto): **non integrate**. La richiesta
era di integrare solo dopo aver verificato endpoint, formato, granularità comunale e annualità, e
qui non è stato possibile. Sono elencate in `output_v3/fonti_candidate_da_verificare.csv` con le note di
metodo. Ad esempio, IdroGEO esce per edizioni e non va replicato sugli anni. Le fonti solo
capoluoghi o solo province sono escluse esplicitamente. `diagnostica/catalogo_tavole_istat.csv` elenca
tutte le tavole dei file ISTAT scaricati, con anni e copertura comunale: serve a scegliere altri
indicatori da aggiungere a `SPEC_ISTAT`.

## Errori della v2 corretti

1. **Link rifiuti "non trovato" (2010–2023).** La v2 cercava i link nell'HTML, ma i link sono generati via JS. Ora si usa l'endpoint parametrico `?aa=ANNO`, con controllo dello status HTTP, del contenuto (no HTML) e della dimensione. Se due anni restituiscono un file identico (MD5), l'anno viene rifiutato: vuol dire che l'endpoint ignora `aa`.
2. **"Campo codice comunale ambiguo".** La regex della v2 non riconosceva l'intestazione `Istat` (0 match, ma il messaggio diceva "ambiguo"). Ora il codice si identifica da **intestazione + contenuto** (≥90% di valori a 6–8 cifre, quasi unici). Se i candidati sono 0 o più di 1, l'errore elenca le intestazioni. Nessuna scelta arbitraria.
3. **"25 nomi / 26 colonne", "Stopped early on line 1186".** Il `;` finale aggiungeva un campo vuoto e le righe `Vedi aggregazione` hanno meno campi: `fread` si fermava e **le righe successive andavano perse in silenzio**. Ora c'è un parser proprio: decodifica UTF-8/CP1252 con BOM, split che rispetta le virgolette, ricompone i record spezzati su più righe e classifica ogni record (`completa`, `rinvio_aggregazione`, `aggregazione`, `anomala`). Nessun record viene perso: gli anomali finiscono in diagnostica e oltre il `max_anomalie_pct` l'anno viene rifiutato.
4. **Aggregazioni.** I comuni con "Vedi aggregazione" hanno le misure a NA e lo stato `in_aggregazione`. Il dato aggregato è conservato in `ispra_rifiuti_aggregazioni_sovracomunali.csv` insieme alla lista dei membri e **non viene mai attribuito** ai comuni.
5. **Codici a 7 cifre** (zero iniziale perso per le regioni 01–09) diventavano NA e venivano scartati in silenzio. Ora vengono recuperati. Il prefisso regionale viene confrontato con il nome della regione.
6. **Misure rifiuti.** `pro.?capite|kg.?ab` catturava sia RD sia RU pro capite: risultava ambiguo e diventava NA senza log. Ora ogni misura ha regex di inclusione ed esclusione. L'esito (OK/NON_PRESENTE/AMBIGUA) viene registrato per anno. Le unità sono dichiarate dalle intestazioni e verificate con il controllo RU_t·1000/pop ≈ RU pro capite.
7. **Numeri.** Il formato decimale viene deciso per colonna o file, non per singolo valore. `-`, `n.d.` e simili diventano NA, mai 0. I valori non numerici vengono contati.
8. **ISTAT: perdita di precisione.** `as.matrix` su un data frame misto arrotondava a 7 cifre significative. Ora la lettura avviene come testo. La riga degli anni si cerca solo sopra i dati. Le intestazioni con celle unite vengono riempite a destra e il "Totale" per sesso deve essere univoco. Le righe titolo non vengono propagate.
9. **ArcGIS suolo.** Gli attributi `NULL` facevano fallire `as_tibble`. La paginazione si fermava se `maxRecordCount` era < 1000. Ora si usano `returnCountOnly` + `exceededTransferLimit` e un controllo finale sul totale. La semantica `csuolo1`/`csuolo8` era **assunta**: ora si deduce dagli alias, oppure si imposta `CONFIG$soil_field_map`. Gli incrementi 2006→2012 e 2012→2015 sono pluriennali e venivano presentati come annuali: ora sono esclusi dalla serie annuale e registrati nel log.
10. **Province e regioni assenti.** `DEN_REG`/`DEN_UTS` non stanno nello shapefile dei comuni. Ora vengono uniti da `ProvCM*` e `Reg*`.
11. **Codici fuori geografia 2024** venivano persi dal `left_join` senza traccia. Ora finiscono in `diagnostica/*fuori_geografia*.csv`, con l'informazione su soppressione e confluenza se le variazioni sono disponibili.
12. **Denominatore.** Nella v2 una fonte fallita usciva dal denominatore e la completezza risultava gonfiata. Ora ci sono tre livelli distinti (vedi sotto).
13. **Heatmap.** `reorder(indicatore, dimensione)` su un carattere non è valido. Corretto.

## Stati delle celle e denominatori

Ogni cella (comune, anno, indicatore) ha uno stato (`stato_celle_long.rds`):

| Stato | Significato |
|---|---|
| `ANNO_NON_RILEVATO` | anno fuori dalle annualità della fonte |
| `FONTE_NON_ACQUISITA` | anno teorico, ma download, parsing o colonna non riusciti |
| `COMUNE_NON_ESISTENTE` | comune istituito dopo l'anno (solo fonti `anno_corrente`) |
| `DATO_AGGREGATO` | valore disponibile solo a livello di aggregazione sovracomunale |
| `ASSENTE_IN_FONTE` | fonte acquisita, comune assente nel file |
| `MANCANTE` | comune presente nella fonte, valore mancante |
| `OSSERVATO` | valore presente |

- `completezza_teorica` = osservati / indicatori **teorici**. Le fonti fallite contano come mancanti. È la misura usata nelle mappe.
- `completezza_acquisita` = osservati / indicatori **acquisiti**.
- `quota_acquisita` = acquisiti / teorici.
- Le celle `COMUNE_NON_ESISTENTE` sono escluse da tutti i denominatori.

## Output (`output_v3/`)

| File | Contenuto |
|---|---|
| `panel_comuni.csv` / `.rds` | panel wide: codice (stringa a 6 cifre), comune, provincia, sigla, regione, anno, indicatori, `rifiuti_stato`, `rifiuti_aggregazione`, `rifiuti_codice_fonte`, `rifiuti_ricodificato`, `comune_esistente` |
| `panel_comuni_2023.csv`, `_2024.csv` | sezioni trasversali |
| `dizionario_indicatori.csv` | definizione, unità, polarità, dimensione, fonte, URL, geografia, anni teorici/acquisiti/con dati, titolo della tavola letto dal file |
| `completezza_indicatore_anno.csv` | A. % comuni con dato per indicatore × anno |
| `completezza_comune_anno.csv` | B. completezza per comune × anno (teorica, acquisita, ambientale) |
| `completezza_comune_anno_dimensione.csv`, `completezza_dimensione_anno.csv` | C. per dimensione |
| `mappa_completezza_{totale,ambientale}_{2023,2024}.png`, `completezza_{2023,2024}.gpkg` | D. mappe |
| `heatmap_copertura_indicatore_anno.png`, `serie_copertura_*.png`, `finestre_temporali.{png,csv}` | E. analisi temporale; le finestre mostrano gli intervalli di anni in cui il maggior numero di indicatori ha copertura ≥ `cov_soglia` |
| `comuni_geometrie_2024.gpkg`, `contiguita_comuni.{csv,rds}` | geometrie, contiguità queen e rook |
| `controlli_qualita.csv` | esito di tutti i controlli (OK/WARN/FAIL) |
| `pipeline_log.txt`, `errori_pipeline.csv`, `download_log.csv` | log: URL, status HTTP, byte, MD5, cache |
| `manifest_fonti.csv`, `fonti_candidate_da_verificare.csv` | inventario delle fonti |
| `diagnostica/` | intestazioni ISPRA, mappa delle colonne, righe anomale, codici fuori geografia, nomi incoerenti, colonne ISTAT scelte, campi suolo con alias, catalogo tavole ISTAT, verifica endpoint, copertura per regione |

Lettura del CSV mantenendo i codici come stringhe:
```r
readr::read_csv("output_v3/panel_comuni.csv", col_types = readr::cols(codice_istat = "c", .default = "?"))
```

## Controlli di qualità automatici

Lo script verifica automaticamente:
- unicità comune × anno e formato del codice a 6 cifre;
- universo ≥ `n_min_comuni`;
- percentuali in [0,100] e scala 0–1 sospetta;
- non negatività di t, ha, kg e €;
- anni con dati fuori dalle annualità teoriche;
- copertura nazionale per indicatore e anno (< 50% dei comuni: possibile dato solo capoluoghi), regioni senza dati;
- nessun valore attribuito ai membri delle aggregazioni e nessun valore su comuni non esistenti;
- coerenza RD% ISTAT/ISPRA;
- unità RU (t vs kg/ab);
- suolo in ha / area vs % ISTAT;
- codici fuori dalla geografia 2024 e nomi incoerenti per codice e anno;
- record anomali e duplicati ISPRA.

Nessuna imputazione e nessun NA sostituito con 0.

## Geografie storiche

- Le tavole ISTAT AMdC e il servizio suolo usano confini recenti: vengono unite direttamente.
- ISPRA rifiuti usa i confini dell'anno. Le ricodifiche **1:1** (tipo `AP`, cambio di provincia senza variazioni territoriali) vengono applicate e marcate. Fusioni e soppressioni **non** vengono ricostruite: le osservazioni dei comuni soppressi restano in diagnostica. I comuni nati da fusione risultano `COMUNE_NON_ESISTENTE` negli anni precedenti, se il file delle variazioni è leggibile.
- Prima di confrontare nel tempo le serie ISPRA rifiuti a livello di comune, controlla `rifiuti_ricodificato`, `istituito_nell_anno` e i file `*fuori_geografia*`.

## Primo run: cosa controllare

1. `diagnostica/verifica_endpoint.csv`: status di tutti gli URL.
2. `diagnostica/ispra_rifiuti_struttura_file.csv` e `ispra_rifiuti_mappa_colonne.csv`: una riga per anno, con encoding, numero di campi, colonna codice, esito di ogni misura. Se una misura è `NON_PRESENTE` o `AMBIGUA`, guarda `ispra_rifiuti_intestazioni.csv` e adatta `WASTE_MEAS`.
3. `diagnostica/ispra_suolo_campi.csv`: se gli alias non bastano, imposta `CONFIG$soil_field_map`.
4. `diagnostica/variazioni_tipi.csv`: i codici `CS`, `ES` e `AP` devono essere presenti, altrimenti l'esistenza dei comuni resta NA.
5. `diagnostica/istat_colonne_scelte.csv` e la colonna `titolo_tavola_fonte` del dizionario: conferma le unità segnate "vedi titolo tavola".
6. `controlli_qualita.csv`: righe FAIL e WARN.
