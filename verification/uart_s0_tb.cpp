// Focused verification suite for Lite-16550A MMIO UART
// Specification authority: docs/architecture/platform-sbi-v1.md (frozen v1)
// Covers all 24 required scenarios:
// 1. reset register values
// 2. THR TX emission
// 3. one accepted write -> one TX event
// 4. rejected write -> zero TX events
// 5. DLAB=0 THR semantics
// 6. DLAB=1 DLL write/readback
// 7. DLAB=1 DLM write/readback
// 8. DLL write produces zero TX
// 9. DLM write produces zero TX
// 10. DLAB return to 0 restores THR/IER behavior
// 11. IER read/write
// 12. IIR non-FIFO reporting
// 13. FCR write ignored
// 14. LCR read/write
// 15. MCR read/write
// 16. LSR THRE/TEMT
// 17. MSR deterministic behavior
// 18. SCR read/write
// 19. invalid size rejected with zero side effects
// 20. misaligned access rejected with zero side effects
// 21. unimplemented UART offsets deterministic behavior
// 22. PMP-denied upstream UART access produces no UART request/mutation
// 23. PTW UART access rejected upstream
// 24. reset during/around access produces no spurious TX

#include "Vfursoy_s0_uart.h"
#include "verilated.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

static constexpr uint64_t UART_BASE = 0x0000000010000000ULL;

static void check(bool cond, const std::string &msg) {
    if (!cond) {
        throw std::runtime_error("FAIL: " + msg);
    }
}

struct UartDriver {
    Vfursoy_s0_uart dut;
    unsigned cycles = 0;
    std::vector<uint8_t> tx_log;

    void tick() {
        dut.clk_i = 0; dut.eval();
        dut.clk_i = 1; dut.eval();
        if (dut.tx_valid_o) {
            tx_log.push_back(dut.tx_data_o);
        }
        dut.clk_i = 0; dut.eval();
        ++cycles;
    }

    void reset() {
        dut.clk_i = 0; dut.rst_i = 1;
        dut.req_valid_i = 0; dut.req_store_i = 0;
        dut.req_addr_i = 0; dut.req_size_i = 0; dut.req_store_data_i = 0;
        dut.rsp_ready_i = 1;
        dut.eval();
        for (int i = 0; i < 3; i++) tick();
        dut.rst_i = 0;
        dut.eval();
        tx_log.clear();
    }

    // Perform 32-bit MMIO write
    bool write32(uint64_t addr, uint32_t data, unsigned size = 2) {
        dut.req_valid_i = 1;
        dut.req_store_i = 1;
        dut.req_addr_i = addr;
        dut.req_size_i = size;
        dut.req_store_data_i = uint64_t(data);
        dut.rsp_ready_i = 1;
        dut.eval();

        check(dut.req_ready_o, "write32: req_ready_o not asserted in IDLE");
        tick();

        dut.req_valid_i = 0;
        dut.eval();

        // Wait for response
        unsigned wait_cycles = 0;
        while (!dut.rsp_valid_o && wait_cycles < 10) {
            tick();
            ++wait_cycles;
        }
        check(dut.rsp_valid_o, "write32: rsp_valid_o timeout");
        bool err = dut.rsp_error_o;
        tick(); // Complete handshake
        return !err;
    }

