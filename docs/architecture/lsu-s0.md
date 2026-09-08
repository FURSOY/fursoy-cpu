# Slice-0 LSU decode contract

`fursoy_s0_lsu_decode` recognizes RV64I LB/LH/LW/LD/LBU/LHU/LWU and
SB/SH/SW/SD. It forms the byte effective address from `rs1 + sign-extended
immediate`, identifies width and unsigned loads, and preserves the low source
bits for stores. This first interface rejects naturally misaligned accesses at
the core boundary; the later trap layer will report load/store-address-misaligned
instead of silently splitting a transaction. The ISA permits implementations to
handle misalignment, but it does not require invisible support. [RV64I
specification](https://docs.riscv.org/reference/isa/unpriv/rv64.html)

## Slice-0 data transaction contract

The core permits one outstanding data transaction. Request fields remain stable
while `req_valid` is asserted and `req_ready` is low. A store finishes at the
request handshake: a simultaneous request error terminates it as a precise store
access fault, while a successful handshake retires it; stores have no response.

Every accepted load finishes through exactly one response, including failed
loads. The response producer keeps `rsp_valid`, data, and error stable until the
`rsp_valid && rsp_ready` handshake. An error response produces a precise load
access fault and does not write the destination register or publish a commit.
For a zero-latency external RAM, a response presented in the same cycle as its
load request handshake is backpressured; the producer holds it through the next
cycle, when the SoC's registered RAM response ownership permits acceptance.

Reset cancels the core and interconnect ownership of any outstanding load. The
external RAM side must cancel its pending transaction on reset; the Slice-0 SoC
also accepts and discards any response presented while reset is asserted or no
live response owner exists, preventing an already-present stale response from
being attached to a later load. CLINT response state is cleared by the same reset.
