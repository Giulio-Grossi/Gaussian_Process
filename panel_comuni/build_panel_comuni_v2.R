#!/usr/bin/env Rscript
# PANEL SOSTENIBILITA' COMUNI ITALIANI - v2 (02 novembre 2026)
# 1) ISTAT A misura di Comune, tavole storiche armonizzate al 31/12/2024
# 2) ISPRA consumo di suolo, servizio ArcGIS comunale, anni 2006, 2012, 2015-2024
# 3) ISPRA Catasto rifiuti: CSV annuali 2010-2024, download scoperto dalla pagina ufficiale
# 4) Mappa completezza geografica e matrice di copertura indicatore x anno
# NESSUNA IMPUTAZIONE. Nessuna pretesa di dati aggiornati al 2025 per il panel 2024.
# Richiede: R >= 4.2, connessione Internet, sistema con librerie sf (GDAL/GEOS/PROJ).

options(timeout = max(900, getOption('timeout')))
CONFIG <- list(
  years = c(2006L, 2010:2024),
  focus_years = c(2023L, 2024L),
  do_geometry = TRUE,
  do_waste = TRUE,
  do_soil = TRUE,
  redownload = FALSE,
  n_min_comuni = 6500L
)
args0 <- commandArgs(trailingOnly = FALSE)
arg_file <- grep('^--file=', args0, value = TRUE)
ROOT <- if (length(arg_file)) dirname(normalizePath(sub('^--file=', '', arg_file[1]))) else getwd()
RAW <- file.path(ROOT, 'raw'); OUT <- file.path(ROOT, 'output_v2')
dir.create(RAW, recursive = TRUE, showWarnings = FALSE)
dir.create(OUT, recursive = TRUE, showWarnings = FALSE)

pkgs <- c('readxl','dplyr','tidyr','readr','stringr','tibble','ggplot2',
          'httr2','jsonlite','rvest','xml2','data.table')
if (CONFIG$do_geometry) pkgs <- c(pkgs, 'sf')
for (p in unique(pkgs)) {
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = 'https://cloud.r-project.org')
  if (!requireNamespace(p, quietly = TRUE)) stop('Pacchetto necessario non installabile: ', p)
}
suppressPackageStartupMessages({
  library(dplyr); library(tidyr); library(readr); library(tibble);
  library(ggplot2); library(stringr)
})

LOG <- file.path(OUT, 'pipeline_log.txt')
cat('PIPELINE v2 | ', as.character(Sys.time()), '\n', file = LOG)
logmsg <- function(...) {
  s <- paste0(..., collapse = '')
  message(s)
  cat(s, '\n', file = LOG, append = TRUE)
}
err_tbl <- tibble::tibble(componente = character(), dettaglio = character())
add_error <- function(component, error) {
  msg <- if (inherits(error, 'condition')) conditionMessage(error) else as.character(error)
  logmsg('ERRORE [', component, ']: ', msg)
  err_tbl <<- dplyr::bind_rows(err_tbl, tibble::tibble(componente=component, dettaglio=msg))
}
clean_text <- function(x) {
  x <- iconv(as.character(x), from='', to='ASCII//TRANSLIT', sub='')
  tolower(trimws(gsub('[[:space:]]+', ' ', x)))
}
code6 <- function(x, allow_ispra8 = FALSE) {
  z <- trimws(as.character(x))
  z <- sub('\\.0+$', '', z)
  z[is.na(z)] <- ''
  if (allow_ispra8) {
    z[grepl('^[0-9]{8}$',z)] <- substr(z[grepl('^[0-9]{8}$',z)], 3, 8)
  }
  out <- rep(NA_character_, length(z))
  ok <- grepl('^[0-9]{4,6}$', z)
  out[ok] <- sprintf('%06d', as.integer(z[ok]))
  out
}
num_it <- function(x) {
  if (is.numeric(x)) return(as.numeric(x))
  z <- trimws(as.character(x))
  z[clean_text(z) %in% c('', 'na', 'n.a.', 'n.d.', 'nd', '..','...','-', 'x', 's','*','null','non disponibile')] <- NA_character_
  has_comma <- grepl(',',z,fixed=TRUE)
  z[has_comma] <- gsub('\\.', '', z[has_comma])
  z[has_comma] <- gsub(',', '.', z[has_comma], fixed=TRUE)
  z <- gsub('[[:space:]]', '', z)
  suppressWarnings(as.numeric(z))
}
assert_keys <- function(z, name='dati') {
  if (!all(c('codice_istat','anno') %in% names(z))) stop('Chiavi assenti in ',name)
  if (anyNA(z$codice_istat) || anyNA(z$anno)) stop('Chiavi mancanti in ',name)
  if (anyDuplicated(z[c('codice_istat','anno')])) stop('Duplicati comune-anno in ',name)
  invisible(TRUE)
}
fetch_binary <- function(url, dest, min_bytes=1000) {
  if (file.exists(dest) && !CONFIG$redownload && file.size(dest) >= min_bytes) return(dest)
  logmsg('Download: ',url)
  tmp <- paste0(dest,'.part'); if (file.exists(tmp)) unlink(tmp)
  req <- httr2::request(url) |> httr2::req_retry(max_tries=3) |> httr2::req_timeout(900)
  httr2::req_perform(req, path=tmp)
  if (!file.exists(tmp) || file.size(tmp) < min_bytes) stop('File incompleto: ',url)
  if (grepl('\\.(xlsx|zip)$',dest,ignore.case=TRUE)) {
    z <- tryCatch(utils::unzip(tmp, list=TRUE),error=function(e) NULL)
    if (is.null(z) || !nrow(z)) stop('Il download non e un archivio ZIP/XLSX: ',url)
    if (grepl('\\.xlsx$',dest) && !any(z$Name=='xl/workbook.xml')) stop('XLSX privo di workbook: ',url)
  }
  if (file.exists(dest)) unlink(dest)
  if (!file.rename(tmp,dest)) stop('Impossibile rinominare file scaricato: ',dest)
  dest
}
get_json <- function(url, query=list()) {
  req <- httr2::request(url) |> httr2::req_retry(max_tries=3) |> httr2::req_timeout(120)
  if (length(query)) req <- do.call(httr2::req_url_query, c(list(req), query))
  txt <- httr2::resp_body_string(httr2::req_perform(req))
  ans <- jsonlite::fromJSON(txt, simplifyVector=FALSE)
  if (!is.null(ans$error)) stop('Errore server ArcGIS: ',paste(unlist(ans$error),collapse=' / '))
  ans
}

