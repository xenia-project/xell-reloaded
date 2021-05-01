#include "xenonsprs.h"

.globl _start
_start:

b	start_from_rom  // The CD loader will jump to this address.
b	start_from_libxenon
b	.	// for future use
b	.
b	.
b	.
b	.
b	.

.globl start_from_rom
start_from_rom:
	bl	init_regs

		// disable interrupts (but enable vector available, gcc likes to use VMX
		// for memset)
	lis	%r13, 0x200
	mtmsrd	%r13, 1

	li	%r3, 2
	isync
	mtspr	lpcr, %r3            // LPCR[RMI] = 1 (Real-Mode cache inhibited)
	isync
	li      %r3, 0x3FF
	rldicr  %r3, %r3, 32,31
	tlbiel	%r3,1                // TLB invalidate (local) 0x000003FF_00000000
	sync
	isync

	mfspr	%r10, hid1
	li	%r11, 3
	rldimi	%r10, %r11, 58,4     // enable icache
	rldimi	%r10, %r11, 38,25    // instr. prefetch
	sync
	mtspr	hid1, %r10
	sync
	isync

	mfspr	%r10, lpcr
	li	    %r11, 1
	rldimi	%r10, %r11, 1,62
	isync
	mtspr	lpcr, %r10
	isync

		// set stack
	li	%sp, 0
	oris	%sp, %sp, 0x8000
	rldicr	%sp, %sp, 32,31
	oris	%sp, %sp, 0x1e00     // R1 = 0x80000000_1E000000

	mfspr	%r3, pir
	slwi	%r4, %r3, 16  		 // 64k stack per thread
	sub		%sp, %sp, %r4
	subi	%sp, %sp, 0x80

	cmpwi	%r3, 0
	bne	other_threads_waiter

	lis	%r3, 0x8000
	rldicr  %r3, %r3, 32,31
	oris	%r3, %r3, start@high
	ori	%r3, %r3, start@l
	ld	%r2, 8(%r3)

	lis	%r3, 0x8000
	sldi	%r3, %r3, 32
	oris	%r3, %r3, 1f@high
	ori	%r3, %r3, 1f@l
	mtctr	%r3
	bctr
1:


	mfspr	%r3, pir
	mfspr	%r4, hrmor
	mfpvr	%r5
	bl	start

1:
	b	1b

start_from_libxenon:
	lis	%r3, wakeup_cpus@high
	ori	%r3, %r3, wakeup_cpus@l
	li	%r4, 1
	std	%r4, 0(%r3)
		
	b	start_from_rom


other_threads_waiter:
	lis	%r4, 0x8000
	rldicr	%r4, %r4, 32,31
	oris	%r4, %r4, processors_online@high
	ori	%r4, %r4, processors_online@l
	slwi	%r3, %r3, 2
	add	%r4, %r4, %r3
	li	%r5, 1
	stw	%r5, 0(%r4)

	lis	%r3, 0x8000
	rldicr	%r3, %r3, 32,31
	oris	%r3, %r3, secondary_hold_addr@high
	ori	%r3, %r3, secondary_hold_addr@l

1:
	or	%r1, %r1, %r1	// low priority
	ld	%r4, 0(%r3)
	cmpwi	%r4, 0
	beq	1b

	li	%r3, 0
	mtspr	hrmor, %r3
	mtspr	rmor, %r3

	mtctr	%r4

	mfspr	%r3, pir

	bctr

.globl other_threads_startup
other_threads_startup:
	mfspr	%r3, pir
	andi.   %r3,%r3,1
	cmplwi  %r3,1
	beq	1f

	bl	init_regs
	
	li	%r3,0
	mtspr	hrmor,%r3
	sync
	isync

	// 0x00C00000
	// TE = 0b11 (enable both threads)
	lis	%r3,0xC0
	mtspr	ctrlwr,%r3
	sync
	isync

1:
	li	%r4,0x30 // Clear IR/DR
	mfmsr	%r3
	andc	%r3,%r3,%r4
	mtsrr1	%r3

	lis	%r3, start_from_rom@high
	ori	%r3, %r3, start_from_rom@l

	mtsrr0	%r3
	rfid

init_regs:
	or	%r2, %r2, %r2 // normal priority

	// Set up the HID (Hardware Implementation Dependent) registers.
	// Refer to Cell Broadband Engine Registers, v1.5

	// HID0: Implementation differs per CPU, but some bits are reused.
	// On the Cell Broadband Engine, this just inhibits things we probably don't want.
	li	%r3, 0
	mtspr	hid0, %r3
	sync
	isync

	// As per the Cell Broadband Engine Hardware Initialization Guide.
	// Enable the L1 data cache.
	// 0x00003F0000000000
	li	%r3, 0x3f00
	rldicr	%r3, %r3, 32,31
	mtspr	hid4, %r3
	sync
	isync

	// As per Cell Broadband Engine Hardware Initialization Guide.
	// Enable the L1 instruction cache, and make 0x100 the reset vector for thread 0.
	// DIS_SYSRST_REG = 1 (Disable config ring system reset vector)
	// 0x9C30104000000000
	lis	%r3, 0x9c30
	ori	%r3,%r3, 0x1040
	rldicr	%r3, %r3, 32,31
	mtspr   hid1, %r3
	sync
	isync

	// Initialize RMSC to set the real mode address boundary to 2TB.
	// RMSC = 0b1110b
	// LB   = 0b1000 (64KB / 16MB large page table size)
	// TB   = 0b1 (Time base enabled)
	// 0x0001803800000000
	lis	%r3, 1
	ori	%r3,%r3, 0x8038
	rldicr	%r3, %r3, 32,31
	mtspr	hid6, %r3
	sync
	isync

	// Thread Switch Control Register (tscr)
	// WEXT = 1
	// PBUMP = 1 (boost thread priority level to medium when interrupt pending)
	// FPCF = 1
	// PSCTP = 1 (privileged can change priority)
	// 0x001D0000
	lis	%r3, 0x1d
	mtspr	tscr, %r3
	sync
	isync

	// Thread Switch Timeout Register
	// TTM = 0x1000 (thread interrupted after executing 4096 instructions)
	li	%r3, 0x1000
	mtspr	ttr, %r3
	sync
	isync

	blr

.globl other_threads_startup_end
other_threads_startup_end:


.globl fix_hrmor
fix_hrmor:
	li %r3, 0
	mtspr hrmor, %r3
	blr

	// r6 = addr, r7 = hrmor
.globl jump
jump:
	mtspr rmor, %r7
	mtspr hrmor, %r7
	isync
	sync
	mtsrr0 %r6

		/* switch into real mode (clear IR/DR) */
	mfmsr %r6
	li %r7, 0x30
	andc %r6, %r6, %r7
	mtsrr1 %r6
	rfid
