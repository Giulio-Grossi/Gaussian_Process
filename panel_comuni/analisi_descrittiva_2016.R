#!/usr/bin/env Rscript
# =============================================================================
# analisi_descrittiva_2016.R
# Analisi descrittiva del panel comuni (output di build_panel_comuni_v3.R), anni 2016+.
# Uso: source("analisi_descrittiva_2016.R")  oppure  Rscript analisi_descrittiva_2016.R
# Input : output_v3/{panel_comuni.rds, stato_celle_long.rds, dizionario_indicatori.csv,
#                    comuni_geometrie_2024.gpkg, contiguita_comuni.rds}
# Output: analisi_2016/ (tabelle CSV + figure PNG)
# Nessuna imputazione: ogni statistica usa solo valori osservati, n sempre riportato.
# =============================================================================

CFG <- list(
  years      = 2016:2024,
  ref_year   = 2022L,      # anno di riferimento per correlazioni/Moran (max indicatori disponibili)
  cov_soglia = 0.90,       # copertura minima per dire "indicatore disponibile nell'anno"
  simplify_m = 400,        # semplificazione geometrie per mappe (metri)
  n_perm     = 199,        # permutazioni test Moran
  rho_alto   = 0.85,       # soglia ridondanza (Spearman)
  mappe_stato = TRUE,      # mappe di completezza per indicatore (lente: ~1 min/indicatore)
  mappe_valori = TRUE
)
`%||%` <- function(a, b) if (is.null(a) || !length(a)) b else a

.this_dir <- function() {
  a <- grep('^--file=', commandArgs(FALSE), value = TRUE)
  if (length(a)) return(dirname(normalizePath(sub('^--file=', '', a[1]))))
  for (i in rev(seq_len(sys.nframe()))) { f <- sys.frame(i)$ofile; if (!is.null(f)) return(dirname(normalizePath(f))) }
  getwd()
}
ROOT <- getOption('panel.root') %||% .this_dir()
IN   <- file.path(ROOT, 'output_v3')
OUT  <- file.path(ROOT, 'analisi_2016'); dir.create(file.path(OUT, 'mappe_completezza'), recursive = TRUE, showWarnings = FALSE)
dir.create(file.path(OUT, 'mappe_valori'), showWarnings = FALSE)

for (p in c('dplyr', 'tidyr', 'readr', 'ggplot2', 'scales', 'sf', 'data.table'))
  if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = 'https://cloud.r-project.org')
suppressPackageStartupMessages({ library(dplyr); library(tidyr); library(ggplot2); library(sf); library(data.table) })
msg <- function(...) message(format(Sys.time(), '%H:%M:%S'), ' ', ...)
wcsv <- function(x, f) readr::write_csv(as.data.frame(x), file.path(OUT, f), na = 'NA')
gsave <- function(p, f, w, h) ggsave(file.path(OUT, f), p, width = w, height = h, dpi = 160, bg = 'white')

# ---- 1. DATI -----------------------------------------------------------------
P    <- readRDS(file.path(IN, 'panel_comuni.rds')) |> filter(anno %in% CFG$years)
ST   <- as.data.table(readRDS(file.path(IN, 'stato_celle_long.rds')))[anno %in% CFG$years]
DIC  <- readr::read_csv(file.path(IN, 'dizionario_indicatori.csv'), show_col_types = FALSE)
G    <- sf::st_read(file.path(IN, 'comuni_geometrie_2024.gpkg'), quiet = TRUE)
NB   <- readRDS(file.path(IN, 'contiguita_comuni.rds'))
stopifnot(identical(NB$codici, G$codice_istat))
Gs   <- sf::st_simplify(G[, c('codice_istat', 'regione')], preserveTopology = TRUE, dTolerance = CFG$simplify_m)
REG  <- sf::st_simplify(G |> group_by(regione) |> summarise(.groups = 'drop'), preserveTopology = TRUE, dTolerance = 1000)   # confini regionali

