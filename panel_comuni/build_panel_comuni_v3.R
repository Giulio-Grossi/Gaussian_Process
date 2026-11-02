#!/usr/bin/env Rscript
# =============================================================================
# build_panel_comuni_v3.R
# Panel comuni italiani x anno per indicatori di sostenibilita'.
# Uso:        source("build_panel_comuni_v3.R")      oppure  Rscript build_panel_comuni_v3.R
# Solo funz.: options(panel.run = FALSE); source("build_panel_comuni_v3.R")   (test)
# Regole: nessuna imputazione, nessun NA -> 0, nessuna colonna scelta a caso,
#         aggregazioni sovracomunali conservate e MAI attribuite ai comuni,
#         geografie storiche non armonizzate tenute separate e segnalate.
# Requisiti: R >= 4.2, internet, sf (GDAL/GEOS/PROJ).
# =============================================================================

# ---- 0. CONFIG ---------------------------------------------------------------
CONFIG <- list(
  years          = 2006:2024,          # range cercato; anni senza indicatori teorici esclusi
  focus_years    = c(2023L, 2024L),
  waste_years    = 2010:2024,
  do_geometry    = TRUE,
  do_istat       = TRUE,
  do_soil        = TRUE,
  do_waste       = TRUE,
  do_variazioni  = TRUE,               # ISTAT variazioni amministrative (esistenza comuni)
  do_catalogo    = TRUE,               # catalogo tavole ISTAT scaricate (per estensioni)
  do_verifica    = TRUE,               # verifica endpoint a inizio run
  redownload     = FALSE,              # TRUE = ignora cache raw/
  offline        = FALSE,              # TRUE = usa solo raw/, nessun download (test)
  n_min_comuni   = 6500L,              # soglia copertura "nazionale"
  max_anomalie_pct = 2,                # % max righe CSV ISPRA non interpretabili per anno
  cov_soglia     = 0.90,               # copertura minima per "indicatore pienamente disponibile"
  # Alias ArcGIS non informativi (CSUOLO1_06...). Semantica verificata il 02/11/2026 su Milano/Torino/Roma/Arnad
  # e RIVERIFICATA numericamente a ogni run (read_soil): csuolo1 = ha consumati; csuolo4 = % (solo 2024);
  # csuolo8 = variazione netta ha vs anno disponibile precedente (2024 vs 2023 rivisto 'csuolo1__1').
  soil_field_map = list(suolo_consumato_ha = 'csuolo1', suolo_consumato_pct_ispra = 'csuolo4', variazione_netta_suolo_ha = 'csuolo8'),
  min_bytes      = list(geo = 100000, xlsx = 1000, csv = 10000, var = 10000),
  user_agent     = 'panel-comuni-sostenibilita/3.0 (ricerca; R httr2)'
)
options(timeout = max(900, getOption('timeout')))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

.this_file <- function() {
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(normalizePath(sub('^--file=', '', a[1])))
  for (i in rev(seq_len(sys.nframe()))) {
    f <- sys.frame(i)$ofile
    if (!is.null(f)) return(normalizePath(f))
  }
  NA_character_
}
ROOT <- getOption('panel.root') %||% {
  f <- .this_file(); if (is.na(f)) getwd() else dirname(f)
}

# ---- 0b. DIPENDENZE ------------------------------------------------------------
PKGS <- c('dplyr','tidyr','readr','stringr','stringi','tibble','ggplot2','scales',
          'httr2','jsonlite','readxl','data.table','sf','digest')
ensure_pkgs <- function(pk = PKGS) {
  miss <- pk[!vapply(pk, requireNamespace, logical(1), quietly = TRUE)]
  if (length(miss)) {
    message('Installo: ', paste(miss, collapse = ', '))
    install.packages(miss, repos = 'https://cloud.r-project.org')
  }
  miss <- pk[!vapply(pk, requireNamespace, logical(1), quietly = TRUE)]
  if (length(miss)) stop('Pacchetti non installabili: ', paste(miss, collapse = ', '))
  if (utils::packageVersion('httr2') < '1.0.0') stop('Serve httr2 >= 1.0.0')
  invisible(TRUE)
}
ensure_pkgs()
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(tibble)
  library(ggplot2); library(stringr); library(data.table); library(sf)
})
# dplyr vince su data.table per i verbi omonimi
between <- dplyr::between; first <- dplyr::first; last <- dplyr::last

# ---- 1. STATO, LOG, DIAGNOSTICA ------------------------------------------------
.S <- new.env()
init_state <- function(out_dir) {
  .S$OUT  <- out_dir
  .S$DIAG <- file.path(out_dir, 'diagnostica')
  dir.create(.S$DIAG, recursive = TRUE, showWarnings = FALSE)
  .S$LOG  <- file.path(out_dir, 'pipeline_log.txt')
  cat('PIPELINE v3 | ', format(Sys.time()), '\n', file = .S$LOG)
  .S$err  <- tibble(ts = character(), livello = character(), componente = character(), dettaglio = character())
  .S$dl   <- tibble()
  .S$qc   <- tibble(controllo = character(), oggetto = character(), esito = character(),
                    n = integer(), dettaglio = character())
  invisible(TRUE)
}
logmsg <- function(...) {
  s <- paste0(..., collapse = '')
  message(s)
  if (!is.null(.S$LOG)) cat(s, '\n', file = .S$LOG, append = TRUE)
}
add_error <- function(comp, e, livello = 'ERRORE') {
  msg <- if (inherits(e, 'condition')) conditionMessage(e) else paste(as.character(e), collapse = ' ')
  logmsg(livello, ' [', comp, ']: ', msg)
  .S$err <- bind_rows(.S$err, tibble(ts = format(Sys.time()), livello = livello,
                                      componente = comp, dettaglio = msg))
  invisible(NULL)
}
add_qc <- function(controllo, oggetto, esito, n = NA_integer_, dettaglio = '') {
  .S$qc <- bind_rows(.S$qc, tibble(controllo = controllo, oggetto = oggetto, esito = esito,
                                    n = as.integer(n), dettaglio = dettaglio))
  if (esito %in% c('FAIL', 'WARN')) logmsg('QC ', esito, ' [', controllo, ' | ', oggetto, ']: ', dettaglio)
  invisible(NULL)
}
write_diag <- function(x, name) {
  if (is.null(x) || !nrow(x)) return(invisible(NULL))
  readr::write_csv(x, file.path(.S$DIAG, name), na = 'NA')
}

# ---- 2. UTILITA' TESTO / CODICI / NUMERI ----------------------------------------
norm_txt <- function(x) {
  x <- stringi::stri_trans_general(enc2utf8(as.character(x)), 'Latin-ASCII')
  x <- gsub('[‘’`]', "'", x)
  tolower(trimws(gsub('[[:space:]]+', ' ', x)))
}
NA_TOKENS <- c('', 'na', 'n.a.', 'n.a', 'n.d.', 'n.d', 'nd', '..', '...', '-', '--', '—',
               'x', '*', 'null', 'non disponibile', 'nan')

# Codice ISTAT comunale -> stringa 6 cifre. allow8: codice ISPRA = 2 cifre regione + 6 PRO_COM.
code6 <- function(x, allow8 = FALSE) {
  z <- gsub('["\'[:space:]]', '', as.character(x))
  z <- sub('\\.0+$', '', z)
  z[is.na(z)] <- ''
  out <- rep(NA_character_, length(z))
  dig <- grepl('^[0-9]+$', z); n <- nchar(z)
  ok6 <- dig & n >= 4 & n <= 6
  out[ok6] <- formatC(as.integer(z[ok6]), width = 6, flag = '0')
  if (allow8) {
    z8 <- z; z8[dig & n == 7] <- paste0('0', z8[dig & n == 7])   # zero iniziale perso (reg. 01-09)
    ok8 <- dig & n %in% 7:8
    out[ok8] <- substr(z8[ok8], 3, 8)
  }
  out[!is.na(out) & out == '000000'] <- NA_character_
  out
}
code8_region <- function(x) {
  z <- gsub('["\'[:space:]]', '', as.character(x)); z[is.na(z)] <- ''
  z[grepl('^[0-9]{7}$', z)] <- paste0('0', z[grepl('^[0-9]{7}$', z)])
  ifelse(grepl('^[0-9]{8}$', z), substr(z, 1, 2), NA_character_)
}
REGIONI <- tribble(~cod_reg, ~rx,
  '01','piemonte', '02',"valle d.?aosta|vallee d", '03','lombardia', '04','trentino|alto adige|sudtirol',
  '05','veneto', '06','friuli', '07','liguria', '08','emilia', '09','toscana', '10','umbria',
  '11','marche', '12','lazio', '13','abruzz', '14','molise', '15','campania', '16','puglia',
  '17','basilicata', '18','calabria', '19','sicilia', '20','sardegna')
region_code_from_name <- function(x) {
  nx <- norm_txt(x); out <- rep(NA_character_, length(nx))
  for (i in seq_len(nrow(REGIONI))) out[is.na(out) & grepl(REGIONI$rx[i], nx)] <- REGIONI$cod_reg[i]
  out
}

# Numeri: dec='auto' decide per VETTORE (colonna): virgola presente -> formato italiano.
num_it <- function(x, dec = c('auto', 'comma', 'dot')) {
  dec <- match.arg(dec)
  if (is.numeric(x)) return(as.numeric(x))
  z <- trimws(as.character(x)); z <- gsub('[  ]', '', z)
  z[norm_txt(z) %in% NA_TOKENS] <- NA_character_
  if (dec == 'auto') dec <- if (any(grepl(',', z, fixed = TRUE), na.rm = TRUE)) 'comma' else 'dot'
  if (dec == 'comma') {
    z <- gsub('.', '', z, fixed = TRUE); z <- sub(',', '.', z, fixed = TRUE)
  } else {
    md <- !is.na(z) & lengths(regmatches(z, gregexpr('.', z, fixed = TRUE))) > 1
    z[md] <- gsub('.', '', z[md], fixed = TRUE)            # 1.234.567 = migliaia
  }
  z <- sub('%$', '', z)
  ok <- grepl('^[-+]?[0-9]*\\.?[0-9]+([eE][-+]?[0-9]+)?$', z)
  out <- rep(NA_real_, length(z)); out[ok] <- as.numeric(z[ok])
  attr(out, 'n_non_numerici') <- sum(!is.na(z) & !ok)
  attr(out, 'dec') <- dec
  out
}

assert_keys <- function(z, name = 'dati') {
  if (!all(c('codice_istat', 'anno') %in% names(z))) stop('Chiavi assenti in ', name)
  if (anyNA(z$codice_istat) || anyNA(z$anno)) stop('Chiavi mancanti in ', name)
  if (any(!grepl('^[0-9]{6}$', z$codice_istat))) stop('Codici non a 6 cifre in ', name)
  if (anyDuplicated(z[c('codice_istat', 'anno')])) stop('Duplicati comune-anno in ', name)
  invisible(TRUE)
}

# ---- 3. DOWNLOAD CON CACHE E VALIDAZIONE ---------------------------------------
sniff <- function(path, n = 4096) {
  if (!file.exists(path) || file.size(path) == 0) return(raw(0))
  readBin(path, 'raw', min(n, file.size(path)))
}
validate_file <- function(path, kind, min_bytes = 1000) {
  if (!file.exists(path)) return('file assente')
  if (file.size(path) < min_bytes) return(paste0('file troppo piccolo (', file.size(path), ' byte)'))
  b <- sniff(path)
  # testo solo per controlli CSV/JSON; byte grezzi, nessuna conversione multibyte
  head_txt <- rawToChar(b[b != as.raw(0)]); Encoding(head_txt) <- 'bytes'
  if (kind %in% c('zip', 'xlsx')) {
    if (length(b) < 2 || !identical(b[1:2], charToRaw('PK'))) return('non e un archivio ZIP/XLSX')
    z <- tryCatch(utils::unzip(path, list = TRUE), error = function(e) NULL)
    if (is.null(z) || !nrow(z)) return('archivio ZIP illeggibile')
    if (kind == 'xlsx' && !any(z$Name == 'xl/workbook.xml')) return('XLSX privo di workbook')
  }
  if (kind %in% c('csv', 'json')) {
    if (grepl('<html|<!doctype|<head', head_txt, ignore.case = TRUE, useBytes = TRUE)) return('contenuto HTML, non dati')
    if (kind == 'csv' && !grepl(';|,', head_txt, useBytes = TRUE)) return('CSV senza separatori riconoscibili')
  }
  'OK'
}
http_req <- function(url, timeout = 900) {
  httr2::request(url) |>
    httr2::req_user_agent(CONFIG$user_agent) |>
    httr2::req_retry(max_tries = 3) |>
    httr2::req_timeout(timeout) |>
    httr2::req_error(is_error = function(resp) FALSE)
}
log_download <- function(url, dest, esito, status = NA, bytes = NA, cache = FALSE, tipo = NA) {
  .S$dl <- bind_rows(.S$dl, tibble(ts = format(Sys.time()), url = url, file = basename(dest %||% ''),
           http_status = as.integer(status), content_type = as.character(tipo),
           bytes = as.numeric(bytes), da_cache = cache, esito = esito,
           md5 = if (!is.null(dest) && file.exists(dest)) unname(tools::md5sum(dest)) else NA_character_))
}
fetch <- function(url, dest, kind = 'zip', min_bytes = 1000) {
  if (file.exists(dest) && !CONFIG$redownload) {
    v <- validate_file(dest, kind, min_bytes)
    if (v == 'OK') { log_download(url, dest, 'OK', cache = TRUE, bytes = file.size(dest)); return(dest) }
    logmsg('Cache non valida (', v, '): riscarico ', basename(dest))
  }
  if (isTRUE(CONFIG$offline)) { log_download(url, dest, 'ERRORE offline: file non in cache'); stop('Modalita offline: file non in cache: ', basename(dest)) }
  logmsg('Download: ', url)
  tmp <- paste0(dest, '.part'); unlink(tmp)
  resp <- tryCatch(httr2::req_perform(http_req(url), path = tmp),
                   error = function(e) { log_download(url, dest, paste('ERRORE rete:', conditionMessage(e)))
                                         stop('Rete: ', conditionMessage(e)) })
  st <- httr2::resp_status(resp)
  ct <- tryCatch(httr2::resp_header(resp, 'content-type'), error = function(e) NA) %||% NA
  if (st >= 400) { log_download(url, dest, 'ERRORE http', st, file.size(tmp), tipo = ct); unlink(tmp)
                   stop('HTTP ', st, ': ', url) }
  v <- validate_file(tmp, kind, min_bytes)
  if (v != 'OK') { log_download(url, dest, paste('ERRORE contenuto:', v), st, file.size(tmp), tipo = ct)
                   bad <- paste0(dest, '.rifiutato'); file.rename(tmp, bad)
                   stop('Contenuto non valido (', v, '): ', url, ' -> salvato ', basename(bad)) }
  unlink(dest)
  if (!file.rename(tmp, dest)) stop('Rinomina fallita: ', dest)
  log_download(url, dest, 'OK', st, file.size(dest), tipo = ct)
  dest
}
get_json <- function(url, query = list()) {
  req <- http_req(url, 120)
  if (length(query)) req <- httr2::req_url_query(req, !!!query)
  resp <- httr2::req_perform(req)
  st <- httr2::resp_status(resp)
  if (st >= 400) stop('HTTP ', st, ' ', url)
  ans <- jsonlite::fromJSON(httr2::resp_body_string(resp), simplifyVector = FALSE)
  if (!is.null(ans$error)) stop('Errore server ArcGIS: ', paste(unlist(ans$error), collapse = ' / '))
  ans
}