# ============================================================================
# A. CARTOGRAFIA (necessaria per universo completo e mappe)
# ============================================================================
GEOM_URL <- 'https://www.istat.it/storage/cartografia/confini_amministrativi/generalizzati/2025/Limiti01012025_g.zip'
g <- NULL
tryCatch({
  if (!CONFIG$do_geometry) stop('Download geometrie disattivato')
  zfile <- fetch_binary(GEOM_URL, file.path(RAW, 'Limiti01012025_g.zip'), min_bytes=100000)
  folder <- file.path(RAW,'limiti_2025'); dir.create(folder,showWarnings=FALSE)
  if (!length(list.files(folder,pattern='\\.shp$',recursive=TRUE))) unzip(zfile,exdir=folder)
  fs <- list.files(folder, pattern='\\.shp$',recursive=TRUE,full.names=TRUE)
  fs <- fs[grepl('(^|[/\\\\])Com[0-9]',fs,ignore.case=TRUE)]
  if (length(fs)!=1L) stop('Impossibile trovare univocamente lo shapefile comunale')
  g <- suppressWarnings(sf::st_read(fs,quiet=TRUE))
  fields <- intersect(c('PRO_COM_T','PRO_COM','COD_COM','CODICE_COMUNE'),names(g))
  if (!length(fields)) stop('La cartografia non espone il codice comunale ISTAT')
  g$codice_istat <- code6(g[[fields[1]]])
  if (anyNA(g$codice_istat) || anyDuplicated(g$codice_istat) || nrow(g)<CONFIG$n_min_comuni)
    stop('Geometrie non comunali, codici non univoci o insufficienti')
  logmsg('Geometrie ISTAT: ',nrow(g),' comuni (geografia al 01/01/2025).')
  gpkg <- file.path(OUT,'comuni_2024_geometrie.gpkg')
  if (file.exists(gpkg)) unlink(gpkg)
  sf::st_write(g, gpkg, quiet=TRUE)
  # adiacenza da poligoni; se si desidera rook utilizzare st_relate personalizzato
  nb <- sf::st_touches(g)
  adj <- dplyr::bind_rows(lapply(seq_along(nb), function(i) {
    if (!length(nb[[i]])) return(NULL)
    tibble::tibble(codice_istat=g$codice_istat[i], vicino_istat=g$codice_istat[nb[[i]]])
  }))
  readr::write_csv(adj,file.path(OUT,'adiacenza_comuni.csv'))
},error=function(e) add_error('geometria',e))

# ============================================================================
# B. ISTAT A MISURA DI COMUNE. Tabelle e anni controllati su indice 26/05/2026.
# ============================================================================
ISTAT_BASE <- 'https://www.istat.it/storage/misura-comune/'
ISTAT_PAGE <- 'https://www.istat.it/statistica-sperimentale/aggiornamento-degli-indicatori-del-sistema-informativo-a-misura-di-comune/'
istat_files <- c(
  pop='1a-Popolazione-valori-assoluti.xlsx',
  structure='1d-Popolazione-indicatori-struttura.xlsx',
  environment='11-Territorio-e-ambiente.xlsx',
  mobility='15c-Infrastrutture-e-mobilita-per-tassi-di-motorizzazione-e-proventi-dalle-sanzioni.xlsx',
  accidents='15a-Infrastrutture-e-mobilita-incidenti-stradali.xlsx',
  education='4-Istruzione.xlsx', labour='5-Lavoro.xlsx',
  income='6-Benessere-economico.xlsx', innovation='13-Ricerca-innovazione.xlsx',
  entrepreneurship='12a-Economia-insediata-rapporti-caratteristici.xlsx',
  tourism='14-Turismo.xlsx')