# indicatori elementari (escluso ausiliario) + derivati normalizzati per il composito
IND <- DIC |> filter(in_completezza) |> transmute(indicatore, descrizione, dimensione, unita, polarita, fonte, derivato = FALSE)
P <- P |> mutate(
  variazione_suolo_ha_km2 = variazione_netta_suolo_ha / area_km2,                       # ha per km2 di territorio
  variazione_suolo_m2_ab  = 1e4 * variazione_netta_suolo_ha / popolazione,              # m2 per abitante
  suolo_consumato_m2_ab   = 1e4 * suolo_consumato_ha / popolazione)
IND <- bind_rows(IND, tibble(
  indicatore = c('variazione_suolo_ha_km2', 'variazione_suolo_m2_ab', 'suolo_consumato_m2_ab'),
  descrizione = c('Variazione netta suolo consumato per km2 di superficie', 'Variazione netta suolo consumato per abitante',
                  'Suolo consumato per abitante'),
  dimensione = 'ambientale', unita = c('ha/km2', 'm2/ab', 'm2/ab'), polarita = '-',
  fonte = 'derivato (ISPRA suolo, ISTAT pop/area)', derivato = TRUE))
ids <- IND$indicatore
msg('Comuni: ', n_distinct(P$codice_istat), ' | anni: ', paste(range(P$anno), collapse = '-'), ' | indicatori: ', length(ids))

# ---- 2. COPERTURA 2016+ ------------------------------------------------------------
# osservato/esistente da stato celle (fonti) + da valori (derivati)
cov_st <- ST[, .(n_esistenti = sum(stato != 'COMUNE_NON_ESISTENTE'), n_osservati = sum(stato == 'OSSERVATO'),
                 n_mancanti = sum(stato == 'MANCANTE'), n_aggregati = sum(stato == 'DATO_AGGREGATO'),
                 n_assenti = sum(stato == 'ASSENTE_IN_FONTE'),
                 rilevato = any(!stato %in% c('ANNO_NON_RILEVATO', 'FONTE_NON_ACQUISITA'))), by = .(indicatore, anno)]
cov_der <- rbindlist(lapply(IND$indicatore[IND$derivato], function(id) {
  d <- as.data.table(P)[, .(n_esistenti = .N, n_osservati = sum(!is.na(get(id))), n_mancanti = sum(is.na(get(id))),
                           n_aggregati = 0L, n_assenti = 0L, rilevato = any(!is.na(get(id)))), by = anno]
  d[, indicatore := id][]
}), use.names = TRUE)
COV <- rbind(cov_st, cov_der, use.names = TRUE)[indicatore %in% ids]
COV[, copertura := fifelse(rilevato, n_osservati / n_esistenti, NA_real_)]
COV <- merge(COV, as.data.table(IND[, c('indicatore', 'dimensione', 'polarita', 'derivato')]), by = 'indicatore')
wcsv(COV[order(dimensione, indicatore, anno)], 'copertura_indicatore_anno_2016.csv')

# riepilogo per indicatore: anni disponibili (copertura >= soglia), copertura media
RIEP <- COV[, .(anni_rilevati = paste(anno[rilevato], collapse = ';'),
                anni_pieni = paste(anno[rilevato & copertura >= CFG$cov_soglia], collapse = ';'),
                n_anni_pieni = sum(rilevato & copertura >= CFG$cov_soglia, na.rm = TRUE),
                copertura_media = mean(copertura[rilevato], na.rm = TRUE),
                copertura_min = suppressWarnings(min(copertura[rilevato], na.rm = TRUE)),
                quota_aggregati = sum(n_aggregati) / sum(n_esistenti[rilevato])), by = .(indicatore, dimensione, polarita, derivato)]

