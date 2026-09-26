# Bring-up Debug History (Interconnect + SW, 2026-09-26)

How three interacting faults were isolated with VCS on vlsi44. Read
this before touching the arbiter, the xbar FSM, or the SoC boundary.

## Symptom (unified)

Integration: RAM wr/rd + UART read passed, first peripheral **write**
hung (BFM B-timeout). SW: silent fetches, then hang with zero console
output. Common shape: everything works until the first transaction
through the interconnect's peripheral path — RAM-only traffic is fine.

## Bug 1 — arbiter grant hold body missing

`rtl/interconnect/arbiter.v`: the BLOCK_ACK hold branch had the
improved `(grant_reg & request)` condition but an **empty body**, so
every grant dropped the cycle after IDLE-accept. DECODE then reads a
stale direction (`read` is a live grant wire, default 0 = write) and
misdirects all reads into WRITE. Writes survived by luck of the
default. Fix: restored the three hold lines (`grant_valid_next`,
`grant_next`, `grant_encoded_next`) under the improved condition.
Smoking gun: `+XBAR_DEBUG` showed `IDLE --accept READ--> DECODE
--grant gone--> WRITE`, parked forever.

## Bug 2 — floating RLAST on single-beat slaves

`rtl/soc/honours_soc.sv`: UART/Timer/GPIO wrappers expose no RLAST
(single-beat AXI4-Lite style), leaving `m_axi_rlast[1..3]` at Z. The
xbar retires reads only on `current_m_axi_rlast`
(`axi_interconnect.v` STATE_READ), so the first peripheral read parked
the FSM in READ forever — while still forwarding that one R, so the
master-side check **passed** and the *next* op hung. RAM reads always
worked (`axi_ram` drives RLAST). Fix: tie `m_axi_rlast[1..3] = 1'b1`
at the boundary (every beat is last). Required adaptation for any
future single-beat slave on this fabric.

## Bug 3 (removed) — WRITE→READ divert

A `STATE_WRITE` divert on pending AR papered over Bug 1 for RAM reads
(and was load-bearing: removing it before fixing Bug 1 regressed reads
PASS→FAIL). It can only fire spuriously under serial masters
(BFM/adapter never assert AR during writes), and when it fires it
strands the accepted write with no B. Removed; upstream Forencich write
path restored verbatim. The IDLE-direction guard (require VALID present
with the grant) stays — it is protocol-safe.

## Debug probes (all plusarg-gated, zero cost when off)

| Probe | Enable | Shows |
|-------|--------|-------|
| `SOC_DEBUG` | `make integration DEFINES=+define+SOC_DEBUG` | xbar state, grant, s-side and m-side AW/W/B + AR/R handshakes, RAM channel state, every 500 cycles |
| `XBAR_DEBUG` | `+XBAR_DEBUG` on simv | every FSM transition with s-side valids, `m_select`, grant + direction |
| `ADP_DEBUG` | `+ADP_DEBUG` on simv | adapter grants, sub-beat handshakes, B/R captures (64→32 split visible) |

## Tooling notes (VCS U-2023.03)

- The repo-root `./csrc` is shared incremental state across targets and
  **silently reuses stale objects after RTL edits** (watched it skip a
  changed `axi_interconnect.v` and run a ghost mix). After any RTL edit:
  `make clean && rm -rf csrc` before rebuilding. (`-nc` alone did not
  prevent this.)
- `vcs` lives at `~/snps_tools_target/vcs/U-2023.03/linux64/bin`
  (not on default `PATH`); toolchain at `/opt/riscv/bin`
  (auto-fallback in `build_sw.sh`).
- `+define+SOC_DEBUG` flows through `make ... DEFINES=...` for both
  `unit` and `integration`.
