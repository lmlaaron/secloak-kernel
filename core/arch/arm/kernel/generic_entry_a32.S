/*
 * Copyright (c) 2014, Linaro Limited
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 * this list of conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#include <arm32_macros.S>
#include <arm.h>
#include <asm.S>
#include <keep.h>
#include <platform_config.h>
#include <sm/optee_smc.h>
#include <sm/teesmc_opteed.h>
#include <sm/teesmc_opteed_macros.h>

.section .data
.balign 4

#ifdef CFG_BOOT_SYNC_CPU
.equ SEM_CPU_READY, 1
#endif

#ifdef CFG_PL310
.section .rodata.init
panic_boot_file:
	.asciz __FILE__

/*
 * void assert_flat_mapped_range(uint32_t vaddr, uint32_t line)
 */
.section .text.init
LOCAL_FUNC __assert_flat_mapped_range , :
	push	{ r4-r6, lr }
	mov	r4, r0
	mov	r5, r1
	bl	cpu_mmu_enabled
	cmp	r0, #0
	beq	1f
	mov	r0, r4
	bl	virt_to_phys
	cmp	r0, r4
	beq	1f
	/*
	 * this must be compliant with the panic generic routine:
	 * __do_panic(__FILE__, __LINE__, __func__, str)
	 */
	ldr	r0, =panic_boot_file
	mov	r1, r5
	mov	r2, #0
	mov	r3, #0
	bl	__do_panic
	b	.		/* should NOT return */
1:	pop	{ r4-r6, pc }
END_FUNC __assert_flat_mapped_range

	/* panic if mmu is enable and vaddr != paddr (scratch lr) */
	.macro assert_flat_mapped_range va, line
		ldr	r0, =(\va)
		ldr	r1, =\line
		bl	__assert_flat_mapped_range
	.endm
#endif /* CFG_PL310 */

.weak plat_cpu_reset_early
FUNC plat_cpu_reset_early , :
	bx	lr
END_FUNC plat_cpu_reset_early
KEEP_PAGER plat_cpu_reset_early

.section .text.boot
FUNC _start , :
	b	reset
	b	.	/* Undef */
	b	.	/* Syscall */
	b	.	/* Prefetch abort */
	b	.	/* Data abort */
	b	.	/* Reserved */
	b	.	/* IRQ */
	b	.	/* FIQ */
END_FUNC _start
KEEP_INIT _start

	.macro cpu_is_ready
#ifdef CFG_BOOT_SYNC_CPU
	bl	get_core_pos
	lsl	r0, r0, #2
	ldr	r1,=sem_cpu_sync
	ldr	r2, =SEM_CPU_READY
	str	r2, [r1, r0]
	dsb
	sev
#endif
	.endm

	.macro wait_primary
#ifdef CFG_BOOT_SYNC_CPU
	ldr	r0, =sem_cpu_sync
	mov	r2, #SEM_CPU_READY
	sev
1:
	ldr	r1, [r0]
	cmp	r1, r2
	wfene
	bne	1b
#endif
	.endm

	.macro wait_secondary
#ifdef CFG_BOOT_SYNC_CPU
	ldr	r0, =sem_cpu_sync
	mov	r3, #CFG_TEE_CORE_NB_CORE
	mov	r2, #SEM_CPU_READY
	sev
1:
	subs	r3, r3, #1
	beq	3f
	add	r0, r0, #4
2:
	ldr	r1, [r0]
	cmp	r1, r2
	wfene
	bne	2b
	b	1b
3:
#endif
	.endm

	/*
	 * Save boot arguments
	 * entry r0, saved r4: pagestore
	 * entry r1, saved r7: (ARMv7 standard bootarg #1)
	 * entry r2, saved r6: device tree address, (ARMv7 standard bootarg #2)
	 * entry lr, saved r5: non-secure entry address (ARMv7 bootarg #0)
	 */
	.macro bootargs_entry
#if defined(CFG_NS_ENTRY_ADDR)
	ldr	r5, =CFG_NS_ENTRY_ADDR
#else
	mov	r5, lr
#endif
#if defined(CFG_PAGEABLE_ADDR)
	ldr	r4, =CFG_PAGEABLE_ADDR
#else
	mov	r4, r0
#endif
#if defined(CFG_DT_ADDR)
	ldr	r6, =CFG_DT_ADDR
#else
	mov	r6, r2
#endif
	mov	r7, r1
	.endm

LOCAL_FUNC reset , :
	bootargs_entry

	/* Enable alignment checks and disable data and instruction cache. */
	read_sctlr r0