hm <- ggplot(COV, aes(factor(anno), reorder(indicatore, as.numeric(factor(dimensione))))) +
  geom_tile(aes(fill = copertura), colour = 'white', linewidth = .4) +
  geom_text(aes(label = ifelse(rilevato, sprintf('%.0f', 100 * copertura), ''), colour = !is.na(copertura) & copertura > .6), size = 2.6, show.legend = FALSE) +
  scale_colour_manual(values = c(`TRUE` = 'white', `FALSE` = '#222222')) +
  scale_fill_gradient(low = '#eef3fb', high = '#1d4f91', limits = c(0, 1), na.value = '#e3e3e3', labels = scales::percent, name = 'Comuni\ncon dato') +
  facet_grid(dimensione ~ ., scales = 'free_y', space = 'free_y') +
  labs(x = NULL, y = NULL, title = 'Copertura comunale 2016-2024 per indicatore', subtitle = 'Grigio: anno non rilevato dalla fonte. Derivati: calcolati da variabili del panel') +
  theme_minimal(base_size = 10) + theme(panel.grid = element_blank(), strip.text.y = element_text(angle = 0, hjust = 0))
gsave(hm, 'heatmap_copertura_2016.png', 11, 11)

# finestre: per ogni finestra, indicatori pieni in tutti gli anni e comuni con panel bilanciato su quegli indicatori
win_list <- list(c(2016, 2023), c(2018, 2023), c(2019, 2023), c(2021, 2023), c(2022, 2023), c(2016, 2024), c(2022, 2024), c(2023, 2023), c(2024, 2024))
WIN <- rbindlist(lapply(win_list, function(w) {
  yy <- seq(w[1], w[2])
  ok <- COV[anno %in% yy, .(pieno = .N == length(yy) && all(rilevato & copertura >= CFG$cov_soglia)), by = indicatore][pieno == TRUE, indicatore]
  ok <- intersect(ok, ids)
  bal <- if (length(ok)) {
    d <- as.data.table(P)[anno %in% yy, c('codice_istat', ok), with = FALSE]
    d[, .(compl = all(!is.na(as.matrix(.SD)))), by = codice_istat][, sum(compl)]
  } else NA_integer_
  data.table(finestra = paste(w, collapse = '-'), n_anni = length(yy), n_indicatori_pieni = length(ok),
             comuni_panel_bilanciato = bal, quota_comuni = bal / n_distinct(P$codice_istat), indicatori = paste(ok, collapse = ';'))
}))
wcsv(WIN, 'finestre_bilanciate.csv')

# ---- 3. MAPPE DI COMPLETEZZA ------------------------------------------------------------
STATI <- c(OSSERVATO = '#1d4f91', MANCANTE = '#e08a1e', DATO_AGGREGATO = '#8e5bb5', ASSENTE_IN_FONTE = '#c23b3b',
           COMUNE_NON_ESISTENTE = '#4d4d4d', ANNO_NON_RILEVATO = '#e3e3e3', FONTE_NON_ACQUISITA = '#000000')
# (a) completezza del periodo per comune: totale e per dimensione (celle teoriche osservate)
CP <- ST[!stato %in% c('ANNO_NON_RILEVATO', 'COMUNE_NON_ESISTENTE')]
CP <- merge(CP, as.data.table(IND[, c('indicatore', 'dimensione')]), by = 'indicatore')
comp_tot <- CP[, .(completezza = mean(stato == 'OSSERVATO'), n_celle = .N), by = codice_istat]
comp_dim <- CP[, .(completezza = mean(stato == 'OSSERVATO'), n_celle = .N), by = .(codice_istat, dimensione)]
comp_anno <- CP[, .(completezza = mean(stato == 'OSSERVATO')), by = .(codice_istat, anno)]
wcsv(merge(comp_tot, dcast(comp_dim, codice_istat ~ paste0('completezza_', dimensione), value.var = 'completezza'), by = 'codice_istat'),
     'completezza_comune_periodo_2016.csv')
map_theme <- theme_void(base_size = 10) + theme(plot.title = element_text(face = 'bold'), legend.position = 'right')
seq_fill <- function(name = 'Completezza') scale_fill_gradient(low = '#f4e9dc', high = '#1d4f91', limits = c(0, 1), labels = scales::percent, name = name, na.value = '#e3e3e3')
p <- ggplot(left_join(Gs, as_tibble(comp_tot), by = 'codice_istat')) + geom_sf(aes(fill = completezza), colour = NA) +
  geom_sf(data = REG, fill = NA, colour = 'white', linewidth = .25) + seq_fill() +
  labs(title = 'Completezza complessiva 2016-2024', subtitle = 'Quota di celle (indicatore x anno teorici) osservate per comune') + map_theme
