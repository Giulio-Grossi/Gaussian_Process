# Test automatici. Esecuzione: Rscript tests/run_tests.R  (dalla cartella dello script)
library(testthat)

test_that('validate_file: binari ZIP/XLSX in locale UTF-8 (regressione invalid multibyte)', {
  f <- tempfile(fileext = '.bin'); writeBin(as.raw(c(0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe, 0xc3, 0x28, 0x80:0xff)), f)
  expect_no_error(v <- validate_file(f, 'zip', 10))
  expect_match(v, 'ZIP')
  h <- tempfile(fileext = '.csv'); writeBin(c(as.raw(0xe8), charToRaw('<html><body>errore</body></html>')), h)
  expect_match(validate_file(h, 'csv', 5), 'HTML')
})

test_that('code6: formati ISTAT e ISPRA 8 cifre', {
  expect_equal(code6(c('1001', '001001', 1001, '1001.0', ' 001001 ')), rep('001001', 5))
  expect_equal(code6(c('02007004', '2007004', '"02007004"'), allow8 = TRUE), rep('007004', 3))
  expect_true(all(is.na(code6(c('02007004', 'abc', '', NA, '12', '000000')))))   # 8 cifre senza allow8 -> NA
  expect_true(is.na(code6('123456789', allow8 = TRUE)))
  expect_equal(code8_region(c('02007004', '1001001', '001001')), c('02', '01', NA))
})

test_that('num_it: formato italiano, NA veri, niente zeri inventati', {
  x <- num_it(c('1.234,5', '-', '0', 'n.d.', '12,0', ''))
  expect_equal(as.numeric(x), c(1234.5, NA, 0, NA, 12, NA))
  expect_equal(as.numeric(num_it(c('12.5', '1.234.567'))), c(12.5, 1234567))
  y <- num_it(c('abc', '3'))
  expect_equal(attr(y, 'n_non_numerici'), 1L); expect_true(is.na(y[1]))
  expect_equal(as.numeric(num_it('1.234', 'comma')), 1234)
})

test_that('split_fields: ; finale, virgolette, apostrofi', {
  expect_equal(split_fields('a;b;'), c('a', 'b', ''))
  expect_equal(split_fields('a;"b;c";d'), c('a', 'b;c', 'd'))
  expect_equal(split_fields("02007004;Valle d'Aosta;;x"), c('02007004', "Valle d'Aosta", '', 'x'))
})

test_that('regioni: codice da nome', {
  expect_equal(region_code_from_name(c("Valle d'Aosta", 'Vallée d\'Aoste', 'Trentino-Alto Adige', 'Emilia-Romagna', 'xx')),
               c('02', '02', '04', '08', NA))
})

