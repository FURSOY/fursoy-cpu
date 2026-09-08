# Slice-0 fetch transaction contract

`fursoy_s0_fetch` is the first DUT block. It is not an ISA core and emits no
architectural commit. Its only job is to request the first 32-bit instruction
at the Slice-0 test reset PC, `0x80000000`, then retain one accepted response.

The instruction-memory boundary has independent request and response handshakes:

| Signal group | Rule |
|---|---|
| request | `valid` stays asserted with reset PC until `ready` is high on a clock edge |
| response | `ready` stays asserted after the request handshake until `valid` is high on a clock edge; the producer holds instruction data and error stable until that handshake |
| reset | suppresses both transactions and invalidates any saved instruction; the next active cycle starts a fresh reset-PC request |
| completion | exactly one response is retained and no second request is issued |

Every accepted instruction request completes through a response, including an
error response. A successful response retains the instruction; an error response
retains the requested PC and marks it as an instruction access fault without
decoding or committing the response data. Core trap entry uses `mcause=1` and
sets both `mepc` and `mtval` to that requested PC. Reset cancels any outstanding
fetch and ignores responses while reset is asserted; the instruction-memory
producer must also cancel its pending transaction on reset.

The interface has no transaction ID or reset generation tag. Consequently,
producer cancellation on reset is a required contract, not an optional timing
assumption: a pre-reset response must not remain or reappear after reset is
released. A producer that violates this rule could make an old response
indistinguishable from the response to the first post-reset request. The focused
reset test injects a late response during reset, confirms fetch ignores it, then
cancels it before serving the new reset-PC request.

This separates memory latency from future decode/execute work. The later core
will consume the retained instruction, update the architectural PC and publish
a commit trace only when it retires an instruction.