gsave(p, 'mappa_completezza_periodo_totale.png', 8, 9)
p <- ggplot(left_join(Gs, as_tibble(comp_dim), by = 'codice_istat', relationship = 'many-to-many') |> filter(!is.na(dimensione))) +
  geom_sf(aes(fill = completezza), colour = NA) + facet_wrap(~dimensione, ncol = 3) + seq_fill() +
  labs(title = 'Completezza 2016-2024 per dimensione') + map_theme
gsave(p, 'mappa_completezza_periodo_dimensioni.png', 13, 10)
p <- ggplot(left_join(Gs, as_tibble(comp_anno), by = 'codice_istat', relationship = 'many-to-many') |> filter(!is.na(anno))) +
  geom_sf(aes(fill = completezza), colour = NA) + facet_wrap(~anno, ncol = 3) + seq_fill() +
  labs(title = 'Completezza per anno (denominatore: indicatori teorici dell\'anno)') + map_theme
gsave(p, 'mappa_completezza_per_anno.png', 12, 13)

# (b) una mappa di stato per indicatore (anni teorici 2016+)
if (CFG$mappe_stato) for (id in setdiff(ids, IND$indicatore[IND$derivato])) {
  d <- ST[indicatore == id]; yy <- sort(unique(d[stato != 'ANNO_NON_RILEVATO', anno]))
  if (!length(yy)) next
  gm <- merge(Gs, as.data.frame(d[anno %in% yy, .(codice_istat, anno, stato)]), by = 'codice_istat')
  gm$stato <- factor(gm$stato, levels = names(STATI))
  ccov <- COV[indicatore == id & anno %in% yy]; lab <- setNames(sprintf('%d  (%.0f%%)', ccov$anno, 100 * ccov$copertura), ccov$anno)
  p <- ggplot(gm) + geom_sf(aes(fill = stato), colour = NA) + facet_wrap(~anno, ncol = min(3, length(yy)), labeller = as_labeller(lab)) +
    scale_fill_manual(values = STATI, drop = TRUE, name = NULL) +
    labs(title = id, subtitle = paste0(IND$descrizione[IND$indicatore == id], ' - stato del dato per comune (tra parentesi: % comuni osservati)')) + map_theme
  nr <- ceiling(length(yy) / 3)
  gsave(p, file.path('mappe_completezza', paste0(id, '.png')), 4 * min(3, length(yy)) + 2, 4.3 * nr + 1)
  msg('mappa stato: ', id)
}

# ---- 4. STATISTICHE DESCRITTIVE ------------------------------------------------------------
skew <- function(x) { x <- x[!is.na(x)]; if (length(x) < 3 || sd(x) == 0) return(NA_real_); mean((x - mean(x))^3) / sd(x)^3 }
DESC <- rbindlist(lapply(ids, function(id) as.data.table(P)[, {
  x <- get(id); o <- x[!is.na(x)]; m <- stats::median(o); md <- stats::mad(o)
  .(n = length(o), media = mean(o), sd = sd(o), cv = sd(o) / abs(mean(o)), min = suppressWarnings(min(o)),
    p05 = quantile(o, .05, names = FALSE), p25 = quantile(o, .25, names = FALSE), mediana = m,
    p75 = quantile(o, .75, names = FALSE), p95 = quantile(o, .95, names = FALSE), max = suppressWarnings(max(o)),
    asimmetria = skew(o), quota_zeri = mean(o == 0), n_outlier_5mad = if (md > 0) sum(abs(o - m) > 5 * md) else NA_integer_)
}, by = anno][n > 0][, indicatore := id][]), use.names = TRUE)
DESC <- merge(as.data.table(IND[, c('indicatore', 'dimensione', 'unita', 'polarita')]), DESC, by = 'indicatore')
wcsv(DESC[order(dimensione, indicatore, anno)], 'statistiche_descrittive_2016.csv')