# ---- 4. URL FONTI ----------------------------------------------------------------
GEOM_URL   <- 'https://www.istat.it/storage/cartografia/confini_amministrativi/generalizzati/2025/Limiti01012025_g.zip'
VAR_URL    <- 'https://www.istat.it/storage/codici-unita-amministrative/Variazioni-amministrative-e-territoriali-dal-1991.zip'
ISTAT_BASE <- 'https://www.istat.it/storage/misura-comune/'
ISTAT_PAGE <- 'https://www.istat.it/statistica-sperimentale/aggiornamento-degli-indicatori-del-sistema-informativo-a-misura-di-comune/'
SOIL_API   <- paste0('https://sinacloud.isprambiente.it/arcgisina/rest/services/',
                     'sina_consumo_suolo/Statistiche_consumo_suolo_2025/FeatureServer/1')
WASTE_PAGE <- 'https://www.catasto-rifiuti.isprambiente.it/index.php?pg=downloadComune'
waste_url  <- function(y) paste0('https://www.catasto-rifiuti.isprambiente.it/get/getDettaglioComunale.csv.php?aa=', y)

ISTAT_FILES <- c(
  pop = '1a-Popolazione-valori-assoluti.xlsx',
  structure = '1d-Popolazione-indicatori-struttura.xlsx',
  environment = '11-Territorio-e-ambiente.xlsx',
  mobility = '15c-Infrastrutture-e-mobilita-per-tassi-di-motorizzazione-e-proventi-dalle-sanzioni.xlsx',
  accidents = '15a-Infrastrutture-e-mobilita-incidenti-stradali.xlsx',
  education = '4-Istruzione.xlsx', labour = '5-Lavoro.xlsx',
  income = '6-Benessere-economico.xlsx', innovation = '13-Ricerca-innovazione.xlsx',
  entrepreneurship = '12a-Economia-insediata-rapporti-caratteristici.xlsx',
  tourism = '14-Turismo.xlsx')

# ---- 5. DIZIONARIO (spec teorica) --------------------------------------------------
# polarita: '+' piu' alto = piu' sostenibile; '-' opposto; 'contesto' non orientato; 'ambigua' da decidere.
# geografia: 'armonizzata_2024' = fonte ricostruita su confini 31/12/2024; 'anno_corrente' = confini dell'anno.
# Unita' ISTAT da confermare con 'titolo_tavola_fonte' (estratto dal file a run time).
SPEC_ISTAT <- tribble(
  ~indicatore, ~file, ~tavola, ~anni_teorici, ~dimensione, ~unita, ~polarita, ~descrizione,
  'popolazione',           'pop',         '1.1', 2014:2024, 'demografica',     'abitanti',            'contesto', 'Popolazione residente',
  'indice_vecchiaia',      'structure',   '6.1', 2014:2024, 'demografica',     'pop65+/pop0-14 x100', 'contesto', 'Indice di vecchiaia',
  'indice_dipendenza',     'structure',   '8.1', 2014:2024, 'demografica',     'rapporto x100',       '-',        'Indice di dipendenza strutturale',
  'rd_pct_istat',          'environment', '6.1', 2014:2024, 'ambientale',      '%',                   '+',        'Raccolta differenziata (%) - ISTAT',
  'auto_pre_euro4_pct',    'environment', '8.1', 2014:2023, 'ambientale',      '%',                   '-',        'Autovetture fino a Euro 3 (%)',
  'suolo_consumato_pct_istat','environment','9.1', 2015:2024, 'ambientale',     '%',                   '-',        'Suolo consumato (%) - ISTAT su dati ISPRA',
  'auto_motorizzazione',   'mobility',    '8.1', 2014:2023, 'ambientale',      'vedi titolo tavola',  '-',        'Tasso di motorizzazione autovetture',
  'moto_motorizzazione',   'mobility',    '9.1', 2014:2023, 'ambientale',      'vedi titolo tavola',  '-',        'Tasso di motorizzazione motocicli',
  'incidentalita',         'accidents',   '1.1', 2014:2024, 'infrastrutturale','vedi titolo tavola',  '-',        'Incidentalita stradale',
  'titolo_secondario_pct', 'education',   '4.1', 2018:2023, 'sociale',         '%',                   '+',        'Popolazione con titolo secondario superiore',
  'titolo_terziario_pct',  'education',   '5.1', 2018:2023, 'sociale',         '%',                   '+',        'Popolazione con titolo terziario',
  'tasso_occupazione',     'labour',      '1.1', c(2019L, 2021:2023), 'economica', '%',                 '+',        'Tasso di occupazione',
  'tasso_disoccupazione',  'labour',      '2.1', c(2019L, 2021:2023), 'economica', '%',                 '-',        'Tasso di disoccupazione',
  'redditi_bassi_pct',     'income',      '1.1', 2014:2023, 'economica',       '%',                   '-',        'Contribuenti con reddito < 10 mila euro',
  'reddito_imponibile_medio','income',    '2.1', 2014:2023, 'economica',       'euro',                '+',        'Reddito imponibile medio per contribuente',
  'ftth_pct',              'innovation',  '2.1', 2022:2024, 'infrastrutturale','%',                   '+',        'Copertura FTTH',
  'tasso_imprenditorialita','entrepreneurship','1.1', 2014:2023, 'economica',  'vedi titolo tavola',  '+',        'Tasso di imprenditorialita',
  'densita_unita_locali',  'entrepreneurship','2.1', 2014:2023, 'economica',   'vedi titolo tavola',  'ambigua',  'Densita unita locali',
  'turismo_arrivi',        'tourism',     '2.1', 2014:2024, 'economica',       'vedi titolo tavola',  'ambigua',  'Indice di turisticita (arrivi)',
  'turismo_presenze',      'tourism',     '3.1', 2014:2024, 'economica',       'vedi titolo tavola',  'ambigua',  'Indice di turisticita (presenze)',
  'densita_turistica',     'tourism',     '4.1', 2014:2024, 'economica',       'vedi titolo tavola',  'ambigua',  'Densita presenza turistica',
  'densita_posti_letto',   'tourism',     '7.1', 2014:2024, 'economica',       'vedi titolo tavola',  'ambigua',  'Densita posti letto'
) |> mutate(fonte = 'ISTAT A misura di Comune', url = paste0(ISTAT_BASE, ISTAT_FILES[file]),
            campo = paste0('Tavola ', tavola), geografia = 'armonizzata_2024', in_completezza = TRUE)

SPEC_EXTRA <- tribble(
  ~indicatore, ~fonte, ~campo, ~anni_teorici, ~dimensione, ~unita, ~polarita, ~descrizione, ~geografia, ~in_completezza,
  'suolo_consumato_ha',   'ISPRA Consumo di suolo (ArcGIS)', 'csuolo1_YY', c(2006L, 2012L, 2015:2024), 'ambientale', 'ha', '-', 'Suolo consumato', 'armonizzata_2024', TRUE,
  'suolo_consumato_pct_ispra','ISPRA Consumo di suolo (ArcGIS)', 'csuolo4_YY', 2024L, 'ambientale', '%', '-', 'Suolo consumato su superficie comunale', 'armonizzata_2024', TRUE,
  'variazione_netta_suolo_ha',  'ISPRA Consumo di suolo (ArcGIS)', 'csuolo8_YY', 2016:2024, 'ambientale', 'ha/anno', '-', 'Variazione netta annua suolo consumato (puo essere negativa; 2024 rispetto al 2023 rivisto)', 'armonizzata_2024', TRUE,
  'popolazione_ispra',    'ISPRA Catasto rifiuti', 'Popolazione', 2010:2024, 'demografica', 'abitanti', 'contesto', 'Popolazione usata da ISPRA (ausiliaria, controlli pro capite)', 'anno_corrente', FALSE,
  'ru_totale_t',          'ISPRA Catasto rifiuti', 'Totale RU', 2010:2024, 'ambientale', 't', '-', 'Rifiuti urbani prodotti', 'anno_corrente', TRUE,
  'rd_totale_t',          'ISPRA Catasto rifiuti', 'Totale RD', 2010:2024, 'ambientale', 't', 'contesto', 'Raccolta differenziata (massa)', 'anno_corrente', TRUE,
  'indifferenziato_t',    'ISPRA Catasto rifiuti', 'Indifferenziato', 2010:2024, 'ambientale', 't', '-', 'Rifiuti urbani indifferenziati', 'anno_corrente', TRUE,
  'rd_pct_ispra',         'ISPRA Catasto rifiuti', 'Percentuale RD', 2010:2024, 'ambientale', '%', '+', 'Raccolta differenziata (%) metodo ISPRA', 'anno_corrente', TRUE,
  'ru_procapite_kg',      'ISPRA Catasto rifiuti', 'RU pro capite (se assente: Totale RU*1000/Popolazione, vedi mappa colonne)', 2010:2024, 'ambientale', 'kg/ab/anno', '-', 'Rifiuti urbani pro capite', 'anno_corrente', TRUE,
  'rd_procapite_kg',      'ISPRA Catasto rifiuti', 'RD pro capite (se assente: Totale RD*1000/Popolazione, vedi mappa colonne)', 2010:2024, 'ambientale', 'kg/ab/anno', '+', 'Raccolta differenziata pro capite', 'anno_corrente', TRUE
) |> mutate(url = if_else(grepl('suolo', fonte), SOIL_API, paste0(waste_url('ANNO'))), file = NA_character_, tavola = NA_character_)

build_spec <- function() {
  bind_rows(SPEC_ISTAT, SPEC_EXTRA) |>
    mutate(anni_teorici = lapply(anni_teorici, as.integer),
           sorgente = case_when(fonte == 'ISTAT A misura di Comune' ~ 'istat',
                                grepl('suolo', fonte) ~ 'soil', TRUE ~ 'waste'))
}

# ---- 6. GEOMETRIE E UNIVERSO --------------------------------------------------------
pick_shp <- function(files, prefix) {
  f <- files[grepl(paste0('(^|[/\\\\])', prefix, '[0-9]{8}'), files, ignore.case = TRUE)]
  f <- f[!grepl('_WGS84', f) | length(f) == 1]   # preferisci proiezione nativa se doppia
  if (!length(f)) f <- files[grepl(paste0('(^|[/\\\\])', prefix, '[0-9]{8}'), files, ignore.case = TRUE)]
  if (length(f) != 1L) stop('Shapefile ', prefix, ' non univoco: ', paste(basename(f), collapse = ', '))
  f
}
load_geometry <- function(RAW) {
  zf <- fetch(GEOM_URL, file.path(RAW, 'Limiti01012025_g.zip'), 'zip', CONFIG$min_bytes$geo)
  fold <- file.path(RAW, 'limiti_2025'); dir.create(fold, showWarnings = FALSE)
  if (!length(list.files(fold, '\\.shp$', recursive = TRUE))) utils::unzip(zf, exdir = fold)
  fs <- list.files(fold, '\\.shp$', recursive = TRUE, full.names = TRUE)
  g <- suppressWarnings(sf::st_read(pick_shp(fs, 'Com'), quiet = TRUE))
  f <- intersect(c('PRO_COM_T', 'PRO_COM'), names(g))
  if (!length(f)) stop('Cartografia senza PRO_COM_T/PRO_COM')
  g$codice_istat <- code6(g[[f[1]]])
  if (anyNA(g$codice_istat) || anyDuplicated(g$codice_istat) || nrow(g) < CONFIG$n_min_comuni)
    stop('Geometrie: codici mancanti/duplicati o comuni insufficienti')
  g$comune <- as.character(g[[intersect(c('COMUNE', 'DEN_COM'), names(g))[1]]])
  g$cod_reg <- if ('COD_REG' %in% names(g)) formatC(as.integer(g$COD_REG), width = 2, flag = '0') else NA_character_
  g$cod_uts <- if ('COD_UTS' %in% names(g)) formatC(as.integer(g$COD_UTS), width = 3, flag = '0') else
               substr(g$codice_istat, 1, 3)
  # nomi provincia / regione dagli shapefile ProvCM e Reg
  pv <- tryCatch({
    p <- sf::st_drop_geometry(suppressWarnings(sf::st_read(pick_shp(fs, 'ProvCM'), quiet = TRUE)))
    tibble(cod_uts = formatC(as.integer(p$COD_UTS), width = 3, flag = '0'),
           provincia = as.character(p$DEN_UTS), sigla = as.character(p$SIGLA %||% NA))
  }, error = function(e) { add_error('geometria province', e, 'AVVISO'); NULL })
  rg <- tryCatch({
    r <- sf::st_drop_geometry(suppressWarnings(sf::st_read(pick_shp(fs, 'Reg'), quiet = TRUE)))
    tibble(cod_reg = formatC(as.integer(r$COD_REG), width = 2, flag = '0'), regione = as.character(r$DEN_REG))
  }, error = function(e) { add_error('geometria regioni', e, 'AVVISO'); NULL })
  g <- g[, c('codice_istat', 'comune', 'cod_reg', 'cod_uts')]
  g$area_km2 <- as.numeric(sf::st_area(g)) / 1e6
  base <- sf::st_drop_geometry(g) |> as_tibble()
  base <- if (!is.null(pv)) left_join(base, pv, by = 'cod_uts') else mutate(base, provincia = NA_character_, sigla = NA_character_)
  base <- if (!is.null(rg)) left_join(base, rg, by = 'cod_reg') else mutate(base, regione = NA_character_)
  logmsg('Geometrie ISTAT: ', nrow(g), ' comuni (confini 01/01/2025 = 31/12/2024).')
  list(g = g, base = base)
}
# Contiguita' queen (punto o lato) e rook (solo lato).
adjacency <- function(g) {
  qn <- sf::st_touches(g)
  rk <- sf::st_relate(g, g, pattern = 'F***1****')
  to_tbl <- function(nb, tipo) {
    i <- rep(seq_along(nb), lengths(nb))
    tibble(codice_istat = g$codice_istat[i], vicino_istat = g$codice_istat[unlist(nb)], tipo = tipo)
  }
  adj <- bind_rows(to_tbl(qn, 'queen'), to_tbl(rk, 'rook'))
  isolati <- tibble(codice_istat = g$codice_istat, n_vicini_queen = lengths(qn), n_vicini_rook = lengths(rk)) |>
    filter(n_vicini_queen == 0)
  list(adj = adj, isolati = isolati)
}

