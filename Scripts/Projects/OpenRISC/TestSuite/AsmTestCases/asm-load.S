/* Tests the load and store instructions.
 *
 * Copyright (C) 1999-2006 OpenCores
 *   Contributors various OpenCores participants
 * Copyright (C) 2010 Embecosm Limited
 *   Contributor Jeremy Bennett <jeremy.bennett@embecosm.com>
 * Copyright (C) 2012 R. Diez
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the Free
 * Software Foundation; either version 3 of the License, or (at your option)
 * any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
 * more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "TestHelpers.inc"


.macro TEST_LW  opcode, label, offset

    LOAD_IMMEDIATE r5, \label

    \opcode  r4, \offset(r5)

    REPORT_REG_TO_CONSOLE r4

.endm


        STANDARD_TEST_ENVIRONMENT

        .section .exception_vectors


        // Bus error exception.
        .org	0x200
bus_error_exception:

        // Skip the offending instruction.

        MOVE_FROM_SPR  r4, SPR_EPCR_BASE  // Address of the instruction that triggered the exception.

        l.addi r4, r4, 4

        MOVE_TO_SPR    SPR_EPCR_BASE, r4

        // Leave in R4 an indication that the bus error exception was run.

        LOAD_IMMEDIATE r4, 0x12345678

        l.rfe


        // Alignment exception.
        .org	0x600
alignment_exception:

        // Skip the offending instruction.

        MOVE_FROM_SPR  r4, SPR_EPCR_BASE  // Address of the instruction that triggered the exception.

        l.addi r4, r4, 4

        MOVE_TO_SPR    SPR_EPCR_BASE, r4

        // Leave in R4 just the alignment offset part to indicate that the alignment exception was run.

        MOVE_FROM_SPR  r4, SPR_EEAR_BASE  // Unaligned address that triggered the exception.

        l.andi r4, r4, 3


        l.rfe


        .section .rodata
        .balign 4

50:     .word   0xdeadbeef
51:     .word   0x00000000
52:     .word   0x7fffffff
53:     .word   0x80000000
54:     .word   0xffffffff


        .section .data
        .balign 4

buffer1:  .word 0x00000000
buffer2:  .word 0x00000000
buffer3:  .word 0x00000000
buffer4:  .word 0x00000000
buffer5:


        .section .text
start_tests:
        PUSH LINK_REGISTER_R9


        // Test instruction l.lws
        // NOTE: The instruction l.lws is not implemeted yet in or1200 (as of july 2012), search for "l.lws support patch" in the mailing list.
        //       Note that this instruction is redundant, as l.lwz does exactly the same.

        // Load with zero offset
        TEST_LW l.lws 50b, 0
        TEST_LW l.lws 51b, 0
        TEST_LW l.lws 52b, 0
        TEST_LW l.lws 53b, 0
        TEST_LW l.lws 54b, 0

        // Load with positive offset
        TEST_LW l.lws 50b,  4
        TEST_LW l.lws 50b,  8
        TEST_LW l.lws 50b, 12
        TEST_LW l.lws 50b, 16

        // Load with negative offset
        TEST_LW l.lws 54b, -16
        TEST_LW l.lws 54b, -12
        TEST_LW l.lws 54b,  -8
        TEST_LW l.lws 54b,  -4

        // Test the unaligned memory access exception.
        TEST_LW l.lws 50b, 1
        TEST_LW l.lws 50b, 2
        TEST_LW l.lws 50b, 3


        // ---------- Test instruction l.lwz ----------
        // Same tests as above. The instruction l.lwz does the same as l.lws (it is a redundant instruction).

        // Load with zero offset
        TEST_LW l.lwz 50b, 0
        TEST_LW l.lwz 51b, 0
        TEST_LW l.lwz 52b, 0
        TEST_LW l.lwz 53b, 0
        TEST_LW l.lwz 54b, 0

        // Load with positive offset
        TEST_LW l.lwz 50b,  4
        TEST_LW l.lwz 50b,  8
        TEST_LW l.lwz 50b, 12
        TEST_LW l.lwz 50b, 16

        // Load with negative offset
        TEST_LW l.lwz 54b, -16
        TEST_LW l.lwz 54b, -12
        TEST_LW l.lwz 54b,  -8
        TEST_LW l.lwz 54b,  -4

        // Test the unaligned memory access exception.
        TEST_LW l.lwz 50b, 1
        TEST_LW l.lwz 50b, 2
        TEST_LW l.lwz 50b, 3


        // ---------- Test instruction l.lbz ----------

        // Read data at label 50, forwards, byte by byte.
        LOAD_IMMEDIATE r5, 50b

        l.lbz r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lbz r4, 1(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lbz r4, 2(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lbz r4, 3(r5)
        REPORT_REG_TO_CONSOLE r4


        // Read data at label 50, backwards, byte by byte.
        LOAD_IMMEDIATE r31, 51b

        l.lbz r3, -1(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lbz r3, -2(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lbz r3, -3(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lbz r3, -4(r31)
        REPORT_REG_TO_CONSOLE r3


        // ---------- Test instruction l.lbs ----------

        // Read data at label 50, forwards, byte by byte.
        LOAD_IMMEDIATE r5, 50b

        l.lbs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lbs r4, 1(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lbs r4, 2(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lbs r4, 3(r5)
        REPORT_REG_TO_CONSOLE r4


        // Read data at label 50, backwards, byte by byte.
        LOAD_IMMEDIATE r31, 51b

        l.lbs r3, -1(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lbs r3, -2(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lbs r3, -3(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lbs r3, -4(r31)
        REPORT_REG_TO_CONSOLE r3


        // ---------- Test instruction l.lhz ----------

        // Read data at label 50, forwards, half-word by half-word.
        LOAD_IMMEDIATE r5, 50b

        l.lhz r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lhz r4, 2(r5)
        REPORT_REG_TO_CONSOLE r4


        // Read data at label 50, backwards, half-word by half-word.
        LOAD_IMMEDIATE r31, 51b

        l.lhz r3, -2(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lhz r3, -4(r31)
        REPORT_REG_TO_CONSOLE r3

        // Test the unaligned memory access exception.
        TEST_LW l.lhz 50b, 1
        TEST_LW l.lhz 50b, 3

        // ---------- Test instruction l.lhs ----------

        // Read data at label 50, forwards, half-word by half-word.
        LOAD_IMMEDIATE r5, 50b

        l.lhs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4

        l.lhs r4, 2(r5)
        REPORT_REG_TO_CONSOLE r4


        // Read data at label 50, backwards, half-word by half-word.
        LOAD_IMMEDIATE r31, 51b

        l.lhs r3, -2(r31)
        REPORT_REG_TO_CONSOLE r3

        l.lhs r3, -4(r31)
        REPORT_REG_TO_CONSOLE r3

        // Test the unaligned memory access exception.
        TEST_LW l.lhs 50b, 1
        TEST_LW l.lhs 50b, 3


        // ---------- Test instruction l.sb ----------

        // Write 32-bits forwards, byte-to-byte.

        LOAD_IMMEDIATE r5, buffer1

        LOAD_IMMEDIATE r10, 0xA1
        LOAD_IMMEDIATE r11, 0xA2
        LOAD_IMMEDIATE r12, 0xA3
        LOAD_IMMEDIATE r13, 0xA4

        l.sb 0(r5), r10
        l.sb 1(r5), r11
        l.sb 2(r5), r12
        l.sb 3(r5), r13

        l.lwz r3, 0(r5)
        REPORT_REG_TO_CONSOLE r3

        // Write 32-bits backwards, byte-to-byte.

        LOAD_IMMEDIATE r6, buffer2

        LOAD_IMMEDIATE r10, 0xB1
        LOAD_IMMEDIATE r11, 0xB2
        LOAD_IMMEDIATE r12, 0xB3
        LOAD_IMMEDIATE r13, 0xB4

        l.sb -1(r6), r10
        l.sb -2(r6), r11
        l.sb -3(r6), r12
        l.sb -4(r6), r13

        l.lwz r3, 0(r5)
        REPORT_REG_TO_CONSOLE r3


        // ---------- Test instruction l.sh ----------

        // Write 32-bits forwards, one half-word at a time.

        LOAD_IMMEDIATE r5, buffer1

        LOAD_IMMEDIATE r10, 0x8182
        LOAD_IMMEDIATE r11, 0x8384

        l.sh 0(r5), r10
        l.sh 2(r5), r11

        l.lwz r3, 0(r5)
        REPORT_REG_TO_CONSOLE r3


        // Write 32-bits backwards, one half-word at a time.

        LOAD_IMMEDIATE r6, buffer2

        LOAD_IMMEDIATE r10, 0x5152
        LOAD_IMMEDIATE r11, 0x5354

        l.sh -2(r6), r10
        l.sh -4(r6), r11

        l.lwz r3, 0(r5)
        REPORT_REG_TO_CONSOLE r3


        // Test the unaligned memory access exception.

        CLEAR_REG r4
        l.sh -1(ZERO_R0), ZERO_R0
        REPORT_REG_TO_CONSOLE r4

        CLEAR_REG r4
        l.sh -3(ZERO_R0), ZERO_R0
        REPORT_REG_TO_CONSOLE r4



        // ---------- Test instruction l.sw ----------

        LOAD_IMMEDIATE r5, buffer1
        LOAD_IMMEDIATE r6, buffer5

        LOAD_IMMEDIATE r10, 0xA0B0C0D0
        LOAD_IMMEDIATE r11, 0xA1B1C1D1
        LOAD_IMMEDIATE r12, 0xA2B2C2D2
        LOAD_IMMEDIATE r13, 0xA3B3C3D3

        l.sw  0(r5), r10
        l.sw  4(r5), r11
        l.sw -4(r6), r12
        l.sw -8(r6), r13

        TEST_LW l.lwz buffer1, 0
        TEST_LW l.lwz buffer2, 0
        TEST_LW l.lwz buffer3, 0
        TEST_LW l.lwz buffer4, 0


        // Test the unaligned memory access exception.

        CLEAR_REG r4
        l.sw 1(ZERO_R0), ZERO_R0
        REPORT_REG_TO_CONSOLE r4

        CLEAR_REG r4
        l.sw 2(ZERO_R0), ZERO_R0
        REPORT_REG_TO_CONSOLE r4

        CLEAR_REG r4
        l.sw 3(ZERO_R0), ZERO_R0
        REPORT_REG_TO_CONSOLE r4


        // ---------- Test reading from and writing to an out-of-range memory address (Wishbone bus error) ----------

        LOAD_IMMEDIATE r5, 0x00F00000  // This address should generate an access violation.
        CLEAR_REG r4
        l.lbs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4

        LOAD_IMMEDIATE r5, 0x00F00000  // This address should generate an access violation.
        CLEAR_REG r4
        l.sb 0(r5), r4
        REPORT_REG_TO_CONSOLE r4

        // Address starting with 0xF0 are not normally covered by any peripheral and should generate an access violation.
        // Note that this test is known to hang with most Wishbone switch/interconnect implementations
        // used with OpenRISC CPUs (as of Oct 2012).
        LOAD_IMMEDIATE r5, 0xF0000000
        CLEAR_REG r4
        l.lbs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4

        // Address starting with 0x90 are normally handled by the UART, which often does not decode the whole address range.
        // This test checks that all invalid addresses are caught properly.
        // Read test (byte).
        LOAD_IMMEDIATE r5, 0x90001000
        CLEAR_REG r4
        l.lbs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4
        // Write test (byte).
        LOAD_IMMEDIATE r5, 0x90001000
        CLEAR_REG r4
        l.sb 0(r5), r4
        REPORT_REG_TO_CONSOLE r4

        // Read test (word).
        LOAD_IMMEDIATE r5, 0x90001000
        CLEAR_REG r4
        l.lbs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4
        // Write test (word).
        LOAD_IMMEDIATE r5, 0x90001000
        CLEAR_REG r4
        l.sb 0(r5), r4
        REPORT_REG_TO_CONSOLE r4

        // Address starting with 0x92 are normally handled by the Ethernet controller, which often does not decode the whole address range.
        // This test checks that all invalid addresses are caught properly.
        // Read test (byte).
        LOAD_IMMEDIATE r5, 0x92001000
        CLEAR_REG r4
        l.lbs r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4
        // Write test  (byte).
        LOAD_IMMEDIATE r5, 0x92001000
        CLEAR_REG r4
        l.sb 0(r5), r4
        REPORT_REG_TO_CONSOLE r4

        // Read test (word).
        LOAD_IMMEDIATE r5, 0x92001000
        CLEAR_REG r4
        l.lws r4, 0(r5)
        REPORT_REG_TO_CONSOLE r4
        // Write test  (word).
        LOAD_IMMEDIATE r5, 0x92001000
        CLEAR_REG r4
        l.sw 0(r5), r4
        REPORT_REG_TO_CONSOLE r4

        POP LINK_REGISTER_R9
        RETURN_TO_LINK_REGISTER_R9