# andamento mediana e intervallo interquartile per anno
p <- ggplot(DESC, aes(anno, mediana)) + geom_ribbon(aes(ymin = p25, ymax = p75), fill = '#c9d6ea') +
  geom_line(colour = '#1d4f91', linewidth = .7) + geom_point(colour = '#1d4f91', size = 1.4) +
  facet_wrap(~ paste0(indicatore, ' [', unita, ']'), scales = 'free_y', ncol = 5) +
  scale_x_continuous(breaks = CFG$years, labels = function(b) substr(b, 3, 4)) +
  labs(x = NULL, y = NULL, title = 'Mediana comunale (linea) e intervallo interquartile (banda), 2016-2024') +
  theme_minimal(base_size = 8) + theme(panel.grid.minor = element_blank(), strip.text = element_text(size = 7))
gsave(p, 'andamento_mediane_2016.png', 16, 14)

# ---- 5. MAPPE DEI VALORI (ultimo anno disponibile, decili) ----------------------------------------
last_year <- COV[rilevato & copertura > 0, .(anno_mappa = max(anno)), by = indicatore]
if (CFG$mappe_valori) for (id in ids) {
  y <- last_year[indicatore == id, anno_mappa]; if (!length(y)) next
  d <- P[P$anno == y, c('codice_istat', id)]; names(d)[2] <- 'v'
  br <- unique(quantile(d$v, seq(0, 1, .1), na.rm = TRUE))
  d$classe <- if (length(br) > 2) cut(d$v, br, include.lowest = TRUE, dig.lab = 4) else factor(d$v)
  nl <- nlevels(d$classe)
  pal <- grDevices::colorRampPalette(c('#f4e9dc', '#1d4f91'))(nl)
  ii <- IND[IND$indicatore == id, ]
  p <- ggplot(left_join(Gs, d, by = 'codice_istat')) + geom_sf(aes(fill = classe), colour = NA) +
    geom_sf(data = REG, fill = NA, colour = 'white', linewidth = .2) +
    scale_fill_manual(values = pal, na.value = '#bdbdbd', name = paste0('Decili\n[', ii$unita, ']'), na.translate = TRUE, labels = function(l) ifelse(is.na(l), 'non osservato', l)) +
    labs(title = paste0(id, ' - ', y), subtitle = paste0(ii$descrizione, ' | polarita: ', ii$polarita, ' | scuro = valori alti'),
         caption = 'Grigio: non osservato (mancante, aggregato, assente). Nessuna imputazione.') + map_theme
  gsave(p, file.path('mappe_valori', paste0(id, '_', y, '.png')), 8, 9)
}
msg('mappe valori ok')

# ---- 6. CORRELAZIONI (anno di riferimento) ------------------------------------------------------
yr <- CFG$ref_year
avail <- COV[anno == yr & rilevato & copertura >= 0.5, indicatore]
X <- as.data.frame(P[P$anno == yr, intersect(ids, avail)])
R <- suppressWarnings(stats::cor(X, method = 'spearman', use = 'pairwise.complete.obs'))
Nn <- crossprod(!is.na(as.matrix(X)))
ord <- stats::hclust(stats::as.dist(1 - abs(R)), method = 'average')$order
RL <- as.data.table(as.table(R)); setnames(RL, c('a', 'b', 'rho'))
RL[, `:=`(a = factor(a, levels = colnames(R)[ord]), b = factor(b, levels = colnames(R)[ord]))]
p <- ggplot(RL, aes(a, b, fill = rho)) + geom_tile(colour = 'white') +
  geom_text(aes(label = ifelse(abs(rho) >= .5 & a != b, sprintf('%.2f', rho), '')), size = 2.2) +
  scale_fill_gradient2(low = '#b2182b', mid = '#f7f7f7', high = '#2166ac', limits = c(-1, 1), name = 'Spearman') +
  labs(x = NULL, y = NULL, title = paste0('Correlazioni di Spearman tra indicatori, ', yr), subtitle = 'Ordinamento per cluster gerarchico su 1-|rho|; numeri solo se |rho| >= 0.5') +
  theme_minimal(base_size = 9) + theme(axis.text.x = element_text(angle = 60, hjust = 1), panel.grid = element_blank())
