# Rscript tests/run_tests.R   (da panel_comuni/)
options(panel.run = FALSE)
here <- if (file.exists('build_panel_comuni_v3.R')) '.' else '..'
source(file.path(here, 'build_panel_comuni_v3.R'))
source(file.path(here, 'tests', 'helper_fixtures.R'))
CONFIG$n_min_comuni <- 10L   # fixture: 25 comuni
for (p in c('testthat', 'writexl')) if (!requireNamespace(p, quietly = TRUE)) install.packages(p, repos = 'https://cloud.r-project.org')
res <- testthat::test_file(file.path(here, 'tests', 'test_pipeline.R'), reporter = 'summary', stop_on_failure = FALSE)
df <- as.data.frame(res)
cat('\nTest:', nrow(df), '| falliti:', sum(df$failed), '| errori:', sum(df$error), '\n')
if (sum(df$failed) + sum(df$error) > 0) quit(status = 1)