# ---- 7. VARIAZIONI AMMINISTRATIVE (esistenza comuni, ricodifiche 1:1) ----------------
read_variazioni <- function(RAW) {
  zf <- fetch(VAR_URL, file.path(RAW, 'variazioni_dal_1991.zip'), 'zip', CONFIG$min_bytes$var)
  fold <- file.path(RAW, 'variazioni'); dir.create(fold, showWarnings = FALSE)
  utils::unzip(zf, exdir = fold)
  f <- list.files(fold, '\\.(xlsx|xls|csv)$', recursive = TRUE, full.names = TRUE)
  if (!length(f)) stop('Nessuna tabella nello zip variazioni')
  f <- f[1]
  d <- if (grepl('csv$', f)) {
    data.table::fread(f, colClasses = 'character', encoding = 'Latin-1', data.table = FALSE)
  } else as.data.frame(readxl::read_excel(f, col_types = 'text'))
  nn <- norm_txt(names(d))
  col <- function(rx, excl = '^$') { i <- which(grepl(rx, nn) & !grepl(excl, nn))
    if (length(i) < 1) stop('Variazioni: colonna non trovata: ', rx, ' | campi: ', paste(names(d), collapse = ' | '))
    i[1] }
  j_tipo <- col('tipo.*variaz'); j_cod <- col('codice.*comune', 'associat|nuov')
  j_ass  <- col('codice.*(associat|nuov)'); j_dat <- col('decorrenza|^data')
  dt <- suppressWarnings(as.Date(d[[j_dat]], tryFormats = c('%d/%m/%Y', '%Y-%m-%d')))
  if (all(is.na(dt))) dt <- as.Date(suppressWarnings(as.numeric(d[[j_dat]])), origin = '1899-12-30')
  v <- tibble(tipo = toupper(trimws(d[[j_tipo]])), codice = code6(d[[j_cod]]),
              codice_assoc = code6(d[[j_ass]]), data = dt) |> filter(!is.na(data))
  list(
    istituiti  = v |> filter(tipo == 'CS', !is.na(codice)) |> group_by(codice_istat = codice) |>
                 summarise(data_istituzione = min(data), .groups = 'drop'),
    soppressi  = v |> filter(tipo == 'ES', !is.na(codice)) |>
                 transmute(codice_istat = codice, data_soppressione = data, codice_confluito = codice_assoc),
    # AP = cambio appartenenza provinciale con nuovo codice, territorio invariato -> ricodifica 1:1 lecita
    ricodifiche = v |> filter(tipo == 'AP', !is.na(codice), !is.na(codice_assoc), codice != codice_assoc) |>
                 transmute(codice_old = codice, codice_new = codice_assoc, data_variazione = data),
    tipi = count(v, tipo))
}
# esiste[c, y] = FALSE se comune istituito dopo il 31/12/y. NA = non determinabile.
esistenza_tbl <- function(base_codes, years, var) {
  e <- tidyr::expand_grid(codice_istat = base_codes, anno = years)
  if (is.null(var)) return(mutate(e, comune_esistente = NA))
  e |> left_join(var$istituiti, by = 'codice_istat') |>
    mutate(comune_esistente = is.na(data_istituzione) | data_istituzione <= as.Date(paste0(anno, '-12-31')),
           istituito_nell_anno = !is.na(data_istituzione) & format(data_istituzione, '%Y') == as.character(anno)) |>
    select(-data_istituzione)
}

# ---- 8. ISTAT A MISURA DI COMUNE -----------------------------------------------------
find_sheet <- function(file, table) {
  sheets <- readxl::excel_sheets(file); txt <- norm_txt(sheets)
  rgx <- paste0('(^|[^0-9.])', gsub('.', '[._ -]', table, fixed = TRUE), '([^0-9]|$)')
  hit <- which(grepl(rgx, txt, perl = TRUE))
  if (length(hit) == 1L) return(sheets[hit])
  hits <- character()
  for (s in sheets) {
    pv <- suppressMessages(readxl::read_excel(file, sheet = s, col_names = FALSE, n_max = 12,
                                              col_types = 'text', .name_repair = 'minimal'))
    t <- paste(norm_txt(unlist(pv, use.names = FALSE)), collapse = ' ')
    if (grepl(paste0('tavola\\s*', gsub('.', '\\.', table, fixed = TRUE), '(?![0-9])'), t, perl = TRUE)) hits <- c(hits, s)
  }
  if (length(hits) == 1L) return(hits)
  stop('Tavola ', table, ' non univoca (', length(hits), ' candidati). Fogli: ', paste(sheets, collapse = '; '))
}
# Intestazioni multi-riga con celle unite: riempi a destra (forward fill) per riga.
ffill_row <- function(v) {
  if (sum(nzchar(v)) < 2) return(v)          # riga titolo: non propagare
  cur <- ''; for (i in seq_along(v)) { if (nzchar(v[i])) cur <- v[i] else v[i] <- cur }; v }

read_istat_table <- function(path, table, id, years_exp, valid_codes = NULL) {
  sheet <- find_sheet(path, table)
  m <- as.matrix(suppressMessages(readxl::read_excel(path, sheet = sheet, col_names = FALSE,
                 col_types = 'text', .name_repair = 'minimal')))   # testo: nessuna perdita precisione
  m[is.na(m)] <- ''; m <- trimws(m)
  nr <- nrow(m); nc <- ncol(m)
  if (nr < CONFIG$n_min_comuni || nc < 3L) stop('Foglio troppo piccolo: ', sheet)
  # colonna codice: max overlap con universo, preferenza a etichetta 'codice'
  cc <- seq_len(min(12, nc)); codecols <- lapply(cc, function(j) code6(m[, j]))
  first_code_row <- vapply(codecols, function(x) { w <- which(!is.na(x)); if (length(w)) w[1] else NA_integer_ }, 1L)
  ov <- vapply(codecols, function(x) {
    u <- unique(stats::na.omit(x)); if (is.null(valid_codes)) length(u) else length(intersect(u, valid_codes)) }, 1L)
  uq <- vapply(codecols, function(x) { x <- stats::na.omit(x); if (!length(x)) 0 else length(unique(x)) / length(x) }, 1)
  lab <- vapply(cc, function(j) paste(norm_txt(m[seq_len(min(15, nr)), j]), collapse = ' '), '')
  hint <- grepl('codice|cod\\.|istat|pro_com', lab)
  elig <- which(ov >= CONFIG$n_min_comuni & uq > 0.95)
  if (!length(elig)) stop('Colonna codice ISTAT non identificata: ', sheet)
  if (length(elig) > 1 && sum(hint[elig]) == 1) elig <- elig[hint[elig]]
  if (length(elig) > 1) { best <- elig[ov[elig] == max(ov[elig])]
    if (length(best) > 1) stop('Piu colonne codice equivalenti in ', sheet, ': ', paste(best, collapse = ','))
    elig <- best }
  jc <- elig; cd <- codecols[[jc]]
  r0 <- first_code_row[jc]
  # riga anni: solo righe di intestazione (prima del primo codice)
  hd <- m[seq_len(r0 - 1L), , drop = FALSE]
  if (!nrow(hd)) stop('Nessuna intestazione sopra i dati: ', sheet)
  hy <- matrix(suppressWarnings(as.integer(sub('\\.0+$', '', hd))), nrow = nrow(hd))
  sc <- rowSums(hy >= 2000 & hy <= 2030, na.rm = TRUE)
  yr <- which.max(sc); if (sc[yr] < 1L) stop('Riga anni non trovata: ', sheet)
  yrow <- hy[yr, ]
  hfill <- apply(hd, 1, ffill_row); if (is.null(dim(hfill))) hfill <- matrix(hfill, ncol = 1)
  hlab <- apply(hfill, 1, function(z) paste(norm_txt(z), collapse = ' | '))   # etichetta completa per colonna
  th <- hd[seq_len(max(0, yr - 1)), 1]; th <- th[nzchar(th) & !grepl('^indice$', norm_txt(th))]; title <- paste(unique(th), collapse = ' / ')
  nmcol <- setdiff(which(grepl('denominazione|comune', lab) & !grepl('codice', lab)), jc)
  nmv <- if (length(nmcol)) m[, nmcol[1]] else rep(NA_character_, nr)
  keep <- which(!is.na(cd) & seq_len(nr) >= r0)
  if (length(unique(cd[keep])) < CONFIG$n_min_comuni) stop('Copertura comunale insufficiente: ', sheet)
  years_found <- sort(unique(stats::na.omit(yrow[yrow >= min(CONFIG$years) & yrow <= max(CONFIG$years)])))
  parts <- list(); scelte <- list()
  for (y in years_found) {
    js <- which(yrow == y)
    if (length(js) > 1L) {   # es. per sesso: SOLO colonna 'totale' univoca, mai somme di tassi
      tot <- js[grepl('totale|maschi e femmine|\\bmf\\b|entrambi', hlab[js])]
      if (length(tot) != 1L) stop('Anno ', y, ': ', length(js), ' colonne, totale non univoco (', sheet, ')')
      js <- tot
    }
    v <- num_it(m[keep, js])
    scelte[[as.character(y)]] <- tibble(anno = y, colonna = js, etichetta = hlab[js],
                                        n_non_numerici = attr(v, 'n_non_numerici'))
    d <- tibble(codice_istat = cd[keep], anno = as.integer(y), val = as.numeric(v), nome = nmv[keep])
    ck <- d |> group_by(codice_istat) |> summarise(nv = n_distinct(val, na.rm = TRUE), .groups = 'drop')
    if (any(ck$nv > 1L)) stop('Duplicati discordanti ', id, ' / ', y)
    d <- d |> group_by(codice_istat, anno) |>
      summarise(val = if (all(is.na(val))) NA_real_ else val[!is.na(val)][1],
                nome = dplyr::first(nome), .groups = 'drop')
    names(d)[names(d) == 'val'] <- id
    parts[[as.character(y)]] <- d
  }
  if (!length(parts)) stop('Nessun anno estratto: ', id)
  ans <- bind_rows(parts); assert_keys(ans, id)
  list(data = ans, years_found = years_found, sheet = sheet, title = title,
       extra = setdiff(years_found, years_exp), mancanti = setdiff(intersect(years_exp, CONFIG$years), years_found),
       scelte = bind_rows(scelte))
}
# Catalogo di tutte le tavole: per trovare ulteriori indicatori comunali (NON integrati automaticamente).
istat_catalog <- function(paths, valid_codes) {
  out <- list()
  for (k in names(paths)) {
    p <- paths[[k]]; if (is.na(p)) next
    for (s in readxl::excel_sheets(p)) {
      r <- tryCatch({
        m <- as.matrix(suppressMessages(readxl::read_excel(p, sheet = s, col_names = FALSE, col_types = 'text',
                                                           .name_repair = 'minimal')))
        m[is.na(m)] <- ''
        cod <- if (ncol(m)) max(vapply(seq_len(min(8, ncol(m))), function(j) {
          length(intersect(unique(stats::na.omit(code6(m[, j]))), valid_codes %||% unique(stats::na.omit(code6(m[, j]))))) }, 1L)) else 0L
        hy <- suppressWarnings(as.integer(m[seq_len(min(30, nrow(m))), ]))
        yy <- sort(unique(hy[!is.na(hy) & hy >= 2000 & hy <= 2030]))
        tibble(file = k, foglio = s, titolo = substr(paste(m[1:min(4, nrow(m)), 1], collapse = ' / '), 1, 300),
               n_righe = nrow(m), n_codici_comunali = cod, anni = paste(yy, collapse = ';'),
               copertura_nazionale = cod >= CONFIG$n_min_comuni)
      }, error = function(e) tibble(file = k, foglio = s, titolo = paste('ERRORE:', conditionMessage(e))))
      out[[length(out) + 1]] <- r
    }
  }
  bind_rows(out)
}