# Nota: alcuni anni sono assenti anche all'interno degli intervalli (lavoro: 2020).
sp <- list(
  c('popolazione','pop','1.1','2014:2024','contesto','Popolazione residente'),
  c('indice_vecchiaia','structure','6.1','2014:2024','contesto','Indice di vecchiaia'),
  c('indice_dipendenza','structure','8.1','2014:2024','contesto','Indice di dipendenza strutturale'),
  c('raccolta_differenziata_pct','environment','6.1','2014:2024','ambientale','Raccolta differenziata (%)'),
  c('auto_pre_euro4_pct','environment','8.1','2014:2023','mobilita_ambiente','Veicoli pre Euro 4 (%)'),
  c('suolo_consumato_pct_istat','environment','9.1','2015:2024','ambientale','Suolo consumato (%) - ISTAT'),
  c('auto_motorizzazione','mobility','8.1','2014:2023','mobilita_ambiente','Tasso motorizzazione autovetture'),
  c('moto_motorizzazione','mobility','9.1','2014:2023','mobilita_ambiente','Tasso motorizzazione motocicli'),
  c('incidentalita','accidents','1.1','2014:2024','mobilita_ambiente','Incidentalita stradale'),
  c('titolo_secondario_pct','education','4.1','2018:2023','societa','Titolo secondario'),
  c('titolo_terziario_pct','education','5.1','2018:2023','societa','Titolo terziario'),
  c('tasso_occupazione','labour','1.1','c(2019,2021:2023)','economia','Tasso occupazione'),
  c('tasso_disoccupazione','labour','2.1','c(2019,2021:2023)','economia','Tasso disoccupazione'),
  c('redditi_bassi_pct','income','1.1','2014:2023','economia','Redditi inferiori a 10mila euro'),
  c('reddito_imponibile_medio','income','2.1','2014:2023','economia','Reddito imponibile per contribuente'),
  c('ftth_pct','innovation','2.1','2022:2024','infrastrutture','Copertura FTTH'),
  c('tasso_imprenditorialita','entrepreneurship','1.1','2014:2023','economia','Tasso imprenditorialita'),
  c('densita_unita_locali','entrepreneurship','2.1','2014:2023','economia','Densita unita locali'),
  c('turismo_arrivi','tourism','2.1','2014:2024','pressione','Indice turisticita arrivi'),
  c('turismo_presenze','tourism','3.1','2014:2024','pressione','Indice turisticita presenze'),
  c('densita_turistica','tourism','4.1','2014:2024','pressione','Densita presenza turistica'),
  c('densita_posti_letto','tourism','7.1','2014:2024','pressione','Densita posti letto')
)
spec <- tibble::as_tibble(do.call(rbind,sp),.name_repair='minimal')
names(spec) <- c('indicatore','file','tavola','anni_expr','dimensione','descrizione')
spec <- spec |> mutate(fonte='ISTAT A misura di Comune', url=paste0(ISTAT_BASE,istat_files[file]),
                      anni=lapply(anni_expr, function(s) as.integer(eval(parse(text=s)))))

# Rileva tavola dal nome del foglio (prima scelta) o titolo nelle prime 12 righe.
find_sheet <- function(file, table) {
  sheets <- readxl::excel_sheets(file)
  txt <- clean_text(sheets)
  rgx <- paste0('(^|[^0-9])', gsub('\\.','[._ -]',table),'([^0-9]|$)')
  hit <- which(grepl(rgx,txt,perl=TRUE))
  if (length(hit)==1L) return(sheets[hit])
  hits <- character()
  for (sheet in sheets) {
    preview <- suppressWarnings(readxl::read_excel(file,sheet=sheet,col_names=FALSE,
                              n_max=12,.name_repair='minimal'))
    alltxt <- paste(clean_text(unlist(preview,use.names=FALSE)),collapse=' ')
    if (grepl(paste0('tavola[[:space:]]*',gsub('\\.','\\\\.',table),'(?![0-9])'),
              alltxt,perl=TRUE)) hits <- c(hits,sheet)
  }
  if (length(hits)==1L) return(hits)
  stop('Tavola ',table,' ambigua. Sheets=',paste(sheets,collapse='; '))
}

