#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export FLUIDVOICE_APP_NAME="FluidVoice Personal"
export FLUIDVOICE_DERIVED_DATA_PATH="${FLUIDVOICE_DERIVED_DATA_PATH:-${PROJECT_DIR}/DerivedData}"
exec "${PROJECT_DIR}/build.sh" "${1:-public}"
