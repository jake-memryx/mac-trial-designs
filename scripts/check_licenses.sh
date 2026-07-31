#!/usr/bin/env bash
set -u

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: scripts/check_licenses.sh [--no-color]"
    exit 0
fi

force_plain=0
if [[ "${1:-}" == "--no-color" ]]; then
    force_plain=1
elif (( $# != 0 )); then
    echo "Usage: scripts/check_licenses.sh [--no-color]" >&2
    exit 2
fi

if ! command -v lmutil >/dev/null 2>&1; then
    echo "error: lmutil is not available on PATH" >&2
    exit 127
fi

license_source="${CDS_LIC_FILE:-${LM_LICENSE_FILE:-}}"
if [[ -z "$license_source" ]]; then
    echo "error: neither CDS_LIC_FILE nor LM_LICENSE_FILE is set" >&2
    exit 2
fi

if [[ -t 1 && -z "${NO_COLOR:-}" && $force_plain -eq 0 ]]; then
    reset=$'\033[0m'
    bold=$'\033[1m'
    cyan=$'\033[36m'
    green=$'\033[32m'
    red=$'\033[31m'
    dim=$'\033[2m'
else
    reset=""
    bold=""
    cyan=""
    green=""
    red=""
    dim=""
fi

xcelium_version=$(xrun -version 2>&1 | awk '/^TOOL:/{print $3; exit}')
genus_version=$(genus -version 2>&1 | awk -F 'Version: ' '/Program Name:/{print $2; exit}')
xcelium_version=${xcelium_version:-unknown}
genus_version=${genus_version:-unknown}

declare -a tools=("Xcelium" "Genus")
declare -a versions=("$xcelium_version" "$genus_version")
declare -a features=("Xcelium_Single_Core" "Genus_Synthesis")
declare -a totals=()
declare -a available=()

status_regex='Total of ([0-9]+) licenses? issued;[[:space:]]+Total of ([0-9]+) licenses? in use'

for feature in "${features[@]}"; do
    status=$(lmutil lmstat -c "$license_source" -f "$feature" 2>&1 || true)
    if [[ $status =~ $status_regex ]]; then
        total=${BASH_REMATCH[1]}
        used=${BASH_REMATCH[2]}
        totals+=("$total")
        available+=("$((total - used))")
    else
        totals+=("-")
        available+=("-")
    fi
done

bar_width=16
make_bar() {
    local total=$1
    local free=$2
    local bar=""
    local cell

    if [[ $total == "-" || $total -eq 0 ]]; then
        for ((cell = 0; cell < bar_width; cell++)); do bar+='·'; done
        printf '%s%s%s' "$dim" "$bar" "$reset"
        return
    fi

    local free_cells=$(((free * bar_width + total / 2) / total))
    (( free > 0 && free_cells == 0 )) && free_cells=1
    (( free < total && free_cells == bar_width )) && free_cells=$((bar_width - 1))
    local used_cells=$((bar_width - free_cells))

    printf '%s' "$green"
    for ((cell = 0; cell < free_cells; cell++)); do printf '█'; done
    printf '%s' "$red"
    for ((cell = 0; cell < used_cells; cell++)); do printf '░'; done
    printf '%s' "$reset"
}

printf '%s╭──────────┬────────────────┬───────┬───────────┬──────────────────╮%s\n' "$cyan" "$reset"
printf '%s│%s %-8s %s│%s %-14s %s│%s %5s %s│%s %9s %s│%s %-16s %s│%s\n' \
    "$cyan" "$bold" "Tool" "$cyan" "$bold" "Version" "$cyan" \
    "$bold" "Total" "$cyan" "$bold" "Available" "$cyan" \
    "$bold" "Availability" "$cyan" "$reset"
printf '%s├──────────┼────────────────┼───────┼───────────┼──────────────────┤%s\n' "$cyan" "$reset"

for i in "${!tools[@]}"; do
    if [[ ${available[$i]} != "-" && ${available[$i]} -gt 0 ]]; then
        availability_color=$green
    else
        availability_color=$red
    fi

    printf '%s│%s %-8s %s│%s %-14s %s│ %5s %s│%s %9s %s│ ' \
        "$cyan" "$bold" "${tools[$i]}" "$cyan" "$reset" "${versions[$i]}" \
        "$cyan" "${totals[$i]}" "$cyan" "$availability_color" \
        "${available[$i]}" "$cyan"
    make_bar "${totals[$i]}" "${available[$i]}"
    printf ' %s│%s\n' "$cyan" "$reset"
done

printf '%s╰──────────┴────────────────┴───────┴───────────┴──────────────────╯%s\n' "$cyan" "$reset"
printf '%s█ available  %s░ in use%s\n' "$green" "$red" "$reset"
