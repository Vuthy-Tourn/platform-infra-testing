#!/usr/bin/env bash
set -euo pipefail

SERVICE_PATH="${1:-.}"

if [[ ! -d "${SERVICE_PATH}" ]]; then
  echo "Service path does not exist for Dockerfile detection: ${SERVICE_PATH}" >&2
  exit 1
fi

find "${SERVICE_PATH}" -maxdepth 1 -type f \( -iname 'Dockerfile' -o -iname 'dockerfile' \) | sort | head -n1 || true
