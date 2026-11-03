# Fixture SINTETICHE per test offline. Struttura ISPRA = quella REALE osservata il 02/11/2026
# su getDettaglioComunale.csv.php?aa=2010..2024 (stessa intestazione tutti gli anni):
# riga titolo con tab, 25 intestazioni, righe dati con tab iniziali e ';' finale (26 campi),
# 'Dato riferito a' = Comune | Aggregazione: X (capofila, valori = totale aggregazione) |
# Vedi aggregazione: X (21 campi, '-'), nota finale. Valori NON reali.

ISPRA_HEADER <- c('IstatComune', 'Regione', 'Provincia', 'Comune', 'Popolazione', 'Dato riferito a',
  'Frazione umida(1) (t)', 'Verde (t)', ' Carta e cartone (t)', 'Vetro (t)', 'Legno (t)', 'Metallo (t)', 'Plastica (t)',
  'RAEE (t)', 'Tessili (t)', 'Selettiva (t)', 'Rifiuti da C e D (t)', 'Pulizia stradale a recupero (t)',
  'Ingombranti misti a recupero (t)', 'Altro (t)', 'Totale RD (t)', 'Ingombranti a smaltimento (t)',
  'Indifferenziato (t)', 'Totale RU (t)', 'Percentuale RD (%)')   # 25 nomi

fmt_it <- function(x, d = 3) formatC(formatC(x, format = 'f', digits = d, big.mark = '.', decimal.mark = ','), width = 20)

ispra_row <- function(code8, reg, prov, com, pop, rd, ru, rif = 'Comune') {
  paste0('\t\t\t\t', paste(c(code8, reg, prov, com, pop, rif, fmt_it(rep(rd / 14, 14)), fmt_it(rd), '-',
                              fmt_it(ru - rd), fmt_it(ru), paste0('  ', fmt_it(100 * rd / ru, 2) |> trimws(), '%'), ''),
                            collapse = ';'))   # ';' finale -> 26 campi
}
ispra_rinvio <- function(code8, reg, prov, com, pop, agg)
  paste0('\t\t\t\t', paste(c(code8, reg, prov, com, pop, paste('Vedi aggregazione:', agg), rep('-', 15)), collapse = ';'))   # 21 campi

# comuni sintetici: prov 001 (reg 01 Piemonte) e 007 (reg 02 Valle d'Aosta)
synthetic_comuni <- function() {
  tibble::tibble(codice_istat = c(sprintf('001%03d', 1:13), sprintf('007%03d', 1:12)),
                 comune = c(paste('Comune', 1:12), 'Forlì Test', paste('Valle', 1:11), 'Nuovo Fuso'),
                 cod_reg = rep(c('01', '02'), c(13, 12)), cod_uts = rep(c('001', '007'), c(13, 12)))
}

write_ispra_csv <- function(path, year, comuni, extra = TRUE) {
  L <- c(paste0('\t\tProduzione e raccolta differenziata su scala comunale anno ', year, ' (ISPRA)'), paste(ISPRA_HEADER, collapse = ';'))
  for (i in seq_len(nrow(comuni))) {
    c6 <- comuni$codice_istat[i]; reg <- comuni$cod_reg[i]
    if (year < 2023 && c6 == '007012') next                        # comune istituito nel 2023
    if (year == 2022 && c6 == '001013') next                       # nel 2022 ha ancora il vecchio codice 099001
    regn <- if (reg == '01') 'Piemonte' else "Valle d'Aosta"
    prov <- if (reg == '01') 'Torino' else 'Aosta'
    if (c6 == '007004') {                                           # rinvio spezzato su 2 righe fisiche
      L <- c(L, "\t\t\t\t02007004;Valle d'Aosta;Aosta;ARNAD;1228;", 'Vedi aggregazione: EVANCON-MONT CERVIN;-;-;-;-;-;-;-;-;-;-;-;-;-;-;-')
      next
    }
    if (c6 == '007006') { L <- c(L, ispra_rinvio('02007006', regn, prov, 'VALLE 6', 303, 'EVANCON-MONT CERVIN')); next }
    if (c6 == '007002') { L <- c(L, ispra_row('02007002', regn, prov, "ANTEY-SAINT-ANDRE'", 553, 13617.735, 17968.935,
                                              rif = 'Aggregazione: EVANCON-MONT CERVIN')); next }   # capofila = totale
    code8 <- paste0(reg, c6); if (reg == '01' && i %% 2 == 0) code8 <- sub('^0', '', code8)  # zero perso
    pop <- 1000 + 37 * i; ru <- pop * 0.5; rd <- ru * (0.4 + 0.02 * i)
    row <- ispra_row(code8, regn, prov, toupper(comuni$comune[i]), pop, rd, ru)
    if (c6 == '001005') { f <- strsplit(row, ';', fixed = TRUE)[[1]]; f[24] <- '-'; row <- paste(f, collapse = ';') }   # RU '-' -> NA
    L <- c(L, row)
  }
  if (extra) {
    L <- c(L, '\t\t\t\t01001003;Piemonte;Torino;COMUNE 3;1111;Comune;riga troncata;1;2')                   # anomala
    if (year == 2022) L <- c(L, ispra_row('01001099', 'Piemonte', 'Torino', 'SOPPRESSO', 500, 100, 250))
    if (year == 2022) L <- c(L, ispra_row('01099001', 'Piemonte', 'Torino', 'COMUNE 13', 900, 100, 250))  # vecchio codice (AP)
    L <- c(L, L[3])                                                  # duplicato identico
    L <- c(L, '', 'Note: (1) incluso il quantitativo avviato a compostaggio domestico')
  }
  txt <- iconv(paste(L, collapse = '\r\n'), 'UTF-8', 'CP1252')       # CP1252 per robustezza (reale: ASCII)
  writeBin(charToRaw(txt), path)
  invisible(path)
}

