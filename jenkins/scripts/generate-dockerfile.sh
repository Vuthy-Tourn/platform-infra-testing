#!/usr/bin/env bash
set -euo pipefail

FRAMEWORK="${1:-static}"
SCRIPTS_DIR="${2:-$(pwd)}"
TEMPLATES_DIR="${SCRIPTS_DIR}/../../docker/dockerfiles"

template_for_framework() {
  case "$1" in
    springboot-maven|java-maven|springboot) echo "Dockerfile.maven" ;;
    springboot-gradle|java-gradle|gradle)   echo "Dockerfile.gradle" ;;
    nextjs|nodejs)                           echo "Dockerfile.nodejs" ;;
    react|static)                            echo "Dockerfile.static" ;;
    *)                                       echo "Dockerfile.static" ;;
  esac
}

detect_java_version() {
  local search_files=()
  local version=""
  local search_cmd="grep -Eho"

  [[ -f build.gradle ]] && search_files+=("build.gradle")
  [[ -f build.gradle.kts ]] && search_files+=("build.gradle.kts")
  [[ -f pom.xml ]] && search_files+=("pom.xml")
  [[ -f gradle.properties ]] && search_files+=("gradle.properties")

  if command -v rg >/dev/null 2>&1; then
    search_cmd="rg -I -o"
  fi

  find_java_version() {
    local pattern="$1"
    local match=""

    match="$(${search_cmd} "${pattern}" "${search_files[@]}" 2>/dev/null | head -n1 || true)"
    if [[ -n "${match}" ]]; then
      echo "${match}" | grep -Eo '[0-9]+' | head -n1
    fi
  }

  if [[ ${#search_files[@]} -gt 0 ]]; then
    for pattern in \
      'JavaLanguageVersion\.of\([0-9]+\)' \
      'VERSION_[0-9]+' \
      'sourceCompatibility.*[0-9]+' \
      'targetCompatibility.*[0-9]+' \
      '<java.version>[0-9]+</java.version>' \
      '<maven.compiler.release>[0-9]+</maven.compiler.release>' \
      '<maven.compiler.source>[0-9]+</maven.compiler.source>' \
      '<maven.compiler.target>[0-9]+</maven.compiler.target>' \
      'javaVersion.*[0-9]+' \
      'java.version.*[0-9]+'; do
      version="$(find_java_version "${pattern}")"
      if [[ -n "${version}" ]]; then
        break
      fi
    done
  fi

  echo "${version:-21}"
}

SELECTED_TEMPLATE="$(template_for_framework "${FRAMEWORK}")"
SOURCE_FILE="${TEMPLATES_DIR}/${SELECTED_TEMPLATE}"
FORCE_PLATFORM_DOCKERFILE="${FORCE_PLATFORM_DOCKERFILE:-false}"

if [[ ! -f "${SOURCE_FILE}" ]]; then
  echo "Template ${SELECTED_TEMPLATE} was not found. Falling back to Dockerfile.static."
  SOURCE_FILE="${TEMPLATES_DIR}/Dockerfile.static"
fi

if [[ -f Dockerfile && "${FORCE_PLATFORM_DOCKERFILE}" != "true" ]]; then
  echo "User-provided Dockerfile detected. Skipping template generation."
  exit 0
fi

if [[ -f Dockerfile && "${FORCE_PLATFORM_DOCKERFILE}" == "true" ]]; then
  echo "Overwriting existing Dockerfile with platform template for ${FRAMEWORK}."
fi

if [[ "${SELECTED_TEMPLATE}" == "Dockerfile.gradle" || "${SELECTED_TEMPLATE}" == "Dockerfile.maven" ]]; then
  JAVA_VERSION="$(detect_java_version)"
  echo "Detected Java version: ${JAVA_VERSION}"
  sed "s/__JAVA_VERSION__/${JAVA_VERSION}/g" "${SOURCE_FILE}" > Dockerfile
else
  cp "${SOURCE_FILE}" Dockerfile
fi

echo "Generated Dockerfile from template: ${SELECTED_TEMPLATE}"