gsave(p, paste0('correlazioni_spearman_', yr, '.png'), 12, 11)
up <- which(upper.tri(R), arr.ind = TRUE)
PAIRS <- data.table(a = rownames(R)[up[, 1]], b = colnames(R)[up[, 2]], rho = R[up], n = Nn[up])[order(-abs(rho))]
wcsv(PAIRS, paste0('correlazioni_coppie_', yr, '.csv'))
wcsv(PAIRS[abs(rho) >= CFG$rho_alto], paste0('coppie_ridondanti_', yr, '.csv'))

# ---- 7. AUTOCORRELAZIONE SPAZIALE (Moran I, queen, standardizzata per riga) -----------------------
moran <- function(x, nb, nperm = CFG$n_perm) {
  ok <- !is.na(x); idx <- which(ok); pos <- integer(length(x)); pos[idx] <- seq_along(idx)
  ii <- rep(seq_along(nb), lengths(nb)); jj <- unlist(nb)
  keep <- ok[ii] & ok[jj]; ii <- pos[ii[keep]]; jj <- pos[jj[keep]]
  deg <- tabulate(ii, length(idx)); has <- deg > 0
  z <- x[idx] - mean(x[idx]); w <- 1 / deg[ii]
  stat <- function(z) { lag <- numeric(length(z)); lag[has] <- rowsum(w * z[jj], ii)[, 1]; sum(z[has] * lag[has]) / sum(z[has]^2) }
  I <- stat(z); perm <- replicate(nperm, stat(sample(z)))
  c(I = I, atteso = -1 / (sum(has) - 1), z_perm = (I - mean(perm)) / sd(perm), p_perm = (1 + sum(perm >= I)) / (nperm + 1),
    n = sum(has), isolati_o_senza_vicini_osservati = sum(!has))
}
set.seed(2016)
ord_codes <- match(NB$codici, P$codice_istat[P$anno == yr])
MOR <- rbindlist(lapply(intersect(ids, avail), function(id) {
  out <- lapply(c(yr, last_year[indicatore == id, anno_mappa]), function(y) {
    v <- P[[id]][P$anno == y][match(NB$codici, P$codice_istat[P$anno == y])]
    if (sum(!is.na(v)) < 100) return(NULL)
    as.data.table(as.list(moran(v, NB$queen)))[, `:=`(indicatore = id, anno = y)]
  })
  rbindlist(out)
}), use.names = TRUE) |> unique(by = c('indicatore', 'anno'))
MOR <- merge(MOR, as.data.table(IND[, c('indicatore', 'dimensione')]), by = 'indicatore')
wcsv(MOR[order(-I)], 'moran_I.csv')
p <- ggplot(MOR[anno == yr], aes(I, reorder(indicatore, I), fill = dimensione)) + geom_col(width = .7) +
  scale_fill_manual(values = c(ambientale = '#2a7f62', economica = '#1d4f91', sociale = '#c05a1b', demografica = '#7b6ea8', infrastrutturale = '#8a8a3a')) +
  labs(x = "I di Moran (contiguita queen, pesi standardizzati per riga)", y = NULL, title = paste0('Autocorrelazione spaziale degli indicatori, ', yr),
       subtitle = paste0('Tutti i valori con p di permutazione <= ', sprintf('%.3f', max(MOR$p_perm)), ' sono significativi rispetto a 0')) +
  theme_minimal(base_size = 10) + theme(legend.position = 'top', panel.grid.major.y = element_blank())
gsave(p, paste0('moran_I_', yr, '.png'), 9, 8)