synthetic_geometry_zip <- function(dir) {
  cm <- synthetic_comuni()
  cells <- lapply(seq_len(25), function(k) { i <- (k - 1) %% 5; j <- (k - 1) %/% 5
    sf::st_polygon(list(matrix(c(i, j, i + 1, j, i + 1, j + 1, i, j + 1, i, j) * 1000 + c(400000, 5000000), ncol = 2, byrow = TRUE))) })
  com <- sf::st_sf(COD_RIP = 1L, COD_REG = as.integer(cm$cod_reg), COD_PROV = as.integer(cm$cod_uts), COD_CM = 0L,
                   COD_UTS = as.integer(cm$cod_uts), PRO_COM = as.integer(cm$codice_istat), PRO_COM_T = cm$codice_istat,
                   COMUNE = cm$comune, COMUNE_A = NA_character_, geometry = sf::st_sfc(cells, crs = 32632))
  pv <- sf::st_sf(COD_UTS = c(1L, 7L), DEN_UTS = c('Torino', 'Aosta'), SIGLA = c('TO', 'AO'),
                  geometry = sf::st_sfc(cells[1:2], crs = 32632))
  rg <- sf::st_sf(COD_REG = c(1L, 2L), DEN_REG = c('Piemonte', "Valle d'Aosta"), geometry = sf::st_sfc(cells[1:2], crs = 32632))
  root <- file.path(dir, 'Limiti01012025_g')
  for (nm in c('Com01012025_g', 'ProvCM01012025_g', 'Reg01012025_g')) dir.create(file.path(root, nm), recursive = TRUE)
  sf::st_write(com, file.path(root, 'Com01012025_g', 'Com01012025_g_WGS84.shp'), quiet = TRUE)
  sf::st_write(pv, file.path(root, 'ProvCM01012025_g', 'ProvCM01012025_g_WGS84.shp'), quiet = TRUE)
  sf::st_write(rg, file.path(root, 'Reg01012025_g', 'Reg01012025_g_WGS84.shp'), quiet = TRUE)
  zf <- file.path(dir, 'Limiti01012025_g.zip')
  old <- setwd(dir); on.exit(setwd(old))
  utils::zip(zf, list.files('Limiti01012025_g', recursive = TRUE, full.names = TRUE), flags = '-q')
  zf
}

# Foglio ISTAT sintetico: titolo, riga gruppi (opzionale), riga anni, dati.
istat_sheet <- function(codes, names, years, title, groups = NULL, f = function(i, y) 10 + i + (y - 2014) / 10) {
  ng <- if (is.null(groups)) 1 else length(groups)
  nc <- 2 + ng * length(years)
  hdr_title <- c(title, rep('', nc - 1))
  hdr_grp <- if (!is.null(groups)) c('', '', unlist(lapply(groups, function(g) c(g, rep('', length(years) - 1))))) else NULL
  hdr_y <- c('Codice comune', 'Comune', rep(as.character(years), ng))
  body <- t(vapply(seq_along(codes), function(i) {
    v <- unlist(lapply(seq_len(ng), function(g) vapply(years, function(y) format(f(i, y) * g, nsmall = 2), '')))
    c(codes[i], names[i], v) }, character(nc)))
  m <- rbind(hdr_title, rep('', nc), hdr_grp, hdr_y, body)
  df <- as.data.frame(m, stringsAsFactors = FALSE); names(df) <- paste0('V', seq_len(nc)); df
}

