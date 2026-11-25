#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RUN_ID="$(python3 -c "import json,os; print(json.loads(os.environ.get('JOB_INPUTS_JSON','{}'))['run_id'])")"
export RUN_ID
export GH_TOKEN="${GITHUB_SIM_TOKEN:-${GH_TOKEN:-}}"
export GITHUB_SIM_TOKEN="${GH_TOKEN:-}"

python3 -m venv "$RUN_DIR/venv"
source "$RUN_DIR/venv/bin/activate"
pip install -q -r requirements.txt
git checkout -qf dev
git pull -q origin dev || true
python scripts/ci_run_sim_fix.py