# ---- 9. ISPRA CONSUMO DI SUOLO (ArcGIS) ------------------------------------------------
classify_soil_fields <- function(fl) {
  # fl: tibble(name, alias). Semantica SOLO da alias; nessuna ipotesi.
  c <- fl |> filter(grepl('^csuolo[0-9]+_[0-9]{2}$', name)) |>
    mutate(gruppo = sub('_[0-9]{2}$', '', name), anno = 2000L + as.integer(sub('.*_', '', name)),
           al = norm_txt(alias),
           tipo = case_when(grepl('increm|variaz|nuovo consumo|consumo netto', al) & !grepl('%|percent', al) ~ 'variazione_netta_suolo_ha',
                            grepl('%|percent', al) & !grepl('increm|variaz', al) ~ 'suolo_consumato_pct_ispra',
                            grepl('consum', al) & grepl('\\bha\\b|ettar', al) ~ 'suolo_consumato_ha',
                            TRUE ~ NA_character_))
  if (!is.null(CONFIG$soil_field_map)) {
    mp <- unlist(CONFIG$soil_field_map)
    c$tipo <- names(mp)[match(c$gruppo, mp)]
    c$fonte_semantica <- 'CONFIG$soil_field_map (verifica numerica in read_soil)'
  } else c$fonte_semantica <- 'alias ArcGIS'
  # anni del periodo nell'alias (es. 'incremento 2022-2023')
  yy <- regmatches(c$alias, gregexpr('(19|20)[0-9]{2}', c$alias))
  c$anno_inizio <- vapply(yy, function(z) if (length(z) >= 2) as.integer(z[1]) else NA_integer_, 1L)
  c$anno_alias  <- vapply(yy, function(z) if (length(z)) as.integer(z[length(z)]) else NA_integer_, 1L)
  c
}
read_soil <- function(RAW) {
  meta <- get_json(SOIL_API, list(f = 'json'))
  fl <- tibble(name = vapply(meta$fields, function(f) f$name, ''),
               alias = vapply(meta$fields, function(f) f$alias %||% '', ''),
               type = vapply(meta$fields, function(f) f$type %||% '', ''))
  cf <- classify_soil_fields(fl)
  write_diag(cf, 'ispra_suolo_campi.csv')
  codef <- intersect(c('pro_com_t', 'PRO_COM_T', 'pro_com', 'PRO_COM'), fl$name)[1]
  if (is.na(codef)) stop('Campo codice comunale assente nel servizio suolo')
  use <- cf |> filter(!is.na(tipo))
  if (!nrow(use)) stop('Semantica campi csuolo non deducibile dagli alias: vedi diagnostica/ispra_suolo_campi.csv ',
                       'e imposta CONFIG$soil_field_map')
  bad <- use |> filter(!is.na(anno_alias), anno_alias != anno)
  if (nrow(bad)) add_error('ISPRA suolo', paste('Anno da nome != anno da alias per', paste(bad$name, collapse = ',')), 'AVVISO')
  # paginazione sicura: conteggio + exceededTransferLimit
  n_tot <- get_json(paste0(SOIL_API, '/query'), list(where = '1=1', returnCountOnly = 'true', f = 'json'))$count
  page <- min(as.integer(meta$maxRecordCount %||% 1000L), 2000L)
  off <- 0L; batches <- list()
  oid <- intersect(c('objectid', 'OBJECTID', 'fid', 'FID'), fl$name)[1]
  repeat {
    q <- list(where = '1=1', outFields = paste(unique(c(codef, intersect(c('pro_com', 'PRO_COM'), fl$name), use$name, grep('__[0-9]+$|^Shape__Area$', fl$name, value = TRUE))), collapse = ','), returnGeometry = 'false',
              orderByFields = oid %||% codef, resultOffset = off, resultRecordCount = page, f = 'json')
    js <- get_json(paste0(SOIL_API, '/query'), q)
    if (!length(js$features)) break
    at <- lapply(js$features, function(x) { a <- x$attributes; a[vapply(a, is.null, TRUE)] <- NA; a })
    cur <- data.table::rbindlist(at, fill = TRUE)
    batches[[length(batches) + 1L]] <- cur; off <- off + nrow(cur)
    if (!is.null(n_tot) && off >= n_tot) break
    if (!isTRUE(js$exceededTransferLimit) && nrow(cur) < page) break
    if (off > 50000L) stop('Paginazione ArcGIS fuori controllo')
  }
  dat <- as_tibble(data.table::rbindlist(batches, fill = TRUE))
  if (!is.null(n_tot) && nrow(dat) != n_tot) stop('Righe ArcGIS ', nrow(dat), ' != conteggio ', n_tot)
  if (nrow(dat) < CONFIG$n_min_comuni) stop('Servizio suolo senza copertura nazionale')
  dat$codice_istat <- code6(dat[[codef]])
  # pro_com_t talvolta ' ' (es. 166 comuni prov. Trento nel servizio 2025): ripiego su pro_com numerico, tracciato
  alt <- intersect(c('pro_com', 'PRO_COM'), names(dat))[1]
  if (!is.na(alt)) {
    c2 <- code6(dat[[alt]]); both <- !is.na(dat$codice_istat) & !is.na(c2)
    if (any(dat$codice_istat[both] != c2[both])) stop('pro_com_t e pro_com discordanti in ', sum(dat$codice_istat[both] != c2[both]), ' righe')
    w <- is.na(dat$codice_istat) & !is.na(c2)
    if (any(w)) {
      dat$codice_istat[w] <- c2[w]
      add_error('ISPRA suolo', paste0(sum(w), ' righe con pro_com_t vuoto: codice da pro_com (es. ', paste(head(c2[w], 3), collapse = ','), ')'), 'AVVISO')
    }
  }
  if (anyNA(dat$codice_istat) || anyDuplicated(dat$codice_istat)) stop('Codici suolo mancanti/duplicati: NA=', sum(is.na(dat$codice_istat)), ' dup=', sum(duplicated(dat$codice_istat, incomparables = NA)))
  saveRDS(dat, file.path(RAW, 'ispra_suolo_attributi.rds'))
  # --- verifica numerica della semantica (nessuna fiducia cieca nella mappa)
  ver <- list()
  stock <- use |> filter(tipo == 'suolo_consumato_ha') |> arrange(anno)
  area_ha <- if ('Shape__Area' %in% names(dat)) num_it(dat$Shape__Area) / 1e4 else NULL
  for (i in which(use$tipo == 'suolo_consumato_pct_ispra')) {
    s1 <- stock$name[stock$anno == use$anno[i]]
    if (is.null(area_ha) || !length(s1)) next
    d <- abs(num_it(dat[[use$name[i]]]) - 100 * num_it(dat[[s1]]) / area_ha)
    ok <- stats::median(d, na.rm = TRUE) < 0.1
    ver[[length(ver) + 1]] <- tibble(campo = use$name[i], verifica = paste0('% vs 100*', s1, '/area'), base = s1,
                                     quota_coerente = mean(d < 0.1, na.rm = TRUE), esito = if (ok) 'OK' else 'FALLITA')
    if (!ok) stop('Semantica ', use$name[i], ' non confermata: % non coerente con ha/area')
  }
  keep_var <- character()
  for (i in which(use$tipo == 'variazione_netta_suolo_ha')) {
    y <- use$anno[i]; prev <- stock$anno[stock$anno < y]
    if (!length(prev)) next
    p <- max(prev); v <- num_it(dat[[use$name[i]]])
    cands <- c(stock$name[stock$anno == p], grep(paste0('^', sub('_[0-9]{2}$', '', stock$name[1]), '__[0-9]+$'), names(dat), value = TRUE))
    q <- vapply(cands, function(b) mean(abs(v - (num_it(dat[[stock$name[stock$anno == y]]]) - num_it(dat[[b]]))) < 0.05, na.rm = TRUE), 1)
    best <- names(q)[which.max(q)]
    ok <- max(q) >= 0.99
    annuale <- (y - p) == 1L
    ver[[length(ver) + 1]] <- tibble(campo = use$name[i], verifica = paste0(stock$name[stock$anno == y], ' - base'), base = best,
                                     quota_coerente = max(q), esito = if (!ok) 'FALLITA' else if (!annuale) paste0('PLURIENNALE ', p, '-', y, ': esclusa') else 'OK')
    if (!ok) stop('Semantica ', use$name[i], ' non confermata: non e la differenza tra stock')
    if (annuale) keep_var <- c(keep_var, use$name[i])
    if (annuale && best != stock$name[stock$anno == p]) add_error('ISPRA suolo', paste0(use$name[i], ': calcolata su base rivista ', best, ' (non ', stock$name[stock$anno == p], ')'), 'AVVISO')
  }
  write_diag(bind_rows(ver), 'ispra_suolo_verifica_semantica.csv')
  rev <- grep('__[0-9]+$', fl$name, value = TRUE)
  if (length(rev)) add_error('ISPRA suolo', paste('Campi revisione esclusi dalla serie stock:', paste(rev, collapse = ',')), 'AVVISO')
  li <- list()
  for (i in seq_len(nrow(use))) {
    u <- use[i, ]
    if (u$tipo == 'variazione_netta_suolo_ha' && !u$name %in% keep_var) next
    li[[length(li) + 1]] <- tibble(codice_istat = dat$codice_istat, anno = u$anno, indicatore = u$tipo,
                                   valore = num_it(dat[[u$name]]))
  }
  ld <- bind_rows(li) |> filter(anno %in% CONFIG$years)
  if (anyDuplicated(ld[c('codice_istat', 'anno', 'indicatore')])) stop('Campi suolo multipli per stesso tipo/anno')
  ans <- ld |> tidyr::pivot_wider(names_from = indicatore, values_from = valore)
  assert_keys(ans, 'ISPRA suolo')
  acq <- ld |> distinct(indicatore, anno) |> mutate(acquisito = TRUE)
  list(data = ans, acq = acq, presenza = distinct(ans, codice_istat, anno))
}

# ---- 10. ISPRA CATASTO RIFIUTI ------------------------------------------------------------
read_text_auto <- function(path) {
  b <- readBin(path, 'raw', file.size(path))
  if (length(b) >= 3 && identical(b[1:3], as.raw(c(0xef, 0xbb, 0xbf)))) b <- b[-(1:3)]
  b <- b[b != as.raw(0)]
  txt <- rawToChar(b)
  enc <- if (validUTF8(txt)) 'UTF-8' else 'CP1252'
  if (enc != 'UTF-8') txt <- iconv(txt, 'CP1252', 'UTF-8', sub = '?')
  Encoding(txt) <- 'UTF-8'
  lines <- strsplit(txt, '\r\n|\n|\r', perl = TRUE)[[1]]
  attr(lines, 'encoding') <- enc
  lines
}
# split ';' rispettando virgolette doppie; conserva campi vuoti finali; apostrofi ok.
split_fields <- function(line, sep = ';') {
  if (!grepl('"', line, fixed = TRUE)) return(trimws(strsplit(paste0(line, sep, '\u0001'), sep, fixed = TRUE)[[1]] |> head(-1)))
  trimws(scan(text = line, what = 'character', sep = sep, quote = '"', quiet = TRUE,
              na.strings = character(), strip.white = TRUE, comment.char = ''))
}
# Ricompone record spezzati su piu' righe fisiche: riga non iniziante con codice e record
# precedente incompleto -> continuazione. Ogni riga fisica resta tracciata.
assemble_records <- function(lines, nh, start_rx = '^\\s*"?[0-9]{6,8}"?\\s*;') {
  recs <- list(); cur <- NULL; cur_l <- integer(); nf <- 0L
  flush <- function() if (!is.null(cur)) recs[[length(recs) + 1L]] <<- list(txt = cur, righe = cur_l)
  for (i in seq_along(lines)) {
    l <- lines[i]; if (!nzchar(trimws(l))) next
    st <- grepl(start_rx, l, perl = TRUE)
    if (!is.null(cur) && !st && nf < nh) {
      cur <- paste(cur, l); cur_l <- c(cur_l, i); nf <- length(split_fields(cur))
    } else {
      flush(); cur <- l; cur_l <- i; nf <- length(split_fields(cur))
    }
  }
  flush()
  recs
}
WASTE_MEAS <- tribble(~id, ~inc, ~exc,
  'popolazione_ispra', 'popolazione|abitanti|residenti', 'capite|kg|%',
  'rd_totale_t',       '(totale|tot\\.?)\\s*(rd|raccolta differenziata)|^(rd|raccolta differenziata)\\s*(totale|tot\\.?)|^(rd|raccolta differenziata)\\s*\\((t|tonnellate)\\)$', 'capite|kg|%|percent',
  'ru_totale_t',       '(totale|tot\\.?)\\s*(ru|rifiuti urbani)|^(ru|rifiuti urbani)\\s*(totale|tot\\.?)|^(ru|rifiuti urbani)\\s*\\((t|tonnellate)\\)$|produzione\\s*(totale|ru)', 'capite|kg|%|percent|differenz|\\brd\\b',
  'indifferenziato_t', 'indifferenziat', 'capite|kg|%|percent',
  'rd_pct_ispra',      '(percentuale|perc\\.?|%)\\s*(di\\s*)?(rd|raccolta differenziata)|(rd|raccolta differenziata).*(\\(%\\)|percentuale)', 'capite|kg',
  'ru_procapite_kg',   'pro\\s*-?\\s*capite', '\\brd\\b|differenziat',
  'rd_procapite_kg',   '(\\brd\\b|differenziata).*pro\\s*-?\\s*capite|pro\\s*-?\\s*capite.*(\\brd\\b|differenziata)', 'indifferenz')