#if defined(CFG_SCTLR_ALIGNMENT_CHECK)
	orr	r0, r0, #SCTLR_A
#else
	bic	r0, r0, #SCTLR_A
#endif
	bic	r0, r0, #SCTLR_C
	bic	r0, r0, #SCTLR_I
#if defined(CFG_HWSUPP_MEM_PERM_WXN) && defined(CFG_CORE_RWDATA_NOEXEC)
	orr	r0, r0, #(SCTLR_WXN | SCTLR_UWXN)
#endif
	write_sctlr r0
	isb

	/* Early ARM secure MP specific configuration */
	bl	plat_cpu_reset_early

	ldr	r0, =_start
	write_vbar r0

#if defined(CFG_WITH_ARM_TRUSTED_FW)
	b	reset_primary
#else
	bl	get_core_pos
	cmp	r0, #0
	beq	reset_primary
	b	reset_secondary
#endif
END_FUNC reset

	/*
	 * Setup sp to point to the top of the tmp stack for the current CPU:
	 * sp is assigned stack_tmp_export + cpu_id * stack_tmp_stride
	 */
	.macro set_sp
		bl	get_core_pos
		cmp	r0, #CFG_TEE_CORE_NB_CORE
		/* Unsupported CPU, park it before it breaks something */
		bge	unhandled_cpu
		ldr	r1, =stack_tmp_stride
		ldr	r1, [r1]
		mul	r1, r0, r1
		ldr	r0, =stack_tmp_export
		ldr	r0, [r0]
		add	sp, r1, r0
	.endm

	/*
	 * Cache maintenance during entry: handle outer cache.
	 * End address is exclusive: first byte not to be changed.
	 * Note however arm_clX_inv/cleanbyva operate on full cache lines.
	 *
	 * Use ANSI #define to trap source file line number for PL310 assertion
	 */
	.macro __inval_cache_vrange vbase, vend, line
#ifdef CFG_PL310
		assert_flat_mapped_range (\vbase), (\line)
		bl	pl310_base
		ldr	r1, =(\vbase)
		ldr	r2, =(\vend)
		bl	arm_cl2_invbypa
#endif
		ldr	r0, =(\vbase)
		ldr	r1, =(\vend)
		bl	arm_cl1_d_invbyva
	.endm

	.macro __flush_cache_vrange vbase, vend, line
#ifdef CFG_PL310
		assert_flat_mapped_range (\vbase), (\line)
		ldr	r0, =(\vbase)
		ldr	r1, =(\vend)
		bl	arm_cl1_d_cleanbyva
		bl	pl310_base
		ldr	r1, =(\vbase)
		ldr	r2, =(\vend)
		bl	arm_cl2_cleaninvbypa
#endif
		ldr	r0, =(\vbase)
		ldr	r1, =(\vend)
		bl	arm_cl1_d_cleaninvbyva
	.endm

#define inval_cache_vrange(vbase, vend) \
		__inval_cache_vrange (vbase), ((vend) - 1), __LINE__

#define flush_cache_vrange(vbase, vend) \
		__flush_cache_vrange (vbase), ((vend) - 1), __LINE__

#ifdef CFG_BOOT_SYNC_CPU
#define flush_cpu_semaphores \
		flush_cache_vrange(sem_cpu_sync, \
				   (sem_cpu_sync + (CFG_TEE_CORE_NB_CORE << 2)))
#else
#define flush_cpu_semaphores
#endif

LOCAL_FUNC reset_primary , :
	/* preserve r4-r7: bootargs */

	/*
	 * Clear .bss, this code obviously depends on the linker keeping
	 * start/end of .bss at least 8 byte aligned.
	 */
	ldr	r0, =__bss_start
	ldr	r1, =__bss_end
	mov	r2, #0
	mov	r3, #0
clear_bss:
	stmia	r0!, {r2, r3}
	cmp	r0, r1
	bls	clear_bss

	set_sp

	/* complete ARM secure MP common configuration */
	bl	plat_cpu_reset_late

	/* Enable Console */
	bl	console_init

#ifdef CFG_PL310
	bl	pl310_base
	bl	arm_cl2_config
#endif

	/*
	 * Invalidate dcache for all memory used during initialization to
	 * avoid nasty surprices when the cache is turned on. We must not
	 * invalidate memory not used by OP-TEE since we may invalidate
	 * entries used by for instance ARM Trusted Firmware.
	 */
	inval_cache_vrange(__text_start, __end)

