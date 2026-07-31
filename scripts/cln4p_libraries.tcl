# TSMC CLN4P Base + MB, SVT + LVT + LVTLL, TT 0.75 V, 25 C, CCS.
set cln4p_lib_dir ../cln4p_libs
set cln4p_libraries [list \
    $cln4p_lib_dir/tcbn04p_bwph210l6p51cnod_base_svttt_0p75v_25c_typical_ccs.lib.gz \
    $cln4p_lib_dir/tcbn04p_bwph210l6p51cnod_base_lvttt_0p75v_25c_typical_ccs.lib.gz \
    $cln4p_lib_dir/tcbn04p_bwph210l6p51cnod_base_lvtlltt_0p75v_25c_typical_ccs.lib.gz \
    $cln4p_lib_dir/tcbn04p_bwph210l6p51cnod_mb_svttt_0p75v_25c_typical_ccs.lib.gz \
    $cln4p_lib_dir/tcbn04p_bwph210l6p51cnod_mb_lvttt_0p75v_25c_typical_ccs.lib.gz \
    $cln4p_lib_dir/tcbn04p_bwph210l6p51cnod_mb_lvtlltt_0p75v_25c_typical_ccs.lib.gz \
]

set_db init_lib_search_path $cln4p_lib_dir
read_libs $cln4p_libraries