test_that('parser ISPRA (struttura reale): capofila, rinvii, nota, pro capite derivato', {
  td <- tempfile(); dir.create(td)
  cm <- synthetic_comuni(); p <- file.path(td, 'r.csv'); write_ispra_csv(p, 2024, cm)
  x <- parse_ispra_rifiuti(p, 2024); m <- x$meta
  expect_equal(m$n_campi_intestazione, 25L); expect_equal(m$encoding, 'CP1252'); expect_equal(m$codice_colonna, 'IstatComune')
  # nessun record perso
  expect_equal(m$n_record, m$n_completi + m$n_rinvii + m$n_capofila + m$n_note + m$n_anomali)
  expect_equal(c(m$n_rinvii, m$n_capofila, m$n_note, m$n_anomali), c(2L, 1L, 1L, 1L))
  expect_equal(m$pct_anomali, 100 / (m$n_record - 1))                      # nota esclusa dal denominatore
  ar <- x$comuni[x$comuni$codice_istat == '007004', ]
  expect_equal(ar$tipo_record, 'rinvio_aggregazione'); expect_equal(ar$aggregazione, 'EVANCON-MONT CERVIN')
  expect_equal(ar$popolazione_ispra, 1228)                                  # popolazione resta comunale
  expect_true(all(is.na(unlist(ar[setdiff(WASTE_MEAS$id, 'popolazione_ispra')]))))
  cf <- x$comuni[x$comuni$codice_istat == '007002', ]                       # capofila: totale NON attribuito
  expect_equal(cf$tipo_record, 'capofila_aggregazione'); expect_true(is.na(cf$ru_totale_t)); expect_equal(cf$popolazione_ispra, 553)
  ag <- x$aggregazioni
  expect_equal(nrow(ag), 1L); expect_equal(ag$aggregazione, 'EVANCON-MONT CERVIN'); expect_equal(ag$capofila_codice, '007002')
  expect_equal(ag$ru_totale_t, 17968.935); expect_equal(ag$n_comuni_membri, 3L); expect_equal(ag$popolazione_membri, 553 + 1228 + 303)
  expect_equal(ag$ru_procapite_kg, 17968.935 * 1000 / (553 + 1228 + 303))   # pro capite su popolazione membri
  expect_setequal(x$membri$codice_istat, c('007002', '007004', '007006'))
  expect_true('001002' %in% x$comuni$codice_istat)                         # 7 cifre (zero perso) recuperato
  expect_equal(sum(x$comuni$codice_istat == '001001'), 1L)
  expect_true(x$comuni$flag_duplicato[x$comuni$codice_istat == '001001'])
  r1 <- x$comuni[x$comuni$codice_istat == '001001', ]
  expect_equal(r1$ru_totale_t, 0.5 * 1037, tolerance = 1e-3)
  expect_equal(r1$rd_pct_ispra, 42, tolerance = 1e-6)                       # '  42,00%'
  expect_equal(r1$ru_procapite_kg, 500, tolerance = 1e-6)                   # derivato
  expect_true(is.na(x$comuni$ru_totale_t[x$comuni$codice_istat == '001005']))
  cm2 <- x$colmap
  expect_equal(cm2$esito[cm2$indicatore %in% c('ru_procapite_kg', 'rd_procapite_kg')], c('DERIVATO', 'DERIVATO'))
  expect_true(all(cm2$esito[!cm2$indicatore %in% c('ru_procapite_kg', 'rd_procapite_kg')] == 'OK'))
  expect_equal(cm2$colonna[cm2$indicatore == 'rd_pct_ispra'], 25L)
  expect_true(any(grepl('riga troncata', x$anomalie$testo)))
  expect_false(any(x$comuni$flag_regione))
})

test_that('parser ISPRA: codice ambiguo -> errore, misura ambigua -> NA', {
  td <- tempfile(); dir.create(td); p <- file.path(td, 'a.csv')
  rows <- vapply(1:20, function(i) sprintf('%08d;%08d;Piemonte;X;C%d;100;10', 1001000 + i, 2001000 + i, i), '')
  writeLines(c('Cod A;Cod B;Regione;Provincia;Comune;Totale RU (t);Totale RU (t) bis', rows), p)
  expect_error(parse_ispra_rifiuti(p, 2020), 'non identificabile')
  writeLines(c('Istat;Regione;Provincia;Comune;Totale RU (t);Totale RU (t) bis',
               vapply(1:20, function(i) sprintf('%08d;Piemonte;X;C%d;100;10', 1001000 + i, i), '')), p)
  x <- parse_ispra_rifiuti(p, 2020)
  expect_equal(x$colmap$esito[x$colmap$indicatore == 'ru_totale_t'], 'AMBIGUA')
  expect_true(all(is.na(x$comuni$ru_totale_t)))
})

test_that('ISTAT: totale per sesso selezionato, codici numerici, anni extra', {
  td <- tempfile(); dir.create(td); cm <- synthetic_comuni(); f <- file.path(td, 'e.xlsx')
  s1 <- istat_sheet(as.character(as.integer(cm$codice_istat)), cm$comune, 2018:2023, 'Tavola 4.1 - prova sul totale', groups = c('Maschi', 'Femmine', 'Totale'))
  s2 <- istat_sheet(cm$codice_istat, cm$comune, 2018:2023, 'Tavola 5.1', groups = c('Maschi', 'Femmine'))
  writexl::write_xlsx(list(`Tav. 4.1` = s1, `Tav. 5.1` = s2), f, col_names = FALSE)
  r <- read_istat_table(f, '4.1', 'x', 2019:2023, cm$codice_istat)
  expect_equal(nrow(r$data), 25 * 6); expect_equal(r$extra, 2018L)
  expect_equal(r$data$x[r$data$codice_istat == '001001' & r$data$anno == 2018], 3 * 11.4, tolerance = 1e-6)  # gruppo Totale (x3)
  expect_error(read_istat_table(f, '5.1', 'y', 2018:2023, cm$codice_istat), 'totale non univoco')
  expect_error(find_sheet(f, '9.9'), 'non univoca')
})

