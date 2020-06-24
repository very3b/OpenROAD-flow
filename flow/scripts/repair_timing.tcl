if {![info exists standalone] || $standalone} {

  # Read liberty files
  foreach libFile $::env(LIB_FILES) {
    read_liberty $libFile
  }

  # Read lef
  read_lef $::env(TECH_LEF)
  read_lef $::env(SC_LEF)
  if {[info exist ::env(ADDITIONAL_LEFS)]} {
    foreach lef $::env(ADDITIONAL_LEFS) {
      read_lef $lef
    }
  }

  # Read def and sdc
  read_def $::env(RESULTS_DIR)/3_2_place_dp.def
  read_sdc $::env(RESULTS_DIR)/2_floorplan.sdc
}

proc print_banner {header} {
  puts "\n=========================================================================="
  puts "$header"
  puts "--------------------------------------------------------------------------"
}

# Set res and cap
if {[info exists ::env(WIRE_RC_RES)] && [info exists ::env(WIRE_RC_CAP)]} {
  set_wire_rc -res $::env(WIRE_RC_RES) -cap $::env(WIRE_RC_CAP)
} else {
  set_wire_rc -layer $::env(WIRE_RC_LAYER)
}

set buffer_lib_size small
if {[info exists ::env(TIMING_REPAIR_BUFFER_LIB_SIZE)]} {
  set buffer_lib_size $::env(TIMING_REPAIR_BUFFER_LIB_SIZE)
}

set pessimism_factor 0.75
if {[info exists ::env(TIMING_REPAIR_PESSIMISM_FACTOR)]} {
  set pessimism_factor $::env(TIMING_REPAIR_PESSIMISM_FACTOR)
}
set repair_timing_1_iterations 7
if {[info exists ::env(TIMING_REPAIR_MAJOR_MAX_ITERATION)]} {
  set repair_timing_1_iterations $::env(TIMING_REPAIR_MAJOR_MAX_ITERATION)
}
set repair_timing_2_iterations 3
if {[info exists ::env(TIMING_REPAIR_MINOR_MAX_ITERATION)]} {
  set repair_timing_2_iterations $::env(TIMING_REPAIR_MINOR_MAX_ITERATION)
}

# pre report
log_begin $::env(REPORTS_DIR)/3_pre_timing_repair.rpt

print_banner "report_checks"
report_checks

print_banner "report_tns"
report_tns

print_banner "report_wns"
report_wns

print_banner "report_slew_violations"
report_check_types -max_slew -max_capacitance -max_fanout -violators

print_banner "report_design_area"
report_design_area

print_banner "instance_count"
puts [sta::network_leaf_instance_count]

print_banner "pin_count"
puts [sta::network_leaf_pin_count]

puts ""

puts "pre_repair_slew_vio: [llength [string trim [psn::transition_violations]]]"
puts "pre_repair_cap_vio: [llength [string trim [psn::capacitance_violations]]]"
puts "pre_repair_inst_count: [sta::network_leaf_instance_count]"
puts "pre_repair_pin_count: [sta::network_leaf_pin_count]"

log_end

# Set the buffer cell
set buffer_cell [get_lib_cell [lindex $::env(MIN_BUF_CELL_AND_PORTS) 0]]
set_dont_use $::env(DONT_USE_CELLS)

# Do not buffer chip-level designs
if {![info exists ::env(FOOTPRINT)]} {
  puts "Perform port buffering..."
  # buffer_ports -buffer_cell $buffer_cell
}

