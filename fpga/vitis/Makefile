PLATFORM ?= xilinx_u50_gen3x16_xdma_5_202210_1
XILINX_XRT ?= /opt/xilinx/xrt
BUILD ?= $(CURDIR)/build
BUILD := $(abspath $(BUILD))

.DELETE_ON_ERROR:
.PHONY: all
all: $(BUILD)/dataset_scan.xclbin $(BUILD)/dataset_scan_host

$(BUILD)/dataset_scan.xo: package.tcl kernel.xml ../dataset_scan.sv ../dataset_filter.sv
	mkdir -p "$(BUILD)"
	cd "$(BUILD)" && vivado -mode batch -source "$(CURDIR)/package.tcl" -tclargs "$(BUILD)"

$(BUILD)/dataset_scan.xclbin: $(BUILD)/dataset_scan.xo u50.cfg
	cd "$(BUILD)" && v++ --link --target hw --platform "$(PLATFORM)" --config "$(CURDIR)/u50.cfg" --output "$@" "$<"

$(BUILD)/dataset_scan_host: host.cpp
	mkdir -p "$(BUILD)"
	$(CXX) -std=c++17 -O2 -Wall -Wextra -pthread -I"$(XILINX_XRT)/include" "$<" -L"$(XILINX_XRT)/lib" -lxrt_coreutil -o "$@"
