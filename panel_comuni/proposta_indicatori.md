# Proposta di indicatori per l'indice composito di sostenibilità comunale

Questa è una base per la discussione, non una scelta definitiva. È costruita sui risultati di
`analisi_descrittiva_2016.R` (cartella `analisi_2016/`), con panel aggiornato al 03/11/2026: 7.896 comuni, geografia al 31/12/2024.

## 1. Finestra temporale

| Finestra | Indicatori pieni (≥ 90% comuni) | Comuni con panel bilanciato su quegli indicatori |
|---|---|---|
| 2016–2023 | 28 | 7.399 (93,7%) |
| **2018–2023** | **30** | **7.538 (95,5%)** |
| 2021–2023 | 32 | 7.656 (97,0%) |
| 2016–2024 | 21 | 7.410 (93,8%) |

- **Proposta: 2018–2023 come finestra principale.** Dal 2018 entra l'istruzione (titoli di studio).
- **2024:** mancano ancora reddito, imprese, motorizzazione e istruzione (ISTAT non li ha rilasciati). Si può usare solo per il pilastro ambientale o come aggiornamento successivo.
- **Lavoro** (occupazione, disoccupazione): solo 2019 e 2021–2023, il 2020 manca nella fonte. O si accetta un buco, o si usa la media 2021–2023.
- **FTTH:** solo 2022–2024. Va bene per un indice trasversale (es. 2023), non per un panel lungo.

## 2. Criteri usati

1. **Rilevanza e polarità chiara** rispetto alla sostenibilità (SDG / BES).
2. **Copertura** ≥ 95% dei comuni nella finestra.
3. **Niente indicatori di scala** (tonnellate, ettari, abitanti in valore assoluto): correlano 0,86–0,98 con la popolazione e misurano la dimensione del comune, non la sostenibilità.
4. **Ridondanza**: |ρ Spearman| < 0,85 tra indicatori dello stesso pilastro.
5. **Robustezza**: asimmetria, outlier e rumore nei piccoli comuni.
6. **Struttura spaziale** (I di Moran): non è un criterio di esclusione, ma informa il disegno dell'indice spaziale.

## 3. Set proposto (13 indicatori + 1 trasversale)

| Pilastro | Indicatore | Pol. | Fonte | Moran I 2022 | Note |
|---|---|---|---|---|---|
| Ambientale | `rd_pct_ispra` | + | ISPRA | 0,54 | identico a `rd_pct_istat` (ρ = 1,00): tenerne uno |
| Ambientale | `ru_procapite_kg` | − | ISPRA (derivato) | 0,45 | t × 1000 / popolazione ISPRA |
| Ambientale | `suolo_consumato_pct_istat` | − | ISTAT / ISPRA | 0,77 | ρ = 0,93 con densità unità locali: è il gradiente urbano |
| Ambientale | `variazione_suolo_ha_km2` | − | ISPRA (derivato) | 0,16 | molto rumoroso anno su anno (ρ 2016→2024 = 0,33): usare la **media triennale** |
| Ambientale | `auto_pre_euro4_pct` | − | ISTAT / ACI | 0,84 | ρ = 0,80 con redditi bassi: rischio di contare due volte il gradiente economico |
| Ambientale | `auto_motorizzazione` | − | ISTAT / ACI | 0,19 | **outlier da noleggi**: Aosta 660, Scandicci 497, Trento 423, Bolzano 223 auto/100 ab. (mediana 70); 37 comuni > 100. Winsorizzare o escludere |
| Economico | `redditi_bassi_pct` | − | ISTAT / MEF | 0,84 | ρ = −0,89 con reddito medio: tenerne **uno** (proposta: redditi bassi, perché coglie la vulnerabilità) |
| Economico | `tasso_occupazione` | + | ISTAT | 0,80 | 2019, 2021–23; ρ = −0,79 con disoccupazione: tenerne uno |
| Economico | `tasso_imprenditorialita` | + | ISTAT | 0,39 | |
| Sociale | `titolo_terziario_pct` | + | ISTAT | 0,41 | dal 2018 |
| Sociale | `titolo_secondario_pct` | + | ISTAT | 0,56 | ρ = 0,66 con terziario: accettabile |
| Sociale | `indice_dipendenza` | − | ISTAT | 0,46 | sostenibilità demografica |
| Sociale | `incidentalita` | − | ISTAT | 0,15 | 21% di zeri; rumore forte sotto i 500 abitanti (70% zeri, sd 4,3 contro 1,3): **media triennale** o smoothing |
| Infrastrutture (trasversale) | `ftth_pct` | + | ISTAT / AGCOM | 0,26 | bimodale (44% zeri), solo 2022–24 |

**Copertura del set:**
- i 12 indicatori senza occupazione e FTTH, 2018–2023: **7.542 comuni (95,5%)** con dati completi;
- con l'occupazione (2019 e 2021–23): 7.602;
- con occupazione e FTTH, 2023: 7.688 (97,4%).

Le perdite sono quasi tutte comuni che nei rifiuti ISPRA sono dentro un'aggregazione sovracomunale (339 su 2018–23): Valle d'Aosta, Sicilia centrale e aree interne del Centro-Sud.

### Indicatori da tenere fuori dall'indice (come contesto o controlli)