read_istat <- function(path, table, id, years, valid_codes=NULL) {
  sheet <- find_sheet(path,table)
  df <- suppressWarnings(readxl::read_excel(path,sheet=sheet,col_names=FALSE,
                        .name_repair='minimal', guess_max=10000))
  m <- as.matrix(df); m[is.na(m)] <- ''
  nr <- nrow(m); nc <- ncol(m)
  if (nr<CONFIG$n_min_comuni || nc<4L) stop('Foglio troppo piccolo: ',sheet)
  hd <- m[seq_len(min(60,nr)),,drop=FALSE]
  # Numero esatto di 4 cifre nei range validi, non sottostringhe arbitrarie
  hy <- suppressWarnings(matrix(as.integer(trimws(as.character(hd))),nrow=nrow(hd)))
  scores <- rowSums(hy>=2010 & hy<=2026,na.rm=TRUE)
  yrrow <- which.max(scores)
  if (scores[yrrow]<2L) stop('Intestazione anni non riconosciuta: ',sheet)
  cc <- seq_len(min(12,nc))
  codecols <- lapply(cc,function(j) code6(m[,j]))
  nvalid <- vapply(codecols,function(x) length(unique(stats::na.omit(x))),integer(1))
  overlap <- if (is.null(valid_codes)) nvalid else vapply(codecols,
                        function(x) length(intersect(unique(stats::na.omit(x)),valid_codes)),integer(1))
  label <- vapply(cc,function(j) paste(clean_text(hd[,j]),collapse=' '),character(1))
  hints <- grepl('codice.{0,30}comun|cod.{0,12}istat|pro_com|^codice$', label)
  eligible <- which(overlap>=CONFIG$n_min_comuni)
  if (!length(eligible)) stop('Colonna codice ISTAT non identificata: ',sheet)
  jcode <- eligible[which.max(overlap[eligible]+10000L*hints[eligible])]
  cd <- codecols[[jcode]]
  keep <- which(!is.na(cd) & seq_len(nr)>yrrow)
  if (length(unique(cd[keep]))<CONFIG$n_min_comuni) stop('Copertura comunale insufficiente')
  namecols <- which(grepl('denominazione.*comun|^comune',label) & cc!=jcode)
  namecol <- if(length(namecols)) namecols[1] else if(jcode<nc) jcode+1 else NA_integer_
  namesv <- if(!is.na(namecol)) as.character(m[,namecol]) else rep('',nr)
  parts <- list()
  for (yr in intersect(CONFIG$years,years)) {
    js <- which(hy[yrrow,]==yr)
    if (!length(js)) next
    if (length(js)>1L) {
      # Fogli per sesso: non sommare quote o tassi; accetta solo totale univoco.
      # Tabelle per sesso: gruppi consecutivi di colonne (uno per genere)
      # hanno lo stesso anno iniziale. Risali all'inizio del gruppo, NON
      # cercare 'totale' in una finestra ampia che potrebbe includere altri gruppi.
      first_y <- min(hy[yrrow,hy[yrrow,] %in% years],na.rm=TRUE)
      starts <- which(hy[yrrow,]==first_y)
      lbl <- vapply(js,function(j) {
        start <- max(starts[starts<=j])
        header_cols <- max(1L,start-1L):start
        z <- m[seq_len(max(1L,yrrow-1L)),header_cols,drop=FALSE]
        paste(clean_text(z),collapse=' ')
      },character(1))
      tot <- js[grepl('totale|entrambi.{0,9}sess',lbl)]
      if(length(tot)!=1L) stop('Anno ',yr,' con colonne multiple e totale ambiguo: ',sheet)
      js <- tot
    }
    d <- tibble::tibble(codice_istat=cd[keep],anno=as.integer(yr),
                        val=num_it(m[keep,js]),nome=namesv[keep])
    # controllo chiavi prima dell'aggregazione di eventuali ripetizioni identiche
    ck <- d |> group_by(codice_istat,anno) |> summarise(nv=n_distinct(val,na.rm=TRUE),.groups='drop')
    if(any(ck$nv>1L)) stop('Duplicati discordanti ISTAT ',id,' / ',yr)
    d <- d |> group_by(codice_istat,anno) |> summarise(
      val={x <- val[!is.na(val)];if(length(x))x[1]else NA_real_},
      nome={x <- nome[!is.na(nome) & nzchar(nome)];if(length(x))x[1]else NA_character_},
      .groups='drop')
    if(nrow(d)<CONFIG$n_min_comuni) stop('Campione comunale insufficiente ',id,' / ',yr)
    names(d)[names(d)=='val'] <- id
    parts[[as.character(yr)]] <- d
  }
  if (!length(parts)) stop('Nessun anno estratto: ',id)
  ans <- dplyr::bind_rows(parts)
  assert_keys(ans,id)
  ans
}

istat_paths <- list(); istat_data <- list()
for (key in names(istat_files)) {
  istat_paths[[key]] <- tryCatch(fetch_binary(paste0(ISTAT_BASE,istat_files[[key]]),
                    file.path(RAW,istat_files[[key]])),error=function(e) {add_error(paste0('download ISTAT ',key),e);NA_character_})
}
valid_codes <- if(!is.null(g)) g$codice_istat else NULL
for(i in seq_len(nrow(spec))) {
  z <- spec[i,]
  fp <- istat_paths[[z$file]]
  if(is.na(fp)) {add_error(z$indicatore,'File sorgente non scaricato');next}
  cat('ISTAT: ',z$indicatore,'\n')
  istat_data[[z$indicatore]] <- tryCatch(read_istat(fp,z$tavola,z$indicatore,z$anni[[1]],valid_codes),
      error=function(e){add_error(z$indicatore,e);NULL})
}
# Popolazione e geometrie sono due master possibili, indipendenti dai dataset ISPRA.
if(!is.null(g)) {
  base <- tibble::tibble(codice_istat=g$codice_istat)
  nf <- intersect(c('COMUNE','DEN_COM','COMUNE_A'),names(g))
  base$comune <- if(length(nf)) as.character(g[[nf[1]]]) else NA_character_
  admin <- intersect(c('COD_REG','DEN_REG','COD_PROV','DEN_UTS'),names(g))
  if(length(admin)) base <- dplyr::bind_cols(base,sf::st_drop_geometry(g)[,admin,drop=FALSE])
} else {
  z <- istat_data[['popolazione']]
  if(is.null(z)) stop('Impossibile stabilire universo dei comuni: niente geografia e niente popolazione ISTAT')
  base <- z |> filter(anno==2024) |> select(codice_istat,comune=nome) |> distinct(codice_istat,.keep_all=TRUE)
}
if(nrow(base)<CONFIG$n_min_comuni || anyDuplicated(base$codice_istat)) stop('Master territoriale incompleto')

