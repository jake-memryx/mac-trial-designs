#!/usr/bin/env bash
set -euo pipefail

kit_root="/mnt/mxfs/chip_design/kits/TSMC/CLN4P"
output_dir="${1:-build/cln4p_libs}"

declare -a packages=(base_svt base_lvt base_lvtll mb_svt mb_lvt mb_lvtll)
declare -a archives=(
    "$kit_root/tcbn04p_bwph210l6p51cnod_base_svt_100b/0K27003_20231006/tcbn04p_bwph210l6p51cnod_base_svt_100b_ccs.tar.gz"
    "$kit_root/tcbn04p_bwph210l6p51cnod_base_lvt_100b/0K27003_20231006/tcbn04p_bwph210l6p51cnod_base_lvt_100b_ccs.tar.gz"
    "$kit_root/tcbn04p_bwph210l6p51cnod_base_lvtll_100b/0K27003_20231006/tcbn04p_bwph210l6p51cnod_base_lvtll_100b_ccs.tar.gz"
    "$kit_root/tcbn04p_bwph210l6p51cnod_mb_svt_100b/0K27003_20231006/tcbn04p_bwph210l6p51cnod_mb_svt_100b_ccs.tar.gz"
    "$kit_root/tcbn04p_bwph210l6p51cnod_mb_lvt_100b/0K27003_20231006/tcbn04p_bwph210l6p51cnod_mb_lvt_100b_ccs.tar.xz"
    "$kit_root/tcbn04p_bwph210l6p51cnod_mb_lvtll_100b/0K27003_20231006/tcbn04p_bwph210l6p51cnod_mb_lvtll_100b_ccs.tar.gz"
)
declare -a library_names=(
    "tcbn04p_bwph210l6p51cnod_base_svttt_0p75v_25c_typical_ccs.lib.gz"
    "tcbn04p_bwph210l6p51cnod_base_lvttt_0p75v_25c_typical_ccs.lib.gz"
    "tcbn04p_bwph210l6p51cnod_base_lvtlltt_0p75v_25c_typical_ccs.lib.gz"
    "tcbn04p_bwph210l6p51cnod_mb_svttt_0p75v_25c_typical_ccs.lib.gz"
    "tcbn04p_bwph210l6p51cnod_mb_lvttt_0p75v_25c_typical_ccs.lib.gz"
    "tcbn04p_bwph210l6p51cnod_mb_lvtlltt_0p75v_25c_typical_ccs.lib.gz"
)

mkdir -p "$output_dir"
declare -a pids=()
declare -a temporary_files=()

for i in "${!archives[@]}"; do
    archive="${archives[$i]}"
    library_name="${library_names[$i]}"
    destination="$output_dir/$library_name"
    temporary="$destination.tmp"
    member="TSMCHOME/digital/Front_End/timing_power_noise/CCS/"
    member+="tcbn04p_bwph210l6p51cnod_${packages[$i]}_100b/$library_name"

    [[ -s "$destination" ]] && continue
    if [[ ! -f "$archive" ]]; then
        echo "error: CLN4P archive not found: $archive" >&2
        exit 1
    fi

    echo "Extracting ${packages[$i]} TT 0.75 V 25 C CCS library"
    (tar -xOf "$archive" "$member" > "$temporary" &&
     mv "$temporary" "$destination") &
    pids+=("$!")
    temporary_files+=("$temporary")
done

status=0
for pid in "${pids[@]}"; do
    wait "$pid" || status=1
done

if (( status != 0 )); then
    for temporary in "${temporary_files[@]}"; do
        rm -f "$temporary"
    done
    echo "error: failed to extract one or more CLN4P libraries" >&2
    exit 1
fi

echo "CLN4P libraries ready in $output_dir"

