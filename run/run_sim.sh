#!/usr/bin/env bash
# =============================================================================
# run_sim.sh  –  VCS compile + simulation for tb_axi_interconnect_5x16
#
# Usage:
#   ./run/run_sim.sh          # compile + sim
#   ./run/run_sim.sh gui      # compile + sim + open Verdi
#   ./run/run_sim.sh clean    # remove build artefacts
# =============================================================================
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${PROJ_ROOT}/run"
TB_DIR="${PROJ_ROOT}/tb"
RTL_DIR="${PROJ_ROOT}/rtl/interconnect"

SIM_TOP="tb_axi_interconnect_5x16"
FSDB="${RUN_DIR}/${SIM_TOP}.fsdb"
SIMV="${RUN_DIR}/simv"

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "clean" ]]; then
    echo "[run_sim] Cleaning build artefacts..."
    rm -rf "${RUN_DIR}/simv" "${RUN_DIR}/simv.daidir" \
           "${RUN_DIR}/csrc"  "${RUN_DIR}/ucli.key"   \
           "${RUN_DIR}"/*.fsdb "${RUN_DIR}"/*.log      \
           "${RUN_DIR}"/*.vpd  "${RUN_DIR}"/*.vdb      \
           novas.* verdi_config_file DVEfiles
    echo "[run_sim] Done."
    exit 0
fi

mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"

# ---------------------------------------------------------------------------
# VCS compile
# ---------------------------------------------------------------------------
echo "[run_sim] Compiling with VCS..."

vcs \
    -full64                         \
    -sverilog                       \
    -timescale=1ns/1ps              \
    +define+FSDB                    \
    -kdb                            \
    -lca                            \
    +vcs+lic+wait                   \
    -debug_access+all               \
    -debug_region+cell+encrypt      \
    -l "${RUN_DIR}/compile.log"     \
    -o "${SIMV}"                    \
    "${RTL_DIR}/priority_encoder.v" \
    "${RTL_DIR}/arbiter.v"          \
    "${RTL_DIR}/axi_interconnect.v" \
    "${RUN_DIR}/axi_interconnect_wrap_5x16.v" \
    "${TB_DIR}/${SIM_TOP}.sv"

echo "[run_sim] Compile done. Log: ${RUN_DIR}/compile.log"

# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------
echo "[run_sim] Running simulation..."

"${SIMV}" \
    -l "${RUN_DIR}/sim.log"         \
    +vcs+lic+wait                   \
    -ucli -do "${RUN_DIR}/run.tcl"  \
    2>&1 | tee "${RUN_DIR}/sim_stdout.log"

echo "[run_sim] Simulation done. Log: ${RUN_DIR}/sim.log"
echo "[run_sim] FSDB waveform: ${FSDB}"

# ---------------------------------------------------------------------------
# Optional: open Verdi
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "gui" ]]; then
    echo "[run_sim] Opening Verdi..."
    verdi \
        -sv                                          \
        -f  "${RUN_DIR}/filelist.f"                  \
        -ssf "${FSDB}"                               \
        -sswr "${RUN_DIR}/wave.rc"                   \
        -nologo &
fi