# ============================================================================
# C. ISPRA: CONSUMO DI SUOLO IN ETTARI + INCREMENTO, ARCGIS FEATURESERVER
# Endpoint ufficiale: dati_comunali_consumo_suolo_2025_RDN, campo pro_com_t.
# ============================================================================
SOIL_API <- paste0('https://sinacloud.isprambiente.it/arcgisina/rest/services/',
                    'sina_consumo_suolo/Statistiche_consumo_suolo_2025/FeatureServer/1')
soil <- NULL
soil_expected <- c(2006L,2012L,2015:2024)
read_soil <- function() {
  fmeta <- get_json(SOIL_API, list(f='json'))
  fields <- vapply(fmeta$fields, function(f) f$name, character(1))
  if (!'pro_com_t' %in% fields) stop('Campo comune ISPRA assente')
  candidates <- grep('^csuolo(1|8)_[0-9]{2}$',fields,value=TRUE)
  if (!length(candidates)) stop('Campi suolo in ettari non trovati')
  # Preleviamo solo attributi, non geometrie (query su 7900 comuni).
  out_fields <- paste(c('objectid','pro_com_t',candidates),collapse=',')
  off <- 0L; batches <- list()
  repeat {
    q <- list(where='1=1', outFields=out_fields, returnGeometry='false',
              orderByFields='objectid', resultOffset=as.character(off),
              resultRecordCount='1000', f='json')
    js <- get_json(paste0(SOIL_API,'/query'),q)
    feats <- js$features
    if (is.null(feats) || !length(feats)) break
    at <- lapply(feats,function(x) x$attributes)
    cur <- dplyr::bind_rows(lapply(at, tibble::as_tibble))
    batches[[length(batches)+1L]] <- cur
    off <- off+nrow(cur)
    if(nrow(cur)<1000L) break
    if(off>20000L) stop('Troppe righe ArcGIS, possibile ciclo di paginazione')
  }
  dat <- dplyr::bind_rows(batches)
  if(nrow(dat)<CONFIG$n_min_comuni) stop('ISPRA API suolo non ha copertura nazionale')
  dat$codice_istat <- code6(dat$pro_com_t)
  if(anyNA(dat$codice_istat) || anyDuplicated(dat$codice_istat)) stop('Codici ArcGIS ISPRA duplicati/mancanti')
  li <- list()
  for(j in candidates) {
    yy <- as.integer(substr(j,nchar(j)-1L,nchar(j)))+2000L
    if(!(yy %in% c(2006L,2012L,2015:2024))) next
    indicator <- if (grepl('^csuolo1_',j)) 'suolo_consumato_ha' else 'incremento_suolo_consumato_ha'
    li[[length(li)+1L]] <- tibble::tibble(codice_istat=dat$codice_istat,anno=yy,
                                         indicatore=indicator,valore=num_it(dat[[j]]))
  }
  ldat <- dplyr::bind_rows(li) |> filter(anno %in% CONFIG$years)
  ans <- ldat |> tidyr::pivot_wider(names_from=indicatore,values_from=valore)
  assert_keys(ans,'ISPRA suolo')
  ans
}
if(CONFIG$do_soil) soil <- tryCatch(read_soil(),error=function(e){add_error('ISPRA suolo',e);NULL})