set fast_timing_repair [info exists ::env(TIMING_REPAIR_FAST)]
if {!$fast_timing_repair} {
  puts "Using high-effort timing repair"
  # Do not buffer chip-level designs
  if {![info exists ::env(FOOTPRINT)]} {
    puts "Perform port buffering..."
    buffer_ports -buffer_cell $buffer_cell
  }
  set maximum_negative_slack_path_depth 20
  set repair_ns_args ""
  if {![info exists ::env(TIMING_REPAIR_MAXIMUM_EFFORT)]} {
    set repair_ns_args "-no_resize_for_negative_slack"
    set maximum_negative_slack_path_depth 20
  }
  if {[info exists ::env(TIMING_REPAIR_NEGATIVE_SLACK_PATH_DEPTH)]} {
    set maximum_negative_slack_path_depth $::env(TIMING_REPAIR_NEGATIVE_SLACK_PATH_DEPTH)
  }
  set repair_ns_args "-maximum_negative_slack_path_depth $maximum_negative_slack_path_depth"

  puts "Repair timing \[1\]"
  repair_timing -iterations $repair_timing_1_iterations {*}$repair_ns_args -auto_buffer_library $buffer_lib_size -capacitance_pessimism_factor $pessimism_factor -transition_pessimism_factor $pessimism_factor


  # Repair max fanout
  puts "Repair max fanout..."
  set_max_fanout $::env(MAX_FANOUT) [current_design]
  repair_max_fanout -buffer_cell $buffer_cell

  if { [info exists env(TIE_SEPARATION)] } {
    set tie_separation $env(TIE_SEPARATION)
  } else {
    set tie_separation 0
  }


  # Repair tie lo fanout
  puts "Repair tie lo fanout..."
  set tielo_cell_name [lindex $env(TIELO_CELL_AND_PORT) 0]
  set tielo_lib_name [get_name [get_property [get_lib_cell $tielo_cell_name] library]]
  set tielo_pin $tielo_lib_name/$tielo_cell_name/[lindex $env(TIELO_CELL_AND_PORT) 1]
  repair_tie_fanout -separation $tie_separation $tielo_pin

  # Repair tie hi fanout
  puts "Repair tie hi fanout..."
  set tiehi_cell_name [lindex $env(TIEHI_CELL_AND_PORT) 0]
  set tiehi_lib_name [get_name [get_property [get_lib_cell $tiehi_cell_name] library]]
  set tiehi_pin $tiehi_lib_name/$tiehi_cell_name/[lindex $env(TIEHI_CELL_AND_PORT) 1]
  repair_tie_fanout -separation $tie_separation $tiehi_pin

  # In case tie cells caused new violations
  puts "Repair timing \[2\]"
  repair_timing -iterations $repair_timing_2_iterations {*}$repair_ns_args -auto_buffer_library $buffer_lib_size -capacitance_pessimism_factor $pessimism_factor -transition_pessimism_factor $pessimism_factor

} else {
  puts "Using fast timing repair"
  set_max_fanout $::env(MAX_FANOUT) [current_design]

  puts "Repair design..."
  repair_design -max_wire_length $::env(MAX_WIRE_LENGTH) -buffer_cell $buffer_cell

  # Perform resizing
  puts "Perform resizing after buffer insertion..."
  resize

  if { [info exists env(TIE_SEPARATION)] } {
    set tie_separation $env(TIE_SEPARATION)
  } else {
    set tie_separation 0
  }

  # Repair tie lo fanout
  puts "Repair tie lo fanout..."
  set tielo_cell_name [lindex $env(TIELO_CELL_AND_PORT) 0]
  set tielo_lib_name [get_name [get_property [get_lib_cell $tielo_cell_name] library]]
  set tielo_pin $tielo_lib_name/$tielo_cell_name/[lindex $env(TIELO_CELL_AND_PORT) 1]
  repair_tie_fanout -separation $tie_separation $tielo_pin

  # Repair tie hi fanout
  puts "Repair tie hi fanout..."
  set tiehi_cell_name [lindex $env(TIEHI_CELL_AND_PORT) 0]
  set tiehi_lib_name [get_name [get_property [get_lib_cell $tiehi_cell_name] library]]
  set tiehi_pin $tiehi_lib_name/$tiehi_cell_name/[lindex $env(TIEHI_CELL_AND_PORT) 1]
  repair_tie_fanout -separation $tie_separation $tiehi_pin

  # Repair hold violations
  puts "Repair hold violations..."
  repair_hold_violations -buffer_cell $buffer_cell

}

# post report
log_begin $::env(REPORTS_DIR)/3_post_timing_repair.rpt

print_banner "report_floating_nets"
report_floating_nets

print_banner "report_checks"
report_checks -path_delay max -fields {slew cap input}

report_checks -path_delay min -fields {slew cap input}

print_banner "report_tns"
report_tns

print_banner "report_wns"
report_wns

print_banner "report_slew_violations"
report_check_types -max_slew -max_capacitance -max_fanout -violators

print_banner "report_design_area"
report_design_area

print_banner "instance_count"
puts [sta::network_leaf_instance_count]

print_banner "pin_count"
puts [sta::network_leaf_pin_count]

puts ""


puts "post_repair_slew_vio: [llength [string trim [psn::transition_violations]]]"
puts "post_repair_cap_vio: [llength [string trim [psn::capacitance_violations]]]"
puts "post_repair_inst_count: [sta::network_leaf_instance_count]"
puts "post_repair_pin_count: [sta::network_leaf_pin_count]"

log_end

if {![info exists standalone] || $standalone} {
  write_def $::env(RESULTS_DIR)/3_3_place_repaired.def
  exit
}