- **Scala:** `popolazione`, `ru_totale_t`, `rd_totale_t`, `indifferenziato_t`, `suolo_consumato_ha`, `variazione_netta_suolo_ha` (Moran ≤ 0,21).
- **Duplicati:** `rd_pct_istat` (uguale a ISPRA), `reddito_imponibile_medio` o `redditi_bassi_pct` (uno dei due), `tasso_disoccupazione` o `tasso_occupazione` (uno dei due).
- **Polarità ambigua:**
  - `densita_unita_locali`: misura l'urbanizzazione;
  - `moto_motorizzazione`: le moto possono sostituire l'auto; il suo Moran (0,64) segue clima e costa;
  - turismo (`turismo_arrivi`, `turismo_presenze`, `densita_turistica`, `densita_posti_letto`): è pressione ambientale ma anche reddito. Proposta: un **sotto-indice di pressione turistica** da usare in analisi di sensibilità, non nel nucleo.
- **Anni insufficienti:** `suolo_consumato_pct_ispra` (solo 2024; c'è già il dato ISTAT 2015–2024), `indice_vecchiaia` (contesto, ρ 0,73 con dipendenza).

## 4. Punti aperti

1. **Equilibrio tra pilastri.** Il pilastro ambientale è il più ricco, ma due suoi indicatori su sei (Euro 4, suolo) seguono gradienti economici o urbani. Conviene pesare per pilastro, non per indicatore, e verificare con PCA o correlazioni dentro i pilastri.
2. **Mancano indicatori ambientali e sociali.** Priorità per l'integrazione, da verificare una per una come per le fonti già acquisite:
   - **rischio idrogeologico** (ISPRA IdroGEO: % popolazione e superficie a pericolosità frana o alluvione, per comune; per edizioni, non annuale);
   - **rinnovabili** (GSE Atlaimpianti: kW di fotovoltaico per abitante);
   - **aree protette e Natura 2000** (% di superficie, da overlay GIS);
   - **servizi alla prima infanzia** (ISTAT, comunale);
   - **acqua** (ISTAT Censimento acque per uso civile, perdite di rete; da verificare se comunale e annuale).

   La qualità dell'aria non è disponibile a livello comunale per tutti i comuni.
3. **Piccoli comuni.** Il 25% dei comuni ha meno di 1.000 abitanti (2.012) e lì i tassi sono instabili. Opzioni: medie triennali, smoothing empirical Bayes, oppure smoothing spaziale, che è coerente con l'idea dell'indice spaziale.
4. **Aggregazioni rifiuti.** Nella base dati il dato non viene attribuito ai membri. Per l'indice si può costruire una variante dichiarata in cui i membri ricevono la percentuale e il pro capite dell'aggregazione (stesse condizioni di gestione), e usarla solo come analisi di sensibilità.
5. **Normalizzazione.** Diversi indicatori sono molto asimmetrici (motorizzazione 23, incidentalità 12, variazione suolo 10). Proposta: winsorizzazione all'1°–99° percentile, poi min-max o z-score, con log dove serve. Tutto da testare in sensibilità.
6. **Dimensione spaziale.** Gli indicatori socioeconomici hanno un'autocorrelazione molto forte (I = 0,73–0,84), quelli ambientali "gestionali" (rifiuti, suolo, incidentalità) più debole (0,15–0,54). Il contesto spaziale cambia quindi soprattutto il pilastro economico: punto utile per l'articolo, perché l'indice tradizionale e quello spaziale dovrebbero divergere dove la componente locale è forte.

## 5. Dove guardare

- `analisi_2016/heatmap_copertura_2016.png`, `finestre_bilanciate.csv`: copertura e finestre.
- `analisi_2016/mappe_completezza/<indicatore>.png`: stato del dato per comune e anno (osservato, mancante, aggregato, assente, comune non esistente).
- `analisi_2016/mappa_completezza_periodo_*.png`, `mappa_completezza_per_anno.png`: completezza complessiva.
- `analisi_2016/mappe_valori/`: decili dell'ultimo anno disponibile.
- `analisi_2016/correlazioni_spearman_2022.png`, `coppie_ridondanti_2022.csv`: ridondanze.
- `analisi_2016/moran_I_2022.png`, `moran_I.csv`: struttura spaziale.
- `analisi_2016/scheda_indicatori.csv`: tutte le metriche per indicatore in una tabella.

## 6. Correzioni ai dati emerse da questa analisi (già applicate e rigenerate)

- **Popolazione ISTAT:** il lettore prendeva la colonna **maschi** (anno in cella unita sopra MASCHI | FEMMINE | TOTALE). Esempio: Aosta 15.629 invece di 33.096. Ora il totale è corretto: Italia 2024 = 58,94 milioni.
- **Segno ISTAT "." = "il fenomeno non esiste":** veniva letto come mancante. Ora vale 0 per incidentalità e turismo, che sono tassi su popolazione o superficie. Per questo il turismo passa dal 40% al 100% di copertura (56% di zeri) e l'incidentalità dal 78% al 100% (21% di zeri). Restano mancanti 168 "." su altri indicatori, soprattutto FTTH (119), da decidere.
- **Variazioni ISTAT:** venivano perse le ricodifiche AP (colonna sbagliata e righe senza data). Ora 1.125 osservazioni ISPRA 2010–2023 sono ricodificate, tra cui i comuni sardi nel 2016.