unit_from_header <- function(h) {
  h <- norm_txt(h)
  case_when(grepl('%|percent', h) ~ '%', grepl('kg', h) ~ 'kg/ab', grepl('\\(t\\)|tonnell', h) ~ 't',
            grepl('abitanti|popolaz', h) ~ 'ab', TRUE ~ 'non dichiarata')
}
# Parser ISPRA dettaglio comunale. Restituisce tutto: comuni, aggregazioni, righe anomale, mappa colonne.
parse_ispra_rifiuti <- function(path, year) {
  lines <- read_text_auto(path); enc <- attr(lines, 'encoding')
  if (grepl('<html|<!doctype', paste(head(lines, 20), collapse = ' '), ignore.case = TRUE)) stop('File HTML, non CSV')
  hi <- which(grepl(';', lines) & grepl('comune', norm_txt(lines)) & grepl('istat|regione|provincia', norm_txt(lines)))[1]
  if (is.na(hi)) stop('Intestazione CSV ISPRA non riconoscibile (anno ', year, ')')
  header <- split_fields(lines[hi])
  while (length(header) && !nzchar(header[length(header)])) header <- header[-length(header)]
  nh <- length(header); hn <- norm_txt(header)
  if (anyDuplicated(hn)) add_error(paste('ISPRA rifiuti', year), paste('Intestazioni duplicate:', paste(unique(hn[duplicated(hn)]), collapse = ', ')), 'AVVISO')
  pre <- if (hi > 1) lines[seq_len(hi - 1)] else character()
  recs <- assemble_records(lines[-seq_len(hi)], nh)
  righe <- vapply(recs, function(r) paste(r$righe + hi, collapse = ','), '')
  flds  <- lapply(recs, function(r) split_fields(r$txt))
  # campi vuoti in coda (';' finale) non sono dati
  flds <- lapply(flds, function(f) { while (length(f) > nh && !nzchar(f[length(f)])) f <- f[-length(f)]; f })
  nf <- lengths(flds)
  # 'Dato riferito a': Comune | Aggregazione: X (capofila, valori = TOTALE aggregazione) | Vedi aggregazione: X
  rinvio <- vapply(flds, function(f) any(grepl('^vedi aggregazione', norm_txt(f))), TRUE)
  capof  <- vapply(flds, function(f) any(grepl('^aggregazione\\s*:', norm_txt(f))), TRUE)
  tipo <- ifelse(rinvio, 'rinvio_aggregazione',
          ifelse(capof & nf == nh, 'capofila_aggregazione',
          ifelse(nf == nh, 'completa', ifelse(nf <= 1, 'nota', 'anomala'))))
  # --- colonna codice: intestazione + contenuto, mai scelta arbitraria
  full <- do.call(rbind, flds[tipo == 'completa'])
  if (is.null(full) || nrow(full) < 1) stop('Nessun record completo (anno ', year, ')')
  share <- apply(full, 2, function(z) mean(grepl('^"?[0-9]{6,8}"?$', z)))
  uniq  <- apply(full, 2, function(z) { z <- z[grepl('^[0-9]{6,8}$', z)]; if (!length(z)) 0 else length(unique(z)) / length(z) })
  ch <- which(grepl('istat|^cod(ice)?\\b.*comun|pro.?com', hn))
  cc <- which(share >= 0.90 & uniq >= 0.90)   # duplicati gestiti dopo, non qui
  jc <- intersect(ch, cc)
  how <- 'intestazione+contenuto'
  if (length(jc) != 1L) {
    if (!length(ch) && length(cc) == 1L) { jc <- cc; how <- 'solo contenuto' } else
      stop('Codice comunale non identificabile (anno ', year, '): intestazioni candidate=[',
           paste(header[ch], collapse = ' | '), '], colonne con codici=[', paste(header[cc], collapse = ' | '), ']')
  }
  getc <- function(rx, excl = '^$') { i <- which(grepl(rx, hn) & !grepl(excl, hn) & seq_along(hn) != jc); if (length(i)) i[1] else NA_integer_ }
  jreg <- getc('^regione'); jpro <- getc('^provincia|^prov\\.?$'); jcom <- getc('^comune|denominazione', 'codice|istat')
  # --- misure
  cm <- lapply(seq_len(nrow(WASTE_MEAS)), function(k) {
    i <- which(grepl(WASTE_MEAS$inc[k], hn, perl = TRUE) & !grepl(WASTE_MEAS$exc[k], hn, perl = TRUE))
    tibble(anno = year, indicatore = WASTE_MEAS$id[k], n_match = length(i),
           colonna = if (length(i) == 1) i else NA_integer_,
           intestazione = paste(header[i], collapse = ' | '),
           unita_dichiarata = if (length(i) == 1) unit_from_header(header[i]) else NA_character_,
           esito = if (length(i) == 1) 'OK' else if (!length(i)) 'NON_PRESENTE' else 'AMBIGUA', n_non_numerici = NA_integer_)
  }) |> bind_rows()
  # --- tabella record
  getf <- function(f, j) if (is.na(j) || j > length(f)) NA_character_ else f[j]
  rec <- tibble(anno = as.integer(year), righe_file = righe, tipo_record = tipo, n_campi = nf,
                codice_orig = vapply(flds, getf, '', j = jc),
                regione_fonte = vapply(flds, getf, '', j = jreg),
                provincia_fonte = vapply(flds, getf, '', j = jpro),
                comune_fonte = vapply(flds, getf, '', j = jcom),
                aggregazione = vapply(flds, function(f) { k <- grep('^(vedi )?aggregazione\\s*:', norm_txt(f))[1]
                  if (is.na(k)) NA_character_ else trimws(sub('(?i)^\\s*(vedi\\s+)?aggregazione\\s*:?\\s*', '', f[k], perl = TRUE)) }, ''))
  is8 <- grepl('^[0-9]{7,8}$', gsub('"', '', rec$codice_orig))
  rec$codice_istat <- code6(rec$codice_orig, allow8 = TRUE)
  rec$reg_prefisso <- ifelse(is8, code8_region(rec$codice_orig), NA_character_)
  rec$reg_da_nome  <- region_code_from_name(rec$regione_fonte)
  rec$flag_regione <- !is.na(rec$reg_prefisso) & !is.na(rec$reg_da_nome) & rec$reg_prefisso != rec$reg_da_nome
  # aggregazioni: righe complete senza codice comunale valido, o con nome = aggregazione richiamata
  agg_names <- unique(norm_txt(stats::na.omit(rec$aggregazione)))
  is_agg <- rec$tipo_record == 'completa' & (is.na(rec$codice_istat) | norm_txt(rec$comune_fonte) %in% agg_names)
  rec$tipo_record[is_agg] <- 'aggregazione'
  # valori numerici: SOLO per record completi; formato decimale deciso su tutto il file
  ok <- which(cm$esito == 'OK')
  NUMT <- c('completa', 'aggregazione', 'capofila_aggregazione')
  allv <- unlist(lapply(flds[rec$tipo_record %in% NUMT], function(f) f[cm$colonna[ok]]))
  dec <- if (any(grepl(',', allv, fixed = TRUE))) 'comma' else 'dot'
  for (k in ok) {
    j <- cm$colonna[k]; v <- rep(NA_real_, nrow(rec))
    w <- which(rec$tipo_record %in% NUMT | (cm$indicatore[k] == 'popolazione_ispra' & rec$tipo_record == 'rinvio_aggregazione'))
    x <- num_it(vapply(flds[w], getf, '', j = j), dec)
    v[w] <- x; rec[[cm$indicatore[k]]] <- v
    cm$n_non_numerici[k] <- attr(x, 'n_non_numerici')
  }
  for (id in setdiff(WASTE_MEAS$id, cm$indicatore[ok])) rec[[id]] <- NA_real_
  # pro capite non pubblicato -> derivato (t*1000/abitanti ISPRA), dichiarato come DERIVATO
  for (dd in list(c('ru_procapite_kg', 'ru_totale_t'), c('rd_procapite_kg', 'rd_totale_t'))) {
    w <- which(cm$indicatore == dd[1])
    if (cm$esito[w] == 'NON_PRESENTE' && all(cm$esito[cm$indicatore %in% c(dd[2], 'popolazione_ispra')] == 'OK')) {
      pop <- rec$popolazione_ispra; rec[[dd[1]]] <- ifelse(!is.na(pop) & pop > 0, rec[[dd[2]]] * 1000 / pop, NA_real_)
      cm$esito[w] <- 'DERIVATO'; cm$intestazione[w] <- paste0(dd[2], ' * 1000 / popolazione_ispra'); cm$unita_dichiarata[w] <- 'kg/ab'
    }
  }
  rec$decimale <- dec
  # --- anomalie e tabelle
  anom <- tibble(anno = year, righe_file = righe, n_campi = nf, n_campi_attesi = nh, tipo = tipo,
                 testo = vapply(recs, function(r) substr(r$txt, 1, 500), ''))
  anom <- anom[rec$tipo_record %in% c('anomala', 'nota') | (rec$tipo_record == 'completa' & is.na(rec$codice_istat)) |
               grepl(',', anom$righe_file) | rec$flag_regione, ]
  # aggregazioni: righe senza codice + righe capofila (valori = totale aggregazione)
  aggr <- rec |> filter(tipo_record %in% c('aggregazione', 'capofila_aggregazione')) |>
    mutate(aggregazione = coalesce(aggregazione, comune_fonte),
           capofila_codice = if_else(tipo_record == 'capofila_aggregazione', codice_istat, NA_character_))
  membri <- rec |> filter(tipo_record %in% c('rinvio_aggregazione', 'capofila_aggregazione')) |>
    transmute(anno, aggregazione, codice_istat, comune_fonte, ruolo = if_else(tipo_record == 'capofila_aggregazione', 'capofila', 'membro'),
              popolazione_ispra)
  if (nrow(aggr)) {
    ps <- membri |> group_by(aggregazione) |> summarise(n_comuni_membri = n(), popolazione_membri = sum(popolazione_ispra, na.rm = TRUE), .groups = 'drop')
    aggr <- left_join(aggr, ps, by = 'aggregazione')
    # pro capite dell'aggregazione su popolazione dei membri (non quella del capofila)
    for (dd in list(c('ru_procapite_kg', 'ru_totale_t'), c('rd_procapite_kg', 'rd_totale_t')))
      if (cm$esito[cm$indicatore == dd[1]] == 'DERIVATO') aggr[[dd[1]]] <- aggr[[dd[2]]] * 1000 / aggr$popolazione_membri
  }
  comuni <- rec |> filter(tipo_record %in% c('completa', 'rinvio_aggregazione', 'capofila_aggregazione'), !is.na(codice_istat))
  # membri e capofila: misure SEMPRE NA (il valore e' dell'aggregazione); popolazione resta comunale
  agg_rows <- comuni$tipo_record %in% c('rinvio_aggregazione', 'capofila_aggregazione')
  for (id in setdiff(WASTE_MEAS$id, 'popolazione_ispra')) comuni[[id]][agg_rows] <- NA_real_
  # duplicati codice-anno
  dup <- comuni |> group_by(codice_istat) |> filter(n() > 1) |> ungroup()
  if (nrow(dup)) {
    ident <- dup |> select(codice_istat, all_of(WASTE_MEAS$id)) |> distinct() |> count(codice_istat) |> filter(n > 1)
    comuni <- comuni |> distinct(codice_istat, .keep_all = TRUE)
    if (nrow(ident)) for (id in WASTE_MEAS$id) comuni[[id]][comuni$codice_istat %in% ident$codice_istat] <- NA_real_
    comuni$flag_duplicato <- comuni$codice_istat %in% dup$codice_istat
  } else comuni$flag_duplicato <- FALSE
  pct_anom <- 100 * sum(rec$tipo_record == 'anomala') / max(1, sum(rec$tipo_record != 'nota'))
  list(comuni = comuni, aggregazioni = aggr, membri = membri, anomalie = anom, colmap = cm,
       header = tibble(anno = year, posizione = seq_len(nh), intestazione = header, normalizzata = hn),
       meta = tibble(anno = year, encoding = enc, n_righe_file = length(lines), riga_intestazione = hi,
                     righe_pre_intestazione = paste(substr(pre, 1, 200), collapse = ' // '),
                     n_campi_intestazione = nh, n_record = nrow(rec), n_completi = sum(rec$tipo_record == 'completa'),
                     n_rinvii = sum(rec$tipo_record == 'rinvio_aggregazione'), n_capofila = sum(rec$tipo_record == 'capofila_aggregazione'),
                     n_aggregazioni = nrow(aggr), n_note = sum(rec$tipo_record == 'nota'),
                     n_anomali = sum(rec$tipo_record == 'anomala'), pct_anomali = pct_anom,
                     n_comuni = nrow(comuni), codice_colonna = header[jc], codice_metodo = how, decimale = dec,
                     n_flag_regione = sum(rec$flag_regione), n_duplicati = nrow(dup)))
}
read_waste <- function(RAW, years = CONFIG$waste_years) {
  res <- list(); md5 <- c()
  for (y in years) {
    comp <- paste0('ISPRA rifiuti ', y)
    r <- tryCatch({
      p <- fetch(waste_url(y), file.path(RAW, paste0('ispra_rifiuti_', y, '.csv')), 'csv', CONFIG$min_bytes$csv)
      h <- unname(tools::md5sum(p))
      if (h %in% md5) stop('File identico a quello di un altro anno: endpoint ignora parametro aa? (', names(md5)[md5 == h], ')')
      md5[as.character(y)] <- h
      x <- parse_ispra_rifiuti(p, y)
      if (x$meta$pct_anomali > CONFIG$max_anomalie_pct) stop(sprintf('%.1f%% record anomali (>%s%%): struttura non compresa', x$meta$pct_anomali, CONFIG$max_anomalie_pct))
      if (x$meta$n_comuni < CONFIG$n_min_comuni) stop('Solo ', x$meta$n_comuni, ' comuni: non nazionale')
      if (!any(x$colmap$esito == 'OK')) stop('Nessuna misura identificata; vedi diagnostica intestazioni')
      for (k in which(x$colmap$esito == 'AMBIGUA')) add_error(comp, paste0(x$colmap$indicatore[k], ': colonne ambigue [', x$colmap$intestazione[k], '] -> NA'), 'AVVISO')
      saveRDS(x, file.path(RAW, paste0('ispra_rifiuti_', y, '_parsed.rds')))
      x
    }, error = function(e) { add_error(comp, e); NULL })
    if (!is.null(r)) res[[as.character(y)]] <- r
  }
  if (!length(res)) stop('Nessun CSV ISPRA interpretabile')
  pick <- function(el) bind_rows(lapply(res, `[[`, el))
  comuni <- pick('comuni')
  acq <- pick('colmap') |> filter(esito %in% c('OK', 'DERIVATO')) |> transmute(indicatore, anno = as.integer(anno), acquisito = TRUE)
  list(comuni = comuni, aggregazioni = pick('aggregazioni'), membri = pick('membri'), anomalie = pick('anomalie'),
       colmap = pick('colmap'), header = pick('header'), meta = pick('meta'), acq = acq)
}
# Allinea codici anno-corrente alla geografia 2024: ricodifiche 1:1 (AP) ammesse, il resto separato.
harmonize_codes <- function(d, base, var = NULL) {
  d$codice_fonte <- d$codice_istat; d$ricodificato <- FALSE
  if (!is.null(var) && nrow(var$ricodifiche)) {
    rc <- var$ricodifiche
    for (it in 1:5) {   # catene di ricodifiche
      m <- match(d$codice_istat, rc$codice_old)
      w <- which(!is.na(m) & !(d$codice_istat %in% base$codice_istat) &
                 d$anno < as.integer(format(rc$data_variazione[m], '%Y')) + 1L)
      if (!length(w)) break
      d$codice_istat[w] <- rc$codice_new[m[w]]; d$ricodificato[w] <- TRUE
    }
  }
  fuori <- d |> filter(!codice_istat %in% base$codice_istat)
  if (!is.null(var) && nrow(fuori)) fuori <- left_join(fuori, var$soppressi, by = c('codice_fonte' = 'codice_istat'))
  dentro <- d |> filter(codice_istat %in% base$codice_istat)
  dd <- dentro |> group_by(codice_istat, anno) |> filter(n() > 1) |> ungroup()
  if (nrow(dd)) {   # due codici fonte sullo stesso codice 2024: non sommare, separare
    fuori <- bind_rows(fuori, mutate(dd, motivo = 'collisione dopo ricodifica'))
    dentro <- dentro |> anti_join(distinct(dd, codice_istat, anno), by = c('codice_istat', 'anno'))
  }
  # coerenza nomi codice-fonte vs geografia
  nm <- dentro |> left_join(select(base, codice_istat, comune_ref = comune), by = 'codice_istat') |>
    filter(!is.na(comune_fonte), norm_txt(gsub('[^[:alnum:]]', '', comune_fonte)) != norm_txt(gsub('[^[:alnum:]]', '', comune_ref))) |>
    select(anno, codice_fonte, codice_istat, comune_fonte, comune_ref, ricodificato)
  list(dentro = dentro, fuori = fuori, nomi = nm)
}