#ifdef CFG_PL310
	/* Enable PL310 if not yet enabled */
	bl	pl310_base
	bl	arm_cl2_enable
#endif

	bl	core_init_mmu_map
	bl	core_init_mmu_regs
	bl	cpu_mmu_enable
	bl	cpu_mmu_enable_icache
	bl	cpu_mmu_enable_dcache

	mov	r0, r4		/* pageable part address */
	mov	r1, r5		/* ns-entry address */
	mov	r2, r6		/* DT address */
	bl	generic_boot_init_primary
	mov	r4, r0		/* save entry test vector */

	/*
	 * In case we've touched memory that secondary CPUs will use before
	 * they have turned on their D-cache, clean and invalidate the
	 * D-cache before exiting to normal world.
	 */
	flush_cache_vrange(__text_start, __end)

	/* release secondary boot cores and sync with them */
	cpu_is_ready
	flush_cpu_semaphores
	wait_secondary

#ifdef CFG_PL310_LOCKED
	/* lock/invalidate all lines: pl310 behaves as if disable */
	bl	pl310_base
	bl	arm_cl2_lockallways
	bl	pl310_base
	bl	arm_cl2_cleaninvbyway
#endif

	/*
	 * Clear current thread id now to allow the thread to be reused on
	 * next entry. Matches the thread_init_boot_thread() in
	 * generic_boot.c.
	 */
	bl 	thread_clr_boot_thread

#if defined(CFG_WITH_ARM_TRUSTED_FW)
	/* Pass the vector address returned from main_init */
	mov	r1, r4
#else
	/* realy standard bootarg #1 and #2 to non secure entry */
	mov	r4, #0
	mov	r3, r6		/* std bootarg #2 for register R2 */
	mov	r2, r7		/* std bootarg #1 for register R1 */
	mov	r1, #0
#endif /* CFG_WITH_ARM_TRUSTED_FW */

	mov	r0, #TEESMC_OPTEED_RETURN_ENTRY_DONE
	smc	#0
	b	.	/* SMC should not return */
END_FUNC reset_primary


LOCAL_FUNC unhandled_cpu , :
	wfi
	b	unhandled_cpu
END_FUNC unhandled_cpu

#if defined(CFG_WITH_ARM_TRUSTED_FW)
FUNC cpu_on_handler , :
	mov	r4, r0
	mov	r5, r1
	mov	r6, lr
	read_sctlr r0
#if defined(CFG_SCTLR_ALIGNMENT_CHECK)
	orr	r0, r0, #SCTLR_A
#else
	bic	r0, r0, #SCTLR_A
#endif
#if defined(CFG_HWSUPP_MEM_PERM_WXN) && defined(CFG_CORE_RWDATA_NOEXEC)
	orr	r0, r0, #(SCTLR_WXN | SCTLR_UWXN)
#endif
	write_sctlr r0

	ldr	r0, =_start
	write_vbar r0

	mov	r4, lr
	set_sp

	bl	core_init_mmu_regs
	bl	cpu_mmu_enable
	bl	cpu_mmu_enable_icache
	bl	cpu_mmu_enable_dcache

	mov	r0, r4
	mov	r1, r5
	bl	generic_boot_cpu_on_handler

	bx	r6
END_FUNC cpu_on_handler

#else /* defined(CFG_WITH_ARM_TRUSTED_FW) */

LOCAL_FUNC reset_secondary , :
	wait_primary

	set_sp

	bl	plat_cpu_reset_late

#if defined (CFG_BOOT_SECONDARY_REQUEST)
	/* if L1 is not invalidated before, do it here */
	bl	arm_cl1_d_invbysetway
#endif

	bl	core_init_mmu_regs
	bl	cpu_mmu_enable
	bl	cpu_mmu_enable_icache
	bl	cpu_mmu_enable_dcache

	cpu_is_ready

#if defined (CFG_BOOT_SECONDARY_REQUEST)
	/* generic_boot_core_hpen return value (r0) is ns entry point */
	bl	generic_boot_core_hpen
#else
	mov	r0, r5		/* ns-entry address */
#endif
	bl	generic_boot_init_secondary

	mov	r0, #TEESMC_OPTEED_RETURN_ENTRY_DONE
	mov	r1, #0
	mov	r2, #0
	mov	r3, #0
	mov	r4, #0
	smc	#0
	b	.	/* SMC should not return */
END_FUNC reset_secondary
#endif /* defined(CFG_WITH_ARM_TRUSTED_FW) */
