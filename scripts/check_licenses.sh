#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  scripts/check_licenses.sh                 Check Xcelium and Genus licenses
  scripts/check_licenses.sh FEATURE [...]   Check specific FlexNet features
  scripts/check_licenses.sh --all           Show all features and active users

Examples:
  scripts/check_licenses.sh
  scripts/check_licenses.sh Xcelium_Single_Core Genus_Synthesis
  scripts/check_licenses.sh --all
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v lmutil >/dev/null 2>&1; then
    echo "error: lmutil is not available on PATH" >&2
    exit 127
fi

# Cadence commonly uses either variable. Prefer the Cadence-specific setting
# when both are present.
license_source="${CDS_LIC_FILE:-${LM_LICENSE_FILE:-}}"
if [[ -z "$license_source" ]]; then
    echo "error: neither CDS_LIC_FILE nor LM_LICENSE_FILE is set" >&2
    exit 2
fi

echo "License source: $license_source"

if [[ "${1:-}" == "--all" ]]; then
    exec lmutil lmstat -a -c "$license_source"
fi

if (( $# == 0 )); then
    features=(Xcelium_Single_Core Genus_Synthesis)
else
    features=("$@")
fi

for feature in "${features[@]}"; do
    echo
    echo "=== $feature ==="
    lmutil lmstat -c "$license_source" -f "$feature"
done