write_variazioni_zip <- function(dir) {
  # colonne nell'ordine del file reale: 'Codice Regione associato' PRIMA del codice comune associato
  d <- data.frame(`Anno` = c('2023', '2023', '2023'), `Tipo variazione` = c('CS', 'ES', 'AP'),
                  `Codice Regione` = c('02', '01', '01'), `Codice Unità territoriale sovracomunale` = c('007', '001', '099'),
                  `Codice Comune formato numerico` = c('7012', '1099', '99001'),
                  `Codice Regione associato alla variazione` = c('', '02', '01'),
                  `Codice Unità territoriale sovracomunale associato alla variazione` = c('', '007', '001'),
                  `Denominazione Comune` = c('Nuovo Fuso', 'Soppresso', 'Comune 13'),
                  `Codice del Comune associato alla variazione o nuovo codice Istat del Comune` = c('', '7012', '1013'),
                  `Denominazione Comune associata alla variazione o nuova denominazione` = c('', 'Nuovo Fuso', 'Comune 13'),
                  `Data decorrenza validità amministrativa` = c('01/01/2023', '01/01/2023', '01/05/2023'),
                  check.names = FALSE)
  sub <- file.path(dir, 'var'); dir.create(sub)
  writexl::write_xlsx(d, file.path(sub, 'Variazioni_amministrative.xlsx'))
  zf <- file.path(dir, 'variazioni_dal_1991.zip')
  old <- setwd(sub); on.exit(setwd(old)); utils::zip(zf, 'Variazioni_amministrative.xlsx', flags = '-q')
  zf
}

# Popola una cartella raw/ come cache: la pipeline la usa senza rete.
build_offline_raw <- function(root) {
  raw <- file.path(root, 'raw'); dir.create(raw, recursive = TRUE)
  tmp <- file.path(root, 'tmpfx'); dir.create(tmp)
  file.copy(synthetic_geometry_zip(tmp), file.path(raw, 'Limiti01012025_g.zip'))
  file.copy(write_variazioni_zip(tmp), file.path(raw, 'variazioni_dal_1991.zip'))
  cm <- synthetic_comuni()
  # pop: codici numerici senza zeri (come Excel), anni 2014-2024
  pop <- istat_sheet(as.character(as.integer(cm$codice_istat)), cm$comune, 2014:2024, 'Tavola 1.1 - Popolazione residente',
                     f = function(i, y) 1000 + 37 * i + (y - 2014))
  writexl::write_xlsx(list(`Tav. 1.1` = pop), file.path(raw, '1a-Popolazione-valori-assoluti.xlsx'), col_names = FALSE)
  # ambiente: RD% 6.1 (valore 120 fuori range su un comune per test QC), pre-euro4 8.1, suolo 9.1
  rd <- istat_sheet(cm$codice_istat, cm$comune, 2014:2024, 'Tavola 6.1 - Raccolta differenziata (%)',
                    f = function(i, y) if (i == 3 && y == 2020) 120 else 40 + 2 * i)
  e8 <- istat_sheet(cm$codice_istat, cm$comune, 2014:2023, 'Tavola 8.1 - Autovetture fino a Euro 3 (%)')
  e9 <- istat_sheet(cm$codice_istat, cm$comune, 2015:2024, 'Tavola 9.1 - Suolo consumato (%)', f = function(i, y) 5 + i / 10)
  writexl::write_xlsx(list(`Tav. 6.1` = rd, `Tav. 8.1` = e8, `Tav. 9.1` = e9), file.path(raw, '11-Territorio-e-ambiente.xlsx'), col_names = FALSE)
  # istruzione per sesso: gruppi Maschi/Femmine/Totale con celle unite
  ed4 <- istat_sheet(cm$codice_istat, cm$comune, 2018:2023, 'Tavola 4.1 - Titolo secondario (%)', groups = c('Maschi', 'Femmine', 'Totale'), f = function(i, y) 5 + i / 2)
  ed5 <- istat_sheet(cm$codice_istat, cm$comune, 2018:2023, 'Tavola 5.1 - Titolo terziario (%)', groups = c('Maschi', 'Femmine', 'Totale'), f = function(i, y) 2 + i / 4)
  writexl::write_xlsx(list(`Tav. 4.1` = ed4, `Tav. 5.1` = ed5), file.path(raw, '4-Istruzione.xlsx'), col_names = FALSE)
  for (y in 2022:2024) write_ispra_csv(file.path(raw, paste0('ispra_rifiuti_', y, '.csv')), y, cm)
  unlink(tmp, recursive = TRUE)
  raw
}