test_that('soil: semantica solo da alias, incrementi pluriennali riconosciuti', {
  fl <- tibble::tibble(name = c('csuolo1_22', 'csuolo2_22', 'csuolo8_22', 'csuolo8_15', 'csuolo9_22'),
                       alias = c('Suolo consumato 2022 [ha]', 'Suolo consumato 2022 [%]', 'Incremento 2021-2022 [ha]', 'Incremento 2012-2015 [ha]', 'boh'))
  old <- CONFIG$soil_field_map; CONFIG$soil_field_map <<- NULL; on.exit(CONFIG$soil_field_map <<- old)
  c <- classify_soil_fields(fl)
  expect_equal(c$tipo, c('suolo_consumato_ha', 'suolo_consumato_pct_ispra', 'variazione_netta_suolo_ha', 'variazione_netta_suolo_ha', NA))
  expect_equal(c$anno_inizio[3:4], c(2021L, 2012L))
})

test_that('stati e denominatori: fonte fallita non gonfia la completezza', {
  spec <- tibble::tibble(indicatore = c('a', 'b', 'w'), sorgente = c('istat', 'soil', 'waste'),
                         geografia = c('armonizzata_2024', 'armonizzata_2024', 'anno_corrente'),
                         dimensione = c('ambientale', 'ambientale', 'ambientale'), in_completezza = TRUE,
                         anni_teorici = list(2020:2021, 2020:2021, 2021L))
  panel <- tibble::tibble(codice_istat = rep(c('001001', '001002', '001003'), each = 2), anno = rep(2020:2021, 3),
                          a = c(1, 2, NA, 4, 5, 6), b = NA_real_, w = c(NA, 1, NA, NA, NA, NA))
  acq <- tibble::tibble(indicatore = c('a', 'a', 'w'), anno = c(2020L, 2021L, 2021L), acquisito = TRUE)   # b fallita
  pres <- tibble::tibble(indicatore = c(rep('a', 6), 'w', 'w'), codice_istat = c(rep(c('001001', '001002', '001003'), each = 2), '001001', '001002'),
                         anno = c(rep(2020:2021, 3), 2021L, 2021L))
  es <- tibble::tibble(codice_istat = rep(c('001001', '001002', '001003'), each = 2), anno = rep(2020:2021, 3),
                       comune_esistente = c(TRUE, TRUE, TRUE, TRUE, FALSE, TRUE))
  ag <- tibble::tibble(codice_istat = '001002', anno = 2021L)
  L <- cell_status(panel, spec, acq, pres, es, ag)
  st <- function(c, y, i) L[codice_istat == c & anno == y & indicatore == i, stato]
  expect_equal(st('001001', 2020, 'w'), 'ANNO_NON_RILEVATO')
  expect_equal(st('001001', 2020, 'b'), 'FONTE_NON_ACQUISITA')
  expect_equal(st('001002', 2020, 'a'), 'MANCANTE')
  expect_equal(st('001002', 2021, 'w'), 'DATO_AGGREGATO')
  expect_equal(st('001003', 2021, 'w'), 'ASSENTE_IN_FONTE')
  expect_equal(st('001001', 2021, 'w'), 'OSSERVATO')
  expect_equal(st('001003', 2020, 'a'), 'OSSERVATO')    # ISTAT armonizzata: esistenza non applicata
  C <- completeness(L)
  r <- C$comune_anno[codice_istat == '001001' & anno == 2021]
  expect_equal(r$n_teorici, 3L); expect_equal(r$n_acquisiti, 2L); expect_equal(r$n_osservati, 2L)
  expect_equal(r$completezza_teorica, 2 / 3); expect_equal(r$completezza_acquisita, 1)
  i <- C$indicatore_anno[indicatore == 'b' & anno == 2020]
  expect_equal(i$stato, 'FONTE_NON_ACQUISITA'); expect_true(is.na(i$copertura))
})

test_that('contiguita: griglia 3x3 queen=8 rook=4 al centro', {
  cells <- lapply(0:8, function(k) { i <- k %% 3; j <- k %/% 3
    sf::st_polygon(list(matrix(c(i, j, i + 1, j, i + 1, j + 1, i, j + 1, i, j), ncol = 2, byrow = TRUE))) })
  g <- sf::st_sf(codice_istat = sprintf('001%03d', 1:9), geometry = sf::st_sfc(cells, crs = 32632))
  a <- adjacency(g)$adj
  expect_equal(sum(a$tipo == 'queen' & a$codice_istat == '001005'), 8L)
  expect_equal(sum(a$tipo == 'rook' & a$codice_istat == '001005'), 4L)
})