# ---- 11. STATO DELLE OSSERVAZIONI E COMPLETEZZA ---------------------------------------------
# Stati cella (comune, anno, indicatore):
#   ANNO_NON_RILEVATO  anno fuori dalle annualita' teoriche della fonte
#   FONTE_NON_ACQUISITA anno teorico ma download/parsing falliti o colonna non identificata
#   COMUNE_NON_ESISTENTE comune istituito dopo l'anno (solo fonti 'anno_corrente')
#   DATO_AGGREGATO     valore riportato solo per aggregazione sovracomunale
#   ASSENTE_IN_FONTE   fonte acquisita ma comune non presente nel file
#   MANCANTE           comune presente nella fonte, valore mancante
#   OSSERVATO
cell_status <- function(panel, spec, acq, presenza, esist = NULL, aggr = NULL) {
  ids <- spec$indicatore
  P <- data.table::as.data.table(panel[, c('codice_istat', 'anno', intersect(ids, names(panel)))])
  for (id in setdiff(ids, names(P))) P[[id]] <- NA_real_
  L <- data.table::melt(P, id.vars = c('codice_istat', 'anno'), measure.vars = ids,
                        variable.name = 'indicatore', value.name = 'valore', variable.factor = FALSE)
  sp <- data.table::as.data.table(spec[, c('indicatore', 'sorgente', 'geografia', 'dimensione', 'in_completezza')])
  L <- sp[L, on = 'indicatore']
  teo <- data.table::rbindlist(lapply(seq_len(nrow(spec)), function(i) data.table::data.table(indicatore = spec$indicatore[i], anno = spec$anni_teorici[[i]], teorico = TRUE)))
  L <- teo[L, on = c('indicatore', 'anno')]; L[is.na(teorico), teorico := FALSE]
  A <- data.table::as.data.table(acq)[, .(indicatore, anno = as.integer(anno), acquisito)]
  L <- unique(A)[L, on = c('indicatore', 'anno')]; L[is.na(acquisito), acquisito := FALSE]
  PR <- data.table::as.data.table(presenza)[, .(indicatore, codice_istat, anno = as.integer(anno), in_fonte = TRUE)]
  L <- unique(PR)[L, on = c('indicatore', 'codice_istat', 'anno')]; L[is.na(in_fonte), in_fonte := FALSE]
  if (!is.null(esist)) {
    E <- data.table::as.data.table(esist)[, .(codice_istat, anno, comune_esistente)]
    L <- E[L, on = c('codice_istat', 'anno')]
  } else L[, comune_esistente := NA]
  if (!is.null(aggr) && nrow(aggr)) {
    G <- unique(data.table::as.data.table(aggr)[, .(codice_istat, anno = as.integer(anno), in_aggr = TRUE)])
    L <- G[L, on = c('codice_istat', 'anno')]; L[is.na(in_aggr) | sorgente != 'waste', in_aggr := FALSE]
  } else L[, in_aggr := FALSE]
  L[, stato := data.table::fcase(
    !teorico, 'ANNO_NON_RILEVATO',
    !acquisito, 'FONTE_NON_ACQUISITA',
    geografia == 'anno_corrente' & comune_esistente %in% FALSE, 'COMUNE_NON_ESISTENTE',
    !is.na(valore), 'OSSERVATO',
    in_aggr, 'DATO_AGGREGATO',
    !in_fonte, 'ASSENTE_IN_FONTE',
    default = 'MANCANTE')]
  L[]
}
# Tre denominatori: teorico (fallimenti contano come mancanti), acquisito, osservato.
completeness <- function(L) {
  L <- L[in_completezza == TRUE]
  agg <- function(DT, by) DT[, .(n_teorici = sum(teorico & stato != 'COMUNE_NON_ESISTENTE'),
                                 n_acquisiti = sum(teorico & acquisito & stato != 'COMUNE_NON_ESISTENTE'),
                                 n_osservati = sum(stato == 'OSSERVATO'),
                                 n_aggregati = sum(stato == 'DATO_AGGREGATO'),
                                 n_assenti_fonte = sum(stato == 'ASSENTE_IN_FONTE'),
                                 n_non_esistente = sum(stato == 'COMUNE_NON_ESISTENTE')), by = by][
    , `:=`(completezza_teorica = data.table::fifelse(n_teorici > 0, n_osservati / n_teorici, NA_real_),
           completezza_acquisita = data.table::fifelse(n_acquisiti > 0, n_osservati / n_acquisiti, NA_real_),
           quota_acquisita = data.table::fifelse(n_teorici > 0, n_acquisiti / n_teorici, NA_real_))][]
  ca <- agg(L, c('codice_istat', 'anno'))
  cd <- agg(L, c('codice_istat', 'anno', 'dimensione'))
  amb <- cd[dimensione == 'ambientale', .(codice_istat, anno, completezza_teorica_ambientale = completezza_teorica,
                                          completezza_acquisita_ambientale = completezza_acquisita)]
  ca <- amb[ca, on = c('codice_istat', 'anno')]
  ind <- L[, .(n_comuni = .N, n_esistenti = sum(stato != 'COMUNE_NON_ESISTENTE'),
               n_osservati = sum(stato == 'OSSERVATO'), n_aggregati = sum(stato == 'DATO_AGGREGATO'),
               n_assenti_fonte = sum(stato == 'ASSENTE_IN_FONTE'), n_mancanti = sum(stato == 'MANCANTE'),
               teorico = teorico[1], acquisito = acquisito[1]), by = .(indicatore, dimensione, anno)][
    , `:=`(copertura = data.table::fifelse(teorico & acquisito, n_osservati / n_esistenti, NA_real_),
           stato = data.table::fcase(!teorico, 'ANNO_NON_RILEVATO', !acquisito, 'FONTE_NON_ACQUISITA',
                                     n_osservati == 0, 'NESSUN_DATO', default = 'ACQUISITO'))][]
  anno <- ind[, .(n_ind_teorici = sum(teorico), n_ind_acquisiti = sum(teorico & acquisito),
                  n_ind_copertura_soglia = sum(teorico & acquisito & copertura >= CONFIG$cov_soglia, na.rm = TRUE),
                  copertura_media_acquisiti = mean(copertura[teorico & acquisito], na.rm = TRUE)), by = anno][
    ca[, .(completezza_teorica_media = mean(completezza_teorica, na.rm = TRUE),
           completezza_acquisita_media = mean(completezza_acquisita, na.rm = TRUE)), by = anno], on = 'anno']
  dimanno <- ind[teorico == TRUE, .(n_ind_teorici = .N, n_ind_acquisiti = sum(acquisito),
                                    copertura_media_su_teorici = mean(data.table::fifelse(acquisito, copertura, 0)),
                                    copertura_media_su_acquisiti = mean(copertura[acquisito], na.rm = TRUE)),
                 by = .(anno, dimensione)]
  stati <- L[, .N, by = .(anno, stato)][order(anno, stato)]
  list(comune_anno = ca[order(codice_istat, anno)], comune_anno_dim = cd[order(codice_istat, anno, dimensione)],
       indicatore_anno = ind[order(dimensione, indicatore, anno)], anno = anno[order(anno)],
       dimensione_anno = dimanno[order(anno, dimensione)], stati = stati)
}
# Finestre temporali: quota di indicatori con copertura >= soglia in TUTTI gli anni della finestra.
time_windows <- function(ind, years, min_len = 2L) {
  ids <- unique(ind$indicatore); out <- list()
  ok <- ind[, .(ok = isTRUE(teorico & acquisito & copertura >= CONFIG$cov_soglia)), by = .(indicatore, anno)]
  for (a in years) for (b in years[years >= a + min_len - 1L]) {
    w <- ok[anno >= a & anno <= b & anno %in% years, .(tutti = all(ok) && .N == sum(years >= a & years <= b)), by = indicatore]
    out[[length(out) + 1]] <- data.table::data.table(inizio = a, fine = b, lunghezza = b - a + 1L,
                                                     n_ind_pieni = sum(w$tutti), quota_ind_pieni = sum(w$tutti) / length(ids))
  }
  data.table::rbindlist(out)
}

# ---- 12. CONTROLLI DI QUALITA' -------------------------------------------------------------
qc_panel <- function(panel, base, spec, L, extra = list()) {
  d <- anyDuplicated(panel[c('codice_istat', 'anno')])
  add_qc('unicita comune x anno', 'panel', if (d) 'FAIL' else 'OK', sum(duplicated(panel[c('codice_istat', 'anno')])))
  bad <- sum(!grepl('^[0-9]{6}$', panel$codice_istat))
  add_qc('formato codice ISTAT 6 cifre', 'panel', if (bad) 'FAIL' else 'OK', bad)
  add_qc('universo comuni', 'base', if (nrow(base) >= CONFIG$n_min_comuni) 'OK' else 'FAIL', nrow(base))
  add_qc('prefisso provincia valido', 'base', if (all(substr(base$codice_istat, 1, 3) %in% unique(substr(base$codice_istat, 1, 3)))) 'OK' else 'FAIL',
         length(unique(substr(base$codice_istat, 1, 3))), 'province distinte')
  rng <- list()
  for (i in seq_len(nrow(spec))) {
    id <- spec$indicatore[i]; if (!id %in% names(panel)) next
    x <- panel[[id]]; if (all(is.na(x))) next
    u <- spec$unita[i]
    if (u == '%') {
      n_out <- sum(x < 0 | x > 100, na.rm = TRUE)
      add_qc('percentuale in [0,100]', id, if (n_out) 'FAIL' else 'OK', n_out)
      if (max(x, na.rm = TRUE) <= 1) add_qc('scala percentuale', id, 'WARN', NA, 'max <= 1: possibile proporzione 0-1')
      if (n_out) rng[[id]] <- panel[!is.na(x) & (x < 0 | x > 100), c('codice_istat', 'anno', id)] |> rename(valore = 3) |> mutate(indicatore = id)
    } else if (u %in% c('t', 'ha', 'kg/ab/anno', 'abitanti', 'euro', 'ha/anno')) {
      n_neg <- sum(x < 0, na.rm = TRUE)
      add_qc('non negativita', id, if (n_neg) 'FAIL' else 'OK', n_neg)
    }
    # anni con dati fuori dagli anni teorici
    ya <- unique(panel$anno[!is.na(x)]); fuori <- setdiff(ya, spec$anni_teorici[[i]])
    add_qc('coerenza annualita', id, if (length(fuori)) 'FAIL' else 'OK', length(fuori), paste(fuori, collapse = ';'))
  }
  write_diag(bind_rows(rng), 'qc_valori_fuori_intervallo.csv')
  # copertura nazionale: indicatori-anno acquisiti con pochi comuni (solo capoluoghi/province?)
  cov <- L[in_completezza == TRUE & teorico & acquisito, .(n_oss = sum(stato == 'OSSERVATO'), n = sum(stato != 'COMUNE_NON_ESISTENTE')), by = .(indicatore, anno)]
  low <- cov[n_oss < 0.5 * n]
  add_qc('copertura nazionale (>=50% comuni)', 'indicatore x anno', if (nrow(low)) 'WARN' else 'OK', nrow(low),
         paste(head(paste0(low$indicatore, ':', low$anno), 30), collapse = ' '))
  write_diag(as_tibble(low), 'qc_copertura_non_nazionale.csv')
  # copertura per regione: regione con 0 osservazioni mentre altre ne hanno
  if ('regione' %in% names(base) && !all(is.na(base$regione))) {
    R <- data.table::as.data.table(base[, c('codice_istat', 'regione')])[L[in_completezza == TRUE & teorico & acquisito], on = 'codice_istat']
    rr <- R[, .(quota = mean(stato == 'OSSERVATO')), by = .(indicatore, anno, regione)]
    z <- rr[, .(n_reg_zero = sum(quota == 0), regioni = paste(regione[quota == 0], collapse = ';')), by = .(indicatore, anno)][n_reg_zero > 0]
    add_qc('regioni senza osservazioni', 'indicatore x anno', if (nrow(z)) 'WARN' else 'OK', nrow(z))
    write_diag(as_tibble(z), 'qc_regioni_senza_dati.csv')
    write_diag(as_tibble(rr), 'copertura_regione_indicatore_anno.csv')
  }
  # celle osservate per comuni non esistenti: impossibile
  ne <- L[stato == 'COMUNE_NON_ESISTENTE' & !is.na(valore)]
  add_qc('valori su comuni non esistenti', 'fonti anno_corrente', if (nrow(ne)) 'FAIL' else 'OK', nrow(ne))
  # aggregazioni: nessun valore sui membri
  if ('rifiuti_stato' %in% names(panel)) {
    wid <- intersect(spec$indicatore[spec$sorgente == 'waste'], names(panel))
    m <- panel[panel$rifiuti_stato %in% c('in_aggregazione', 'capofila_aggregazione'), setdiff(wid, 'popolazione_ispra'), drop = FALSE]
    n_v <- if (nrow(m)) sum(!is.na(as.matrix(m))) else 0L
    add_qc('aggregazioni non attribuite ai comuni', 'ISPRA rifiuti', if (n_v) 'FAIL' else 'OK', n_v,
           paste0(sum(panel$rifiuti_stato %in% c('in_aggregazione', 'capofila_aggregazione')), ' comune-anno in aggregazione'))
  }
  # coerenze tra fonti / unita'
  cross <- function(a, b, nome, tol) {
    if (!all(c(a, b) %in% names(panel))) return(invisible())
    w <- !is.na(panel[[a]]) & !is.na(panel[[b]]); if (sum(w) < 50) return(invisible())
    dif <- abs(panel[[a]][w] - panel[[b]][w])
    add_qc(nome, paste(a, 'vs', b), if (stats::median(dif) > tol) 'WARN' else 'OK', sum(w),
           sprintf('mediana |diff| = %.3f; quota |diff|>%s = %.3f; cor = %.3f', stats::median(dif), tol, mean(dif > tol),
                   suppressWarnings(stats::cor(panel[[a]][w], panel[[b]][w]))))
  }
  cross('rd_pct_istat', 'rd_pct_ispra', 'coerenza RD% ISTAT/ISPRA', 1)
  if (all(c('ru_totale_t', 'popolazione_ispra', 'ru_procapite_kg') %in% names(panel)) && !isTRUE(.S$procapite_derivato)) {
    panel$.pc <- panel$ru_totale_t * 1000 / panel$popolazione_ispra
    w <- !is.na(panel$.pc) & !is.na(panel$ru_procapite_kg) & panel$ru_procapite_kg > 0
    if (sum(w) > 50) { r <- stats::median(panel$.pc[w] / panel$ru_procapite_kg[w])
      add_qc('unita RU t vs kg/ab', 'ISPRA rifiuti', if (abs(r - 1) > 0.05) 'FAIL' else 'OK', sum(w),
             sprintf('mediana (RU_t*1000/pop)/RU_procapite = %.4f (atteso 1)', r)) }
  }
  if (all(c('suolo_consumato_ha', 'suolo_consumato_pct_istat', 'area_km2') %in% names(panel))) {
    panel$.sp <- 100 * panel$suolo_consumato_ha / (panel$area_km2 * 100)
    cross('.sp', 'suolo_consumato_pct_istat', 'coerenza suolo ha/area vs % ISTAT', 1)
  }
  for (nm in names(extra)) add_qc(nm, extra[[nm]]$oggetto, extra[[nm]]$esito, extra[[nm]]$n, extra[[nm]]$dettaglio)
  invisible(.S$qc)
}