# ============================================================================
# D. ISPRA: CATASTO RIFIUTI (2010-2024). SCOPERTA URL SENZA INVENTARE ENDPOINT.
# La pagina ufficiale espone una riga per anno con scaricamento CSV nazionale.
# Se cambia HTML, il codice fallisce in modo esplicito e conserva gli altri dati.
# ============================================================================
WASTE_PAGE <- 'https://www.catasto-rifiuti.isprambiente.it/index.php?pg=downloadComune'
# Prendi href o onclick contenuti nella riga dell'anno; non suppone nomi CSV.
waste_urls <- function() {
  doc <- rvest::read_html(WASTE_PAGE)
  trs <- rvest::html_elements(doc,'tr')
  out <- list()
  for(y in 2010:2024) {
    hits <- trs[vapply(trs,function(tr) {
      t <- trimws(rvest::html_text2(tr))
      grepl(paste0('(^|[^0-9])',y,'([^0-9]|$)'),t,perl=TRUE)
    },logical(1))]
    if(!length(hits)) next
    for(tr in hits) {
      anchors <- rvest::html_elements(tr,'a')
      urls <- rvest::html_attr(anchors,'href')
      urls <- urls[!is.na(urls) & nzchar(urls) & urls!='#']
      if(length(urls)) {
        out[[as.character(y)]] <- xml2::url_absolute(urls[1],WASTE_PAGE)
        break
      }
      nodes <- rvest::html_elements(tr,'button,input,td,a')
      js <- rvest::html_attr(nodes,'onclick')
      js <- js[!is.na(js)]
      # solo URL letterali nei click handler (in caso di JS dinamico: errore)
      pats <- regmatches(js,gregexpr('(?i)[[:alnum:]_./?&=%+-]+\\.csv(?:[?&][^\"\x27 ]*)?',js,perl=TRUE))
      literal <- unlist(pats,use.names=FALSE)
      if(length(literal)) {out[[as.character(y)]] <- xml2::url_absolute(literal[1],WASTE_PAGE);break}
    }
  }
  out
}
# Legge colonne per NOME, non per posizione. Verifica duplicati e codifica ISPRA.
read_waste_file <- function(path,year) {
  lines <- readLines(path,n=40,warn=FALSE,encoding='UTF-8')
  skip <- which(grepl('codice|comune|istat',clean_text(lines)))[1]-1L
  if(is.na(skip)) stop('CSV ISPRA senza intestazione riconoscibile: ',basename(path))
  if(grepl('<html|<!doctype',paste(lines,collapse=' '),ignore.case=TRUE)) stop('Il link ISPRA scarica HTML, non un CSV')
  dat <- data.table::fread(path,skip=skip,encoding='UTF-8',data.table=FALSE,
                           check.names=FALSE,na.strings=c('','-','NA','n.d.','Vedi aggregazione'))
  nn <- clean_text(names(dat))
  getcol <- function(regex, mandatory=FALSE) {
    ii <- grep(regex,nn,perl=TRUE)
    if(length(ii)!=1L) {
      if(mandatory) stop('Colonna non univoca/assente: ',regex,'; campi=',paste(names(dat),collapse=' | '))
      return(rep(NA_real_,nrow(dat)))
    }
    num_it(dat[[ii]])
  }
  ico <- grep('codice.*(istat|comun)|cod.*istat|^codice$',nn)
  if(length(ico)!=1L) stop('CSV ISPRA: campo codice comunale ambiguo')
  cd <- code6(dat[[ico]],allow_ispra8=TRUE)
  z <- tibble::tibble(codice_istat=cd,anno=as.integer(year),
       rifiuti_urbani_t=getcol('rifiuti.?urbani|produzione.?totale'),
       raccolta_differenziata_t=getcol('raccolta.?differenziata|^rd.?totale'),
       rifiuti_kg_abitante=getcol('pro.?capite|kg.?ab')) |>
       filter(!is.na(codice_istat))
  if(nrow(z)<CONFIG$n_min_comuni) stop('Non e un CSV nazionale comunale  ',year)
  if(all(is.na(z$rifiuti_urbani_t)) && all(is.na(z$raccolta_differenziata_t)) &&
     all(is.na(z$rifiuti_kg_abitante))) stop('CSV ISPRA privo di misure identificabili; controllo schema necessario')
  # Unita' sbagliate non vanno inferite da valori numerici: colonne non riconosciute restano NA.
  if(anyDuplicated(z[c('codice_istat','anno')])) stop('Codici comunali duplicati ISPRA ',year)
  z
}
waste <- NULL
if(CONFIG$do_waste) {
  waste <- tryCatch({
    urlmap <- waste_urls()
    if(!length(urlmap)) stop('Impossibile identificare link CSV nella pagina downloadComune; HTML cambiato')
    lst <- list()
    for(yr in 2010:2024) {
      url <- urlmap[[as.character(yr)]]
      if(is.null(url)) {add_error(paste0('ISPRA rifiuti ',yr),'Link CSV annuale non trovato');next}
      dpath <- file.path(RAW,paste0('ispra_rifiuti_',yr,'.csv'))
      val <- tryCatch({
        fetch_binary(url,dpath,min_bytes=10000)
        read_waste_file(dpath,yr)
      },error=function(e){add_error(paste0('ISPRA rifiuti ',yr),e);NULL})
      if(!is.null(val)) lst[[as.character(yr)]] <- val
    }
    if(!length(lst)) stop('Nessun CSV ISPRA interpretabile')
    out <- dplyr::bind_rows(lst)
    assert_keys(out,'ISPRA rifiuti')
    out
  },error=function(e){add_error('ISPRA rifiuti',e);NULL})
}

# ============================================================================
# E. ASSEMBLAGGIO, GEOGRAFIA DI RIFERIMENTO E PROVENIENZA
# ============================================================================
panel <- tidyr::crossing(codice_istat=base$codice_istat,anno=CONFIG$years) |>
  left_join(base,by='codice_istat')
for(nm in names(istat_data)) {
  dat <- istat_data[[nm]]
  if (is.null(dat)) next
  dat <- dat |> select(-any_of('nome'))
  panel <- left_join(panel,dat,by=c('codice_istat','anno'))
}
if(!is.null(soil)) panel <- left_join(panel,soil,by=c('codice_istat','anno'))
if(!is.null(waste)) panel <- left_join(panel,waste,by=c('codice_istat','anno'))
assert_keys(panel,'pannello finale')
stopifnot(nrow(panel)==nrow(base)*length(CONFIG$years))
# Pre-2024: i file ISPRA originari non sono armonizzati automaticamente ai confini 2024.
# Non reinterpretare l'assenza di un codice soppresso come missing ambientale.
panel$geografia_istat_armonizzata_2024 <- TRUE  # solo variabili ISTAT
panel$geografia_ispra_da_verificare <- panel$anno<2024  # fonti ISPRA non armonizzate
panel <- arrange(panel,codice_istat,anno)