# ---- 8. STABILITA' TEMPORALE ------------------------------------------------------------------
STAB <- rbindlist(lapply(ids, function(id) {
  d <- as.data.table(P)[!is.na(get(id)), .(codice_istat, anno, v = get(id))]
  if (length(unique(d$anno)) < 2) return(NULL)
  y0 <- min(d$anno); y1 <- max(d$anno)
  w <- dcast(d[anno %in% c(y0, y1)], codice_istat ~ anno, value.var = 'v')
  rho <- suppressWarnings(stats::cor(w[[2]], w[[3]], method = 'spearman', use = 'complete.obs'))
  d[, mu := mean(v), by = codice_istat]
  quota_between <- d[, sum((mu - mean(v))^2) / sum((v - mean(v))^2)]
  data.table(indicatore = id, anno_inizio = y0, anno_fine = y1, rho_spearman_inizio_fine = rho,
             quota_varianza_tra_comuni = quota_between, n_anni = length(unique(d$anno)))
}))
wcsv(STAB, 'stabilita_temporale.csv')

# ---- 9. PROFILO REGIONALE (mediane, anno di riferimento) ------------------------------------------
RG <- as.data.table(P)[anno == yr, lapply(.SD, function(x) stats::median(x, na.rm = TRUE)), by = regione, .SDcols = intersect(ids, avail)]
wcsv(RG, paste0('mediane_regionali_', yr, '.csv'))
RGL <- melt(RG, id.vars = 'regione', variable.name = 'indicatore', value.name = 'mediana')
RGL[, z := (mediana - mean(mediana, na.rm = TRUE)) / sd(mediana, na.rm = TRUE), by = indicatore]
RGL <- merge(RGL, as.data.table(IND[, c('indicatore', 'polarita', 'dimensione')]), by = 'indicatore')
RGL[, z_orientato := fcase(polarita == '+', z, polarita == '-', -z, default = NA_real_)]
p <- ggplot(RGL[!is.na(z_orientato)], aes(indicatore, regione, fill = pmax(pmin(z_orientato, 2.5), -2.5))) + geom_tile(colour = 'white') +
  facet_grid(. ~ dimensione, scales = 'free_x', space = 'free_x') +
  scale_fill_gradient2(low = '#b2182b', mid = '#f7f7f7', high = '#2166ac', limits = c(-2.5, 2.5), name = 'z orientato\n(+ = meglio)') +
  labs(x = NULL, y = NULL, title = paste0('Profilo regionale delle mediane comunali, ', yr),
       subtitle = 'z-score tra regioni, segno invertito per indicatori a polarita negativa; esclusi contesto/ambigui') +
  theme_minimal(base_size = 9) + theme(axis.text.x = element_text(angle = 60, hjust = 1), panel.grid = element_blank())
gsave(p, paste0('profilo_regionale_', yr, '.png'), 13, 8)

# ---- 10. SCHEDA DI SINTESI PER INDICATORE ---------------------------------------------------------
SCH <- Reduce(function(a, b) merge(a, b, by = 'indicatore', all.x = TRUE), list(
  as.data.table(IND[, c('indicatore', 'descrizione', 'dimensione', 'unita', 'polarita', 'fonte', 'derivato')]),
  RIEP[, .(indicatore, anni_pieni, n_anni_pieni, copertura_media, copertura_min, quota_aggregati)],
  DESC[anno == yr, .(indicatore, cv_ref = cv, asimmetria_ref = asimmetria, quota_zeri_ref = quota_zeri)],
  MOR[anno == yr, .(indicatore, moran_I_ref = I, moran_p_ref = p_perm)],
  STAB[, .(indicatore, rho_inizio_fine = rho_spearman_inizio_fine, quota_varianza_tra_comuni)],
  rbind(PAIRS, PAIRS[, .(a = b, b = a, rho, n)])[abs(rho) >= CFG$rho_alto, .(ridondante_con = paste0(b, ' (', sprintf('%.2f', rho), ')', collapse = '; ')), by = .(indicatore = a)]))
wcsv(SCH[order(dimensione, indicatore)], 'scheda_indicatori.csv')
msg('FINE. Output in ', OUT)