# ---- 13. GRAFICI E MAPPE -------------------------------------------------------------------
COL_SEQ <- c('#eef3fb', '#1d4f91')   # sequenziale monotono (chiaro -> scuro)
COL_NA  <- '#d9d9d9'; COL_FAIL <- '#7f7f7f'
plot_heatmap <- function(ind, spec, file) {
  d <- as_tibble(ind) |> left_join(select(spec, indicatore, dim2 = dimensione), by = 'indicatore') |>
    mutate(lab = paste0(indicatore, ' [', dim2, ']'),
           lab = factor(lab, levels = rev(sort(unique(lab)))),
           txt = case_when(stato == 'FONTE_NON_ACQUISITA' ~ 'X', stato == 'ACQUISITO' ~ sprintf('%.0f', 100 * copertura), TRUE ~ ''))
  p <- ggplot(d, aes(factor(anno), lab)) +
    geom_tile(aes(fill = copertura), colour = 'white', linewidth = .4) +
    geom_tile(data = filter(d, stato == 'FONTE_NON_ACQUISITA'), fill = COL_FAIL, colour = 'white', linewidth = .4) +
    geom_text(aes(label = txt, colour = !is.na(copertura) & copertura > .6), size = 2.3, show.legend = FALSE) +
    scale_colour_manual(values = c(`TRUE` = 'white', `FALSE` = '#222222')) +
    scale_fill_gradient(low = COL_SEQ[1], high = COL_SEQ[2], limits = c(0, 1), na.value = COL_NA,
                        labels = scales::percent, name = 'Comuni con dato') +
    labs(x = 'Anno', y = NULL, title = 'Copertura comunale per indicatore e anno',
         subtitle = 'Numeri = % comuni esistenti con dato | grigio chiaro: anno non rilevato dalla fonte | grigio scuro con X: fonte prevista ma non acquisita') +
    theme_minimal(base_size = 10) + theme(panel.grid = element_blank(), axis.text.x = element_text(angle = 45, hjust = 1))
  ggsave(file, p, width = 14, height = max(6, 0.28 * length(unique(d$lab)) + 2), dpi = 200, bg = 'white')
}
plot_time <- function(anno_tbl, dimanno, dir) {
  a <- as_tibble(anno_tbl) |> mutate(quota_acquisiti = n_ind_acquisiti / pmax(n_ind_teorici, 1)) |>
    select(anno, `Indicatori acquisiti / teorici` = quota_acquisiti,
           `Completezza media (denominatore teorico)` = completezza_teorica_media,
           `Completezza media (denominatore acquisito)` = completezza_acquisita_media) |>
    pivot_longer(-anno, names_to = 'misura', values_to = 'valore')
  p1 <- ggplot(a, aes(anno, valore, colour = misura)) + geom_line(linewidth = .7, na.rm = TRUE) + geom_point(size = 2.2, na.rm = TRUE) +
    scale_y_continuous(limits = c(0, 1), labels = scales::percent) + scale_x_continuous(breaks = unique(a$anno)) +
    scale_colour_manual(values = c('#1d4f91', '#c05a1b', '#4f9a62'), name = NULL) +
    labs(x = 'Anno', y = NULL, title = 'Copertura informativa per anno',
         subtitle = 'Il denominatore teorico conta come mancanti le fonti non acquisite') +
    theme_minimal(base_size = 11) + theme(legend.position = 'top', axis.text.x = element_text(angle = 45, hjust = 1),
                                          panel.grid.minor = element_blank())
  ggsave(file.path(dir, 'serie_copertura_anno.png'), p1, width = 11, height = 6, dpi = 200, bg = 'white')
  b <- as_tibble(dimanno)
  p2 <- ggplot(b, aes(anno, copertura_media_su_teorici)) + geom_col(fill = COL_SEQ[2], width = .7) +
    facet_wrap(~dimensione, ncol = 1) + scale_y_continuous(limits = c(0, 1), labels = scales::percent) +
    scale_x_continuous(breaks = unique(b$anno)) +
    labs(x = 'Anno', y = 'Copertura media (indicatori teorici)', title = 'Copertura per dimensione e anno') +
    theme_minimal(base_size = 10) + theme(axis.text.x = element_text(angle = 45, hjust = 1), panel.grid.minor = element_blank())
  ggsave(file.path(dir, 'serie_copertura_dimensione.png'), p2, width = 10, height = 9, dpi = 200, bg = 'white')
}
plot_windows <- function(win, file) {
  p <- ggplot(as_tibble(win), aes(factor(inizio), factor(fine), fill = quota_ind_pieni)) + geom_tile(colour = 'white') +
    geom_text(aes(label = n_ind_pieni), size = 2.4) +
    scale_fill_gradient(low = COL_SEQ[1], high = COL_SEQ[2], limits = c(0, 1), labels = scales::percent, name = 'Indicatori\npieni') +
    labs(x = 'Anno iniziale', y = 'Anno finale', title = 'Finestre temporali: indicatori con copertura >= soglia in tutti gli anni',
         subtitle = paste0('Soglia = ', 100 * CONFIG$cov_soglia, '% comuni; numero = indicatori disponibili su tutta la finestra')) +
    theme_minimal(base_size = 10) + theme(panel.grid = element_blank())
  ggsave(file, p, width = 10, height = 8, dpi = 200, bg = 'white')
}
plot_map <- function(g, z, v, yr, file, titolo) {
  gm <- dplyr::left_join(g, z, by = 'codice_istat')
  if (all(is.na(gm[[v]]))) return(invisible(FALSE))
  p <- ggplot(gm) + geom_sf(aes(fill = .data[[v]]), colour = NA) +
    scale_fill_gradient(low = COL_SEQ[1], high = COL_SEQ[2], limits = c(0, 1), na.value = COL_NA,
                        labels = scales::percent, name = 'Completezza') +
    coord_sf(datum = NA) +
    labs(title = paste0(titolo, ' - ', yr),
         subtitle = 'Denominatore: indicatori teorici per l\'anno (fonti fallite = mancanti); confini ISTAT 31/12/2024',
         caption = 'Fonti: ISTAT, ISPRA. Nessuna imputazione.') +
    theme_void(base_size = 11) + theme(plot.title = element_text(face = 'bold'), plot.caption = element_text(size = 7))
  ggsave(file, p, width = 8, height = 9.5, dpi = 200, bg = 'white')
  invisible(TRUE)
}

# ---- 14. VERIFICA ENDPOINT ------------------------------------------------------------------
verify_endpoints <- function() {
  urls <- c(GEOM_URL, VAR_URL, paste0(ISTAT_BASE, ISTAT_FILES), paste0(SOIL_API, '?f=json'), waste_url(range(CONFIG$waste_years)))
  bind_rows(lapply(urls, function(u) {
    r <- tryCatch({
      resp <- httr2::req_perform(http_req(u, 60) |> httr2::req_method('HEAD'))
      tibble(http_status = httr2::resp_status(resp),
             content_type = httr2::resp_header(resp, 'content-type') %||% NA_character_,
             content_length = httr2::resp_header(resp, 'content-length') %||% NA_character_, errore = NA_character_)
    }, error = function(e) tibble(http_status = NA_integer_, content_type = NA_character_, content_length = NA_character_, errore = conditionMessage(e)))
    mutate(r, url = u, .before = 1)
  }))
}

