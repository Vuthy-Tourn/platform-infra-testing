#!/usr/bin/env bash
set -euo pipefail

first_existing() {
  local file
  for file in "$@"; do
    if [[ -f "$file" ]]; then
      echo "$file"
      return 0
    fi
  done
  return 1
}

trim_java_version() {
  local version="${1:-}"
  version="${version#1.}"
  printf '%s\n' "$version"
}

gradle_file="$(first_existing build.gradle build.gradle.kts || true)"
if [[ -n "${gradle_file:-}" ]]; then
  version="$(sed -nE 's/.*JavaLanguageVersion\.of\(([0-9]+)\).*/\1/p' "$gradle_file" | head -n1)"
  if [[ -n "${version:-}" ]]; then
    echo "$version"
    exit 0
  fi

  version="$(sed -nE 's/.*sourceCompatibility *= *["'"'"']?([0-9]+).*/\1/p' "$gradle_file" | head -n1)"
  if [[ -n "${version:-}" ]]; then
    echo "$version"
    exit 0
  fi

  version="$(sed -nE 's/.*targetCompatibility *= *["'"'"']?([0-9]+).*/\1/p' "$gradle_file" | head -n1)"
  if [[ -n "${version:-}" ]]; then
    echo "$version"
    exit 0
  fi
fi

if [[ -f pom.xml ]]; then
  version="$(sed -nE 's@.*<java\.version>([^<]+)</java\.version>.*@\1@p' pom.xml | head -n1)"
  if [[ -n "${version:-}" ]]; then
    trim_java_version "$version"
    exit 0
  fi

  version="$(sed -nE 's@.*<maven\.compiler\.release>([^<]+)</maven\.compiler\.release>.*@\1@p' pom.xml | head -n1)"
  if [[ -n "${version:-}" ]]; then
    trim_java_version "$version"
    exit 0
  fi

  version="$(sed -nE 's@.*<maven\.compiler\.source>([^<]+)</maven\.compiler\.source>.*@\1@p' pom.xml | head -n1)"
  if [[ -n "${version:-}" ]]; then
    trim_java_version "$version"
    exit 0
  fi

  version="$(sed -nE 's@.*<maven\.compiler\.target>([^<]+)</maven\.compiler\.target>.*@\1@p' pom.xml | head -n1)"
  if [[ -n "${version:-}" ]]; then
    trim_java_version "$version"
    exit 0
  fi
fi

echo ""
