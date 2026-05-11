#!/usr/bin/env bash
set -euo pipefail

# Java / Spring Boot
# Checks root first, then one level deep to support multi-module repos
# where build.gradle lives inside submodule directories (e.g. api-gateway/build.gradle).
find_gradle_file() {
  [[ -f build.gradle ]]     && echo 'build.gradle'     && return
  [[ -f build.gradle.kts ]] && echo 'build.gradle.kts' && return
  find . -maxdepth 2 \( -name 'build.gradle' -o -name 'build.gradle.kts' \) \
    ! -path './.git/*' | sort | head -n1
}

if [[ -f pom.xml ]]; then
  if grep -Eiq 'spring-boot' pom.xml; then
    echo 'springboot-maven'
  else
    echo 'java-maven'
  fi
  exit 0
fi

GRADLE_FILE="$(find_gradle_file)"
if [[ -n "${GRADLE_FILE}" ]]; then
  if grep -Eiq 'spring-boot|org\.springframework\.boot' "${GRADLE_FILE}" 2>/dev/null; then
    echo 'springboot-gradle'
  else
    echo 'java-gradle'
  fi
  exit 0
fi

# Node.js ecosystem
if [[ -f package.json ]]; then
  if grep -Eiq '"next"' package.json 2>/dev/null; then
    echo 'nextjs'
    exit 0
  fi
  if grep -Eiq '"react"' package.json 2>/dev/null; then
    echo 'react'
    exit 0
  fi
  echo 'nodejs'
  exit 0
fi

# Unsupported frameworks for this microservice infra profile
if [[ -f requirements.txt || -f pyproject.toml || -f setup.py ]]; then
  echo 'Python services are not supported by this microservice infra profile.' >&2
  exit 1
fi

if [[ -f composer.json ]]; then
  echo 'PHP services are not supported by this microservice infra profile.' >&2
  exit 1
fi

# Static fallback
echo 'static'