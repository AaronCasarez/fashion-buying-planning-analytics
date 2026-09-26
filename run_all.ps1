# Rebuilds the DuckDB database, runs every analysis file in order, and
# writes the Tableau exports. Run from the repo root:
#   .\run_all.ps1
# Requires the DuckDB CLI (https://duckdb.org/docs/installation) on PATH,
# or set $duckdb below to its full path.

$duckdb = "duckdb"
if (Test-Path "..\tools\duckdb.exe") { $duckdb = "..\tools\duckdb.exe" }

$files = @(
    "sql/00_load_data.sql",
    "sql/01_data_quality_checks.sql",
    "sql/02_business_performance.sql",
    "sql/03_category_performance.sql",
    "sql/04_product_performance.sql",
    "sql/05_trend_analysis.sql",
    "sql/06_assortment_opportunities.sql",
    "sql/07_tableau_exports.sql"
)

New-Item -ItemType Directory -Force exports | Out-Null

foreach ($f in $files) {
    Write-Host "Running $f ..."
    & $duckdb hm.duckdb -c ".read $f" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed on $f" }
}
Write-Host "Done. Tableau files are in exports/."
