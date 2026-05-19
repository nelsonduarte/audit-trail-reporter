# Transpile + run the audit-trail-reporter.
#
# Capa's --run mode does not pass extra arguments through to
# the program. This wrapper transpiles to a temporary .py and
# runs it with the args the user passed.

$ErrorActionPreference = "Stop"

Set-Location -LiteralPath $PSScriptRoot

if (-not (Test-Path "out")) {
    New-Item -ItemType Directory -Path "out" | Out-Null
}

$env:CAPA_PATH = "libraries"
python -m capa --transpile reporter.capa | Out-File -Encoding utf8 _reporter.py
python _reporter.py @args
