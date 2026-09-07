# Regression loop for the reference core.
#
#   make           # unit tests + core test + co-simulation trace diff
#   make cosim     # just the trace diff -- the highest-value single check
#   make wave      # core run with VCD output
#   make clean
#
# Adapt the file lists; keep the structure. A one-command regression is what
# makes it cheap enough to run after every edit, which is the whole point.

IVERILOG := iverilog -g2001
VVP      := vvp
MODEL    := python3 ../scripts/rv_model.py

RTL      := rv32_multicycle.v
SIM_ONLY := rv32_soc_sim.v          # NEVER add this to a synthesis file list
PROG     := selftest

.PHONY: all unit core cosim wave vectors clean

all: unit core cosim

# ---- unit tests ------------------------------------------------------------
unit: tb_alu.vvp tb_lsu.vvp
	@echo "== ALU =="; $(VVP) tb_alu.vvp | tail -2
	@echo "== LSU =="; $(VVP) tb_lsu.vvp | tail -2

tb_alu.vvp: $(RTL) tb_unit_template.v
	$(IVERILOG) -o $@ -s tb_unit_template $^

tb_lsu.vvp: $(RTL) tb_lsu.v
	$(IVERILOG) -o $@ -s tb_lsu $^

# ---- core test --------------------------------------------------------------
core: tb_core.vvp $(PROG).hex
	@echo "== core =="; $(VVP) tb_core.vvp +hex=$(PROG).hex +cov | tail -15

tb_core.vvp: $(RTL) $(SIM_ONLY) tb_core.v
	$(IVERILOG) -o $@ -s tb_core $^

$(PROG).hex: $(PROG).s
	$(MODEL) --asm $< --hex $@

# ---- co-simulation: the single highest-value check --------------------------
cosim: tb_core.vvp $(PROG).hex
	@$(MODEL) --trace $(PROG).hex 2>/dev/null > model.trace
	@$(VVP) tb_core.vvp +hex=$(PROG).hex +trace 2>/dev/null \
	    | grep -E '^[0-9a-f]{8} ' > rtl.trace
	@if diff -q model.trace rtl.trace >/dev/null; then \
	    echo "== cosim == traces identical ($$(wc -l < rtl.trace) instructions)"; \
	 else \
	    echo "== cosim == FIRST DIVERGENCE:"; \
	    diff model.trace rtl.trace | head -6; exit 1; \
	 fi

wave: tb_core.vvp $(PROG).hex
	$(VVP) tb_core.vvp +hex=$(PROG).hex +dumpvcd

vectors:
	python3 ../scripts/gen_vectors.py --all

clean:
	rm -f *.vvp *.vcd *.trace $(PROG).hex