# ============================================================================
# F. DIZIONARIO e tre stati di missing: anno non previsto, fonte non estratta,
#    anno previsto ma valore mancante. No LOCF, no zero, no interpolazione.
# ============================================================================
extra_spec <- tibble::tibble(
  indicatore=c('suolo_consumato_ha','incremento_suolo_consumato_ha',
              'rifiuti_urbani_t','raccolta_differenziata_t','rifiuti_kg_abitante'),
  file=c('ISPRA REST','ISPRA REST',rep('ISPRA CSV',3)),
  tavola=c('csuolo1_YY','csuolo8_YY',rep('CSV annuale',3)),
  anni_expr=c('c(2006,2012,2015:2024)','c(2012,2015:2024)',rep('2010:2024',3)),
  dimensione=c('ambientale','ambientale',rep('ambientale',3)),
  descrizione=c('Suolo consumato in ettari','Incremento suolo consumato in ettari',
                'Rifiuti urbani: produzione in tonnellate',
                'Raccolta differenziata: massa in tonnellate',
                'Rifiuti urbani pro capite (unità da CSV)'),
  fonte=c(rep('ISPRA Consumo di suolo ArcGIS',2),rep('ISPRA Catasto rifiuti',3)),
  url=c(rep(SOIL_API,2),rep(WASTE_PAGE,3)),
  anni=list(c(2006L,2012L,2015:2024),c(2012L,2015:2024),2010:2024,2010:2024,2010:2024)
)
# Non considerare disponibile una variabile solo perche' compare nel dizionario.
spec_all <- bind_rows(spec,extra_spec)
used <- spec_all$indicatore
for(nm in used) if(!nm %in% names(panel)) panel[[nm]] <- NA_real_
extracted_istat <- names(istat_data)[!vapply(istat_data,is.null,logical(1))]
extracted <- c(extracted_istat,if(!is.null(soil))c('suolo_consumato_ha','incremento_suolo_consumato_ha'),
               if(!is.null(waste))c('rifiuti_urbani_t','raccolta_differenziata_t','rifiuti_kg_abitante'))
spec_all <- spec_all |>
  mutate(stato_estrazione=if_else(indicatore %in% extracted,'estratto','FONTE_NON_ESTRATTA'),
         anni_previsti=vapply(anni, function(x) paste(x,collapse=';'),character(1)))

cover_ind <- tidyr::expand_grid(indicatore=used,anno=CONFIG$years) |>
  left_join(spec_all |> select(indicatore,dimensione,stato_estrazione,anni_previsti),by='indicatore') |>
  mutate(anno_previsto=mapply(function(yy,zz) yy %in% spec_all$anni[[match(zz,spec_all$indicatore)]],
                       anno,indicatore),
         n_comuni=nrow(base))
cover_ind$n_presenti <- vapply(seq_len(nrow(cover_ind)),function(i) {
  if(!cover_ind$anno_previsto[i] || cover_ind$stato_estrazione[i]!='estratto') return(NA_integer_)
  sum(!is.na(panel[[cover_ind$indicatore[i]]][panel$anno==cover_ind$anno[i]]))
},integer(1))
cover_ind <- cover_ind |> mutate(
  copertura=if_else(anno_previsto & stato_estrazione=='estratto',n_presenti/n_comuni,NA_real_),
  stato=case_when(!anno_previsto~'ANNO_NON_PREVISTO',
                  stato_estrazione!='estratto'~'FONTE_NON_ESTRATTA',
                  n_presenti==0~'NESSUN_DATO',
                  TRUE~'MISURATO'))

# Calcola copertura per comune e anno, condizionata ai soli indicatori attesi E letti.
obs <- lapply(CONFIG$years,function(y) {
  ids <- spec_all$indicatore[vapply(seq_len(nrow(spec_all)),function(j)
       y %in% spec_all$anni[[j]] && spec_all$stato_estrazione[j]=='estratto',logical(1))]
  ids_env <- intersect(ids,spec_all$indicatore[spec_all$dimensione %in% c('ambientale','mobilita_ambiente')])
  tmp <- panel |> filter(anno==y)
  cal <- function(cols) if(!length(cols)) rep(NA_real_,nrow(tmp)) else rowMeans(!is.na(tmp[,cols,drop=FALSE]))
  tibble::tibble(codice_istat=tmp$codice_istat,anno=y,
    n_attesi=length(ids), n_attesi_ambientali=length(ids_env),
    completezza_totale=cal(ids),completezza_ambientale=cal(ids_env),
    n_presenti=if(length(ids)) rowSums(!is.na(tmp[,ids,drop=FALSE])) else NA_integer_)
})
completezza_comune <- bind_rows(obs)
cover_year <- cover_ind |> filter(anno_previsto & stato_estrazione=='estratto') |>
  group_by(anno,dimensione) |>
  summarise(n_indicatori=n(),copertura_media=mean(copertura,na.rm=TRUE),.groups='drop')

# ============================================================================
# G. USCITE FILE, MAPPE COMPLETENESS E HEATMAP ANNUALE
# ============================================================================
write_csv(panel,file.path(OUT,'panel_comuni_2006_2024_anni_disponibili.csv'),na='')
write_csv(panel |> filter(anno>=2014),file.path(OUT,'panel_comuni_2014_2024.csv'),na='')
for(y in CONFIG$focus_years) write_csv(panel |> filter(anno==y),
                                    file.path(OUT,paste0('comuni_',y,'.csv')),na='')
