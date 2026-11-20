if {$argc != 1} { error "Usage: package.tcl <build-directory>" }

set scripts [file dirname [file normalize [info script]]]
set sources [file dirname $scripts]
set build [file normalize [lindex $argv 0]]
set ip_dir [file join $build dataset_scan_ip]
file mkdir $build

create_project -force dataset_scan [file join $build vivado] -part xcu50-fsvh2104-2-e
add_files [list [file join $sources dataset_scan.sv] [file join $sources dataset_filter.sv]]
set_property top dataset_scan [current_fileset]
update_compile_order -fileset sources_1
ipx::package_project -force -root_dir $ip_dir -vendor cospe.local -library kernel -taxonomy /Kernel -import_files -set_current true
set core [ipx::current_core]
set_property name dataset_scan $core
set_property version 1.0 $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
set_property ipi_drc {ignore_freq_hz true} $core
set_property vitis_drc {ctrl_protocol user_managed} $core

foreach port {s_axi_control m_axi_gmem} {
    ipx::associate_bus_interfaces -busif $port -clock ap_clk $core
}
set master [ipx::get_bus_interfaces m_axi_gmem -of_objects $core]
set read_write [ipx::get_bus_parameters READ_WRITE_MODE -of_objects $master]
if {[llength $read_write] == 0} {
    set read_write [ipx::add_bus_parameter READ_WRITE_MODE $master]
}
set_property value READ_ONLY $read_write

set slave [ipx::get_bus_interfaces s_axi_control -of_objects $core]
set map [ipx::get_memory_maps s_axi_control -of_objects $core]
if {[llength $map] == 0} { set map [ipx::add_memory_map s_axi_control $core] }
set_property slave_memory_map_ref s_axi_control $slave
set block [lindex [ipx::get_address_blocks -of_objects $map] 0]
if {$block eq ""} { set block [ipx::add_address_block reg0 $map] }
set_property range 4096 $block
set_property width 32 $block
foreach {name offset size access} {
    control  0x00 32 read-write
    records  0x10 64 read-write
    count    0x18 32 read-write
    matches  0x20 64 read-only
    checksum 0x28 32 read-only
} {
    set reg [ipx::add_register $name $block]
    set_property address_offset $offset $reg
    set_property size $size $reg
    set_property access $access $reg
    if {$name eq "records"} {
        set bus [ipx::add_register_parameter ASSOCIATED_BUSIF $reg]
        set_property value m_axi_gmem $bus
    }
}

ipx::update_source_project_archive -component $core
ipx::save_core $core
ipx::check_integrity $core
package_xo -force -xo_path [file join $build dataset_scan.xo] -kernel_name dataset_scan \
    -ip_directory $ip_dir -kernel_xml [file join $scripts kernel.xml] -ctrl_protocol user_managed