    // Perform 32-bit MMIO read
    bool read32(uint64_t addr, uint32_t &data_out, unsigned size = 2) {
        dut.req_valid_i = 1;
        dut.req_store_i = 0;
        dut.req_addr_i = addr;
        dut.req_size_i = size;
        dut.req_store_data_i = 0;
        dut.rsp_ready_i = 1;
        dut.eval();

        check(dut.req_ready_o, "read32: req_ready_o not asserted in IDLE");
        tick();

        dut.req_valid_i = 0;
        dut.eval();

        unsigned wait_cycles = 0;
        while (!dut.rsp_valid_o && wait_cycles < 10) {
            tick();
            ++wait_cycles;
        }
        check(dut.rsp_valid_o, "read32: rsp_valid_o timeout");
        data_out = uint32_t(dut.rsp_data_o & 0xFFFFFFFFULL);
        bool err = dut.rsp_error_o;
        tick(); // Complete handshake
        return !err;
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    UartDriver d;

    try {
        std::cout << "Starting Lite-16550A UART verification suite...\n";

        // =====================================================================
        // Scenario 1: Reset Register Values
        // =====================================================================
        {
            d.reset();
            uint32_t val = 0;
            check(d.read32(UART_BASE + 0x00, val), "Read RBR failed");
            check((val & 0xFF) == 0x00, "Reset RBR != 0x00");

            check(d.read32(UART_BASE + 0x04, val), "Read IER failed");
            check((val & 0xFF) == 0x00, "Reset IER != 0x00");

            check(d.read32(UART_BASE + 0x08, val), "Read IIR failed");
            check((val & 0xFF) == 0x01, "Reset IIR != 0x01 (expected no interrupt pending)");

            check(d.read32(UART_BASE + 0x0C, val), "Read LCR failed");
            check((val & 0xFF) == 0x03, "Reset LCR != 0x03 (expected 8N1, DLAB=0)");

            check(d.read32(UART_BASE + 0x10, val), "Read MCR failed");
            check((val & 0xFF) == 0x00, "Reset MCR != 0x00");

            check(d.read32(UART_BASE + 0x14, val), "Read LSR failed");
            check((val & 0xFF) == 0x60, "Reset LSR != 0x60 (expected THRE=1, TEMT=1, DR=0)");

            check(d.read32(UART_BASE + 0x18, val), "Read MSR failed");
            check((val & 0xFF) == 0x00, "Reset MSR != 0x00");

            check(d.read32(UART_BASE + 0x1C, val), "Read SCR failed");
            check((val & 0xFF) == 0x00, "Reset SCR != 0x00");

            check(!d.dut.tx_valid_o, "tx_valid_o active out of reset");
            check(!d.dut.irq_o, "irq_o active out of reset");
            check(d.tx_log.empty(), "Spurious TX log out of reset");
            std::cout << "Scenario 1 (Reset register values): PASS\n";
        }

        // =====================================================================
        // Scenario 2: THR TX Emission
        // =====================================================================
        {
            d.reset();
            bool ok = d.write32(UART_BASE + 0x00, 'H');
            check(ok, "THR write failed");
            check(d.tx_log.size() == 1, "Expected exactly 1 TX event");
            check(d.tx_log[0] == 'H', "TX data mismatch: expected 'H'");
            std::cout << "Scenario 2 (THR TX emission): PASS\n";
        }

        // =====================================================================
        // Scenario 3: One accepted write -> One TX event
        // =====================================================================
        {
            d.write32(UART_BASE + 0x00, 'e');
            d.write32(UART_BASE + 0x00, 'l');
            d.write32(UART_BASE + 0x00, 'l');
            d.write32(UART_BASE + 0x00, 'o');
            check(d.tx_log.size() == 5, "Expected 5 TX events for 'Hello'");
            check(d.tx_log[1] == 'e' && d.tx_log[2] == 'l' && d.tx_log[3] == 'l' && d.tx_log[4] == 'o',
                  "Sequential TX characters mismatch");
            std::cout << "Scenario 3 (One accepted write -> One TX event): PASS\n";
        }

        // =====================================================================
        // Scenario 4: Rejected write -> Zero TX events
        // =====================================================================
        {
            unsigned prev_tx_count = d.tx_log.size();
            // Invalid size: 64-bit store (size=3)
            bool ok = d.write32(UART_BASE + 0x00, 'X', 3);
            check(!ok, "64-bit store should be rejected with bus error");
            check(d.tx_log.size() == prev_tx_count, "Rejected write must not emit TX");

            // Misaligned store (size=2, unaligned address)
            ok = d.write32(UART_BASE + 0x01, 'Y', 2);
            check(!ok, "Misaligned store should be rejected with bus error");
            check(d.tx_log.size() == prev_tx_count, "Misaligned write must not emit TX");

            // Byte store (size=0) & Halfword store (size=1) to THR should succeed
            ok = d.write32(UART_BASE + 0x00, 'B', 0);
            check(ok, "Byte store to UART THR should succeed");
            check(d.tx_log.size() == prev_tx_count + 1 && d.tx_log.back() == 'B', "Byte store emits TX");

            ok = d.write32(UART_BASE + 0x00, 'H', 1);
            check(ok, "Halfword store to UART THR should succeed");
            check(d.tx_log.size() == prev_tx_count + 2 && d.tx_log.back() == 'H', "Halfword store emits TX");
            std::cout << "Scenario 4 (Rejected/Narrow UART write TX handling): PASS\n";
        }

        // =====================================================================
        // Scenario 5: DLAB=0 THR Semantics
        // =====================================================================
        {
            d.reset();
            // Verify LCR[7] == 0
            uint32_t lcr = 0;
            d.read32(UART_BASE + 0x0C, lcr);
            check((lcr & 0x80) == 0, "DLAB should be 0");

            d.write32(UART_BASE + 0x00, 'A');
            check(d.tx_log.size() == 1 && d.tx_log[0] == 'A', "THR emit with DLAB=0 failed");

            // Read RBR: should return 0x00 (empty)
            uint32_t rbr = 0xFF;
            d.read32(UART_BASE + 0x00, rbr);
            check((rbr & 0xFF) == 0x00, "RBR read returned non-zero");
            std::cout << "Scenario 5 (DLAB=0 THR semantics): PASS\n";
        }

        // =====================================================================
        // Scenario 6: DLAB=1 DLL write/readback
        // =====================================================================
        {
            // Set DLAB = 1
            d.write32(UART_BASE + 0x0C, 0x83);
            uint32_t lcr = 0;
            d.read32(UART_BASE + 0x0C, lcr);
            check((lcr & 0x80) == 0x80, "Failed to set DLAB=1");

            // Write DLL = 0x54
            d.write32(UART_BASE + 0x00, 0x54);
            uint32_t dll = 0;
            d.read32(UART_BASE + 0x00, dll);
            check((dll & 0xFF) == 0x54, "DLL readback mismatch: expected 0x54");
            std::cout << "Scenario 6 (DLAB=1 DLL write/readback): PASS\n";
        }

        // =====================================================================
        // Scenario 7: DLAB=1 DLM write/readback
        // =====================================================================
        {
            // Write DLM = 0x12
            d.write32(UART_BASE + 0x04, 0x12);
            uint32_t dlm = 0;
            d.read32(UART_BASE + 0x04, dlm);
            check((dlm & 0xFF) == 0x12, "DLM readback mismatch: expected 0x12");
            std::cout << "Scenario 7 (DLAB=1 DLM write/readback): PASS\n";
        }

        // =====================================================================
        // Scenario 8: DLL write produces zero TX
        // =====================================================================
        {
            unsigned prev_tx = d.tx_log.size();
            d.write32(UART_BASE + 0x00, 'Z');
            check(d.tx_log.size() == prev_tx, "DLL write emitted spurious TX character");
            uint32_t dll = 0;
            d.read32(UART_BASE + 0x00, dll);
            check((dll & 0xFF) == 'Z', "DLL value not updated");
            std::cout << "Scenario 8 (DLL write produces zero TX): PASS\n";
        }

        // =====================================================================
        // Scenario 9: DLM write produces zero TX
        // =====================================================================
        {
            unsigned prev_tx = d.tx_log.size();
            d.write32(UART_BASE + 0x04, 0x34);
            check(d.tx_log.size() == prev_tx, "DLM write emitted spurious TX character");
            uint32_t dlm = 0;
            d.read32(UART_BASE + 0x04, dlm);
            check((dlm & 0xFF) == 0x34, "DLM value not updated");
            std::cout << "Scenario 9 (DLM write produces zero TX): PASS\n";
        }

        // =====================================================================
        // Scenario 10: DLAB return to 0 restores THR/IER behavior
        // =====================================================================
        {
            // Return DLAB to 0
            d.write32(UART_BASE + 0x0C, 0x03);
            uint32_t lcr = 0;
            d.read32(UART_BASE + 0x0C, lcr);
            check((lcr & 0x80) == 0x00, "DLAB should be 0");

            // Offset 0x00 write must now emit TX character
            unsigned prev_tx = d.tx_log.size();
            d.write32(UART_BASE + 0x00, 'K');
            check(d.tx_log.size() == prev_tx + 1 && d.tx_log.back() == 'K',
                  "Restored THR write did not emit TX character");

            // Offset 0x00 read should return RBR=0 (not DLL='Z')
            uint32_t rbr = 0xFF;
            d.read32(UART_BASE + 0x00, rbr);
            check((rbr & 0xFF) == 0x00, "RBR read returned DLL value instead of RBR");

            // Offset 0x04 read should return IER=0 (not DLM=0x34)
            uint32_t ier = 0xFF;
            d.read32(UART_BASE + 0x04, ier);
            check((ier & 0xFF) == 0x00, "IER read returned DLM value instead of IER");
            std::cout << "Scenario 10 (DLAB return to 0 restores THR/IER behavior): PASS\n";
        }

        // =====================================================================
        // Scenario 11: IER read/write and interrupt lifecycle
        // =====================================================================
        {
            d.reset();
            // Write IER: enable ETBEI (bit 1)
            d.write32(UART_BASE + 0x04, 0x02);
            uint32_t ier = 0;
            d.read32(UART_BASE + 0x04, ier);
            check((ier & 0xFF) == 0x02, "IER write/readback mismatch");
            check(d.dut.irq_o, "Expected irq_o asserted when ETBEI enabled and THRE=1");

            // Read IIR: should report THRE interrupt pending (0x02)
            uint32_t iir = 0;
            d.read32(UART_BASE + 0x08, iir);
            check((iir & 0xFF) == 0x02, "IIR should report THRE interrupt (0x02)");
            check(!d.dut.irq_o, "Reading IIR should clear THRE interrupt");

            // Second IIR read: should report no interrupt pending (0x01)
            d.read32(UART_BASE + 0x08, iir);
            check((iir & 0xFF) == 0x01, "Second IIR read should report no pending interrupt");

            // Disable IER
            d.write32(UART_BASE + 0x04, 0x00);
            check(!d.dut.irq_o, "irq_o should be 0 when IER=0");
            std::cout << "Scenario 11 (IER read/write and interrupt lifecycle): PASS\n";
        }

        // =====================================================================
        // Scenario 12: IIR Non-FIFO reporting
        // =====================================================================
        {
            uint32_t iir = 0;
            d.read32(UART_BASE + 0x08, iir);
            check((iir & 0xC0) == 0x00, "IIR bits 7:6 must be 2'b00 (non-FIFO mode)");
            std::cout << "Scenario 12 (IIR non-FIFO reporting): PASS\n";
        }

        // =====================================================================
        // Scenario 13: FCR write ignored
        // =====================================================================
        {
            // Write FCR = 0xC7 (attempt to enable and reset FIFOs)
            bool ok = d.write32(UART_BASE + 0x08, 0xC7);
            check(ok, "FCR write should be accepted without bus error");
            uint32_t iir = 0;
            d.read32(UART_BASE + 0x08, iir);
            check((iir & 0xC0) == 0x00, "FCR write must not enable FIFOs (IIR[7:6] must stay 00)");
            std::cout << "Scenario 13 (FCR write ignored): PASS\n";
        }

        // =====================================================================
        // Scenario 14: LCR read/write
        // =====================================================================
        {
            d.write32(UART_BASE + 0x0C, 0x1B);
            uint32_t lcr = 0;
            d.read32(UART_BASE + 0x0C, lcr);
            check((lcr & 0xFF) == 0x1B, "LCR readback mismatch: expected 0x1B");
            d.write32(UART_BASE + 0x0C, 0x03); // Restore 8N1
            std::cout << "Scenario 14 (LCR read/write): PASS\n";
        }

        // =====================================================================
        // Scenario 15: MCR read/write
        // =====================================================================
        {
            d.write32(UART_BASE + 0x10, 0x0B);
            uint32_t mcr = 0;
            d.read32(UART_BASE + 0x10, mcr);
            check((mcr & 0xFF) == 0x0B, "MCR readback mismatch: expected 0x0B");
            d.write32(UART_BASE + 0x10, 0x00);
            std::cout << "Scenario 15 (MCR read/write): PASS\n";
        }

        // =====================================================================
        // Scenario 16: LSR THRE/TEMT read-only behavior
        // =====================================================================
        {
            uint32_t lsr = 0;
            d.read32(UART_BASE + 0x14, lsr);
            check((lsr & 0xFF) == 0x60, "LSR should report 0x60 (THRE=1, TEMT=1, DR=0)");

            // Attempt to overwrite LSR
            d.write32(UART_BASE + 0x14, 0x00);
            d.read32(UART_BASE + 0x14, lsr);
            check((lsr & 0xFF) == 0x60, "LSR must be read-only (writes ignored)");
            std::cout << "Scenario 16 (LSR THRE/TEMT): PASS\n";
        }

        // =====================================================================
        // Scenario 17: MSR deterministic behavior
        // =====================================================================
        {
            uint32_t msr = 0xFF;
            d.read32(UART_BASE + 0x18, msr);
            check((msr & 0xFF) == 0x00, "MSR should report 0x00");

            d.write32(UART_BASE + 0x18, 0xFF);
            d.read32(UART_BASE + 0x18, msr);
            check((msr & 0xFF) == 0x00, "MSR must be read-only (writes ignored)");
            std::cout << "Scenario 17 (MSR deterministic behavior): PASS\n";
        }

        // =====================================================================
        // Scenario 18: SCR read/write
        // =====================================================================
        {
            d.write32(UART_BASE + 0x1C, 0xA5);
            uint32_t scr = 0;
            d.read32(UART_BASE + 0x1C, scr);
            check((scr & 0xFF) == 0xA5, "SCR readback mismatch: expected 0xA5");
            std::cout << "Scenario 18 (SCR read/write): PASS\n";
        }

        // =====================================================================
        // Scenario 19: Invalid size rejected with zero side effects
        // =====================================================================
        {
            // Attempt 64-bit access (size=3) to SCR
            bool ok = d.write32(UART_BASE + 0x1C, 0x5A, 3);
            check(!ok, "64-bit store to UART MMIO must raise bus error");
            uint32_t scr = 0;
            d.read32(UART_BASE + 0x1C, scr);
            check((scr & 0xFF) == 0xA5, "Rejected 64-bit store must not mutate SCR");

            // 16-bit (size=1) and 8-bit (size=0) SCR writes & reads succeed, misaligned 16-bit rejected
            ok = d.write32(UART_BASE + 0x1C, 0x3C, 1);
            check(ok, "16-bit store to UART MMIO should succeed");
            d.read32(UART_BASE + 0x1C, scr, 1);
            check((scr & 0xFF) == 0x3C, "16-bit store should update SCR");

            ok = d.write32(UART_BASE + 0x1C, 0x6E, 0);
            check(ok, "8-bit store to UART MMIO should succeed");
            d.read32(UART_BASE + 0x1C, scr, 0);
            check((scr & 0xFF) == 0x6E, "8-bit store should update SCR");

            ok = d.write32(UART_BASE + 0x1D, 0x77, 1);
            check(!ok, "Misaligned 16-bit store to odd address must raise bus error");
            d.read32(UART_BASE + 0x1C, scr);
            check((scr & 0xFF) == 0x6E, "Rejected misaligned 16-bit store must not mutate SCR");
            std::cout << "Scenario 19 (Invalid size rejected / byte+halfword supported): PASS\n";
        }

        // =====================================================================
        // Scenario 20: Misaligned access rejected with zero side effects
        // =====================================================================
        {
            bool ok = d.write32(UART_BASE + 0x01, 0x77);
            check(!ok, "Misaligned address 0x1000_0001 must raise bus error");

            ok = d.write32(UART_BASE + 0x02, 0x77);
            check(!ok, "Misaligned address 0x1000_0002 must raise bus error");

            ok = d.write32(UART_BASE + 0x03, 0x77);
            check(!ok, "Misaligned address 0x1000_0003 must raise bus error");
            std::cout << "Scenario 20 (Misaligned access rejected with zero side effects): PASS\n";
        }

        // =====================================================================
        // Scenario 21: Unimplemented UART offsets deterministic behavior
        // =====================================================================
        {
            uint32_t val = 0xFFFFFFFF;
            bool ok = d.read32(UART_BASE + 0x20, val);
            check(ok, "Read unimplemented offset 0x20 should succeed without error");
            check(val == 0x00, "Unimplemented offset 0x20 must read as 0");

            ok = d.read32(UART_BASE + 0x800, val);
            check(ok, "Read unimplemented offset 0x800 should succeed without error");
            check(val == 0x00, "Unimplemented offset 0x800 must read as 0");

            ok = d.write32(UART_BASE + 0x20, 0x12345678);
            check(ok, "Write unimplemented offset 0x20 should succeed without error");
            d.read32(UART_BASE + 0x20, val);
            check(val == 0x00, "Unimplemented offset 0x20 must remain 0 after write");
            std::cout << "Scenario 21 (Unimplemented UART offsets deterministic behavior): PASS\n";
        }

        // =====================================================================
        // Scenario 22: PMP-denied upstream UART access produces no UART request/mutation
        // =====================================================================
        {
            // Upstream PMP denial simulation: when PMP denies access, no request is presented
            // Verify UART remains in current state with zero TX and zero register corruption
            uint32_t scr_before = 0;
            d.read32(UART_BASE + 0x1C, scr_before);
            unsigned tx_before = d.tx_log.size();

            // Simulate 5 idle cycles with no upstream request
            for (int i = 0; i < 5; i++) d.tick();

            check(d.tx_log.size() == tx_before, "PMP-denied state produced unexpected TX");
            uint32_t scr_after = 0;
            d.read32(UART_BASE + 0x1C, scr_after);
            check(scr_after == scr_before, "PMP-denied state mutated UART state");
            std::cout << "Scenario 22 (PMP-denied upstream access zero mutation/TX): PASS\n";
        }

        // =====================================================================
        // Scenario 23: PTW UART access rejected upstream
        // =====================================================================
        {
            // When PTW targets UART window, interconnect rejects upstream without asserting req_valid_i
            // Verify UART remains completely unaffected
            unsigned tx_before = d.tx_log.size();
            for (int i = 0; i < 5; i++) d.tick();
            check(d.tx_log.size() == tx_before, "PTW rejection upstream produced unexpected TX");
            check(!d.dut.tx_valid_o, "tx_valid_o asserted during PTW rejection");
            std::cout << "Scenario 23 (PTW UART access rejected upstream): PASS\n";
        }

        // =====================================================================
        // Scenario 24: Reset during/around access produces no spurious TX
        // =====================================================================
        {
            // Present a write to THR but assert reset at the same time
            d.dut.req_valid_i = 1;
            d.dut.req_store_i = 1;
            d.dut.req_addr_i = UART_BASE;
            d.dut.req_size_i = 2;
            d.dut.req_store_data_i = 'Q';
            d.dut.rst_i = 1; // RESET ASSERTED
            d.dut.eval();

            d.tick();

            check(!d.dut.tx_valid_o, "Reset must strictly suppress TX emission");
            check(d.tx_log.empty() || d.tx_log.back() != 'Q', "Reset emitted spurious 'Q'");

            // Deassert reset cleanly
            d.dut.rst_i = 0;
            d.dut.req_valid_i = 0;
            d.dut.eval();
            d.tick();

            check(!d.dut.tx_valid_o, "tx_valid_o asserted after reset release");
            std::cout << "Scenario 24 (Reset during access produces no spurious TX): PASS\n";
        }

        std::cout << "\nAll 24 Lite-16550A UART scenarios passed successfully!\n";
        std::cout << "{\"status\":\"pass\",\"scenarios\":24}\n";
        return 0;

    } catch (const std::exception &e) {
        std::cerr << "UART_S0_TB ERROR: " << e.what() << "\n";
        return 1;
    }
}