test_that('pipeline completa offline su fixture sintetiche', {
  root <- tempfile('panel_'); dir.create(root); build_offline_raw(root)
  old <- CONFIG
  on.exit(CONFIG <<- old, add = TRUE)
  CONFIG$n_min_comuni <<- 10L; CONFIG$waste_years <<- 2022:2024; CONFIG$do_soil <<- FALSE
  CONFIG$do_verifica <<- FALSE; CONFIG$offline <<- TRUE; CONFIG$max_anomalie_pct <<- 10; CONFIG$min_bytes <<- list(geo = 100, xlsx = 100, csv = 100, var = 100)
  res <- suppressMessages(run_pipeline(root))
  out <- file.path(root, 'output_v3'); P <- res$panel
  expect_equal(nrow(P), 25 * length(unique(P$anno)))
  expect_false(anyDuplicated(P[c('codice_istat', 'anno')]) > 0)
  expect_true(all(grepl('^[0-9]{6}$', P$codice_istat)))
  expect_equal(unique(P$regione[P$cod_reg == '02']), "Valle d'Aosta")
  # aggregazione: ARNAD senza valori, stato annotato
  ar <- P[P$codice_istat == '007004' & P$anno == 2024, ]
  expect_equal(ar$rifiuti_stato, 'in_aggregazione'); expect_true(is.na(ar$ru_totale_t))
  cf <- P[P$codice_istat == '007002' & P$anno == 2024, ]
  expect_equal(cf$rifiuti_stato, 'capofila_aggregazione'); expect_true(is.na(cf$ru_totale_t)); expect_true(is.na(cf$ru_procapite_kg))
  # ricodifica 1:1 (AP): vecchio 099001 -> 001013 nel 2022
  expect_true(P$rifiuti_ricodificato[P$codice_istat == '001013' & P$anno == 2022])
  # comune istituito 2023: non esistente 2022 per fonte anno_corrente
  L <- readRDS(file.path(out, 'stato_celle_long.rds'))
  expect_equal(L[codice_istat == '007012' & anno == 2022 & indicatore == 'rd_pct_ispra', stato], 'COMUNE_NON_ESISTENTE')
  expect_equal(L[codice_istat == '001001' & anno == 2015 & indicatore == 'rd_pct_ispra', stato], 'FONTE_NON_ACQUISITA')
  expect_equal(L[codice_istat == '001001' & anno == 2020 & indicatore == 'suolo_consumato_ha', stato], 'FONTE_NON_ACQUISITA')
  # soppresso: fuori geografia, conservato in diagnostica
  fz <- read.csv(file.path(out, 'diagnostica', 'ispra_rifiuti_codici_fuori_geografia_2024.csv'), colClasses = 'character')
  expect_true('001099' %in% fz$codice_istat)
  # denominatore: teorica <= acquisita
  C <- read.csv(file.path(out, 'completezza_comune_anno.csv'), colClasses = c(codice_istat = 'character'))
  expect_true(all(C$completezza_teorica <= C$completezza_acquisita + 1e-12, na.rm = TRUE))
  # QC: RD% ISTAT = 120 rilevato
  qc <- res$qc
  expect_equal(qc$esito[qc$controllo == 'percentuale in [0,100]' & qc$oggetto == 'rd_pct_istat'], 'FAIL')
  expect_equal(qc$esito[qc$controllo == 'aggregazioni non attribuite ai comuni'], 'OK')
  expect_equal(qc$esito[qc$controllo == 'unicita comune x anno'], 'OK')
  # file attesi
  for (f in c('panel_comuni.csv', 'panel_comuni.rds', 'dizionario_indicatori.csv', 'completezza_indicatore_anno.csv',
              'heatmap_copertura_indicatore_anno.png', 'serie_copertura_anno.png', 'finestre_temporali.png',
              'mappa_completezza_totale_2024.png', 'mappa_completezza_ambientale_2023.png', 'completezza_2024.gpkg',
              'comuni_geometrie_2024.gpkg', 'contiguita_comuni.csv', 'pipeline_log.txt', 'download_log.csv',
              'errori_pipeline.csv', 'controlli_qualita.csv', 'ispra_rifiuti_aggregazioni_sovracomunali.csv'))
    expect_true(file.exists(file.path(out, f)), info = f)
  d <- res$dict
  expect_equal(d$stato_estrazione[d$indicatore == 'titolo_secondario_pct'], 'acquisito')
  expect_equal(d$stato_estrazione[d$indicatore == 'reddito_imponibile_medio'], 'FONTE_NON_ACQUISITA')
  assign('OFFLINE_OUT', out, envir = globalenv())
})
