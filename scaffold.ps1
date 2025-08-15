Write-Host "Erstelle Projektstruktur..."

New-Item -ItemType Directory -Force -Path docs,src\mt5\ea,src\mt5\indicators,src\mt5\include,src\gpt_mode,src\tools,tests,data\raw,data\processed,configs,.github\ISSUE_TEMPLATE | Out-Null

Set-Content .gitignore "# Git ignore rules"
Set-Content LICENSE "MIT License"
Set-Content README.md "# XAUUSD Meta-Strategy Bot"
Set-Content README_DEV.md "# README_DEV – Laufende Entwickler-Doku"
Set-Content CONTRIBUTING.md "# Contributing rules"
Set-Content .github\PULL_REQUEST_TEMPLATE.md "## PR Template"
Set-Content .github\ISSUE_TEMPLATE\bug_report.md "--- Bug report template ---"
Set-Content .github\ISSUE_TEMPLATE\feature_request.md "--- Feature request template ---"
Set-Content src\mt5\ea\XAUUSD_MasterEA_v1_0.mq5 "// EA Stub"
Set-Content src\gpt_mode\response.schema.json "{}"
Set-Content configs\example.runtime.json "{}"

Write-Host "Projektstruktur erstellt."
