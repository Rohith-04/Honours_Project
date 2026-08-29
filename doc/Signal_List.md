# Custom IP Signal List — NDA Reduction Engine, HPM, NDA Watchdog

Scope: signals connecting the three custom IPs to each other and to the rest of the SoC
(crossbar, PIC). Standard AXI4 / AXI4-Lite channel signals (AWADDR, ARVALID, RDATA, etc.)
are referenced as bundled interfaces rather than broken out individually, since those follow
the standard protocol and aren't project-specific decisions. The signals broken out in full
below are the custom, point-to-point ones — these are the actual architecture decisions.

---

## NDA Reduction Engine

| Signal | Direction | Connects to | Description |
|---|---|---|---|
| `s_axil_nda_ctrl` | slave (bundled AXI4-Lite) | Crossbar (CPU side) | Control/status interface. CPU writes base address, length, operation, start command; reads status and result. |
| `m_axi_nda_data` | master (bundled AXI4) | Crossbar (DDR side) | Data interface. NDA issues its own burst reads to fetch the operand array. |
| `nda_active` | output | NDA Watchdog, HPM | Asserted while the NDA is running a reduction. Lets both listeners know the NDA is doing work, without either driving anything back. |
| `nda_beat_done` | output | NDA Watchdog, HPM | Pulses once per completed read beat. This is the "progress heartbeat" the Watchdog uses to detect stalls, and HPM uses to count NDA-attributed memory activity. |
| `nda_irq_done` | output | PIC | Interrupt raised when a reduction completes normally (result ready in `NDA_RESULT`). |
| `wdg_abort` | input | NDA Watchdog | Forces the NDA out of its current operation into a safe idle state. Does not interrupt an AXI burst already in flight — the NDA finishes the burst in progress, then does not issue the next one. |

---

## NDA Watchdog

| Signal | Direction | Connects to | Description |
|---|---|---|---|
| `s_axil_wdg_ctrl` | slave (bundled AXI4-Lite) | Crossbar (CPU side) | Config/status interface. CPU sets the timeout threshold and reads whether an abort has occurred. |
| `nda_active` | input | NDA Reduction Engine | Tells the Watchdog when to start/continue monitoring. |
| `nda_beat_done` | input | NDA Reduction Engine | Progress signal. If no pulse arrives within the configured timeout window while `nda_active` is high, the Watchdog declares a stall. |
| `wdg_abort` | output | NDA Reduction Engine | Asserted on timeout. Tells the NDA to discard its in-progress reduction and return to idle (discard-and-restart fallback). |
| `wdg_irq_abort` | output | PIC | Interrupt raised when the Watchdog fires, signalling the driver to fall back to software. |
| `wdg_fallback_event` | output | HPM | Pulses once per fallback event, purely for counting. Nothing downstream depends on HPM receiving this — if HPM isn't present, this output simply goes unconnected. |

---

## Hardware Performance Monitor (HPM)

| Signal | Direction | Connects to | Description |
|---|---|---|---|
| `s_axil_hpm_ctrl` | slave (bundled AXI4-Lite) | Crossbar (CPU side) | Config/status interface. CPU reads out the cycle counter, bus-transaction counter, NDA-activity counter, and fallback counter. |
| `axi_snoop_bus` | input (bundled, read-only tap) | Crossbar | Passive tap on the crossbar's AXI channel handshakes (address-phase and response-phase signals), used to increment the general bus-transaction counter. HPM never drives anything back onto this bus. |
| `nda_active` | input | NDA Reduction Engine | Used to attribute activity time specifically to the NDA rather than general CPU traffic. |
| `nda_beat_done` | input | NDA Reduction Engine | Increments the NDA-activity counter per completed beat. |
| `wdg_fallback_event` | input | NDA Watchdog | Increments the fallback counter. |

---

## Decoupling note

HPM only appears as a **listener** in every row above — every signal into HPM is an input,
and HPM drives nothing into the NDA or Watchdog. This is what makes it removable by
construction: gating HPM's instantiation behind a single top-level parameter (e.g.
`ENABLE_HPM`) drops its logic from synthesis with no edits required anywhere else, since
nothing else has a dependency on it. This is also what makes the earlier defense
concrete — you can synthesize the SoC with and without HPM and read the actual area
delta off the report, rather than asserting the cost is small.