write_csv(cover_ind,file.path(OUT,'copertura_indicatore_anno.csv'),na='')
write_csv(cover_year,file.path(OUT,'copertura_dimensione_anno.csv'),na='')
write_csv(completezza_comune,file.path(OUT,'completezza_comune_anno.csv'),na='')
write_csv(spec_all |> select(-anni),file.path(OUT,'dizionario_indicatori.csv'),na='')
write_csv(err_tbl,file.path(OUT,'errori_pipeline.csv'))
saveRDS(panel,file.path(OUT,'panel_comuni_2006_2024_anni_disponibili.rds'))

# anni con fallimento del downloader nel grafico = non misurati, distinti da NA legittimi.
pheat <- cover_ind |>
  ggplot(aes(x=factor(anno),y=reorder(indicatore,dimensione),fill=copertura))+
  geom_tile(color='white',linewidth=.2)+
  geom_tile(data=function(x)x |> filter(stato=='FONTE_NON_ESTRATTA'),
            fill='gray55',color='white',linewidth=.2)+
  scale_fill_viridis_c(option='cividis',limits=c(0,1),na.value='gray92',
                      labels=scales::percent, name='Comuni con dato')+
  labs(x='Anno',y=NULL,title='Copertura comunale per indicatore e anno',
       subtitle='Grigio chiaro: anno non previsto | grigio scuro: fonte non estratta')+
  theme_minimal(base_size=11)+theme(panel.grid=element_blank(),axis.text.x=element_text(angle=45,hjust=1))
ggsave(file.path(OUT,'heatmap_copertura_indicatore_anno.png'),pheat,
       width=14,height=10,dpi=200)

ptimes <- cover_year |> ggplot(aes(x=anno,y=copertura_media,color=dimensione))+
  geom_line(linewidth=.8)+geom_point(size=1.5)+
  scale_y_continuous(limits=c(0,1),labels=scales::percent)+
  scale_x_continuous(breaks=CONFIG$years)+
  labs(x='Anno',y='Copertura media degli indicatori previsti',color='Dimensione',
       title='Copertura comunale: andamento per dimensione')+
  theme_minimal(base_size=11)+theme(axis.text.x=element_text(angle=45,hjust=1))
ggsave(file.path(OUT,'serie_copertura_dimensione.png'),ptimes,width=11,height=6,dpi=200)

if (!is.null(g)) {
  for(yr in CONFIG$focus_years) {
    z <- completezza_comune |> filter(anno==yr)
    gm <- g |> left_join(z,by='codice_istat')
    for(v in c('completezza_totale','completezza_ambientale')) {
      if(all(is.na(gm[[v]]))) next
      p <- ggplot(gm)+geom_sf(aes(fill=.data[[v]]),color=NA)+
        scale_fill_viridis_c(option='cividis',limits=c(0,1),na.value='gray90',
                            labels=scales::percent,name='Completezza')+
        coord_sf(datum=NA)+
        labs(title=paste0('Completezza ',ifelse(v=='completezza_totale','totale','ambientale'),
                          ' - comuni italiani - ',yr),
             subtitle='Denominatore: soli indicatori previsti ed estratti per l\'anno; confini ISTAT 2024',
             caption='ISTAT, ISPRA. Nessuna imputazione; variazioni amministrative storiche da verificare')+
        theme_void(base_size=12)+theme(plot.title=element_text(face='bold'),
                                      plot.caption=element_text(size=8))
      ggsave(file.path(OUT,paste0('mappa_',v,'_',yr,'.png')),p,width=9,height=10,dpi=200)
    }
  }
  # GPKG leggero dei soli attributi completi 2023-2024: utile in QGIS.
  for(yr in CONFIG$focus_years) {
    gm <- g |> left_join(completezza_comune |> filter(anno==yr),by='codice_istat')
    dest <- file.path(OUT,paste0('completezza_',yr,'.gpkg'))
    if(file.exists(dest)) unlink(dest)
    sf::st_write(gm,dest,quiet=TRUE)
  }
}

source_inventory <- tibble::tibble(
 fonte=c(rep('ISTAT A misura di Comune',length(istat_files)),
          'ISTAT confini generalizzati','ISPRA ArcGIS suolo','ISPRA Catasto Rifiuti'),
 url=c(paste0(ISTAT_BASE,istat_files),GEOM_URL,SOIL_API,WASTE_PAGE),
 file_locale=c(istat_files,'Limiti01012025_g.zip','REST API','CSV per anno'),
 disponibilita_locale=c(vapply(istat_paths,function(p) !is.na(p)&&file.exists(p),logical(1)),
                  !is.null(g),!is.null(soil),!is.null(waste)))
write_csv(source_inventory,file.path(OUT,'manifest_fonti.csv'))
logmsg('FINE | Comuni=',nrow(base),' | indicatori estratti=',length(extracted),
       ' | anni=',paste(range(CONFIG$years),collapse='-'))
logmsg('Cartella output: ',OUT)
logmsg('Indicatori NON estratti: ', paste(setdiff(spec_all$indicatore,extracted),collapse=', '))