# ---- 15. PIPELINE ---------------------------------------------------------------------------
run_pipeline <- function(root = ROOT) {
  RAW <- file.path(root, 'raw'); OUT <- file.path(root, 'output_v3')
  dir.create(RAW, recursive = TRUE, showWarnings = FALSE); dir.create(OUT, recursive = TRUE, showWarnings = FALSE)
  init_state(OUT)
  spec <- build_spec()
  if (CONFIG$do_verifica) write_diag(verify_endpoints(), 'verifica_endpoint.csv')

  # A. geografia
  geo <- if (CONFIG$do_geometry) tryCatch(load_geometry(RAW), error = function(e) { add_error('geometria', e); NULL }) else NULL
  g <- geo$g
  if (!is.null(g)) {
    ad <- tryCatch(adjacency(g), error = function(e) { add_error('contiguita', e); NULL })
    if (!is.null(ad)) {
      readr::write_csv(ad$adj, file.path(OUT, 'contiguita_comuni.csv'))
      write_diag(ad$isolati, 'comuni_senza_vicini.csv')
      saveRDS(list(queen = sf::st_touches(g), rook = sf::st_relate(g, g, pattern = 'F***1****'), codici = g$codice_istat),
              file.path(OUT, 'contiguita_comuni.rds'))
    }
    gp <- file.path(OUT, 'comuni_geometrie_2024.gpkg'); unlink(gp)
    sf::st_write(dplyr::left_join(g, select(geo$base, codice_istat, provincia, sigla, regione), by = 'codice_istat'), gp, quiet = TRUE)
  }
  # B. variazioni
  var <- if (CONFIG$do_variazioni) tryCatch(read_variazioni(RAW), error = function(e) { add_error('variazioni ISTAT', e, 'AVVISO'); NULL }) else NULL
  if (!is.null(var)) { write_diag(var$tipi, 'variazioni_tipi.csv'); write_diag(var$ricodifiche, 'variazioni_ricodifiche.csv') }

  # C. ISTAT
  istat <- list(); paths <- list(); scelte <- list(); titoli <- list()
  if (CONFIG$do_istat) {
    for (k in names(ISTAT_FILES)) paths[[k]] <- tryCatch(fetch(paste0(ISTAT_BASE, ISTAT_FILES[[k]]), file.path(RAW, ISTAT_FILES[[k]]), 'xlsx', CONFIG$min_bytes$xlsx),
                                                          error = function(e) { add_error(paste('download ISTAT', k), e); NA_character_ })
    vc <- geo$base$codice_istat
    for (i in seq_len(nrow(SPEC_ISTAT))) {
      z <- SPEC_ISTAT[i, ]; fp <- paths[[z$file]]
      if (is.na(fp)) { add_error(z$indicatore, 'file sorgente non scaricato'); next }
      r <- tryCatch(read_istat_table(fp, z$tavola, z$indicatore, z$anni_teorici[[1]], vc), error = function(e) { add_error(z$indicatore, e); NULL })
      if (is.null(r)) next
      if (length(r$extra)) logmsg('ISTAT ', z$indicatore, ': anni aggiuntivi trovati ', paste(r$extra, collapse = ','))
      if (length(r$mancanti)) add_error(z$indicatore, paste('anni attesi assenti nel file:', paste(r$mancanti, collapse = ',')), 'AVVISO')
      istat[[z$indicatore]] <- r
      scelte[[z$indicatore]] <- mutate(r$scelte, indicatore = z$indicatore, foglio = r$sheet)
      titoli[[z$indicatore]] <- r$title
    }
    write_diag(bind_rows(scelte), 'istat_colonne_scelte.csv')
    if (CONFIG$do_catalogo) write_diag(tryCatch(istat_catalog(paths, vc), error = function(e) { add_error('catalogo ISTAT', e); NULL }), 'catalogo_tavole_istat.csv')
  }
  # anni teorici ISTAT = attesi U trovati (massimizza copertura, nulla di inventato)
  for (id in names(istat)) {
    w <- which(spec$indicatore == id)
    spec$anni_teorici[[w]] <- sort(unique(c(spec$anni_teorici[[w]], istat[[id]]$years_found)))
  }
  # universo
  base <- geo$base
  if (is.null(base)) {
    pp <- istat[['popolazione']]$data
    if (is.null(pp)) stop('Universo comuni non determinabile: geometrie e popolazione ISTAT assenti')
    base <- pp |> filter(anno == max(anno)) |> transmute(codice_istat, comune = nome, cod_reg = NA_character_,
              cod_uts = substr(codice_istat, 1, 3), area_km2 = NA_real_, provincia = NA_character_, sigla = NA_character_, regione = NA_character_)
    add_error('universo', 'geometrie assenti: universo da popolazione ISTAT ultimo anno', 'AVVISO')
  }
  if (nrow(base) < CONFIG$n_min_comuni || anyDuplicated(base$codice_istat)) stop('Universo comuni incompleto')

  # D. ISPRA suolo
  soil <- if (CONFIG$do_soil) tryCatch(read_soil(RAW), error = function(e) { add_error('ISPRA suolo', e); NULL }) else NULL
  # E. ISPRA rifiuti
  waste <- if (CONFIG$do_waste) tryCatch(read_waste(RAW), error = function(e) { add_error('ISPRA rifiuti', e); NULL }) else NULL
  hw <- NULL
  if (!is.null(waste)) {
    hw <- harmonize_codes(waste$comuni, base, var)
    .S$procapite_derivato <- any(waste$colmap$esito == 'DERIVATO')
    write_diag(waste$meta, 'ispra_rifiuti_struttura_file.csv'); write_diag(waste$colmap, 'ispra_rifiuti_mappa_colonne.csv')
    write_diag(waste$header, 'ispra_rifiuti_intestazioni.csv'); write_diag(waste$anomalie, 'ispra_rifiuti_righe_anomale_o_segnalate.csv')
    readr::write_csv(waste$aggregazioni, file.path(OUT, 'ispra_rifiuti_aggregazioni_sovracomunali.csv'), na = 'NA')
    readr::write_csv(waste$membri, file.path(OUT, 'ispra_rifiuti_membri_aggregazioni.csv'), na = 'NA')
    write_diag(hw$fuori, 'ispra_rifiuti_codici_fuori_geografia_2024.csv'); write_diag(hw$nomi, 'ispra_rifiuti_nomi_incoerenti.csv')
  }

  # F. assemblaggio
  years <- CONFIG$years[vapply(CONFIG$years, function(y) any(vapply(spec$anni_teorici, function(a) y %in% a, TRUE)), TRUE)]
  panel <- tidyr::crossing(codice_istat = base$codice_istat, anno = years) |>
    left_join(select(base, codice_istat, comune, provincia, sigla, regione, cod_reg, area_km2), by = 'codice_istat')
  presenza <- list(); acq <- list(); fuori_istat <- list()
  for (id in names(istat)) {
    d <- istat[[id]]$data |> select(-any_of('nome')) |> filter(anno %in% years)
    panel <- left_join(panel, d, by = c('codice_istat', 'anno'))
    presenza[[id]] <- d |> transmute(indicatore = id, codice_istat, anno)
    acq[[id]] <- tibble(indicatore = id, anno = istat[[id]]$years_found, acquisito = TRUE)
    fz <- istat[[id]]$data |> filter(!codice_istat %in% base$codice_istat)
    if (nrow(fz)) { add_error(id, paste(n_distinct(fz$codice_istat), 'codici ISTAT non in geografia 2024: esclusi, vedi diagnostica'), 'AVVISO')
                    fuori_istat[[id]] <- mutate(fz |> select(codice_istat, anno, nome), indicatore = id) }
  }
  write_diag(bind_rows(fuori_istat), 'istat_codici_fuori_geografia_2024.csv')
  pres <- bind_rows(presenza)
  if (!is.null(soil)) {
    panel <- left_join(panel, soil$data, by = c('codice_istat', 'anno'))
    pres <- bind_rows(pres, inner_join(soil$presenza, soil$acq, by = 'anno', relationship = 'many-to-many') |> select(indicatore, codice_istat, anno))
    acq$soil <- soil$acq
  }
  aggr_members <- NULL
  if (!is.null(hw)) {
    wid <- intersect(WASTE_MEAS$id, names(hw$dentro))
    wd <- hw$dentro |> transmute(codice_istat, anno, across(all_of(wid)),
                                 rifiuti_stato = case_when(tipo_record == 'rinvio_aggregazione' ~ 'in_aggregazione',
                                                           tipo_record == 'capofila_aggregazione' ~ 'capofila_aggregazione', TRUE ~ 'comunale'),
                                 rifiuti_aggregazione = aggregazione, rifiuti_codice_fonte = codice_fonte,
                                 rifiuti_ricodificato = ricodificato, rifiuti_flag_duplicato = flag_duplicato)
    panel <- left_join(panel, wd, by = c('codice_istat', 'anno'))
    pres <- bind_rows(pres, inner_join(select(wd, codice_istat, anno), waste$acq, by = 'anno', relationship = 'many-to-many') |> select(indicatore, codice_istat, anno))
    acq$waste <- waste$acq
    aggr_members <- filter(wd, rifiuti_stato %in% c('in_aggregazione', 'capofila_aggregazione'))
  }
  for (id in spec$indicatore) if (!id %in% names(panel)) panel[[id]] <- NA_real_
  esist <- if (!is.null(var)) esistenza_tbl(base$codice_istat, years, var) else NULL
  if (!is.null(esist)) panel <- left_join(panel, esist, by = c('codice_istat', 'anno')) else
    panel <- mutate(panel, comune_esistente = NA, istituito_nell_anno = NA)
  panel <- panel |> mutate(geografia_riferimento = 'ISTAT 31/12/2024',
                           fonti_non_armonizzate = 'ISPRA rifiuti (confini anno corrente)') |> arrange(codice_istat, anno)
  assert_keys(panel, 'panel finale')
  stopifnot(nrow(panel) == nrow(base) * length(years))

  # G. stati e completezza
  acq_t <- bind_rows(acq)
  L <- cell_status(panel, spec, acq_t, pres, esist, aggr_members)
  C <- completeness(L)
  win <- time_windows(C$indicatore_anno, years)

  # H. QC
  extra <- list()
  if (!is.null(hw)) extra$`codici ISPRA fuori geografia 2024` <- list(oggetto = 'ISPRA rifiuti', esito = if (nrow(hw$fuori)) 'WARN' else 'OK', n = nrow(hw$fuori),
                                    dettaglio = 'osservazioni non attribuite (soppressi/variati): vedi diagnostica')
  if (!is.null(hw)) extra$`nomi incoerenti codice-anno` <- list(oggetto = 'ISPRA rifiuti', esito = if (nrow(hw$nomi)) 'WARN' else 'OK', n = nrow(hw$nomi), dettaglio = '')
  if (!is.null(waste)) extra$`righe anomale ISPRA` <- list(oggetto = 'ISPRA rifiuti', esito = if (sum(waste$meta$n_anomali)) 'WARN' else 'OK', n = sum(waste$meta$n_anomali), dettaglio = 'conservate in diagnostica')
  if (is.null(var)) extra$`esistenza comuni` <- list(oggetto = 'variazioni ISTAT', esito = 'WARN', n = NA, dettaglio = 'variazioni non lette: COMUNE_NON_ESISTENTE non determinabile')
  qc_panel(panel, base, spec, L, extra)

  # I. dizionario
  anni_acq <- acq_t |> group_by(indicatore) |> summarise(anni_acquisiti = paste(sort(unique(anno)), collapse = ';'), .groups = 'drop')
  anni_dat <- bind_rows(lapply(intersect(spec$indicatore, names(panel)), function(id) {
    ok <- !is.na(panel[[id]]); if (!any(ok)) return(NULL)
    tibble(indicatore = id, anni_con_dati = paste(sort(unique(panel$anno[ok])), collapse = ';'), n_osservazioni = sum(ok)) }))
  dict <- spec |> mutate(anni_teorici = vapply(anni_teorici, function(a) paste(a, collapse = ';'), ''),
                         titolo_tavola_fonte = vapply(indicatore, function(i) titoli[[i]] %||% NA_character_, '')) |>
    left_join(anni_acq, by = 'indicatore') |> left_join(anni_dat, by = 'indicatore') |>
    mutate(stato_estrazione = if_else(is.na(anni_acquisiti), 'FONTE_NON_ACQUISITA', 'acquisito')) |>
    select(indicatore, descrizione, dimensione, unita, polarita, fonte, url, campo, geografia, in_completezza,
           anni_teorici, anni_acquisiti, anni_con_dati, n_osservazioni, stato_estrazione, titolo_tavola_fonte)

  # J. scritture
  readr::write_csv(panel, file.path(OUT, 'panel_comuni.csv'), na = 'NA')
  saveRDS(panel, file.path(OUT, 'panel_comuni.rds'))
  for (y in intersect(CONFIG$focus_years, years)) readr::write_csv(filter(panel, anno == y), file.path(OUT, paste0('panel_comuni_', y, '.csv')), na = 'NA')
  readr::write_csv(dict, file.path(OUT, 'dizionario_indicatori.csv'), na = 'NA')
  readr::write_csv(as_tibble(C$indicatore_anno), file.path(OUT, 'completezza_indicatore_anno.csv'), na = 'NA')
  readr::write_csv(as_tibble(C$comune_anno), file.path(OUT, 'completezza_comune_anno.csv'), na = 'NA')
  readr::write_csv(as_tibble(C$comune_anno_dim), file.path(OUT, 'completezza_comune_anno_dimensione.csv'), na = 'NA')
  readr::write_csv(as_tibble(C$dimensione_anno), file.path(OUT, 'completezza_dimensione_anno.csv'), na = 'NA')
  readr::write_csv(as_tibble(C$anno), file.path(OUT, 'completezza_anno.csv'), na = 'NA')
  readr::write_csv(as_tibble(C$stati), file.path(OUT, 'stati_celle_anno.csv'), na = 'NA')
  readr::write_csv(as_tibble(win), file.path(OUT, 'finestre_temporali.csv'), na = 'NA')
  saveRDS(L[, .(codice_istat, anno, indicatore, stato)], file.path(OUT, 'stato_celle_long.rds'))
  tryCatch({
    plot_heatmap(C$indicatore_anno, spec, file.path(OUT, 'heatmap_copertura_indicatore_anno.png'))
    plot_time(C$anno, C$dimensione_anno, OUT)
    plot_windows(win, file.path(OUT, 'finestre_temporali.png'))
  }, error = function(e) add_error('grafici', e))
  if (!is.null(g)) for (y in intersect(CONFIG$focus_years, years)) tryCatch({
    z <- as_tibble(C$comune_anno)[C$comune_anno$anno == y, ]
    plot_map(g, z, 'completezza_teorica', y, file.path(OUT, paste0('mappa_completezza_totale_', y, '.png')), 'Completezza complessiva')
    plot_map(g, z, 'completezza_teorica_ambientale', y, file.path(OUT, paste0('mappa_completezza_ambientale_', y, '.png')), 'Completezza ambientale')
    dest <- file.path(OUT, paste0('completezza_', y, '.gpkg')); unlink(dest)
    sf::st_write(dplyr::left_join(g, z, by = 'codice_istat'), dest, quiet = TRUE)
  }, error = function(e) add_error(paste('mappe', y), e))
  readr::write_csv(.S$qc, file.path(OUT, 'controlli_qualita.csv'), na = 'NA')
  readr::write_csv(.S$err, file.path(OUT, 'errori_pipeline.csv'), na = 'NA')
  readr::write_csv(.S$dl, file.path(OUT, 'download_log.csv'), na = 'NA')
  readr::write_csv(tibble(sorgente = c('geometria', 'variazioni', paste0('istat_', names(ISTAT_FILES)), 'ispra_suolo', 'ispra_rifiuti'),
                          url = c(GEOM_URL, VAR_URL, paste0(ISTAT_BASE, ISTAT_FILES), SOIL_API, waste_url('ANNO')),
                          acquisita = c(!is.null(g), !is.null(var), vapply(names(ISTAT_FILES), function(k) !is.na(paths[[k]] %||% NA), TRUE), !is.null(soil), !is.null(waste)),
                          ultimo_accesso = format(Sys.time())), file.path(OUT, 'manifest_fonti.csv'))
  readr::write_csv(FONTI_CANDIDATE, file.path(OUT, 'fonti_candidate_da_verificare.csv'))
  logmsg('FINE | comuni=', nrow(base), ' | anni=', paste(range(years), collapse = '-'),
         ' | indicatori acquisiti=', sum(dict$stato_estrazione == 'acquisito'), '/', nrow(dict),
         ' | errori=', sum(.S$err$livello == 'ERRORE'), ' | QC FAIL=', sum(.S$qc$esito == 'FAIL'))
  logmsg('Non acquisiti: ', paste(dict$indicatore[dict$stato_estrazione != 'acquisito'], collapse = ', '))
  invisible(list(panel = panel, dict = dict, completezza = C, qc = .S$qc, errori = .S$err))
}

# Fonti aggiuntive: NON integrate finche' endpoint/formato/granularita'/annualita' non verificati.
FONTI_CANDIDATE <- tribble(
  ~tema, ~fonte, ~url_da_verificare, ~granularita_attesa, ~annualita_attesa, ~stato, ~nota,
  'Rinnovabili', 'GSE Atlaimpianti / open data', 'https://atla.gse.it/atlaimpianti/ ; https://www.gse.it/dati-e-scenari', 'impianto -> comune (da verificare)', 'stock corrente', 'NON INTEGRATA', 'verificare export comunale storico; non usare dati provinciali',
  'Rischio idrogeologico', 'ISPRA IdroGEO', 'https://idrogeo.isprambiente.it', 'comunale', 'edizioni (non annuale)', 'NON INTEGRATA', 'attribuire per edizione, MAI replicare su anni',
  'Aree protette', 'MASE EUAP + Natura 2000', 'https://www.mase.gov.it ; https://www.eea.europa.eu (Natura 2000)', 'poligoni -> overlay comuni', 'release (EUAP statico)', 'NON INTEGRATA', 'calcolo % area comunale con sf::st_intersection',
  'Parco veicolare', 'ACI Autoritratto', 'https://www.aci.it/laci/studi-e-ricerche/dati-e-statistiche/autoritratto.html', 'comunale (da verificare)', 'annuale', 'NON INTEGRATA', 'ISTAT AMdC gia include motorizzazione e pre-Euro4 da fonte ACI',
  'Ambiente urbano', 'ISTAT Dati ambientali nelle citta', 'https://www.istat.it', 'solo capoluoghi', 'annuale', 'ESCLUSA', 'non copre tutti i comuni',
  'Verde urbano', 'ISPRA/ISTAT verde urbano', 'https://www.istat.it', 'solo capoluoghi', 'annuale', 'ESCLUSA', 'non copre tutti i comuni',
  'Altre tavole ISTAT', 'ISTAT A misura di Comune', 'output_v3/diagnostica/catalogo_tavole_istat.csv', 'comunale se copertura_nazionale=TRUE', 'vedi catalogo', 'DA SELEZIONARE', 'aggiungere a SPEC_ISTAT con unita e polarita')

if (!identical(getOption('panel.run'), FALSE)) RESULT <- run_pipeline()
