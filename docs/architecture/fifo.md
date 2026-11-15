# FIFO-001 — Single-Clock Small Control Queue

Status: RTL lab pilot. Not a CPU ROB/LSQ design or final physical IP.

Parameters: `WIDTH >= 1`, `DEPTH >= 1`; non-power-of-two depths are supported.
Operations occur on the rising clock edge. Synchronous active-high reset has priority over flush; both empty the queue. While reset or flush is active, `ready`/`valid` are low and no transfers are accepted on that clock edge. Storage bits are not zeroed on reset/flush, and invalid entries are not driven on the output; this is not a physical data-wipe or security sanitization mechanism.

Enqueue occurs only when `in_valid && in_ready`, and dequeue occurs only when `out_valid && out_ready`. The producer must hold pending valid data until accepted or cleared by reset/flush. The output remains stable while stalled; reset/flush cancels any pending transaction.
There is no combinational bypass on an empty queue: the first entry becomes valid on the following cycle. Invalid output data is driven to zero. When reading on the same clock edge in a full queue, incoming data is accepted: the oldest entry is popped and the new entry is stored (including for `DEPTH = 1`).

This behavior creates an `out_ready -> in_ready` combinational path. Combinational loops must not be formed during integration; long pipelines require a register slice or an alternative queue interface. Storage is a small asynchronously read register array; no SRAM macro is assumed. Frequency, area, and power have not been measured for this pilot, and it is not approved for CPU critical paths.

| Requirement | Verification Method |
|---|---|
| `FIFO-01` Data ordering and losslessness | Independent C++ `deque`, checking outputs at every rising clock cycle |
| `FIFO-02` Full/empty boundaries | Directed fill, stall, and drain tests |
| `FIFO-03` Simultaneous transfer at full capacity | Directed and randomized full-exchange tests |
| `FIFO-04` Reset/flush cancellation | Verified with buffered data present and simultaneous push/pop requests |
| `FIFO-05` Pointer wrap-around | Repeated transfers at `DEPTH = 1/3/8` |
| `FIFO-06` Internal invariants | RTL assertions on counter and pointer ranges |
| `FIFO-07` Testbench sensitivity | Deliberate bit-flip fault injection in a scratch copy must trigger scoreboard failure |

Simulation matrix: `WIDTH/DEPTH` = `8/1`, `32/3`, `8/8`, `32/8`; three fixed seeds each. Under random stimulus, pending producer data is preserved. Corner-case coverage counters are checked for pass criteria. This suite does not constitute a formal proof across all parameter values.
