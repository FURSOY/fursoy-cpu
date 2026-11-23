#ifndef FURSOY_S2_SBI_H
#define FURSOY_S2_SBI_H

#define SBI_MAX_HARTS        4UL
#ifndef FURSOY_NUM_HARTS
#define FURSOY_NUM_HARTS     SBI_MAX_HARTS
#endif
#define SBI_STACK_SIZE       4096UL
#define SMODE_ENTRY_ADDR     0x80200000UL
#define DTB_DEFAULT_ADDR     0x82000000UL

#define DRAM_BASE            0x80000000UL
#define DRAM_SIZE            0x10000000UL
#define DRAM_END             (DRAM_BASE + DRAM_SIZE)

#define CLINT_BASE           0x02000000UL
#define CLINT_MSIP(h)        (*(volatile unsigned int *)(CLINT_BASE + 0x0000UL + 4UL * (unsigned long)(h)))
#define CLINT_MTIMECMP(h)    (*(volatile unsigned long *)(CLINT_BASE + 0x4000UL + 8UL * (unsigned long)(h)))
#define CLINT_MTIME          (*(volatile unsigned long *)(CLINT_BASE + 0xBFF8UL))

#define UART_BASE            0x10000000UL
#define UART_THR             (*(volatile unsigned int *)(UART_BASE + 0x00UL))
#define UART_RBR             (*(volatile unsigned int *)(UART_BASE + 0x00UL))
#define UART_LSR             (*(volatile unsigned int *)(UART_BASE + 0x14UL))
#define UART_LSR_DR          0x01U
#define UART_LSR_THRE        0x20U

/* Legacy SBI EIDs */
#define SBI_LEGACY_SET_TIMER         0x00L
#define SBI_LEGACY_CONSOLE_PUTCHAR   0x01L
#define SBI_LEGACY_CONSOLE_GETCHAR   0x02L
#define SBI_LEGACY_CLEAR_IPI         0x03L
#define SBI_LEGACY_SEND_IPI          0x04L
#define SBI_LEGACY_REMOTE_FENCE_I    0x05L
#define SBI_LEGACY_REMOTE_SFENCE_VMA 0x06L
#define SBI_LEGACY_SHUTDOWN          0x08L

/* Standard SBI v0.2+ EIDs */
#define SBI_EXT_BASE                 0x10L
#define SBI_EXT_TIME                 0x54494D45L
#define SBI_EXT_IPI                  0x00735049L
#define SBI_EXT_RFENCE               0x52464E43L
#define SBI_EXT_HSM                  0x0048534DL
#define SBI_EXT_SRST                 0x53525354L
#define SBI_EXT_DBCN                 0x4442434EL

/* HSM States */
#define SBI_HSM_STATE_STARTED        0UL
#define SBI_HSM_STATE_STOPPED        1UL
#define SBI_HSM_STATE_START_PENDING  2UL
#define SBI_HSM_STATE_STOP_PENDING   3UL

/* SBI Standard Error Codes */
#define SBI_SUCCESS                  0L
#define SBI_ERR_FAILED              -1L
#define SBI_ERR_NOT_SUPPORTED       -2L
#define SBI_ERR_INVALID_PARAM       -3L
#define SBI_ERR_DENIED              -4L
#define SBI_ERR_INVALID_ADDRESS     -5L
#define SBI_ERR_ALREADY_AVAILABLE   -6L

/* Internal IPI Pending Bitmask */
#define IPI_BIT_SSIP                 (1U << 0)
#define IPI_BIT_FENCE_I              (1U << 1)
#define IPI_BIT_SFENCE_VMA           (1U << 2)
#define IPI_BIT_SFENCE_VMA_ASID      (1U << 3)
#define IPI_REASON_HALT              (1U << 4)

#ifndef __ASSEMBLER__

typedef unsigned char      uint8_t;
typedef unsigned int       uint32_t;
typedef unsigned long      uint64_t;
typedef unsigned long      uintptr_t;
typedef long               int64_t;

typedef struct {
    volatile uint64_t hsm_state;
    volatile uint64_t start_addr;
    volatile uint64_t opaque;
    volatile uint32_t pending_ipi;
    uint32_t          _pad0;
    volatile uint64_t rfence_addr;
    volatile uint64_t rfence_size;
    volatile uint64_t rfence_asid;
    uint64_t          _pad1;
} __attribute__((aligned(64))) sbi_hart_t;

typedef struct {
    long error;
    long value;
} sbi_ret_t;

typedef struct {
    uint64_t ra;
    uint64_t sp;
    uint64_t gp;
    uint64_t tp;
    uint64_t t0;
    uint64_t t1;
    uint64_t t2;
    uint64_t s0;
    uint64_t s1;
    uint64_t a0;
    uint64_t a1;
    uint64_t a2;
    uint64_t a3;
    uint64_t a4;
    uint64_t a5;
    uint64_t a6;
    uint64_t a7;
    uint64_t s2;
    uint64_t s3;
    uint64_t s4;
    uint64_t s5;
    uint64_t s6;
    uint64_t s7;
    uint64_t s8;
    uint64_t s9;
    uint64_t s10;
    uint64_t s11;
    uint64_t t3;
    uint64_t t4;
    uint64_t t5;
    uint64_t t6;
    uint64_t mepc;
    uint64_t mstatus;
    uint64_t mcause;
    uint64_t mtval;
} sbi_trap_regs_t;

extern volatile uint64_t g_sbi_num_harts;
extern volatile uint64_t g_sbi_dtb_addr;

void sbi_init_bsp(uint64_t num_harts, uint64_t dtb_addr);
uint64_t sbi_secondary_wait_start(uint64_t hartid, uint64_t *out_start_addr, uint64_t *out_opaque);
void sbi_handle_msip(uint64_t hartid);
void sbi_handle_trap(sbi_trap_regs_t *regs);

#endif /* !__ASSEMBLER__ */
#endif /* FURSOY_S2_SBI_H */
