#!/usr/bin/env bash
set -euo pipefail
pipeline="${1:?pipeline script}"
exec bash "$pipeline"