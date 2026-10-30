#ifndef FURSOY_S1_SBI_H
#define FURSOY_S1_SBI_H

#include <stdint.h>

// SBI Error Codes (Specification v2.0)
#define SBI_SUCCESS               0
#define SBI_ERR_FAILED           -1
#define SBI_ERR_NOT_SUPPORTED    -2
#define SBI_ERR_INVALID_PARAM    -3
#define SBI_ERR_DENIED           -4
#define SBI_ERR_INVALID_ADDRESS  -5
#define SBI_ERR_ALREADY_AVAILABLE -6
#define SBI_ERR_ALREADY_STARTED  -7
#define SBI_ERR_ALREADY_STOPPED  -8

// SBI Extension IDs (EIDs)
#define SBI_EXT_BASE             0x10
#define SBI_EXT_TIME             0x54494D45
#define SBI_EXT_SRST             0x53525354
#define SBI_EXT_DBCN             0x4442434E

// Base Extension Function IDs
#define SBI_BASE_GET_SPEC_VERSION    0
#define SBI_BASE_GET_IMPL_ID         1
#define SBI_BASE_GET_IMPL_VERSION    2
#define SBI_BASE_PROBE_EXTENSION     3
#define SBI_BASE_GET_MVENDORID       4
#define SBI_BASE_GET_MARCHID         5
#define SBI_BASE_GET_MIMPID          6

// System Reset Types
#define SBI_SRST_RESET_TYPE_SHUTDOWN    0
#define SBI_SRST_RESET_TYPE_COLD_REBOOT 1
#define SBI_SRST_RESET_TYPE_WARM_REBOOT 2

// System Reset Reasons
#define SBI_SRST_RESET_REASON_NONE      0
#define SBI_SRST_RESET_REASON_SYSFAIL   1

// Hardware Memory Map Constants
#define CLINT_BASE               0x02000000ULL
#define CLINT_MSIP               (CLINT_BASE + 0x0000ULL)
#define CLINT_MTIMECMP           (CLINT_BASE + 0x4000ULL)
#define CLINT_MTIME              (CLINT_BASE + 0xBFF8ULL)

#define PLIC_BASE                0x0C000000ULL
#define UART_BASE                0x10000000ULL
#define UART_THR                 (UART_BASE + 0x00ULL)
#define UART_LSR                 (UART_BASE + 0x14ULL)

// SBI Return Structure
struct sbiret {
    int64_t error;
    int64_t value;
};

#endif // FURSOY_S1_SBI_H
