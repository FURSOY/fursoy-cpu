read_liberty tools/synth/lib/NangateOpenCellLibrary_typical.lib
read_verilog build/synth/dtlb_netlist.v
link_design fursoy_s1_dtlb

create_clock -name clk -period 2.0 [get_ports clk_i]
set_input_delay -clock clk 0.2 [all_inputs -no_clocks]
set_output_delay -clock clk 0.2 [all_outputs]

report_checks -path_delay min -digits 3
report_checks -path_delay max -digits 3
report_worst_slack -max
report_tns
