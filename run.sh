#!/usr/bin/env bash
# Transpile + run the audit-trail-reporter.
#
# Capa's `--run` mode does not pass extra arguments through to
# the program. This wrapper transpiles to a temporary .py and
# runs it with the args the user passed.
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p out

export CAPA_PATH="libraries"
python -m capa --transpile reporter.capa > _reporter.py
python _reporter.py "$@"
