#ifndef FURSOY_SBI_H
#define FURSOY_SBI_H

#include <stdint.h>

// Standard SBI Error Codes
#define SBI_SUCCESS                0
#define SBI_ERR_FAILED            -1
#define SBI_ERR_NOT_SUPPORTED     -2
#define SBI_ERR_INVALID_PARAM     -3
#define SBI_ERR_DENIED            -4
#define SBI_ERR_INVALID_ADDRESS   -5
#define SBI_ERR_ALREADY_AVAILABLE -6

// Standard SBI Extension IDs (EIDs)
#define SBI_EXT_BASE 0x10
#define SBI_EXT_TIME 0x54494D45
#define SBI_EXT_SRST 0x53525354
#define SBI_EXT_DBCN 0x4442434E

// Base Extension Function IDs (FIDs)
#define SBI_BASE_GET_SPEC_VERSION 0
#define SBI_BASE_GET_IMPL_ID      1
#define SBI_BASE_GET_IMPL_VERSION 2
#define SBI_BASE_PROBE_EXTENSION  3
#define SBI_BASE_GET_MVENDORID    4
#define SBI_BASE_GET_MARCHID      5
#define SBI_BASE_GET_MIMPID       6

// System Reset Types
#define SBI_SRST_RESET_TYPE_SHUTDOWN    0
#define SBI_SRST_RESET_TYPE_COLD_REBOOT  1
#define SBI_SRST_RESET_TYPE_WARM_REBOOT  2

// Memory-Mapped Peripheral Registers
#define CLINT_BASE     0x02000000ULL
#define CLINT_MTIMECMP 0x02004000ULL
#define CLINT_MTIME    0x0200BFF8ULL

#define UART_BASE      0x10000000ULL
#define UART_THR       0x10000000ULL
#define UART_LSR       0x10000014ULL

struct sbiret {
    int64_t error;
    int64_t value;
};

void sbi_trap_entry(void);
struct sbiret sbi_ecall_dispatch(uint64_t eid, uint64_t fid,
                                 uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3);
void sbi_timer_trap_handler(void);
void sbi_panic(uint64_t cause, uint64_t epc, uint64_t tval);

#endif /* FURSOY_SBI_H */
