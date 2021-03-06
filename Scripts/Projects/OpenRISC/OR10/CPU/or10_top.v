
/*  OR10 CPU core version 0.82 Beta

    See the README file for more information about the CPU core.

    Wishbone Datasheet:

      General description:         32-bit master, Wishbone B3
      Supported cycles:            MASTER, READ/WRITE
      Data port, size:             32-bit
      Data port, granularity:      8-bit
      Data port, max operand size: 32-bit
      Data transfer ordering:      probably big endian (haven't looked into it yet)
      Data transfer sequencing:    Undefined

      Both wb_err_i and wb_err_rty cause a CPU exception.

      The Wishbone reset signal resets the CPU too, but not all registers are cleared on reset.
      There is no need to assert reset at the beginning.

   ----------------

   Copyright (C) 2012, R. Diez

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU Lesser General Public License version 3
   as published by the Free Software Foundation.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU Lesser General Public License version 3 for more details.

   You should have received a copy of the GNU Lesser General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

`include "simulator_features.v"
`include "or1200_defines.v"
`include "or10_defines.v"


module or10_top
   #(
     parameter RESET_VECTOR = `OR10_ADDR_WIDTH'h00000100,  // 0x100 is the standard OpenRISC boot address, it must be 32-bit aligned.

     parameter ENABLE_DEBUG_UNIT      = 1,
     parameter ENABLE_WATCHPOINTS     = ENABLE_DEBUG_UNIT,  // From the whole watchpoint functionality, only hardware breakpoints are implemented.
     parameter WATCHPOINT_COUNT       = 2,  // The maximum is 8. The higher the count, the more FPGA resources are consumed.
                                            // If > 0, remember to set ENABLE_WATCHPOINTS and ENABLE_DEBUG_UNIT too.

     parameter ENABLE_TICK_TIMER_UNIT = 1,
     parameter ENABLE_PIC_UNIT        = 1,

     parameter ENABLE_INSTRUCTION_ROR  = 1,  // See GCC's switch '-mno-ror' . This saves a few FPGA resources, but not many.
     parameter ENABLE_SERIAL_SHIFTER   = 1,  // A serial shifter is slower but needs fewer FPGA resources.
                                             // This affects l.sll, l.slli, l.sra, l.srai, l.srl, l.srli, l.ror, l.rori.
     parameter ENABLE_INSTRUCTION_CMOV = 1,  // See GCC's switch '-mno-cmov'. This does not seem to save many FPGA resources.

     parameter ENABLE_INSTRUCTION_MUL  = 1,  // See GCC's switch '-msoft-mul'. The default implementation is not pipelined and limits
                                             // the maximum CPU frequency unnecessarily, see ENABLE_EXTERNAL_MULTIPLIER for an alternative implementation.
     parameter ENABLE_EXTERNAL_MULTIPLIER = 0,  // If you enable this, you'll have to manually modify the Verilog sources,
                                                // see the readme file for details.
     parameter EXTERNAL_MULTIPLIER_DELAY_IN_CLOCK_TICKS = 1,  // Must match what you specified in the external multiplier. Only used if ENABLE_EXTERNAL_MULTIPLIER has been set.


     parameter ENABLE_INSTRUCTION_DIV  = 1,  // See GCC's switch '-msoft-div'. The current implementation is not synthesisable, at least for Xilinx FPGAs.
     parameter ENABLE_EXTERNAL_DIVIDER = 0,  // If you enable this, you'll have to manually modify the Verilog sources,
                                             // see the readme file for details.

     parameter ENABLE_INSTRUCTION_EXT  = 1,  // See GCC's switch '-mno-sext'

     parameter TRACE_ASM_EXECUTION = 0,
     parameter TRACE_EXCEPTIONS    = TRACE_ASM_EXECUTION,
     parameter ENABLE_ASSERT_ON_ATYPICAL_EXCEPTIONS     = 1, // Helps debug your software.
     parameter ENABLE_ASSERT_ON_ZERO_INSTRUCTION_OPCODE = 1  // Helps debugging by asserting if the CPU strays into memory that only contains zeros.
    )
   (
    input                                wb_clk_i,
    input                                wb_rst_i, // There is no need to assert reset at the beginning.

    input                                wb_ack_i, // See the Wishbone Datasheet above.
    input                                wb_err_i,
    input                                wb_rty_i,
    input [`OR10_OPERAND_WIDTH-1:0]      wb_dat_i,
    output reg                           wb_cyc_o,
    output reg [`OR10_ADDR_WIDTH-1:0]    wb_adr_o,
    output reg                           wb_stb_o,
    output reg                           wb_we_o,
    output reg [3:0]                     wb_sel_o,
    output reg [`OR10_OPERAND_WIDTH-1:0] wb_dat_o,

    input [`OR10_OPERAND_WIDTH-1:0]      pic_ints_i, // Interrupt request lines.

    input [15:0]                         dbg_spr_number_i,
    input [`OR10_OPERAND_WIDTH-1:0]      dbg_data_i,
    output reg [`OR10_OPERAND_WIDTH-1:0] dbg_data_o,
    input                                dbg_stb_i, // Do not use directly, see synchronised_dbg_stb_i instead.
    input                                dbg_we_i,
    output reg                           dbg_ack_o,
    output reg                           dbg_err_o, // Asserted as part of the data, before dbg_ack_o.

    output reg                           dbg_is_stalled_o  // See comments to STATE_DEBUG_xxx about why this is a separate signal.
   );

   localparam TRACE_ASM_INDENT = "            ";  // Indent the extra information and error lines by the number of characters taken by the address field.
   localparam TRACE_DEBUG_INTERFACE = TRACE_ASM_EXECUTION;

   localparam ENABLE_GPR_ACCESS_OVER_SPR = ENABLE_DEBUG_UNIT;

   // These NOP_xxx definitions match the ones in file spr-defs.h in both ORPSoCV2 and or1ksim.
   localparam NOP_NOP            = 16'h0000;   // Normal nop instruction
   localparam NOP_EXIT           = 16'h0001;   // End of simulation
   localparam NOP_REPORT         = 16'h0002;   // Simple report
   // localparam NOP_PRINTF      = 16'h0003;   // Simprintf instruction (obsolete, not available in or1ksim)
   localparam NOP_PUTC           = 16'h0004;   // JPB: Simputc instruction
   // localparam NOP_CNT_RESET   = 16'h0005;   // Reset statistics counters
   // localparam NOP_GET_TICKS   = 16'h0006;   // JPB: Get # ticks running
   // localparam NOP_GET_PS      = 16'h0007;   // JPB: Get picosecs/cycle
   // localparam NOP_DBG_IF_TEST = 16'h000A;   // not available in or1ksim
   localparam NOP_EXIT_SILENT    = 16'h000C;   // Peter Gavin's Newlib uses this l.nop code.


   // The l.nop instruction uses register R3 for most nop opcodes.
   localparam NOP_REG_R3 = 3;

   localparam LINK_REGISTER_R9 = 9;

   localparam GPR_COUNT = 32;

   // For convenience:
   localparam DW = `OR10_OPERAND_WIDTH;
   localparam AW = `OR10_ADDR_WIDTH;

   localparam WISHBONE_SEL_WIDTH = 4;
   localparam GPR_NUMBER_WIDTH = 5;

   localparam WATCHPOINT_INDEX_WIDTH = 3;  // 2^3 = maximum of 8 watchpoints

   // Exception vectors.
   localparam BUS_ERROR_VECTOR_ADDR           = `OR10_ADDR_WIDTH'h00000200;
   localparam TICK_TIMER_VECTOR_ADDR          = `OR10_ADDR_WIDTH'h00000500;
   localparam ALIGNMENT_VECTOR_ADDR           = `OR10_ADDR_WIDTH'h00000600;
   localparam ILLEGAL_INSTRUCTION_VECTOR_ADDR = `OR10_ADDR_WIDTH'h00000700;
   localparam EXTERNAL_INTERRUPT_VECTOR_ADDR  = `OR10_ADDR_WIDTH'h00000800;
   localparam RANGE_VECTOR_ADDR               = `OR10_ADDR_WIDTH'h00000B00;
   localparam SYSTEM_CALL_VECTOR_ADDR         = `OR10_ADDR_WIDTH'h00000C00;
   localparam TRAP_VECTOR_ADDR                = `OR10_ADDR_WIDTH'h00000E00;


   // State machine definitions.
   //
   // The STATE_xxx constants should be an enumerated type, but "typedef enum"
   // is not supported by Icarus Verilog (as of July 2012).

   localparam STATE_RESET                           = 0;

   // The CPU spends most of its time in this state. The sequence is as follows:
   //  1) The CPU issues a Wishbone fetch (read) request and enters STATE_WAITING_FOR_INSTRUCTION_FETCH.
   //  2) On the next clock posedge, the Wishbone slave decodes and executes the request.
   //     The CPU reads wb_ack_i == 0 and therefore does nothing (it waits).
   //  3) On the next clock posedge, the CPU reads the Wishbone results, executes the instruction
   //     and issues the next Wishbone fetch. Meantime, the Wishbone slave sets wb_ack_i = 0. Goto step (2).
   // Therefore, it takes at least 2 clock cycles in STATE_WAITING_FOR_INSTRUCTION_FETCH to execute an instruction.
   // Note that GPR writes on the Register File from last instruction (if any) usually happen in the first
   // STATE_WAITING_FOR_INSTRUCTION_FETCH clock cycle too.
   localparam STATE_WAITING_FOR_INSTRUCTION_FETCH   = 1;

   // If an instruction needs to access memory, it needs 2 extra cycles in this state.
   localparam STATE_WAITING_FOR_WISHBONE_DATA_CYCLE = 2;

   localparam STATE_SLEEP                           = 3;

   localparam STATE_SHIFTING                        = 4;  // Used only when ENABLE_SERIAL_SHIFTER      is set.
   localparam STATE_MULTIPLYING                     = 5;  // Used only when ENABLE_EXTERNAL_MULTIPLIER is set.
   localparam STATE_DIVIDING                        = 6;  // Used only when ENABLE_EXTERNAL_DIVIDER    is set.


   // All STATE_DEBUG_xxx states have to do with the Debug Interface. During a Debug Interface operation,
   // the CPU is temporarily stalled. This is necessary so as to avoid conflicts with the running software,
   // as the Register File has only 2 ports (1 read and 1 read/write) for normal operation.
   // In order to support concurrent Debug Interface accesses, the Register File would need one extra
   // read/write port, and extra logic would also be needed for non-GPR reads and writes (for the rest of the SPRs).
   // It would be possible to optimise the design in order to allow as much concurrent access as possible,
   // but I do not think it's worth the effort.
   //
   // Note that, because of the temporary CPU stall, most of the JTAG operations change the timing of the
   // software running on the CPU. Most Debug Interface accesses are issued from GDB when the software is
   // stopped at a breakpoint, so it does not matter. The only time whether it really matters is
   // if you have time-critical, hand-tuned assembly code, and the JTAG interface introduces random delays
   // by polling the CPU so as to find out whether it has stopped at some breakpoint yet.
   // That's the reason why there is a separate dbg_is_stalled_o signal which allows
   // the DEBUG_CMD_IS_CPU_STALLED command to query the stalled/running status without temporarily
   // stalling the CPU.
   //
   // Note that, when unstalling the CPU, the dbg_is_stalled_o signal is set to 0 one clock cycle
   // before dbg_ack_o gets asserted. This timing is important, as unstalling the CPU is actually
   // a Debug Interface SPR write operation, and we want to make sure that dbg_is_stalled_o
   // is reset before that write operation completes. The reason is that the DEBUG_CMD_IS_CPU_STALLED command,
   // as described above, does not stall the CPU and can therefore be considered asynchronous
   // to the other Debug Interface operations. When single-stepping with the debugger, GDB will
   // query the stall status immediately after unstalling the CPU, and we want to make sure that
   // the stall status is not stale at that point in time. That is, if the CPU is stalled,
   // it means it has already completed the next instruction in single-step mode.

   localparam STATE_DEBUG_WAITING_FOR_REG_FILE_READ = 7;  // This state helps simplify the Register File address logic. We could probably optimise it
                                                          // away and cut one clock cycle from the Debug Interface's response time.
                                                          // Note that not all accesses involve the Register File, but all reads go through this state anyway.

   localparam STATE_DEBUG_WAITING_FOR_ACK_ASSERT    = 8;  // This state implements a delay between presenting valid data in dbg_data_o and dbg_err_o
                                                          // and asserting dbg_ack_o. The delay is necessary for clock domain crossing purposes.

   localparam STATE_DEBUG_WAITING_FOR_STB_DEASSERT  = 9;

   localparam STATE_DEBUG_STALLED                   = 10;
   localparam STATE_DEBUG_WAITING_FOR_WISHBONE_DEBUG_INTERFACE_CYCLE = 11;


   reg [3:0]  current_state;  // See the STATE_xxx constants.


   // Top-level instructions constants.
   localparam OR10_INST_ADDI                           = 6'h27;
   localparam OR10_INST_ADDIC                          = 6'h28;
   localparam OR10_INST_ANDI                           = 6'h29;
   localparam OR10_INST_BF                             = 6'h04;
   localparam OR10_INST_BNF                            = 6'h03;
   localparam OR10_INST_J                              = 6'h00;
   localparam OR10_INST_JAL                            = 6'h01;
   localparam OR10_INST_JALR                           = 6'h12;
   localparam OR10_INST_JR                             = 6'h11;
   localparam OR10_INST_MFSPR                          = 6'h2D;
   localparam OR10_INST_MOVHI                          = 6'h06;
   localparam OR10_INST_MTSPR                          = 6'h30;
   localparam OR10_INST_NOP                            = 6'h05;
   localparam OR10_INST_ORI                            = 6'h2A;
   localparam OR10_INST_MULI                           = 6'h2C;
   localparam OR10_INST_SYS_TRAP                       = 6'h08;
   localparam OR10_INST_RFE                            = 6'h09;
   localparam OR10_INST_SB                             = 6'h36;
   localparam OR10_INST_SH                             = 6'h37;
   localparam OR10_INST_PREFIX_38                      = 6'h38;
   localparam OR10_INST_SW                             = 6'h35;
   localparam OR10_INST_XORI                           = 6'h2B;
   localparam OR10_INST_LBS                            = 6'h24;
   localparam OR10_INST_LBZ                            = 6'h23;
   localparam OR10_INST_LHS                            = 6'h26;
   localparam OR10_INST_LHZ                            = 6'h25;
   localparam OR10_INST_LWZ                            = 6'h21;
   localparam OR10_INST_LWS                            = 6'h22;
   localparam OR10_INST_SHIFT_I                        = 6'h2e;
   localparam OR10_INST_SFXXI                          = 6'h2F;
   localparam OR10_INST_SFXX                           = 6'h39;
   // Maximum value:                                     6'h3f

   // Shift and Rotate instruction definitions.
   localparam OR10_SHIFTINST_SLL  = 0;
   localparam OR10_SHIFTINST_SLLI = 1;
   localparam OR10_SHIFTINST_SRA  = 2;
   localparam OR10_SHIFTINST_SRAI = 3;
   localparam OR10_SHIFTINST_SRL  = 4;
   localparam OR10_SHIFTINST_SRLI = 5;
   localparam OR10_SHIFTINST_ROR  = 6;
   localparam OR10_SHIFTINST_RORI = 7;

   // Add instruction definitions.
   localparam OR10_ADDINST_ADD   = 0;
   localparam OR10_ADDINST_ADDC  = 1;
   localparam OR10_ADDINST_ADDI  = 2;
   localparam OR10_ADDINST_ADDIC = 3;

   // Data width of the read operation currently being issued on the Wishbone bus.
   localparam WOPW_32    = 0;
   localparam WOPW_8_Z   = 1;  // Read one byte, zero-fill the rest.
   localparam WOPW_8_S   = 2;  // Read one byte, sign-extend the rest.
   localparam WOPW_16_Z  = 3;
   localparam WOPW_16_S  = 4;

   // If you modify this value, make sure to update the CPU reset logic in GdbToJtagBridge too.
   // Only bits FO (Fixed One, a constant '1') and SM (Supervisor Mode) are set.
   localparam RESET_SPR_SR = `OR10_OPERAND_WIDTH'b0000000000000000_1000000000000001;


   // Clock domain crossing synchroniser for the Debug Interface.
   wire synchronised_dbg_stb_i;
   generate if ( ENABLE_DEBUG_UNIT )
     begin
        clock_domain_crossing_synchroniser clock_domain_crossing_synchroniser_dbg_stb_i( wb_clk_i, dbg_stb_i, synchronised_dbg_stb_i );
     end
   else
     begin
        // Bypass the synchronisation. It's generally not safe, but the !ENABLE_DEBUG_UNIT logic further below remains only
        // to detect Verilog programming errors.
        assign synchronised_dbg_stb_i = dbg_stb_i;
     end
   endgenerate


   // ------------- General Purpose Register File -------------

   // See the or10_register_file module for a detailed explanation about why we need this construct
   // and how register reads and writes work.

   // Read interface for both ports (asynchronous).
   reg  [`OR10_REG_NUMBER]        gpr_register_number_to_read_or_write_1;
   reg  [`OR10_REG_NUMBER]        gpr_register_number_to_read_2;

   wire [`OR10_OPERAND_WIDTH-1:0] gpr_register_value_read_1;
   wire [`OR10_OPERAND_WIDTH-1:0] gpr_register_value_read_2;

   // Write interface for the 1st port (synchronous).
   reg [`OR10_REG_NUMBER]         gpr_register_number_to_write_1;
   reg [`OR10_OPERAND_WIDTH-1:0]  gpr_register_value_to_write_1;
   reg                            gpr_write_enable_1;

   always @(*)
     begin
        // Register File Port 1 (read/write).
        if ( gpr_write_enable_1 )
          begin
             gpr_register_number_to_read_or_write_1 = gpr_register_number_to_write_1;
          end
        else if ( `IS_SIMULATION && wb_dat_i[ `OR10_IOP_PREFIX ] == OR10_INST_NOP )
          begin
             // During simulation, the l.nop instruction reads from R3.
             gpr_register_number_to_read_or_write_1 = NOP_REG_R3;
          end
        else if ( ENABLE_GPR_ACCESS_OVER_SPR && current_state == STATE_DEBUG_WAITING_FOR_REG_FILE_READ )
          begin
             // The Debug Interface may be reading from an SPR that is not a GPR,
             // so this read may be wasted, but that does not matter and helps keep
             // the logic simple. Other paths of the Register File read logic often get wasted too.
             gpr_register_number_to_read_or_write_1 = dbg_spr_number_i[4:0];
          end
        else
          begin
             gpr_register_number_to_read_or_write_1 = wb_dat_i[ `OR10_IOP_GPR1 ];
          end

        // Register File Port 1 (read only).
        gpr_register_number_to_read_2 = wb_dat_i[ `OR10_IOP_GPR2 ];
     end

   or10_register_file or10_register_file_instance( .clk_i( wb_clk_i ),
                                                   .register_number_1_i( gpr_register_number_to_read_or_write_1 ),
                                                   .data_1_o           ( gpr_register_value_read_1 ),
                                                   .write_enable_1_i   ( gpr_write_enable_1 ),
                                                   .data_1_i           ( gpr_register_value_to_write_1 ),
                                                   .register_number_2_i( gpr_register_number_to_read_2 ),
                                                   .data_2_o           ( gpr_register_value_read_2 ) );

   // ------------- Other CPU registers -------------

   reg [DW-1:0]        cpureg_spr_sr;    // SPR SR (Supervision Register).

   reg [`OR10_PC_ADDR] cpureg_spr_epcr;  // Exception Saved PC Register. Note that this register does not have the last 2 bits.
   reg [DW-1:0]        cpureg_spr_eear;  // Exception Effective Address Register.
   reg [DW-1:0]        cpureg_spr_esr;   // Exception Saved SR Register.

   reg [DW-1:0]        cpureg_spr_picmr;  // PIC Mode Register.

   reg [DW-1:0]        cpureg_spr_ttmr;   // Tick Timer Mode Register.
   reg [DW-1:0]        cpureg_spr_ttcr;   // Tick Timer Counter Register.

   reg                 is_trap_debug_unit_enabled;
   reg                 is_stop_reason_trap;
   reg                 stop_at_next_instruction_1;  // This is the "single step" setting in DMR1.
   reg                 stop_at_next_instruction_2;  // Delayed so that the CPU has time to execute one instruction.
   reg [`OR10_PC_ADDR] dbg_write_mem_addr;  // Memory address for the next Debug Interface memory write operation.

   reg [`OR10_PC_ADDR] cpureg_pc;         // Current program counter. Note that this register does not have the last 2 bits.

   // TODO: maybe we don't need to store all 32 bits of the watchpoint address.
   reg [AW-1:0]        watchpoints[ (1<<WATCHPOINT_INDEX_WIDTH)-1:0 ];

   reg [2:0]              shift_operation; // See the `OR10_SHIFTINST_xxx constants.
   reg [4:0]              shift_bit_count;
   reg [DW-1:0]           shift_result;
   reg [`OR10_REG_NUMBER] shift_dest_reg;


   // ------------- Address helper functions -------------

   function automatic [AW-1:0] pc_addr_to_32;
      input reg [`OR10_PC_ADDR] pc_addr;
      begin
         pc_addr_to_32 = { pc_addr, 2'b00 };
      end
   endfunction

   function automatic [`OR10_PC_ADDR] addr_32_to_pc;
      input reg [AW-1:0] addr_32;
      reg   addr_32_to_pc_prevent_unused_warning_with_verilator;
      begin
         addr_32_to_pc_prevent_unused_warning_with_verilator = &{ 1'b0, addr_32[1:0], 1'b0 };

         addr_32_to_pc = addr_32[ `OR10_PC_ADDR ];
      end
   endfunction

   function automatic is_addr_aligned;
      input reg [AW-1:0] addr;
      reg   is_addr_aligned_prevent_unused_warning_with_verilator;
      begin
         is_addr_aligned_prevent_unused_warning_with_verilator = &{ 1'b0, addr[`OR10_PC_ADDR], 1'b0 };

         is_addr_aligned = ( addr[1:0] == 0 );
      end
   endfunction


   // ------------- Wishbone select signal (wb_sel_o) helper functions -------------

   function automatic [WISHBONE_SEL_WIDTH-1:0] wishbone_byte_sel_from_addr;
      input reg [1:0] addr;
      begin
         `UNIQUE case ( addr )
                   2'b00: wishbone_byte_sel_from_addr = 4'b1000;
                   2'b01: wishbone_byte_sel_from_addr = 4'b0100;
                   2'b10: wishbone_byte_sel_from_addr = 4'b0010;
                   2'b11: wishbone_byte_sel_from_addr = 4'b0001;
                 endcase
      end
   endfunction

   function automatic [WISHBONE_SEL_WIDTH-1:0] wishbone_half_word_sel_from_addr;
      input reg [1:0] addr;
      begin
         case ( addr )
           2'b00: wishbone_half_word_sel_from_addr = 4'b1100;
           2'b10: wishbone_half_word_sel_from_addr = 4'b0011;
           default:
             begin
                // This should never happen, the caller should have already checked.
                `ASSERT_FALSE;
                wishbone_half_word_sel_from_addr = 4'bxxxx;
             end
         endcase
      end
   endfunction


   // ------------- Wishbone cycle management -------------

   // Registers for Wishbone data access.
   // 1st group, needed for keep_wishbone_data_cycle.
   reg [AW-1:0]                 wishdat_addr;
   reg [DW-1:0]                 wishdat_data;
   reg [WISHBONE_SEL_WIDTH-1:0] wishdat_sel;
   reg                          wishdat_write_enable;
   // 2nd group, needed for read cycles only.
   reg [`OR10_REG_NUMBER] wishdat_dest_gpr;      // Only in read cycles.
   reg [2:0]              wishdat_load_op_type;  // See the WOPW_xxx constants.


   // On every clock edge, this task is called upfront, in order to setup the default values
   // for the Wishbone cycle registers. All other tasks must overwrite
   // these values if some Wishbone operation is to be executed.

   task automatic stop_wishbone_cycle;
      begin
         // During reset, only wb_cyc_o and wb_stb_o must be deasserted.
         // Other output signals don't matter.
         // If you modify this code, please keep the "initial" section below in sync.
         wb_cyc_o <= 0;
         wb_stb_o <= 0;

         wb_adr_o <= {AW{1'bx}};
         wb_dat_o <= {DW{1'bx}};
         wb_sel_o <= {WISHBONE_SEL_WIDTH{1'bx}};
         wb_we_o  <= 1'bx;
      end
   endtask


   task automatic internal_start_wishbone_cycle;
      begin
         wb_cyc_o <= 1;
         wb_stb_o <= 1;
      end
   endtask


   task automatic start_wishbone_instruction_fetch_cycle;
      input reg [AW-1:0] pc;
      begin
         if ( !is_addr_aligned( pc ) )
           begin
              `ASSERT_FALSE;
           end

         internal_start_wishbone_cycle;

         wb_adr_o <= pc;
         wb_dat_o <= {DW{1'bx}};
         wb_sel_o <= {WISHBONE_SEL_WIDTH{1'b1}};
         wb_we_o  <= 0;

         current_state <= STATE_WAITING_FOR_INSTRUCTION_FETCH;
         cpureg_pc <= addr_32_to_pc( pc );
      end
   endtask


   task automatic internal_start_wishbone_data_cycle;

      input reg [AW-1:0]                 addr;
      input reg [DW-1:0]                 data;
      input reg [WISHBONE_SEL_WIDTH-1:0] sel;
      input reg                          write_enable;

      begin
         internal_start_wishbone_cycle;

         // Note that, even though the memory is 32-bit wide, when reading just an 8-bit value
         // the address passed down does have the last 2 bits, which means that the address
         // could be unaligned. For example, the DPI UART module (for Verilog simulations only)
         // uses those bits in order to address its 8-bit registers; that module can only
         // access one 8-bit register at a time.
         //
         // In addition to those last 2 bits, the Wishbone 'sel' signal helps place the data
         // at the right bits, so one would think that the last 2 address bits constitute
         // then redundant information.
         wb_adr_o <= addr;
         wb_dat_o <= data;

         wb_sel_o <= sel;
         wb_we_o  <= write_enable;
      end
   endtask


   task automatic keep_wishbone_data_cycle;
      begin
         /* $display( "Wishbone data cycle still active for addr 0x%08h, sel 0x%1h, write %01d.",
                   wishdat_addr,
                   wishdat_sel,
                   wishdat_write_enable ); */

         internal_start_wishbone_data_cycle( wishdat_addr,
                                             wishdat_data,
                                             wishdat_sel,
                                             wishdat_write_enable );
      end
   endtask


   task automatic start_wishbone_data_read_cycle;

      input reg [AW-1:0]                 addr;
      input reg [WISHBONE_SEL_WIDTH-1:0] sel;
      input reg [`OR10_REG_NUMBER]       dest_cpu_gpr_reg;  // Only used if is_from_debug_interface == 0,
      input reg                          is_from_debug_interface;
      input reg [2:0]                    load_op_type;
      inout reg                          can_interrupt;  // We pass this argument only so that nobody forgets to set this flag.

      begin
         if ( !can_interrupt )
           begin
              `ASSERT_FALSE;
           end
         can_interrupt = 0;

         internal_start_wishbone_data_cycle( addr, {DW{1'bx}}, sel, 0 );

         if ( is_from_debug_interface )
           current_state <= STATE_DEBUG_WAITING_FOR_WISHBONE_DEBUG_INTERFACE_CYCLE;
         else
           current_state <= STATE_WAITING_FOR_WISHBONE_DATA_CYCLE;

         // This information is for subsequent calls to keep_wishbone_data_cycle.
         wishdat_addr         <= addr;
         wishdat_data         <= {DW{1'bx}};
         wishdat_sel          <= sel;
         wishdat_write_enable <= 0;

         // This information is to process the read data when the Wishbone cycle completes.
         wishdat_dest_gpr     <= dest_cpu_gpr_reg;
         wishdat_load_op_type <= load_op_type;
      end
   endtask


   task automatic start_wishbone_data_write_cycle;

      input reg [AW-1:0]                 addr;
      input reg [DW-1:0]                 data;
      input reg [WISHBONE_SEL_WIDTH-1:0] sel;
      input reg                          is_from_debug_interface;
      inout reg                          can_interrupt;  // We pass this argument only so that nobody forgets to set this flag.

      begin
         if ( !can_interrupt )
           begin
              `ASSERT_FALSE;
           end
         can_interrupt = 0;

         internal_start_wishbone_data_cycle( addr, data, sel, 1 );

         if ( is_from_debug_interface )
           current_state <= STATE_DEBUG_WAITING_FOR_WISHBONE_DEBUG_INTERFACE_CYCLE;
         else
           current_state <= STATE_WAITING_FOR_WISHBONE_DATA_CYCLE;

         // This information is for subsequent calls to keep_wishbone_data_cycle.
         wishdat_addr         <= addr;
         wishdat_data         <= data;
         wishdat_sel          <= sel;
         wishdat_write_enable <= 1;

         // For write cycles, the following information is not needed.
         wishdat_dest_gpr     <= {GPR_NUMBER_WIDTH{1'bx}};
         wishdat_load_op_type <= 3'bxxx;
      end
   endtask


   // ------------- Exception management -------------

   // External Interrupts and Tick Timer Interrupts trigger normal exceptions.
   // If the current instruction's execution stage has raised an exception,
   // we cannot raise another one at the same time, so any External and Timer
   // Interrupts must wait for the first exception handler to enable
   // exceptions again.
   //
   // We can only respond to interrupts between instructions. If the CPU
   // is waiting for a Wishbone transaction, we cannot interrupt it.
   //
   // With the current CPU implementation, it's easier to raise a pending interrupt
   // exception at the end of the fetch phase, but the CPU would then react more slowly,
   // as the just-fetched opcode gets discarded in the process.
   //
   // When raising an interrupt, the exception logic needs to save the current PC and SR registers.
   // However, they may have been modified by the current instruction, so the exception logic
   // cannot fetch the values from cpureg_pc and cpureg_spr_sr, we need to maintain
   // separate variables like next_pc and next_sr and update them along the way
   // with '=' rather than '<='. The trouble is, the Verilog code would then mix the usage of '=' and '<='
   // overall, and Verilator raises warnings about it (as of August 2012), even if the '=' assignments
   // are correctly placed. The only way I have found around this issue is to pass the xxx_next
   // variables as task inout arguments all over the place, which is rather inconvenient.

   task automatic internal_raise_exception;

      input reg [AW-1:0]        vector_addr;
      input reg [`OR10_PC_ADDR] epcr;
      input reg [AW-1:0]        eear;
      input reg [DW-1:0]        esr;
      inout reg                 can_interrupt;  // We pass this argument only so that nobody forgets to set this flag.

      reg [AW-1:0]              workaround_verilator_bug;

      begin
         if ( ENABLE_ASSERT_ON_ATYPICAL_EXCEPTIONS )
           begin
              case ( vector_addr )
                BUS_ERROR_VECTOR_ADDR,
                ALIGNMENT_VECTOR_ADDR,
                ILLEGAL_INSTRUCTION_VECTOR_ADDR,
                RANGE_VECTOR_ADDR,
                TRAP_VECTOR_ADDR:
                  begin
                     `ASSERT_FALSE;
                  end
                default:
                  begin
                     // Nothing to do here.
                  end
              endcase
           end

         if ( !can_interrupt )
           begin
              `ASSERT_FALSE;
           end
         can_interrupt = 0;

         cpureg_spr_epcr <= epcr;
         cpureg_spr_eear <= eear;
         cpureg_spr_esr  <= esr;
         cpureg_spr_sr   <= RESET_SPR_SR;
         start_wishbone_instruction_fetch_cycle( vector_addr );

         if ( TRACE_EXCEPTIONS )
           begin
              workaround_verilator_bug = pc_addr_to_32( epcr );
              $display( "Exception raised, vector addr: 0x%08h, data addr: 0x%08h, saved SR: 0x%08h, return addr: 0x%08h.",
                        vector_addr, eear, esr, workaround_verilator_bug );
           end
      end
   endtask


   task automatic raise_exception_with_eear;
      input reg [AW-1:0]        vector_addr;
      input reg [`OR10_PC_ADDR] epcr;
      input reg [AW-1:0]        eear;
      input reg [DW-1:0]        esr;
      inout reg                 can_interrupt;
      begin
         internal_raise_exception( vector_addr, epcr, eear, esr, can_interrupt );
      end
   endtask


   task automatic raise_exception_without_eear;
      input reg [AW-1:0]        vector_addr;
      input reg [`OR10_PC_ADDR] epcr;
      input reg [DW-1:0]        esr;
      inout reg                 can_interrupt;
      begin
         internal_raise_exception( vector_addr,
                                   epcr,
                                   0,  // Note that the OpenRISC specification does not say that we should clear the SPR EEAR register.
                                   esr,
                                   can_interrupt );
      end
   endtask


   task automatic raise_ov_or_cy_range_exception_if_necessary;

      input reg [4:0]    sr_bit_number;
      input reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      begin
         // About triggering on OV edge:
         //   Note that the Range Exception triggers on edge, when the OV flag changes from 0 to 1.
         //   This matches the behaviour of the or1ksim simulator, but it's unlike ORPSoC V2's OR1200 core.
         //   This means that if an eventual exception handler wants to continue execution of the offending software
         //   and does not clear the overflow flag beforehand, the next instruction will not raise
         //   an overflow exception again.

         // About completing execution on overflow exception:
         //   It's not clear in the OpenRISC specification whether an arithmetic instruction should execute
         //   and then possibly raise an overflow exception afterwards, or whether it should raise an overflow
         //   exception instead of completing execution. That is, it's not clear whether the instruction should
         //   store the results that caused the overflow or not. The current implementation here does complete
         //   execution, which is what the or1ksim simulator appears to do. This probably means that
         //   an eventual overflow exception handler should not try to restart the offending software with l.rfe,
         //   as the arithmetic instruction would execute a second time and the arithmetic results may then be wrong.
         //   It also means that the exception handler can see the result, but not the original operand that led
         //   to the overflow, as at least one of them may have been overwritten with the overflowed result.

         if ( cpureg_spr_sr[ `OR1200_SR_OVE ] == 1 &&
              cpureg_spr_sr[ sr_bit_number  ] == 0 &&
              next_sr      [ sr_bit_number  ] == 1 )
           begin
              raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, next_sr, can_interrupt );
           end
      end
   endtask

   task automatic raise_ov_range_exception_if_necessary;
      input reg [DW-1:0] next_sr;
      inout reg          can_interrupt;
      begin
         raise_ov_or_cy_range_exception_if_necessary( `OR1200_SR_OV, next_sr, can_interrupt );
      end
   endtask

   task automatic raise_cy_range_exception_if_necessary;
      input reg [DW-1:0] next_sr;
      inout reg          can_interrupt;
      begin
         raise_ov_or_cy_range_exception_if_necessary( `OR1200_SR_CY, next_sr, can_interrupt );
      end
   endtask


   task automatic raise_reserved_instruction_opcode_bits_exception;
      // Note that we assume here that the instruction bits are checked before any
      // execution takes place, so the value of cpureg_spr_sr would not have changed.
      // Therefore, we do not need the next_sr argument at this point.
      //   input reg [DW-1:0] next_sr;
      inout reg can_interrupt;
      begin
         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: Illegal instruction exception raised for instruction opcode 0x%08h: some of the reserved bits in the opcode are not zero.",
                     `OR10_TRACE_PC_VAL, wb_dat_i );
         raise_exception_without_eear( ILLEGAL_INSTRUCTION_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
      end
   endtask

   task automatic raise_illegal_instruction_exception;
      // Note that we assume here that the instruction opcode is checked before any
      // execution takes place, so the value of cpureg_spr_sr would not have changed.
      // Therefore, we do not need the next_sr argument at this point.
      //   input reg [DW-1:0] next_sr;
      inout reg can_interrupt;
      begin
         // All callers to raise_illegal_instruction_exception have already called $display() in order
         // to print an instruction-specific error message.
         raise_exception_without_eear( ILLEGAL_INSTRUCTION_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
      end
   endtask


   // --------------- Register file management ---------------

   task automatic stop_register_file_write_operation;
      begin
         gpr_write_enable_1             <= 0;
         gpr_register_number_to_write_1 <= {GPR_NUMBER_WIDTH{1'bx}};
         gpr_register_value_to_write_1  <= {DW{1'bx}};
      end
   endtask


   task automatic schedule_register_write_during_next_cycle;
      input reg [`OR10_REG_NUMBER]        register_number;
      input reg [`OR10_OPERAND_WIDTH-1:0] register_value;
      begin
         // This task needs to overwrite everything that 'stop_register_file_write_operation' does.

         // $display("Writing value 0x%08h to register R%0d", register_value, register_number);
         gpr_register_number_to_write_1 <= register_number;
         gpr_register_value_to_write_1  <= register_value;
         gpr_write_enable_1             <= 1;
      end
   endtask


   // --------------- Execute each of the CPU instructions ---------------

   task automatic execute_nop;

      inout reg  can_interrupt;
      reg [15:0] nop_code;

      begin
         if ( wb_dat_i[23:16] != 0 )
           raise_reserved_instruction_opcode_bits_exception( can_interrupt );
         else if ( `IS_SIMULATION )
           begin
              nop_code = wb_dat_i[15:0];

              case ( nop_code )
                NOP_NOP: begin
                   // This is the "do nothing" variant of the l.nop instruction.
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: l.nop %0d (no operation)", `OR10_TRACE_PC_VAL, nop_code );
                end

                NOP_EXIT, NOP_EXIT_SILENT:
                  begin
                     // Note that the test suite looks for strings like "exit(1)",
                     // therefore something like "exit(  1)" would fail.
                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.nop %0d (NOP_EXIT)", `OR10_TRACE_PC_VAL, nop_code );

                     $display( "Instruction \"l.nop NOP_EXIT\" found at address 0x%08h, ending the simulation.", `OR10_TRACE_PC_VAL );

                     if ( nop_code != NOP_EXIT_SILENT )
                       $display( "exit(%0d)", gpr_register_value_read_1 );

                     $finish;
                  end

                NOP_REPORT:
                  begin
                     // Note that the test suite looks for strings
                     // like "report(0x7ffffffe);", therefore something like "report (0x7ffffffe);"
                     // (note the extra space character) would fail.
                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.nop %0d (NOP_REPORT)", `OR10_TRACE_PC_VAL, nop_code );

                     $display("report(0x%h);", gpr_register_value_read_1 );
                  end

                NOP_PUTC:
                  begin
                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.nop %0d (NOP_PUTC)", `OR10_TRACE_PC_VAL, nop_code );

                     if ( gpr_register_value_read_1[DW-1:8] != 0 )
                       begin
                          $display( "ERROR: l.nop NOP_PUTC instruction at address 0x%08h found in register R3 out-of-range value 0x%08h.",
                                    `OR10_TRACE_PC_VAL,
                                    gpr_register_value_read_1 );
                          `ASSERT_FALSE;
                       end
                     $write( "%c", gpr_register_value_read_1[7:0] );
                  end

                default:
                  begin
                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.nop %0d (unknown nop code)", `OR10_TRACE_PC_VAL, nop_code );
                     $display( "ERROR: Default case for nop_code=%0d at instruction address 0x%08h.",
                               nop_code, `OR10_TRACE_PC_VAL );
                     `ASSERT_FALSE;
                  end
              endcase
           end
         else
           begin
              // When not running under a Verilog Simulator, all l.nop codes are actually ignored.
              //
              // If you do plan to synthesise a CPU that uses the l.nop codes, note also that the Register File
              // does not place R3 in gpr_register_value_read_1 for l.nop instructions
              // when not running under a simulator, but this is an optimisation that can be disabled.
           end
      end
   endtask


   task automatic execute_movhi;

      inout reg can_interrupt;

      reg [15:0]             immediate_value;
      reg [`OR10_REG_NUMBER] dest_register;

      begin
         if ( wb_dat_i[20:17] != 0 )
           raise_reserved_instruction_opcode_bits_exception( can_interrupt );
         else if ( wb_dat_i[16] != 0 )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: Illegal instruction exception raised for unsupported instruction 'l.macrc'.",
                          `OR10_TRACE_PC_VAL );
              raise_illegal_instruction_exception( can_interrupt );
           end
         else
           begin
              immediate_value = wb_dat_i[15:0];
              dest_register   = wb_dat_i[`OR10_IOP_DEST_GPR];

              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: l.movhi r%0d, 0x%04h", `OR10_TRACE_PC_VAL, dest_register, immediate_value );

              schedule_register_write_during_next_cycle( dest_register, { immediate_value, 16'b0 } );
           end
      end
   endtask


   task automatic execute_ori;

      reg [15:0]             immediate_value;
      reg [`OR10_REG_NUMBER] dest_register;
      reg [`OR10_REG_NUMBER] src_register;
      reg [DW-1:0]           result;

      begin
         immediate_value = wb_dat_i[15:0];
         src_register    = wb_dat_i[`OR10_IOP_GPR1];
         dest_register   = wb_dat_i[`OR10_IOP_DEST_GPR];

         result = { gpr_register_value_read_1[31:16], ( gpr_register_value_read_1[15:0] | immediate_value ) };

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.ori r%0d, r%0d, 0x%04h (result 0x%08h)",
                     `OR10_TRACE_PC_VAL,
                     dest_register,
                     src_register,
                     immediate_value,
                     result );

         schedule_register_write_during_next_cycle( dest_register, result );
      end
   endtask


   task automatic execute_andi;

      reg [15:0]             immediate_value;
      reg [`OR10_REG_NUMBER] dest_register;
      reg [`OR10_REG_NUMBER] src_register;
      reg [DW-1:0]           result;

      begin
         immediate_value = wb_dat_i[15:0];
         src_register    = wb_dat_i[`OR10_IOP_GPR1];
         dest_register   = wb_dat_i[`OR10_IOP_DEST_GPR];

         result = { 16'h0000, ( gpr_register_value_read_1[15:0] & immediate_value ) };

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.andi r%0d, r%0d, 0x%04h (result 0x%08h)",
                     `OR10_TRACE_PC_VAL,
                     dest_register,
                     src_register,
                     immediate_value,
                     result );

         schedule_register_write_during_next_cycle( dest_register, result );
      end
   endtask


   task automatic execute_xori;
      reg [15:0]             immediate_value;
      reg [`OR10_REG_NUMBER] dest_register;
      reg [`OR10_REG_NUMBER] src_register;
      reg [DW-1:0]           result;

      begin
         immediate_value = wb_dat_i[15:0];
         src_register    = wb_dat_i[`OR10_IOP_GPR1];
         dest_register   = wb_dat_i[`OR10_IOP_DEST_GPR];

         // Note that "l.xori rD,rA,-1" has the same effect as the non-existant l.not instruction.

         result = gpr_register_value_read_1 ^ { {16{immediate_value[15]}}, immediate_value };

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.xori r%0d, r%0d, 0x%04h (result 0x%08h)",
                     `OR10_TRACE_PC_VAL,
                     dest_register,
                     src_register,
                     immediate_value,
                     result );

         schedule_register_write_during_next_cycle( dest_register, result );
      end
   endtask


   task automatic execute_sys_trap;

      inout reg can_interrupt;

      reg [15:0] immediate_value;

      begin
         immediate_value = wb_dat_i[15:0];

         case ( wb_dat_i[25:16] )
           10'b0000000000:
             begin
                // The OpenRISC specification does not say what to do with the immediate value in this case.

                if ( TRACE_ASM_EXECUTION )
                  $display( "0x%08h: l.sys 0x%04h",
                            `OR10_TRACE_PC_VAL,
                            immediate_value );

                raise_exception_without_eear( SYSTEM_CALL_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
             end

           10'b0100000000:
             begin
                // The immediate value is now ignored, like in all other processor implementations.
                // Note that GDB uses an "l.trap 1" instruction to trigger software breakpoints.

                if ( TRACE_ASM_EXECUTION )
                  $display( "0x%08h: l.trap 0x%04h (%0s)",
                            `OR10_TRACE_PC_VAL,
                            immediate_value,
                            is_trap_debug_unit_enabled ? "transfers control to the JTAG Debug Unit" : "raises the Trap exception" );

                if ( is_trap_debug_unit_enabled )
                  begin
                     can_interrupt = 0;
                     is_stop_reason_trap <= 1;
                     dbg_is_stalled_o    <= 1;
                     current_state       <= STATE_DEBUG_STALLED;
                  end
                else
                  begin
                     raise_exception_without_eear( TRAP_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
                  end
             end

           10'b0000000001:  // 16-bit opcode: 0x2001. Note that the l.sleep instruction is not in the "OpenRISC 1000 Architecture Manual".
             begin
                if ( TRACE_ASM_EXECUTION )
                  $display( "0x%08h: l.sleep 0x%04h",
                            `OR10_TRACE_PC_VAL,
                            immediate_value );

                can_interrupt = 0;  // We might waste one clock cycle, but it's better to keep the CPU simple.
                current_state <= STATE_SLEEP;
             end

           default:
             begin
                if ( TRACE_ASM_EXECUTION )
                  $display( "0x%08h: Illegal instruction exception raised for unsupported l.sys/l.trap instruction.",
                            `OR10_TRACE_PC_VAL );
                raise_illegal_instruction_exception( can_interrupt );
             end
         endcase
      end
   endtask


   task automatic execute_ext_b_h_instruction;

      inout reg can_interrupt;

      reg [3:0] opcode;
      reg [`OR10_REG_NUMBER] src_register;
      reg [`OR10_REG_NUMBER] dest_register;
      reg [15:0] src;
      reg [DW-1:0] result;
      reg [7 * 8 - 1:0] instruction_name;
      reg               should_raise_illegal_instruction_exception;

      begin
         if ( wb_dat_i[15:10] != 0 ||
              wb_dat_i[ 5: 4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              opcode        = wb_dat_i[9:6];
              src_register  = wb_dat_i[`OR10_IOP_GPR1];
              dest_register = wb_dat_i[`OR10_IOP_DEST_GPR];

              src = gpr_register_value_read_1[15:0];
              should_raise_illegal_instruction_exception = 0;

              case ( opcode )

                0:
                  begin
                     result = { {16{src[15]}}, src[15:0] };
                     instruction_name = "l.exths";
                  end

                1:
                  begin
                     result = { {24{src[7]}}, src[7:0] };
                     instruction_name = "l.extbs";
                  end

                2:
                  begin
                     result = { 16'h00, src[15:0] };
                     instruction_name = "l.exthz";
                  end

                3:
                  begin
                     result = { 24'h0000, src[7:0] };
                     instruction_name = "l.extbz";
                  end

                default:
                  begin
                     should_raise_illegal_instruction_exception = 1;
                     result = {DW{1'bx}};
                  end
              endcase

              if ( should_raise_illegal_instruction_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported l.extXX instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
              else
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: %0s r%0d, r%0d (result 0x%08h)",
                               `OR10_TRACE_PC_VAL,
                               instruction_name,
                               dest_register,
                               src_register,
                               result );

                   schedule_register_write_during_next_cycle( dest_register, result );
                end
           end
      end
   endtask


   task automatic execute_ext_w_instruction;

      inout reg can_interrupt;

      reg [3:0] opcode;
      reg [`OR10_REG_NUMBER] src_register;
      reg [`OR10_REG_NUMBER] dest_register;
      reg [DW-1:0] result;
      reg [7 * 8 - 1:0] instruction_name;
      reg               should_raise_illegal_instruction_exception;

      begin
         if ( wb_dat_i[15:10] != 0 ||
              wb_dat_i[ 5: 4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              // Both instructions l.extws and l.extwz have the same implementation on 32-bit processors,
              // and they are both unnecessary, as l.ori can also be used to copy a register to another one.
              // On 64-bit processors, l.extws would do sign extension, and l.extwz zero extension.

              opcode        = wb_dat_i[9:6];
              src_register  = wb_dat_i[`OR10_IOP_GPR1];
              dest_register = wb_dat_i[`OR10_IOP_DEST_GPR];

              result = gpr_register_value_read_1;
              should_raise_illegal_instruction_exception = 0;


              case ( opcode )
                0: instruction_name = "l.extws";
                1: instruction_name = "l.extwz";
                default:
                  should_raise_illegal_instruction_exception = 1;
              endcase

              if ( should_raise_illegal_instruction_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported l.extwX instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
              else
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: %0s r%0d, r%0d (result 0x%08h)",
                               `OR10_TRACE_PC_VAL,
                               instruction_name,
                               dest_register,
                               src_register,
                               result );

                   schedule_register_write_during_next_cycle( dest_register, result );
                end
           end
      end
   endtask


   task automatic execute_cmov;

      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER] src_register_a;
      reg [`OR10_REG_NUMBER] src_register_b;
      reg [`OR10_REG_NUMBER] dest_register;

      begin
         src_register_a = wb_dat_i[`OR10_IOP_GPR1];
         src_register_b = wb_dat_i[`OR10_IOP_GPR2];
         dest_register  = wb_dat_i[`OR10_IOP_DEST_GPR];

         if ( wb_dat_i[10]  != 0 ||
              wb_dat_i[7:4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              schedule_register_write_during_next_cycle( dest_register,
                                                               cpureg_spr_sr[`OR1200_SR_F]
                                                                 ? gpr_register_value_read_1
                                                                 : gpr_register_value_read_2 );
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: l.cmov r%0d, r%0d, r%0d (value 0x%08h taken from r%0d)",
                          `OR10_TRACE_PC_VAL,
                          dest_register,
                          src_register_a,
                          src_register_b,
                          cpureg_spr_sr[`OR1200_SR_F] ? gpr_register_value_read_1 : gpr_register_value_read_2,
                          cpureg_spr_sr[`OR1200_SR_F] ? src_register_a : src_register_b );
           end
      end
   endtask


   task automatic execute_logic_instruction;

      input reg [3:0] opcode;
      inout reg       can_interrupt;

      reg [`OR10_REG_NUMBER]  src_register_a;
      reg [`OR10_REG_NUMBER]  src_register_b;
      reg [`OR10_REG_NUMBER]  dest_register;

      reg [DW-1:0] result;
      reg          should_raise_illegal_instruction_exception;

      begin
         if ( wb_dat_i[10]  != 0 ||
              wb_dat_i[7:4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              src_register_a  = wb_dat_i[`OR10_IOP_GPR1];
              src_register_b  = wb_dat_i[`OR10_IOP_GPR2];
              dest_register   = wb_dat_i[`OR10_IOP_DEST_GPR];

              should_raise_illegal_instruction_exception = 0;

              case ( opcode )
                4'h3:
                  begin
                     result = gpr_register_value_read_1 &
                              gpr_register_value_read_2;

                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.and r%0d, r%0d, r%0d (result 0x%08h = 0x%08h AND 0x%08h)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 src_register_b,
                                 result,
                                 gpr_register_value_read_1,
                                 gpr_register_value_read_2 );
                  end

                4'h4:
                  begin
                     result = gpr_register_value_read_1 |
                              gpr_register_value_read_2;

                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.or r%0d, r%0d, r%0d (result 0x%08h = 0x%08h OR 0x%08h)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 src_register_b,
                                 result,
                                 gpr_register_value_read_1,
                                 gpr_register_value_read_2 );
                  end

                4'h5:
                  begin
                     result = gpr_register_value_read_1 ^ gpr_register_value_read_2;

                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.xor r%0d, r%0d, r%0d (result 0x%08h = 0x%08h XOR 0x%08h)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 src_register_b,
                                 result,
                                 gpr_register_value_read_1,
                                 gpr_register_value_read_2 );
                  end

                default:
                  begin
                    should_raise_illegal_instruction_exception = 1;
                    result = {DW{1'bx}};
                  end
              endcase

              if ( should_raise_illegal_instruction_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported logic instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
              else
                schedule_register_write_during_next_cycle( dest_register, result );
           end
      end
   endtask


   task automatic execute_add_instruction;

      input reg [1:0]    opcode;  // See the ADDINST_xxx constants.
      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg [`OR10_REG_NUMBER]  dest_register;
      reg [`OR10_REG_NUMBER]  src_register_a;
      reg [`OR10_REG_NUMBER]  src_register_b;   // Only for a 2nd register operand.
      reg [15:0] immediate_value;  // Only for a 2nd immediate operand.

      reg [DW-1:0] operand_a;
      reg [DW-1:0] operand_b;
      reg          operand_c;  // Previous carry (for "with carry" instructions only).

      reg [DW-1:0] result;
      reg          carry;     // Meaningful only when adding unsigned integers.
      reg          overflow;  // Meaningful only when adding   signed integers.

      reg          should_raise_reserved_bits_exception;

      begin
         dest_register   = wb_dat_i[`OR10_IOP_DEST_GPR];
         src_register_a  = wb_dat_i[`OR10_IOP_GPR1];
         src_register_b  = wb_dat_i[`OR10_IOP_GPR2];
         immediate_value = wb_dat_i[15:0];

         operand_a = gpr_register_value_read_1;

         should_raise_reserved_bits_exception = 0;

         case ( opcode )
           OR10_ADDINST_ADD, OR10_ADDINST_ADDC:
             begin
                operand_b = gpr_register_value_read_2;

                if ( wb_dat_i[10]  != 0 ||
                     wb_dat_i[7:4] != 0 )
                  should_raise_reserved_bits_exception = 1;
             end

           OR10_ADDINST_ADDI, OR10_ADDINST_ADDIC:
             begin
                operand_b = { {16{immediate_value[15]}}, immediate_value };
             end

           default:
             begin
                `ASSERT_FALSE;
                operand_b = {DW{1'bx}};
             end
         endcase

         if ( should_raise_reserved_bits_exception )
           raise_reserved_instruction_opcode_bits_exception( can_interrupt );
         else
           begin
              case ( opcode )
                OR10_ADDINST_ADD, OR10_ADDINST_ADDI:   operand_c = 0;
                OR10_ADDINST_ADDC, OR10_ADDINST_ADDIC: operand_c = cpureg_spr_sr[`OR1200_SR_CY];

                default:
                  begin
                     `ASSERT_FALSE;
                     operand_c = 1'bx;
                  end
              endcase

              result = operand_a + operand_b + { 31'b0, operand_c };


              // The carry and overflow logic here is based on this source code:
              //   http://joewing.net/hardware/verilog/m6800.v

              carry = ( operand_a[31] & operand_b[31] ) |
                      ( operand_a[31] &   ~result[31] ) |
                      ( operand_b[31] &   ~result[31] );

              overflow = (  operand_a[31] &  operand_b[31] & ~result[31] ) |
                         ( ~operand_a[31] & ~operand_b[31] &  result[31] );


              if ( TRACE_ASM_EXECUTION )
                begin
                   case ( opcode )
                     OR10_ADDINST_ADD:
                       $display( "0x%08h: l.add r%0d, r%0d, r%0d (result 0x%08h = 0x%08h + 0x%08h, resulting CY=%d, OV=%d)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 src_register_b,
                                 result,
                                 operand_a,
                                 operand_b,
                                 carry,
                                 overflow );

                     OR10_ADDINST_ADDI:
                       $display( "0x%08h: l.addi r%0d, r%0d, 0x%04h (result 0x%08h = 0x%08h + 0x%08h, resulting CY=%d, OV=%d)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 immediate_value,
                                 result,
                                 operand_a,
                                 operand_b,
                                 carry,
                                 overflow );

                     OR10_ADDINST_ADDC:
                       $display( "0x%08h: l.addc r%0d, r%0d, r%0d (result 0x%08h = 0x%08h + 0x%08h + prevCY=%1d, resulting CY=%d, OV=%d)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 src_register_b,
                                 result,
                                 operand_a,
                                 operand_b,
                                 operand_c,
                                 carry,
                                 overflow );

                     OR10_ADDINST_ADDIC:
                       $display( "0x%08h: l.addic r%0d, r%0d, 0x%04h (result 0x%08h = 0x%08h + 0x%08h, resulting CY=%d, OV=%d)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_register,
                                 src_register_a,
                                 immediate_value,
                                 result,
                                 operand_a,
                                 operand_b,
                                 carry,
                                 overflow );
                     default:
                       begin
                          `ASSERT_FALSE;
                       end
                   endcase
                end

              next_sr[ `OR1200_SR_CY ] = carry;
              next_sr[ `OR1200_SR_OV ] = overflow;

              raise_ov_range_exception_if_necessary( next_sr, can_interrupt );

              schedule_register_write_during_next_cycle( dest_register, result );
           end
      end
   endtask


   task automatic execute_sub_instruction;

      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg [`OR10_REG_NUMBER] src_reg_a;
      reg [`OR10_REG_NUMBER] src_reg_b;
      reg [`OR10_REG_NUMBER] dest_reg;
      reg [DW-1:0]           src_a;
      reg [DW-1:0]           src_b;

      reg          carry;
      reg          overflow;
      reg [DW-1:0] result;

      begin

         if ( wb_dat_i[10]  != 0 ||
              wb_dat_i[7:4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              src_reg_a = wb_dat_i[`OR10_IOP_GPR1];
              src_reg_b = wb_dat_i[`OR10_IOP_GPR2];
              dest_reg  = wb_dat_i[`OR10_IOP_DEST_GPR];

              src_a = gpr_register_value_read_1;
              src_b = gpr_register_value_read_2;

              result = src_a - src_b;

              // The carry and overflow logic here is based on this source code:
              //   http://joewing.net/hardware/verilog/m6800.v

              carry = ( ~src_a[31] & src_b [31] ) |
                      ( ~src_a[31] & result[31] ) |
                      (  src_b[31] & result[31] );

              overflow = (  src_a[31] & ~src_b[31] & ~result[31] ) |
                         ( ~src_a[31] &  src_b[31] &  result[31] );

              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: l.sub r%0d, r%0d, r%0d (result 0x%08h = 0x%08h - 0x%08h, resulting CY=%d, OV=%d)",
                          `OR10_TRACE_PC_VAL,
                          dest_reg,
                          src_reg_a,
                          src_reg_b,
                          result,
                          src_a,
                          src_b,
                          carry,
                          overflow );

              next_sr[ `OR1200_SR_CY ] = carry;
              next_sr[ `OR1200_SR_OV ] = overflow;

              raise_ov_range_exception_if_necessary( next_sr, can_interrupt );

              schedule_register_write_during_next_cycle( dest_reg, result );
           end
      end
   endtask


   task automatic execute_ff1_fl1;

      inout reg can_interrupt;

      reg [1:0] opcode;
      reg [`OR10_REG_NUMBER] src_reg;
      reg [`OR10_REG_NUMBER] dest_reg;
      reg [DW-1:0]           result;
      reg [DW-1:0]           a;

      reg                    should_raise_illegal_instruction_exception;

      begin
         if ( wb_dat_i[15:11] != 0 ||
              wb_dat_i[10]    != 0 ||
              wb_dat_i[7:4]   != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin

              dest_reg = wb_dat_i[`OR10_IOP_DEST_GPR];
              src_reg  = wb_dat_i[`OR10_IOP_GPR1];
              opcode   = wb_dat_i[9:8];

              a = gpr_register_value_read_1;
              should_raise_illegal_instruction_exception = 0;

              case ( opcode )

                0:
                  begin
                     result = a[0] ? 1 : a[1] ? 2 : a[2] ? 3 : a[3] ? 4 : a[4] ? 5 : a[5] ? 6 : a[6] ? 7 : a[7] ? 8 : a[8] ? 9 : a[9] ? 10 : a[10] ? 11 : a[11] ? 12 : a[12] ? 13 : a[13] ? 14 : a[14] ? 15 : a[15] ? 16 : a[16] ? 17 : a[17] ? 18 : a[18] ? 19 : a[19] ? 20 : a[20] ? 21 : a[21] ? 22 : a[22] ? 23 : a[23] ? 24 : a[24] ? 25 : a[25] ? 26 : a[26] ? 27 : a[27] ? 28 : a[28] ? 29 : a[29] ? 30 : a[30] ? 31 : a[31] ? 32 : 0;

                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.ff1 r%0d, r%0d (result %0d)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_reg,
                                 src_reg,
                                 result );
                  end

                1:
                  begin

                     result = a[31] ? 32 : a[30] ? 31 : a[29] ? 30 : a[28] ? 29 : a[27] ? 28 : a[26] ? 27 : a[25] ? 26 : a[24] ? 25 : a[23] ? 24 : a[22] ? 23 : a[21] ? 22 : a[20] ? 21 : a[19] ? 20 : a[18] ? 19 : a[17] ? 18 : a[16] ? 17 : a[15] ? 16 : a[14] ? 15 : a[13] ? 14 : a[12] ? 13 : a[11] ? 12 : a[10] ? 11 : a[9] ? 10 : a[8] ? 9 : a[7] ? 8 : a[6] ? 7 : a[5] ? 6 : a[4] ? 5 : a[3] ? 4 : a[2] ? 3 : a[1] ? 2 : a[0] ? 1 : 0 ;

                     if ( TRACE_ASM_EXECUTION )
                       $display( "0x%08h: l.fl1 r%0d, r%0d (result %0d)",
                                 `OR10_TRACE_PC_VAL,
                                 dest_reg,
                                 src_reg,
                                 result );
                  end

                default:
                  begin
                     should_raise_illegal_instruction_exception = 1;
                     result = {DW{1'bx}};
                  end
              endcase

              if ( should_raise_illegal_instruction_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported l.fXX bit find instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
              else
                schedule_register_write_during_next_cycle( dest_reg, result );
           end
     end
   endtask


   // These registers are shared between the external multiplier and divider support code,
   // in the hope that this will save some FPGA fabric resources.

   reg [DW:0]             muldiv_operand_a;  // For division, this is the dividend.
   reg [DW:0]             muldiv_operand_b;  // For division, this is the divisor.
   reg                    muldiv_is_unsigned;
   reg [`OR10_REG_NUMBER] muldiv_dest_reg;


   // External multiplier support.

   wire [DW*2+1:0]        mul_result;
   reg [3:0]              mul_delay;

   generate if ( ENABLE_EXTERNAL_MULTIPLIER )
     begin
        or10_external_multiplier hardware_multiplier_instance ( .clk( wb_clk_i ),
                                                                .a( muldiv_operand_a ),
                                                                .b( muldiv_operand_b ),
                                                                .p( mul_result )
                                                              );
     end
   else
     begin
        assign mul_result = 66'h_deadf00d_deadf00d;  // This signal should get optimised away.
     end
   endgenerate


   // External divider support.

   reg                    div_din_tvalid;  // This is a kind of "new data" signal.
   wire                   div_tready_a;  // For a non-blocking divisor generated by Xilinx' Divider Generator 4.0,
   wire                   div_tready_b;  // the _a und _b signals are actually the same signal.

   wire                   div_dout_tvalid;  // This signal seems to be asserted just for 1 clock cycle.
   wire [79:0]            div_dout_tdata;

   generate if ( ENABLE_EXTERNAL_DIVIDER )
     begin
        or10_external_divider hardware_divider_instance ( .aclk( wb_clk_i ),

                                                          .s_axis_divisor_tvalid( div_din_tvalid ),
                                                          .s_axis_divisor_tready( div_tready_b ),
                                                          .s_axis_divisor_tdata(  { 7'b0, muldiv_operand_b } ),

                                                          .s_axis_dividend_tvalid( div_din_tvalid ),
                                                          .s_axis_dividend_tready( div_tready_a ),
                                                          .s_axis_dividend_tdata( { 7'b0, muldiv_operand_a } ),

                                                          .m_axis_dout_tvalid( div_dout_tvalid ),
                                                          .m_axis_dout_tdata( div_dout_tdata )
                                                        );
     end
   else
     begin
        // These signals should get optimised away.
        assign div_tready_a = 1;
        assign div_tready_b = 1;
        assign div_dout_tvalid = 1;
        assign div_dout_tdata = 80'h_deadf00d_deadf00d;
     end
   endgenerate


   task automatic trace_mul_instruction;

      input reg          is_unsigned;
      input reg          is_immediate;

      input reg [`OR10_REG_NUMBER] operand_a_reg;
      input reg [`OR10_REG_NUMBER] operand_b_reg;
      input reg [15:0]             operand_b_immediate;
      input reg [DW-1:0]           operand_a_value;
      input reg [DW-1:0]           operand_b_value;
      input reg [`OR10_REG_NUMBER] dest_reg;

      input reg                    is_result_available;

      input reg [DW-1:0]           result;
      input reg                    carry;
      input reg                    overflow;

      reg [6 * 8 - 1:0]            instruction_name;

      begin
         if ( TRACE_ASM_EXECUTION )
           begin
              if ( is_immediate )
                begin
                   if ( is_result_available )
                     $display( "0x%08h: l.muli r%0d, r%0d, 0x%04h (result 0x%08h * 0x%08h = 0x%08h, CY=%d, OV=%d)",
                               `OR10_TRACE_PC_VAL,
                               dest_reg,
                               operand_a_reg,
                               operand_b_immediate,
                               operand_a_value,
                               operand_b_value,
                               result,
                               carry, overflow );
                   else
                     $display( "0x%08h: l.muli r%0d, r%0d, 0x%04h (0x%08h * 0x%08h, see result below)",
                               `OR10_TRACE_PC_VAL,
                               dest_reg,
                               operand_a_reg,
                               operand_b_immediate,
                               operand_a_value,
                               operand_b_value );

                end
              else
                begin
                   if ( is_unsigned )
                     instruction_name = "l.mulu";
                   else
                     instruction_name = "l.mul";

                   if ( is_result_available )
                     $display( "0x%08h: %0s r%0d, r%0d, r%0d (result 0x%08h * 0x%08h = 0x%08h, CY=%d, OV=%d)",
                               `OR10_TRACE_PC_VAL,
                               instruction_name,
                               dest_reg,
                               operand_a_reg,
                               operand_b_reg,
                               operand_a_value,
                               operand_b_value,
                               result,
                               carry, overflow );
                   else
                     $display( "0x%08h: %0s r%0d, r%0d, r%0d (0x%08h * 0x%08h, see result below)",
                               `OR10_TRACE_PC_VAL,
                               instruction_name,
                               dest_reg,
                               operand_a_reg,
                               operand_b_reg,
                               operand_a_value,
                               operand_b_value );
                end
           end
      end
   endtask


   task automatic calculate_multiplication_carry_overflow;

      input            is_unsigned;
      input [DW*2+1:0] result66;
      inout [DW-1:0]   next_sr;

      reg carry;     // Meaningful only when multiplying unsigned integers.
      reg overflow;  // Meaningful only when multiplying signed   integers.

      begin
         // Possible optimisation: if we didn't need the Carry and Overflow flags, we don't need
         // to calculate the top 32-bits of the result, which might save some FPGA resources (I'm not sure).

         if ( is_unsigned )
           begin
              overflow = 0;
              carry    = result66[DW*2+1:DW] != 0;
           end
         else
           begin
              overflow = result66[DW*2+1:DW] != {34{result66[DW-1]}};
              // I haven't found a way to calculate the carry flag as if the operands had been unsigned integers.
              // This is what or1ksim does, but it cheats by doing both a signed and an unsigned multiplications,
              // which would waste quite a lot of FPGA resources.
              carry    = 0;
           end

         next_sr[ `OR1200_SR_CY ] = carry;
         next_sr[ `OR1200_SR_OV ] = overflow;
      end
   endtask


   task automatic execute_mul_instruction;

      input reg          is_unsigned;
      input reg          is_immediate;

      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg [`OR10_REG_NUMBER] operand_a_reg;
      reg [`OR10_REG_NUMBER] operand_b_reg;       // Only used if non-immediate.
      reg [15:0]             operand_b_immediate; // Only used if immediate.
      reg [DW-1:0]           operand_a_value;     // Just an alias for gpr_register_value_read_1.
      reg [DW-1:0]           operand_b_value;
      reg [DW:0]             op33_a;
      reg [DW:0]             op33_b;
      reg [DW*2+1:0]         result66;
      reg [`OR10_REG_NUMBER] dest_reg;

      reg                    prevent_unused_warning_with_verilator;

      begin
         if ( !is_immediate && ( wb_dat_i[10]  != 0 ||
                                 wb_dat_i[7:4] != 0 ) )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else if ( !is_immediate && wb_dat_i[9:8] != 3 )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: Illegal instruction exception raised for unsupported l.div/l.divi instruction opcode.",
                          `OR10_TRACE_PC_VAL );
              raise_illegal_instruction_exception( can_interrupt );
           end
         else
           begin
             operand_a_reg       = wb_dat_i[`OR10_IOP_GPR1];
             operand_b_reg       = wb_dat_i[`OR10_IOP_GPR2];
             operand_b_immediate = wb_dat_i[15:0];
             dest_reg            = wb_dat_i[`OR10_IOP_DEST_GPR];

             operand_a_value = gpr_register_value_read_1;

             if ( is_immediate )
               operand_b_value = { {16{wb_dat_i[15]}}, operand_b_immediate };  // Sign-extend the immediate value.
             else
               operand_b_value = gpr_register_value_read_2;

             // Multiply 33 * 33 = 66 bits, so that a single signed multiplier can do both signed
             // and unsigned multiplications.
             // There are probably better ways to achieve this, but I'm no expert at 2's complement.

             if ( is_unsigned )
               begin
                  // The sign bit is always zero.
                  op33_a = { 1'b0, operand_a_value };
                  op33_b = { 1'b0, operand_b_value };
               end
             else
               begin
                  // Sign-extend the operands from 32 to 33 bits.
                  op33_a = { operand_a_value[DW-1], operand_a_value };
                  op33_b = { operand_b_value[DW-1], operand_b_value };
               end

              prevent_unused_warning_with_verilator = &{ 1'b0,
                                                         muldiv_operand_a[32],
                                                         muldiv_operand_b[32],
                                                         1'b0 };
             if ( ENABLE_EXTERNAL_MULTIPLIER )
               begin
                  muldiv_operand_a   <= op33_a;
                  muldiv_operand_b   <= op33_b;
                  muldiv_is_unsigned <= is_unsigned;
                  muldiv_dest_reg    <= dest_reg;
                  mul_delay          <= EXTERNAL_MULTIPLIER_DELAY_IN_CLOCK_TICKS;

                  can_interrupt = 0;
                  current_state <= STATE_MULTIPLYING;

                  trace_mul_instruction( is_unsigned,
                                         is_immediate,
                                         operand_a_reg,
                                         operand_b_reg,
                                         operand_b_immediate,
                                         operand_a_value,
                                         operand_b_value,
                                         dest_reg,
                                         0,
                                         0,
                                         0,
                                         0 );
               end
             else
               begin
                  result66 = $signed(op33_a) * $signed(op33_b);

                  calculate_multiplication_carry_overflow( is_unsigned, result66, next_sr );

                  trace_mul_instruction( is_unsigned,
                                         is_immediate,
                                         operand_a_reg,
                                         operand_b_reg,
                                         operand_b_immediate,
                                         operand_a_value,
                                         operand_b_value,
                                         dest_reg,
                                         1,
                                         result66[DW-1:0],
                                         next_sr[ `OR1200_SR_CY ],
                                         next_sr[ `OR1200_SR_OV ] );

                  raise_ov_range_exception_if_necessary( next_sr, can_interrupt );

                  schedule_register_write_during_next_cycle( dest_reg, result66[DW-1:0] );
               end
           end
      end
   endtask


   task automatic trace_div_instruction;

      input reg                    is_unsigned;
      input reg [`OR10_REG_NUMBER] operand_a_reg;
      input reg [`OR10_REG_NUMBER] operand_b_reg;
      input reg [DW-1:0]           operand_a_value;
      input reg [DW-1:0]           operand_b_value;
      input reg [DW-1:0]           result;
      input reg [DW-1:0]           remainder;
      input reg [`OR10_REG_NUMBER] dest_reg;
      input reg                    carry;

      input reg is_result_available;

      reg [6 * 8 - 1:0] instruction_name;

      begin
         if ( TRACE_ASM_EXECUTION )
           begin
              if ( is_unsigned )
                instruction_name = "l.divu";
              else
                instruction_name = "l.div";

              if ( is_result_available )
                $display( "0x%08h: %0s r%0d, r%0d, r%0d (result 0x%08h / 0x%08h = 0x%08h, remainder 0x%08h [debug only], CY=%d)",
                          `OR10_TRACE_PC_VAL,
                          instruction_name,
                          dest_reg,
                          operand_a_reg,
                          operand_b_reg,
                          operand_a_value,
                          operand_b_value,
                          result,
                          remainder,
                          carry );
              else
                $display( "0x%08h: %0s r%0d, r%0d, r%0d (0x%08h / 0x%08h, see result below)",
                          `OR10_TRACE_PC_VAL,
                          instruction_name,
                          dest_reg,
                          operand_a_reg,
                          operand_b_reg,
                          operand_a_value,
                          operand_b_value );
           end
      end
   endtask


   task automatic execute_div_instruction;

      input reg          is_unsigned;

      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg [`OR10_REG_NUMBER] operand_a_reg;
      reg [`OR10_REG_NUMBER] operand_b_reg;       // Only used if non-immediate.
      reg [DW-1:0]           operand_a_value;     // Just an alias for gpr_register_value_read_1.
      reg [DW-1:0]           operand_b_value;
      reg [DW:0]             op33_a;
      reg [DW:0]             op33_b;
      reg [DW:0]             result33;
      reg [DW:0]             remainder33;
      reg [`OR10_REG_NUMBER] dest_reg;
      reg                    carry;

      begin
         if ( wb_dat_i[10]  != 0 ||
              wb_dat_i[7:4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else if ( wb_dat_i[9:8] != 3 )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: Illegal instruction exception raised for unsupported l.div/l.divi instruction opcode.",
                          `OR10_TRACE_PC_VAL );
              raise_illegal_instruction_exception( can_interrupt );
           end
         else
           begin
              operand_a_reg       = wb_dat_i[`OR10_IOP_GPR1];
              operand_b_reg       = wb_dat_i[`OR10_IOP_GPR2];
              dest_reg            = wb_dat_i[`OR10_IOP_DEST_GPR];

              operand_a_value = gpr_register_value_read_1;
              operand_b_value = gpr_register_value_read_2;

              if ( operand_b_value == 0 )
                begin
                   carry = 1;
                   result33    = 0;  // For logging purposes only.
                   remainder33 = 0;  // For logging purposes only.

                   trace_div_instruction( is_unsigned,
                                          operand_a_reg,
                                          operand_b_reg,
                                          operand_a_value,
                                          operand_b_value,
                                          result33[DW-1:0],
                                          remainder33[DW-1:0],
                                          dest_reg,
                                          carry,
                                          1 );
                end
              else
                begin
                   carry = 0;

                   // Divide 33 / 33 = 3 bits, so that a single signed divider can do both signed
                   // and unsigned divisions.
                   // There are probably better ways to achieve this, but I'm no expert at 2's complement.

                   if ( is_unsigned )
                     begin
                        // The sign bit is always zero.
                        op33_a = { 1'b0, operand_a_value };
                        op33_b = { 1'b0, operand_b_value };
                     end
                   else
                     begin
                        // Sign-extend the operands from 32 to 33 bits.
                        op33_a = { operand_a_value[DW-1], operand_a_value };
                        op33_b = { operand_b_value[DW-1], operand_b_value };
                     end

                   if ( ENABLE_EXTERNAL_DIVIDER )
                     begin
                        if ( div_din_tvalid != 0 )
                          begin
                             `ASSERT_FALSE;
                          end

                        muldiv_operand_a    <= op33_a;
                        muldiv_operand_b    <= op33_b;
                        muldiv_is_unsigned  <= is_unsigned;
                        muldiv_dest_reg     <= dest_reg;
                        div_din_tvalid      <= 1;

                        can_interrupt = 0;
                        current_state <= STATE_DIVIDING;

                        trace_div_instruction( is_unsigned,
                                               operand_a_reg,
                                               operand_b_reg,
                                               operand_a_value,
                                               operand_b_value,
                                               0,
                                               0,
                                               dest_reg,
                                               0,
                                               0 );
                     end
                   else
                     begin
                        result33   = $signed(op33_a) / $signed(op33_b);
                        // Note that the remainder is not actually available to the software,
                        // so at the moment it's calculated for tracing purposes only.
                        remainder33 = $signed(op33_a) % $signed(op33_b);

                        // If I have understood 2's complement correctly, we only need sign extension
                        // for unsigned 32-bit numbers. Check that the results match the expectations.
                        if ( is_unsigned )
                          begin
                             if ( result33  [DW]  != 0 ||
                                  remainder33[DW] != 0 )
                               begin
                                  `ASSERT_FALSE;
                               end
                          end
                        else
                          begin
                             if ( result33  [DW]  != result33  [DW-1] ||
                                  remainder33[DW] != remainder33[DW-1] )
                               begin
                                  `ASSERT_FALSE;
                               end
                          end

                        schedule_register_write_during_next_cycle( dest_reg, result33[DW-1:0] );

                        trace_div_instruction( is_unsigned,
                                               operand_a_reg,
                                               operand_b_reg,
                                               operand_a_value,
                                               operand_b_value,
                                               result33[DW-1:0],
                                               remainder33[DW-1:0],
                                               dest_reg,
                                               carry,
                                               1 );
                     end
                end

              // This code is executed when using the external multiplier too, as the carry flag
              // is known in advance.
              next_sr[ `OR1200_SR_CY ] = carry;
              next_sr[ `OR1200_SR_OV ] = 0;

              raise_cy_range_exception_if_necessary( next_sr, can_interrupt );
           end
      end
   endtask


   task automatic trace_shift_instruction;

      input reg [2:0]              opcode;  // See the `OR10_SHIFTINST_xxx constants.
      input reg [4:0]              shift_amount;
      input reg [`OR10_REG_NUMBER] amount_reg;

      input reg [`OR10_REG_NUMBER] src_reg;
      input reg [DW-1:0] src;
      input reg [`OR10_REG_NUMBER] dest_reg;

      input reg          is_result_available;
      input reg [DW-1:0] result;

      reg [6 * 8 - 1:0]  instruction_name;

      begin
         `UNIQUE case ( opcode )
                   OR10_SHIFTINST_SLL:   instruction_name = {8'h00, "l.sll"};
                   OR10_SHIFTINST_SLLI:  instruction_name = {"l.slli"};
                   OR10_SHIFTINST_SRA:   instruction_name = {8'h00, "l.sra"};
                   OR10_SHIFTINST_SRAI:  instruction_name = {"l.srai"};
                   OR10_SHIFTINST_SRL:   instruction_name = {8'h00, "l.srl"};
                   OR10_SHIFTINST_SRLI:  instruction_name = {"l.srli"};
                   OR10_SHIFTINST_ROR:   instruction_name = {8'h00, "l.ror"};
                   OR10_SHIFTINST_RORI:  instruction_name = {"l.rori"};
         endcase

         `UNIQUE case ( opcode )

                   OR10_SHIFTINST_SLL, OR10_SHIFTINST_SRA, OR10_SHIFTINST_SRL, OR10_SHIFTINST_ROR:
                     if ( TRACE_ASM_EXECUTION )
                       begin
                          if ( is_result_available )
                            $display( "0x%08h: %0s r%0d, r%0d, r%0d (0x%08h by %0d, result 0x%08h)",
                                      `OR10_TRACE_PC_VAL,
                                      instruction_name,
                                      dest_reg,
                                      src_reg,
                                      amount_reg,
                                      src,
                                      shift_amount,
                                      result );
                          else
                            $display( "0x%08h: %0s r%0d, r%0d, r%0d (0x%08h by %0d, see result below)",
                                      `OR10_TRACE_PC_VAL,
                                      instruction_name,
                                      dest_reg,
                                      src_reg,
                                      amount_reg,
                                      src,
                                      shift_amount );
                       end

                   OR10_SHIFTINST_SLLI, OR10_SHIFTINST_SRAI, OR10_SHIFTINST_SRLI, OR10_SHIFTINST_RORI:
                     if ( TRACE_ASM_EXECUTION )
                       begin
                          if ( is_result_available )
                            $display( "0x%08h: %0s r%0d, r%0d, %0d (src val 0x%08h, result 0x%08h)",
                                      `OR10_TRACE_PC_VAL,
                                      instruction_name,
                                      dest_reg,
                                      src_reg,
                                      shift_amount,
                                      src,
                                      result );
                          else
                            $display( "0x%08h: %0s r%0d, r%0d, %0d (src val 0x%08h, see result below)",
                                      `OR10_TRACE_PC_VAL,
                                      instruction_name,
                                      dest_reg,
                                      src_reg,
                                      shift_amount,
                                      src );
                       end
         endcase
      end
   endtask


   task automatic execute_shift_instruction_2;

      input reg [2:0]              opcode;  // See the `OR10_SHIFTINST_xxx constants.
      input reg [4:0]              shift_amount;
      input reg [`OR10_REG_NUMBER] amount_reg;  // Only for 2nd operand register (non-immediate) instructions, for logging purposes only.
      inout reg                    can_interrupt;

      reg [`OR10_REG_NUMBER] src_reg;
      reg [`OR10_REG_NUMBER] dest_reg;

      reg [DW-1:0] src;
      reg [DW-1:0] result;

      begin
         dest_reg = wb_dat_i[`OR10_IOP_DEST_GPR];
         src_reg  = wb_dat_i[`OR10_IOP_GPR1];

         src = gpr_register_value_read_1;

         if ( ENABLE_SERIAL_SHIFTER )
           begin
              if ( shift_amount == 0 )
                begin
                   result = src;
                   schedule_register_write_during_next_cycle( dest_reg, result );
                   trace_shift_instruction( opcode, shift_amount, amount_reg, src_reg, src, dest_reg, 1, result );
                end
              else
                begin
                   trace_shift_instruction( opcode, shift_amount, amount_reg, src_reg, src, dest_reg, 0, result );

                   shift_operation <= opcode;
                   shift_bit_count <= shift_amount;
                   shift_result <= src;
                   shift_dest_reg <= dest_reg;

                   can_interrupt = 0;
                   current_state <= STATE_SHIFTING;
                end
           end
         else
           begin
              `UNIQUE case ( opcode )

                   OR10_SHIFTINST_SLL, OR10_SHIFTINST_SLLI:  result = src << shift_amount;
                   OR10_SHIFTINST_SRL, OR10_SHIFTINST_SRLI:  result = src >> shift_amount;
                   OR10_SHIFTINST_SRA, OR10_SHIFTINST_SRAI:  result = $signed(src) >>> shift_amount;
                   OR10_SHIFTINST_ROR, OR10_SHIFTINST_RORI:
                     if ( ENABLE_INSTRUCTION_ROR )
                       result = (src << ( 6'd32 - {1'b0, shift_amount} )) | (src >> shift_amount );
                     else
                       begin
                          `ASSERT_FALSE;
                          result = {DW{1'bx}};
                       end
              endcase

              schedule_register_write_during_next_cycle( dest_reg, result );
              trace_shift_instruction( opcode, shift_amount, amount_reg, src_reg, src, dest_reg, 1, result );
           end
      end
   endtask


   task automatic execute_shift_instruction_reg;

      inout reg can_interrupt;

      reg [3:0]              opcode;
      reg [4:0]              shift_amount;
      reg [`OR10_REG_NUMBER] amount_reg;
      reg                    should_raise_illegal_exception;

      begin
         if ( wb_dat_i[10]  != 0 ||
              wb_dat_i[5:4] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              opcode       = wb_dat_i[9:6];
              amount_reg   = wb_dat_i[`OR10_IOP_GPR2];
              shift_amount = gpr_register_value_read_2[4:0];
              should_raise_illegal_exception = 0;

              case ( opcode )
                4'h0: execute_shift_instruction_2( OR10_SHIFTINST_SLL, shift_amount, amount_reg, can_interrupt );
                4'h1: execute_shift_instruction_2( OR10_SHIFTINST_SRL, shift_amount, amount_reg, can_interrupt );
                4'h2: execute_shift_instruction_2( OR10_SHIFTINST_SRA, shift_amount, amount_reg, can_interrupt );
                4'h3:
                  if ( ENABLE_INSTRUCTION_ROR )
                    execute_shift_instruction_2( OR10_SHIFTINST_ROR, shift_amount, amount_reg, can_interrupt );
                  else
                    should_raise_illegal_exception = 1;

                default:
                  should_raise_illegal_exception = 1;
              endcase

              if ( should_raise_illegal_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported shift/rotate instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
           end
      end
   endtask


   task automatic execute_shift_instruction_immediate;

      inout reg can_interrupt;

      reg [1:0] opcode;
      reg [4:0] shift_amount;
      reg       should_raise_illegal_exception;

      begin
         if ( wb_dat_i[15:8] != 0 )
           raise_reserved_instruction_opcode_bits_exception( can_interrupt );
         else
           begin
              opcode       = wb_dat_i[7:6];
              shift_amount = wb_dat_i[4:0];
              should_raise_illegal_exception = 0;

              `UNIQUE case ( opcode )
                        2'h0: execute_shift_instruction_2( OR10_SHIFTINST_SLLI, shift_amount, {GPR_NUMBER_WIDTH{1'bx}}, can_interrupt );
                        2'h1: execute_shift_instruction_2( OR10_SHIFTINST_SRLI, shift_amount, {GPR_NUMBER_WIDTH{1'bx}}, can_interrupt );
                        2'h2: execute_shift_instruction_2( OR10_SHIFTINST_SRAI, shift_amount, {GPR_NUMBER_WIDTH{1'bx}}, can_interrupt );
                        2'h3: if ( ENABLE_INSTRUCTION_ROR )
                                execute_shift_instruction_2( OR10_SHIFTINST_RORI, shift_amount, {GPR_NUMBER_WIDTH{1'bx}}, can_interrupt );
                              else
                                should_raise_illegal_exception = 1;
                      endcase

              if ( should_raise_illegal_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported immediate shift/rotate instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
           end
      end
   endtask


   task automatic execute_prefix_38_instruction;

      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg [3:0] opcode;
      reg       should_raise_illegal_exception;

      begin
         opcode = wb_dat_i[3:0];
         should_raise_illegal_exception = 0;

         case ( opcode )
           4'h0: execute_add_instruction( OR10_ADDINST_ADD , next_sr, can_interrupt );
           4'h1: execute_add_instruction( OR10_ADDINST_ADDC, next_sr, can_interrupt );
           4'h2: execute_sub_instruction( next_sr, can_interrupt );
           4'h3, 4'h4, 4'h5: execute_logic_instruction( opcode, can_interrupt );

           4'h6: if ( ENABLE_INSTRUCTION_MUL )
                   execute_mul_instruction( 0, 0, next_sr, can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'h8: execute_shift_instruction_reg( can_interrupt );

           4'h9: if ( ENABLE_INSTRUCTION_DIV )
                   execute_div_instruction( 0, next_sr, can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'ha: if ( ENABLE_INSTRUCTION_DIV )
                   execute_div_instruction( 1, next_sr, can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'hb: if ( ENABLE_INSTRUCTION_MUL )
                   execute_mul_instruction( 1, 0, next_sr, can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'hc: if ( ENABLE_INSTRUCTION_EXT )
                   execute_ext_b_h_instruction( can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'hd: if ( ENABLE_INSTRUCTION_EXT )
                   execute_ext_w_instruction( can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'he: if ( ENABLE_INSTRUCTION_CMOV )
                   execute_cmov( can_interrupt );
                 else
                   should_raise_illegal_exception = 1;

           4'hf: execute_ff1_fl1( can_interrupt );

           default: should_raise_illegal_exception = 1;
         endcase

         if ( should_raise_illegal_exception )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: Illegal instruction exception raised for unsupported instruction with a 6-bit opcode prefix of 0x%02h.",
                          `OR10_TRACE_PC_VAL, OR10_INST_PREFIX_38 );
              raise_illegal_instruction_exception( can_interrupt );
           end
      end
   endtask


   task automatic write_spr_sys;  // Special Purpose Registers, System group.

      input reg [10:0]   effective_spr_number;
      input reg [DW-1:0] val;
      output reg         is_invalid_spr_number;
      output reg         should_raise_alignment_exception;

      inout [`OR10_PC_ADDR] next_pc;
      inout reg [DW-1:0] next_sr;

      begin
         is_invalid_spr_number = 0;
         should_raise_alignment_exception = 0;

         case ( effective_spr_number )

           `OR1200_SPRGRP_SYS_SR:   next_sr = val;

           `OR1200_SPRGRP_SYS_NPC:
             begin
                if ( is_addr_aligned( val ) )
                  next_pc = addr_32_to_pc( val );  // Only debuggers should modify the PC this way.
                else
                  should_raise_alignment_exception = 1;
             end

           `OR1200_SPRGRP_SYS_EPCR:
             begin
                // Register cpureg_spr_epcr does not have the last 2 bits, therefore it cannot take
                // any unaligned address.
                if ( is_addr_aligned( val ) )
                  cpureg_spr_epcr <= addr_32_to_pc( val );
                else
                  should_raise_alignment_exception = 1;
             end

           `OR1200_SPRGRP_SYS_EEAR: cpureg_spr_eear <= val;
           `OR1200_SPRGRP_SYS_ESR:  cpureg_spr_esr  <= val;

           default:
             if ( ENABLE_GPR_ACCESS_OVER_SPR &&
                  effective_spr_number >= `OR1200_SPRGRP_SYS_GPR_BASE &&
                  effective_spr_number <  `OR1200_SPRGRP_SYS_GPR_BASE + GPR_COUNT )
               begin
                  // The Debug Interface uses this code path in order to write to the GPRs,
                  // but note that standard software running on the CPU can do it this way too.
                  schedule_register_write_during_next_cycle( effective_spr_number[4:0], val );
               end
             else
               begin
                  is_invalid_spr_number = 1;
               end
         endcase
      end
   endtask


   task automatic write_spr_pic;  // Special Purpose Registers, PIC registers.
      input reg [10:0]   effective_spr_number;
      input reg [DW-1:0] val;
      output reg         is_invalid_spr_number;

      begin
         is_invalid_spr_number = 0;

         case ( effective_spr_number )

           `OR1200_PIC_OFS_PICMR: cpureg_spr_picmr <= val;

           // Writing to PICSR is not allowed. Alternatively, we could just ignore any writes to it.
           //   `OR1200_PIC_OFS_PICSR: cpureg_spr_picsr <= val;

           default:
             is_invalid_spr_number = 1;
         endcase
      end
   endtask


   task automatic write_spr_du;  // Special Purpose Registers, Debug Unit.

      input reg [10:0]   effective_spr_number;
      input reg [DW-1:0] val;
      output reg         is_invalid_spr_number;
      output reg         should_raise_alignment_exception;

      reg [10:0]         watchpoint_index;
      reg                prevent_unused_warning_with_verilator;

      begin
         prevent_unused_warning_with_verilator = &{ 1'b0, val[31:1], 1'b0 };

         is_invalid_spr_number = 0;
         should_raise_alignment_exception = 0;

         case ( effective_spr_number )

           `OR1200_DU_EDIS:
             begin
                if ( TRACE_ASM_EXECUTION && dbg_is_stalled_o != val[0] )
                  begin
                     if ( val[0] )
                       $display( "0x%08h: The CPU has been stalled by the Debug Unit.", `OR10_TRACE_PC_VAL );
                     else
                       $display( "0x%08h: The CPU has been unstalled by the Debug Unit.", `OR10_TRACE_PC_VAL );
                  end

                // Note that any other bits are ignored. We could raise an error if they are not 0.
                dbg_is_stalled_o <= val[0];
             end

           `OR1200_DU_WRITE_MEM_ADDR:
             begin
                // Register dbg_write_mem_addr does not have the last 2 bits, therefore it cannot take
                // any unaligned address.
                if ( is_addr_aligned( val ) )
                  dbg_write_mem_addr <= addr_32_to_pc( val );
                else
                  should_raise_alignment_exception = 1;
             end

           `OR1200_DU_DRR:
             begin
                // Note that any other bits are ignored. We could raise an error if they are not 0.
                is_stop_reason_trap <= val[ `OR1200_DU_DRR_TE ];
             end

           `OR1200_DU_DSR:
             begin
                // Note that any other bits are ignored. We could raise an error if they are not 0.
                if ( ENABLE_DEBUG_UNIT )
                  is_trap_debug_unit_enabled <= val[ `OR1200_DU_DSR_TE ];
                else
                  is_invalid_spr_number = 1;
             end

           `OR1200_DU_DMR1:
             begin
                // Note that any other bits are ignored. We could raise an error if they are not 0.
                stop_at_next_instruction_1 <= val[ `OR1200_DU_DMR1_ST ];
                stop_at_next_instruction_2 <= 0;
             end

           default:
             if ( ENABLE_WATCHPOINTS &&
                  // effective_spr_number >= `OR1200_DU_DVR0 &&  --> Commented out to prevent warning "Comparison is constant due to unsigned arithmetic"
                  effective_spr_number < `OR1200_DU_DVR0 + WATCHPOINT_COUNT )
               begin
                  watchpoint_index = `OR1200_DU_DVR0 + effective_spr_number;
                  if ( watchpoint_index >= (1<<WATCHPOINT_INDEX_WIDTH) )
                    begin
                       `ASSERT_FALSE;
                    end
                  watchpoints[ watchpoint_index[WATCHPOINT_INDEX_WIDTH-1:0] ] <= val;
               end
             else
               is_invalid_spr_number = 1;
         endcase
      end
   endtask


   task automatic write_spr_tt;  // Special Purpose Registers, Tick Timer registers.
      input reg [10:0]   effective_spr_number;
      input reg [DW-1:0] val;
      output reg         is_invalid_spr_number;

      begin
         is_invalid_spr_number = 0;

         case ( effective_spr_number )

           `OR1200_TT_OFS_TTMR:
             begin
                // In case you are considering disabling Tick Timer support,
                // note that Newlib's OpenRISC port, as of July 2012, does not check whether the Tick Timer is present,
                // it always tries to write to the TTMR register.
                cpureg_spr_ttmr <= val;
             end

           `OR1200_TT_OFS_TTCR:
             begin
                cpureg_spr_ttcr <= val;
             end

           default:
             is_invalid_spr_number = 1;
         endcase
      end
   endtask


   task automatic write_cpu_spr;

      input reg [4:0]     effective_spr_group;
      input reg [10:0]    effective_spr_number;
      input reg [DW-1:0]  val;
      output reg          is_invalid_spr_group;
      output reg          is_invalid_spr_number;
      output reg          should_raise_alignment_exception;
      inout [`OR10_PC_ADDR] next_pc;
      inout  reg [DW-1:0] next_sr;

      begin
         is_invalid_spr_group  = 0;
         is_invalid_spr_number = 0;
         should_raise_alignment_exception = 0;

         case ( effective_spr_group )
           `OR1200_SPR_GROUP_SYS: write_spr_sys( effective_spr_number, val, is_invalid_spr_number, should_raise_alignment_exception, next_pc, next_sr );
           `OR1200_SPR_GROUP_TT:  if ( ENABLE_TICK_TIMER_UNIT )
                                    write_spr_tt( effective_spr_number, val, is_invalid_spr_number );
                                  else
                                    is_invalid_spr_group = 1;
           `OR1200_SPR_GROUP_PIC: if ( ENABLE_PIC_UNIT )
                                    write_spr_pic( effective_spr_number, val, is_invalid_spr_number );
                                  else
                                    is_invalid_spr_group = 1;
           `OR1200_SPR_GROUP_DU:  write_spr_du ( effective_spr_number, val, is_invalid_spr_number, should_raise_alignment_exception );

           default:
             is_invalid_spr_group = 1;
         endcase
      end
   endtask


   task automatic execute_mtspr;

      inout [`OR10_PC_ADDR] next_pc;
      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg [`OR10_REG_NUMBER]  src_register;
      reg [`OR10_REG_NUMBER]  gpr1;  // Used here for logging purposes only.
      reg [15:0]              immediate_value;
      reg [DW-1:0]            effective_combined_spr_number;
      reg [4:0]               effective_spr_group;
      reg [10:0]              effective_spr_number;
      reg                     is_invalid_spr_group;
      reg                     is_invalid_spr_number;
      reg                     should_raise_alignment_exception;

      begin
         immediate_value = { wb_dat_i[25:21], wb_dat_i[10:0] };
         src_register    = wb_dat_i[`OR10_IOP_GPR2];
         gpr1            = wb_dat_i[`OR10_IOP_GPR1];

         effective_combined_spr_number = gpr_register_value_read_1 | { 16'b0, immediate_value };
         effective_spr_group           = effective_combined_spr_number[`OR10_SPR_GRP_NUMBER];
         effective_spr_number          = effective_combined_spr_number[`OR10_SPR_REG_NUMBER];

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.mtspr r%0d, r%0d, 0x%04h (effective SPR group %0d, register number %0d, new value 0x%08h)",
                     `OR10_TRACE_PC_VAL,
                     gpr1,
                     src_register,
                     immediate_value,
                     effective_spr_group,
                     effective_spr_number,
                     gpr_register_value_read_2 );

         if ( effective_combined_spr_number[31:16] != 0 )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "%sError decoding instruction l.mtspr: wrong combined SPR number 0x%08h.",
                          TRACE_ASM_INDENT, effective_combined_spr_number );
              raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
           end
         else
           begin
              write_cpu_spr( effective_spr_group,
                             effective_spr_number,
                             gpr_register_value_read_2,
                             is_invalid_spr_group,
                             is_invalid_spr_number,
                             should_raise_alignment_exception,
                             next_pc,
                             next_sr );

              if ( is_invalid_spr_group )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "%sError decoding instruction l.mtspr: wrong SPR group number %0d.",
                               TRACE_ASM_INDENT, effective_spr_group );
                   raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
                end
              else if ( is_invalid_spr_number )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "%sError decoding instruction l.mtspr for group %0d with new value 0x%08h: wrong SPR number %0d.",
                               TRACE_ASM_INDENT, effective_spr_group, gpr_register_value_read_2, effective_spr_number );
                   raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
                end
              else if ( should_raise_alignment_exception )
                begin
                   raise_exception_with_eear( ALIGNMENT_VECTOR_ADDR, cpureg_pc, gpr_register_value_read_2, cpureg_spr_sr, can_interrupt );
                end
           end
      end
   endtask


   task automatic read_spr_sys;  // Special Purpose Registers, System group.

      input reg [10:0]    effective_spr_number;
      output reg [DW-1:0] val;
      output reg          should_raise_range_exception;

      begin
         should_raise_range_exception = 0;

         case ( effective_spr_number )

           `OR1200_SPRGRP_SYS_VR: val = { 8'h12,   // Version 0x12. Not particularly meaningful here, must be >= 0x10 according to the spec.
                                          8'h00,   // Configuration. A value of 0 is probably not OK,  according to the spec it should probably be >= 50.
                                          10'h000, // Reserved bits (with a value of 0).
                                          6'h00    // Revision 0.
                                        };

           `OR1200_SPRGRP_SYS_UPR: val = { 8'h00,  // Custom Units, none present.

                                           12'h000,  // Reserved bits (with a value of 0).

                                           1'b0, // No Floating Point Unit. This bit is not actually defined in the spec,
                                           // and it seems duplicated (see the floating point flag in OR1200_SPRGRP_SYS_CPUCFGR).

                                           ENABLE_TICK_TIMER_UNIT ? 1'b1 : 1'b0, // Tick Timer Unit.

                                           1'b1, // PIC (Programmable Interrupt Controller) Unit.

                                           1'b0, // No Power Management Unit.

                                           1'b0, // No Performance Counters Unit.

                                           ENABLE_DEBUG_UNIT ? 1'b1 : 1'b0, // No Debug Unit.

                                           1'b0, // No MAC instructions.

                                           1'b0, // No Instruction MMU.
                                           1'b0, // No Data MMU.

                                           1'b0, // No Instruction Cache.
                                           1'b0, // No Data Cache.

                                           1'b1  // UPR (Unit Present Register) information is present.
                                         };

           `OR1200_SPRGRP_SYS_CPUCFGR: val = { 21'h000000,  // Reserved bits (with a value of 0).

                                               1'b1,  // ND  bit (position 10): this CPU does not support a jump delay slot (not in the official spec yet).
                                               1'b0,  // No support for some other 64-bit feature.
                                               1'b0,  // No support for some other 64-bit feature.
                                               1'b0,  // No FPU support.
                                               1'b0,  // ORBIS64 instruction set not supported.
                                               1'b1,  // ORBIS32 instruction set supported.
                                               1'b0,  // No custom GPR size (we have the standard 32 registers)
                                               4'h0   // Number of shadow GPRs.
                                             };

           `OR1200_SPRGRP_SYS_NPC:  val = pc_addr_to_32( cpureg_pc );  // Only debuggers should read the PC this way, the OpenRISC specification
                                                                       // states that normal software should use a "jump and link" instruction
                                                                       // so as to get the PC in R9.
           `OR1200_SPRGRP_SYS_SR:   val = cpureg_spr_sr;
           `OR1200_SPRGRP_SYS_EPCR: val = pc_addr_to_32( cpureg_spr_epcr );
           `OR1200_SPRGRP_SYS_EEAR: val = cpureg_spr_eear;
           `OR1200_SPRGRP_SYS_ESR:  val = cpureg_spr_esr;

           default:
             begin
                if ( ENABLE_GPR_ACCESS_OVER_SPR &&
                     effective_spr_number >= `OR1200_SPRGRP_SYS_GPR_BASE &&
                     effective_spr_number <  `OR1200_SPRGRP_SYS_GPR_BASE + GPR_COUNT )
                  begin
                     // The Debug Interface uses this code path in order to read the GPRs,
                     // but note that standard software running on the CPU can do it this way too.
                     val = gpr_register_value_read_1;
                  end
                else
                  begin
                     should_raise_range_exception = 1;
                     val = {DW{1'bx}};
                     `ASSERT_FALSE;
                  end
             end
         endcase
      end
   endtask


   task automatic read_spr_pic;  // Special Purpose Registers, PIC group.

      input reg [10:0]    effective_spr_number;
      output reg [DW-1:0] val;
      output reg          should_raise_range_exception;

      begin
         should_raise_range_exception = 0;

         case ( effective_spr_number )

           `OR1200_PIC_OFS_PICMR: val = cpureg_spr_picmr;
           `OR1200_PIC_OFS_PICSR: val = pic_ints_i;

           default:
             begin
                should_raise_range_exception = 1;
                val = {DW{1'bx}};
             end
         endcase
      end
   endtask


   task automatic read_spr_tt;  // Special Purpose Registers, Tick Timer group.

      input reg [10:0]    effective_spr_number;
      output reg [DW-1:0] val;
      output reg          should_raise_range_exception;

      begin
         should_raise_range_exception = 0;

         case ( effective_spr_number )

           `OR1200_TT_OFS_TTMR: val = cpureg_spr_ttmr;
           `OR1200_TT_OFS_TTCR: val = cpureg_spr_ttcr;

           default:
             begin
                should_raise_range_exception = 1;
                val = {DW{1'bx}};
             end
         endcase
      end
   endtask

   task automatic read_spr_du;  // Special Purpose Registers, Debug Unit group.

      input reg [10:0]    effective_spr_number;
      output reg [DW-1:0] val;
      output reg          should_raise_range_exception;

      reg [10:0]          watchpoint_index;

      begin
         should_raise_range_exception = 0;

         case ( effective_spr_number )

           `OR1200_DU_EDIS: val = { 31'b0, dbg_is_stalled_o };

           // We don't actually need to read from this register, so we could save this logic.
           `OR1200_DU_WRITE_MEM_ADDR: val = pc_addr_to_32( dbg_write_mem_addr );

           `OR1200_DU_DSR:
             begin
                if ( ENABLE_DEBUG_UNIT )
                  begin
                     val = 0;
                     val[ `OR1200_DU_DSR_TE ] = is_trap_debug_unit_enabled;
                  end
                else
                  begin
                     should_raise_range_exception = 1;
                     val = {DW{1'bx}};
                  end
             end

           `OR1200_DU_DRR:
             begin
                val = 0;
                val[ `OR1200_DU_DRR_TE ] = is_stop_reason_trap;
             end

           `OR1200_DU_DMR1:
             begin
                val = 0;
                val[ `OR1200_DU_DMR1_ST ] = stop_at_next_instruction_1;
             end

           `OR1200_DU_WATCHPOINT_COUNT:
             if ( ENABLE_WATCHPOINTS )
               val = WATCHPOINT_COUNT;
             else
               val = 0;

           default:
             if ( ENABLE_WATCHPOINTS &&
                  // effective_spr_number >= `OR1200_DU_DVR0 &&  --> Commented out to prevent warning "Comparison is constant due to unsigned arithmetic"
                  effective_spr_number < `OR1200_DU_DVR0 + WATCHPOINT_COUNT )
               begin
                  watchpoint_index = `OR1200_DU_DVR0 + effective_spr_number;
                  if ( watchpoint_index >= (1<<WATCHPOINT_INDEX_WIDTH) )
                    begin
                       `ASSERT_FALSE;
                    end
                  val = watchpoints[ watchpoint_index[WATCHPOINT_INDEX_WIDTH-1:0] ];
               end
             else
               begin
                  should_raise_range_exception = 1;
                  val = {DW{1'bx}};
               end
         endcase
      end
   endtask


   task automatic read_cpu_spr;

      input reg [4:0]     effective_spr_group;
      input reg [10:0]    effective_spr_number;
      output reg [DW-1:0] val;
      output reg          is_invalid_spr_group;
      output reg          should_raise_range_exception;

      begin
         is_invalid_spr_group = 0;
         should_raise_range_exception = 0;
         val = {DW{1'bx}};

         case ( effective_spr_group )
           `OR1200_SPR_GROUP_SYS: read_spr_sys( effective_spr_number, val, should_raise_range_exception );
           `OR1200_SPR_GROUP_PIC: if ( ENABLE_PIC_UNIT )
                                    read_spr_pic( effective_spr_number, val, should_raise_range_exception );
                                  else
                                    is_invalid_spr_group = 1;
           `OR1200_SPR_GROUP_TT:  if ( ENABLE_TICK_TIMER_UNIT )
                                    read_spr_tt( effective_spr_number, val, should_raise_range_exception );
                                  else
                                    is_invalid_spr_group = 1;
           `OR1200_SPR_GROUP_DU:  read_spr_du( effective_spr_number, val, should_raise_range_exception );

           default:
             is_invalid_spr_group = 1;
         endcase
      end
   endtask


   task automatic execute_mfspr;

      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER] dest_register;
      reg [`OR10_REG_NUMBER] gpr1;  // Used here for logging purposes only.
      reg [15:0]             immediate_value;
      reg [DW-1:0]           effective_combined_spr_number;
      reg [4:0]              effective_spr_group;
      reg [10:0]             effective_spr_number;
      reg [DW-1:0]           val;
      reg                    is_invalid_spr_group;
      reg                    should_raise_range_exception;

      begin
         dest_register    = wb_dat_i[`OR10_IOP_DEST_GPR];
         gpr1             = wb_dat_i[`OR10_IOP_GPR1];
         immediate_value  = wb_dat_i[15:0];

         effective_combined_spr_number = gpr_register_value_read_1 | { 16'b0, immediate_value };
         effective_spr_group  = effective_combined_spr_number[`OR10_SPR_GRP_NUMBER];
         effective_spr_number = effective_combined_spr_number[`OR10_SPR_REG_NUMBER];

         if ( effective_combined_spr_number[31:16] != 0 )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "%sError decoding instruction l.mfspr: wrong SPR register number 0x%08h.",
                          TRACE_ASM_INDENT, effective_combined_spr_number );
              raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
           end
         else
           begin
              // Note that, inn case of exception, the $display call below shows some random value read, which is not quite right,
              // but it does not matter that much.
              read_cpu_spr( effective_spr_group, effective_spr_number, val, is_invalid_spr_group, should_raise_range_exception );

              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: l.mfspr r%0d, r%0d, 0x%04h (effective SPR group %0d, register number %0d, value read 0x%08h)",
                          `OR10_TRACE_PC_VAL,
                          dest_register,
                          gpr1,
                          immediate_value,
                          effective_spr_group,
                          effective_spr_number,
                          val );

              if ( is_invalid_spr_group )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "%sError decoding instruction l.mfspr: wrong SPR group number %0d.",
                               TRACE_ASM_INDENT, effective_spr_group );
                   raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
                end
              else if ( should_raise_range_exception )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "%sError decoding instruction l.mfspr, SPR group number %0d, SPR register number %0d: range exception raised.",
                               TRACE_ASM_INDENT,
                               effective_spr_group,
                               effective_spr_number );
                   raise_exception_without_eear( RANGE_VECTOR_ADDR, cpureg_pc, cpureg_spr_sr, can_interrupt );
                end
              else
                begin
                   schedule_register_write_during_next_cycle( dest_register, val );
                end
           end
      end
   endtask


   task automatic execute_sf;

      inout reg [DW-1:0] next_sr;
      inout reg          can_interrupt;

      reg        is_immediate;
      reg [4:0]  sf_opcode;

      reg [`OR10_REG_NUMBER]  register_a;
      reg [`OR10_REG_NUMBER]  register_b;      // Only for a  register  operand.
      reg [15:0]              immediate_value; // Only for an immediate operand.
      reg [DW-1:0]            val_a;  // For both register or immediate operand, used as an shorter alias.
      reg [DW-1:0]            val_b;  // For both register or immediate operand.

      reg[7 * 8 - 1:0] instruction_name;
      reg              result;

      reg          should_raise_reserved_bits_exception;
      reg          should_raise_illegal_instruction_exception_1;
      reg          should_raise_illegal_instruction_exception_2;

      begin

         register_a = wb_dat_i[`OR10_IOP_GPR1];
         register_b = wb_dat_i[`OR10_IOP_GPR2];
         sf_opcode  = wb_dat_i[25:21];

         should_raise_reserved_bits_exception         = 0;
         should_raise_illegal_instruction_exception_1 = 0;

         case ( wb_dat_i[`OR10_IOP_PREFIX] )
           OR10_INST_SFXX:
             begin
                is_immediate = 0;
                val_b = gpr_register_value_read_2;

                if ( wb_dat_i[10:0] != 0 )
                  should_raise_reserved_bits_exception = 1;
             end
           OR10_INST_SFXXI:
             begin
                is_immediate = 1;
                immediate_value = wb_dat_i[15: 0];
                // Sign-extend the 16-bit value.
                val_b = { {16{immediate_value[15]}}, immediate_value };
             end
           default:
             begin
                should_raise_illegal_instruction_exception_1 = 1;
                is_immediate = 1'bx;
                val_b        = {DW{1'bx}};
             end
         endcase


         if ( should_raise_illegal_instruction_exception_1 )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: Illegal instruction exception raised for unsupported l.sfXX instruction.",
                          `OR10_TRACE_PC_VAL );
              raise_illegal_instruction_exception( can_interrupt );
           end
         else if ( should_raise_reserved_bits_exception )
           raise_reserved_instruction_opcode_bits_exception( can_interrupt );
         else
           begin
              val_a = gpr_register_value_read_1;
              should_raise_illegal_instruction_exception_2 = 0;

              case ( sf_opcode )
                5'b00000:
                  begin
                     instruction_name = {8'h00, "l.sfeq" };
                     result  = ( val_a == val_b ) ? 1'b1 : 1'b0;
                  end

                5'b00001:
                  begin
                     instruction_name = {8'h00, "l.sfne" };
                     result  = ( val_a != val_b ) ? 1'b1 : 1'b0;
                  end

                5'b00010:
                  begin
                     instruction_name = "l.sfgtu";
                     result  = ( val_a > val_b ) ? 1'b1 : 1'b0;
                  end

                5'b00011:
                  begin
                     instruction_name = "l.sfgeu";
                     result  = ( val_a >= val_b ) ? 1'b1 : 1'b0;
                  end

                5'b00100:
                  begin
                     instruction_name = "l.sfltu";
                     result  = ( val_a < val_b ) ? 1'b1 : 1'b0;
                  end

                5'b00101:
                  begin
                     instruction_name = "l.sfleu";
                     result  = ( val_a <= val_b ) ? 1'b1 : 1'b0;
                  end

                5'b01010:
                  begin
                     instruction_name = "l.sfgts";
                     result  = ( $signed(val_a) > $signed(val_b) ) ? 1'b1 : 1'b0;
                  end

                5'b01011:
                  begin
                     instruction_name = "l.sfges";
                     result  = ( $signed(val_a) >= $signed(val_b) ) ? 1'b1 : 1'b0;
                  end

                5'b01100:
                  begin
                     instruction_name = "l.sflts";
                     result  = ( $signed(val_a) < $signed(val_b) ) ? 1'b1 : 1'b0;
                  end

                5'b01101:
                  begin
                     instruction_name = "l.sfles";
                     result  = ( $signed(val_a) <= $signed(val_b) ) ? 1'b1 : 1'b0;
                  end

                default:
                  begin
                     instruction_name = "<none>";  // Prevents C++ compilation warning with Verilator.
                     should_raise_illegal_instruction_exception_2 = 1;
                     result = 1'bx;
                  end
              endcase

              if ( TRACE_ASM_EXECUTION )
                begin
                   if ( is_immediate )
                     $display( "0x%08h: %0si r%0d, 0x%04h (reg val: 0x%08h, immediate: 0x%08h, flag set to %d)",
                               `OR10_TRACE_PC_VAL,
                               instruction_name, register_a, val_b[15:0], val_a, val_b, result );
                   else
                     $display( "0x%08h: %0s r%0d, r%0d (reg val: 0x%08h and 0x%08h, flag set to %d)",
                               `OR10_TRACE_PC_VAL,
                               instruction_name, register_a, register_b, val_a, val_b, result );
                end

              if ( should_raise_illegal_instruction_exception_2 )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for unsupported l.sfXX instruction.",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
              else
                next_sr[`OR1200_SR_F] = result;
           end
      end
   endtask


   task automatic check_zero_jump_offset;
      input reg [25:0] jump_offset;
      begin
         // Note that this error only triggers during simulation, the real hardware will ignore it.
         if ( jump_offset == 0 && ENABLE_ASSERT_ON_ZERO_INSTRUCTION_OPCODE )
           begin
              $display( "A jump or branch instruction with an zero offset was found at address 0x%08h, which jumps to itself causing an infinite loop. While perfectly legal, the instruction opcode is 0x00000000, which normally means the CPU has wandered into an empty memory area due to a software bug.",
                        `OR10_TRACE_PC_VAL );
              `ASSERT_FALSE;
           end
      end
   endtask


   task automatic execute_j;

      input reg             is_jal;  // As opposed to instruction "l.j".
      inout [`OR10_PC_ADDR] next_pc;

      reg [25:0]          jump_offset;
      reg [`OR10_PC_ADDR] jump_target;
      reg [AW-1:0]        workaround_verilator_bug;

      begin
         jump_offset = wb_dat_i[25:0];

         check_zero_jump_offset( jump_offset );

         jump_target = cpureg_pc + { {4{jump_offset[25]}}, jump_offset };

         if ( is_jal )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: l.jal 0x%08h (target addr 0x%08h)",
                          `OR10_TRACE_PC_VAL, jump_offset, pc_addr_to_32(jump_target) );

              next_pc = jump_target;
              schedule_register_write_during_next_cycle( LINK_REGISTER_R9, pc_addr_to_32( cpureg_pc + 1 ) );
           end
         else
           begin
              if ( TRACE_ASM_EXECUTION )
                begin
                   workaround_verilator_bug = pc_addr_to_32(jump_target);
                   $display( "0x%08h: l.j 0x%08h (target addr 0x%08h)",
                             `OR10_TRACE_PC_VAL, jump_offset, workaround_verilator_bug );
                end
              next_pc = jump_target;
           end
      end
   endtask


   task automatic execute_bf;

      input reg             is_bnf;  // As opposed to instruction "l.bf".
      inout [`OR10_PC_ADDR] next_pc;

      reg [25:0]          jump_offset;
      reg [`OR10_PC_ADDR] jump_target;
      reg [AW-1:0]        workaround_verilator_bug;

      begin
         jump_offset = wb_dat_i[25:0];

         // The l.bf and l.bnf instructions do not have an opcode of 0,
         // so this check does not really help catch software bugs at here.
         //   check_zero_jump_offset( jump_offset );

         jump_target = cpureg_pc + { {4{jump_offset[25]}}, jump_offset };

         if ( is_bnf )
           begin
              if ( ! cpureg_spr_sr[`OR1200_SR_F] )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: l.bnf 0x%08h (target addr 0x%08h) (jump taken)",
                               `OR10_TRACE_PC_VAL, jump_offset, pc_addr_to_32( jump_target ) );

                   next_pc = jump_target;
                end
              else
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: l.bnf 0x%08h (target addr 0x%08h) (jump not taken)",
                               `OR10_TRACE_PC_VAL, jump_offset, pc_addr_to_32( jump_target ) );
                end
           end
         else
           begin
              if ( cpureg_spr_sr[`OR1200_SR_F] )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: l.bf 0x%08h (target addr 0x%08h) (jump taken)",
                               `OR10_TRACE_PC_VAL, jump_offset, pc_addr_to_32( jump_target ) );

                   next_pc = jump_target;
                end
              else
                begin
                   if ( TRACE_ASM_EXECUTION )
                     begin
                        workaround_verilator_bug = pc_addr_to_32( jump_target );
                        $display( "0x%08h: l.bf 0x%08h (target addr 0x%08h) (jump not taken)",
                                  `OR10_TRACE_PC_VAL,
                                  jump_offset,
                                  workaround_verilator_bug );
                     end
                end
           end
      end
   endtask


   task automatic execute_jr;

      input reg             is_jalr;  // As opposed to just "l.jr".
      inout [`OR10_PC_ADDR] next_pc;
      inout reg             can_interrupt;

      reg [`OR10_REG_NUMBER] register_number;
      reg [`OR10_PC_ADDR]    jump_target;
      reg [AW-1:0]           workaround_verilator_bug;

      begin
         if ( wb_dat_i[25:16] != 0 ||
              wb_dat_i[10: 0] != 0 )
           begin
              raise_reserved_instruction_opcode_bits_exception( can_interrupt );
           end
         else
           begin
              register_number = wb_dat_i[`OR10_IOP_GPR2];

              if ( is_jalr && register_number == LINK_REGISTER_R9 )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: Illegal instruction exception raised for l.jalr r9 (r9 is illegal as it is the link register).",
                               `OR10_TRACE_PC_VAL );
                   raise_illegal_instruction_exception( can_interrupt );
                end
              else
                begin
                   if ( !is_addr_aligned( gpr_register_value_read_2 ) )
                     begin
                        raise_exception_with_eear( ALIGNMENT_VECTOR_ADDR, cpureg_pc, gpr_register_value_read_2, cpureg_spr_sr, can_interrupt );
                     end
                   else
                     begin
                        jump_target = addr_32_to_pc( gpr_register_value_read_2 );

                        if ( is_jalr )
                          begin
                             if ( TRACE_ASM_EXECUTION )
                               begin
                                  workaround_verilator_bug = pc_addr_to_32( jump_target );
                                  $display( "0x%08h: l.jalr r%0d (target addr 0x%08h)",
                                            `OR10_TRACE_PC_VAL, register_number, workaround_verilator_bug );
                               end

                             next_pc = jump_target;
                             schedule_register_write_during_next_cycle( LINK_REGISTER_R9, pc_addr_to_32( cpureg_pc + 1 ) );
                          end
                        else
                          begin
                             if ( TRACE_ASM_EXECUTION )
                               begin
                                  workaround_verilator_bug = pc_addr_to_32( jump_target );
                                  $display( "0x%08h: l.jr r%0d (target addr 0x%08h)",
                                            `OR10_TRACE_PC_VAL, register_number, workaround_verilator_bug );
                               end

                             next_pc = jump_target;
                          end
                     end
                end
           end
      end
   endtask


   task automatic execute_rfe;

      inout [`OR10_PC_ADDR] next_pc;
      inout reg [DW-1:0] next_sr;

      begin
         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.rfe", `OR10_TRACE_PC_VAL );

         // Note that cpureg_spr_epcr does not have the last 2 bits and therefore is always aligned.
         next_pc = cpureg_spr_epcr;
         next_sr = cpureg_spr_esr;
      end
   endtask


   task automatic execute_sw;

      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER]  data_register;
      reg [`OR10_REG_NUMBER]  base_addr_register;
      reg [15:0]              offset;
      reg [AW-1:0]            effective_addr;

      begin

         base_addr_register = wb_dat_i[`OR10_IOP_GPR1];
         data_register      = wb_dat_i[`OR10_IOP_GPR2];
         offset             = { wb_dat_i[25:21],  wb_dat_i[10:0] };

         // Add the sign-extended offset.
         effective_addr = gpr_register_value_read_1 + { {16{offset[15]}} , offset };

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.sw 0x%04h(r%0d), r%0d (effective addr 0x%08h, value 0x%08h)",
                     `OR10_TRACE_PC_VAL,
                     offset,
                     base_addr_register,
                     data_register,
                     effective_addr,
                     gpr_register_value_read_2 );

         if ( !is_addr_aligned( effective_addr ) )
           begin
              raise_exception_with_eear( ALIGNMENT_VECTOR_ADDR, cpureg_pc, effective_addr, cpureg_spr_sr, can_interrupt );
           end
         else
           begin
              start_wishbone_data_write_cycle( effective_addr,
                                               gpr_register_value_read_2,
                                               {WISHBONE_SEL_WIDTH{1'b1}},
                                               0,
                                               can_interrupt );
           end
      end
   endtask


   task automatic execute_sb;

      inout can_interrupt;

      reg [`OR10_REG_NUMBER]  data_register;
      reg [`OR10_REG_NUMBER]  base_addr_register;
      reg [15:0]              offset;
      reg [AW-1:0]            effective_addr;
      reg [DW-1:0]            data;

      begin
         base_addr_register = wb_dat_i[`OR10_IOP_GPR1];
         data_register      = wb_dat_i[`OR10_IOP_GPR2];
         offset             = { wb_dat_i[25:21],  wb_dat_i[10:0] };

         // Add the sign-extended offset.
         effective_addr = gpr_register_value_read_1 + { {16{offset[15]}} , offset };

         `UNIQUE case ( effective_addr[1:0] )
                   2'b00: data = { gpr_register_value_read_2[7:0], 24'hxxxxxx };
                   2'b01: data = { 8'hxx, gpr_register_value_read_2[7:0], 16'hxxxx };
                   2'b10: data = { 16'hxxxx, gpr_register_value_read_2[7:0], 8'hxx };
                   2'b11: data = { 24'hxxxxxx, gpr_register_value_read_2[7:0] };
                 endcase

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.sb 0x%04h(r%0d), r%0d (effective addr 0x%08h, value 0x%02h)",
                     `OR10_TRACE_PC_VAL,
                     offset,
                     base_addr_register,
                     data_register,
                     effective_addr,
                     data[7:0] );

         start_wishbone_data_write_cycle( effective_addr,
                                          data,
                                          wishbone_byte_sel_from_addr( effective_addr[1:0] ),
                                          0,
                                          can_interrupt );
      end
   endtask


   task automatic execute_sh;

      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER]  data_register;
      reg [`OR10_REG_NUMBER]  base_addr_register;
      reg [15:0]              offset;
      reg [AW-1:0]            effective_addr;
      reg [DW-1:0]            data;
      reg                     should_raise_alignment_exception;

      begin
         base_addr_register = wb_dat_i[`OR10_IOP_GPR1];
         data_register      = wb_dat_i[`OR10_IOP_GPR2];
         offset             = { wb_dat_i[25:21], wb_dat_i[10:0] };

         effective_addr = gpr_register_value_read_1 + { {16{offset[15]}} , offset };

         case ( effective_addr[1:0] )
           2'b00:
             begin
                data = { gpr_register_value_read_2[15:0], 16'hxxxx };
                should_raise_alignment_exception = 0;
             end
           2'b10:
             begin
                data = { 16'hxxxx, gpr_register_value_read_2[15:0] };
                should_raise_alignment_exception = 0;
             end
           default:
             begin
                should_raise_alignment_exception = 1;
                data = 0;  // The trace below will display wrong data, but that does not matter that much.
             end
         endcase

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: l.sh 0x%04h(r%0d), r%0d (effective addr 0x%08h, value 0x%04h)",
                     `OR10_TRACE_PC_VAL,
                     offset,
                     base_addr_register,
                     data_register,
                     effective_addr,
                     data[15:0] );

         if ( should_raise_alignment_exception )
           raise_exception_with_eear( ALIGNMENT_VECTOR_ADDR, cpureg_pc, effective_addr, cpureg_spr_sr, can_interrupt );
         else
           start_wishbone_data_write_cycle( effective_addr,
                                            data,
                                            wishbone_half_word_sel_from_addr( effective_addr[1:0] ),
                                            0,
                                            can_interrupt );
      end
   endtask


   task automatic execute_lwz_lws;

      input reg is_lwz;  // As opposed to l.lws.
      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER]  base_addr_register;
      reg [15:0]              offset;
      reg [`OR10_REG_NUMBER]  dest_register;
      reg [AW-1:0]            effective_addr;

      begin
         // On 32-bit CPU implementations like this one, these 2 instructions
         // should be called l.lw and not l.lws or l.lwz, as the 's' and 'z' suffix do nothing.
         // The zero- or sign-extension would only happen on 64-bit CPU implementations.

         base_addr_register = wb_dat_i[`OR10_IOP_GPR1];
         dest_register      = wb_dat_i[`OR10_IOP_DEST_GPR];
         offset             = wb_dat_i[15:0];

         // Add the sign-extended offset.
         effective_addr = gpr_register_value_read_1 + { {16{offset[15]}} , offset };

         if ( TRACE_ASM_EXECUTION )
           $display( "0x%08h: %0s r%0d, 0x%04h(r%0d) (effective addr 0x%08h)",
                     `OR10_TRACE_PC_VAL,
                     is_lwz ? "l.lwz" : "l.lws",
                     dest_register,
                     offset,
                     base_addr_register,
                     effective_addr );

         if ( !is_addr_aligned( effective_addr ) )
           raise_exception_with_eear( ALIGNMENT_VECTOR_ADDR, cpureg_pc, effective_addr, cpureg_spr_sr, can_interrupt );
         else
           start_wishbone_data_read_cycle( effective_addr,
                                           {WISHBONE_SEL_WIDTH{1'b1}},
                                           dest_register,
                                           0,
                                           WOPW_32,
                                           can_interrupt );
      end
   endtask


   task automatic execute_lbz_lbs;
      input reg is_lbz;  // As opposed to lbs.
      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER]  base_addr_register;
      reg [15:0]              offset;
      reg [`OR10_REG_NUMBER]  dest_register;
      reg [AW-1:0]            effective_addr;
      reg [5 * 8 - 1:0]       instruction_name;

      begin
         base_addr_register = wb_dat_i[`OR10_IOP_GPR1];
         dest_register      = wb_dat_i[`OR10_IOP_DEST_GPR];
         offset             = wb_dat_i[15:0];

         effective_addr = gpr_register_value_read_1 + { {16{offset[15]}} , offset };

         if ( TRACE_ASM_EXECUTION )
           begin
              instruction_name = is_lbz ? "l.lbz" : "l.lbs";

              $display( "0x%08h: %0s r%0d, 0x%04h(r%0d) (effective addr 0x%08h)",
                        `OR10_TRACE_PC_VAL,
                        instruction_name,
                        dest_register,
                        offset,
                        base_addr_register,
                        effective_addr );
           end

         start_wishbone_data_read_cycle( effective_addr,
                                         wishbone_byte_sel_from_addr( effective_addr[1:0] ), // {WISHBONE_SEL_WIDTH{1'b1}},
                                         dest_register,
                                         0,
                                         is_lbz ? WOPW_8_Z : WOPW_8_S,
                                         can_interrupt );
      end
   endtask


   task automatic execute_lhz_lhs;

      input reg is_lhz;  // As opposed to lbs.
      inout reg can_interrupt;

      reg [`OR10_REG_NUMBER]  base_addr_register;
      reg [15:0] offset;
      reg [`OR10_REG_NUMBER]  dest_register;
      reg [AW-1:0] effective_addr;
      reg [5 * 8 - 1:0] instruction_name;

      begin
         base_addr_register = wb_dat_i[`OR10_IOP_GPR1];
         dest_register      = wb_dat_i[`OR10_IOP_DEST_GPR];
         offset             = wb_dat_i[15:0];

         // Add the sign-extended offset.
         effective_addr = gpr_register_value_read_1 + { {16{offset[15]}} , offset };

         if ( TRACE_ASM_EXECUTION )
           begin
              instruction_name = is_lhz ? "l.lhz" : "l.lhs";

              $display( "0x%08h: %0s r%0d, 0x%04h(r%0d) (effective addr 0x%08h)",
                        `OR10_TRACE_PC_VAL,
                        instruction_name,
                        dest_register,
                        offset,
                        base_addr_register,
                        effective_addr );
           end

         // The effective address must be half-word aligned.
         if ( effective_addr[0] != 0 )
           raise_exception_with_eear( ALIGNMENT_VECTOR_ADDR, cpureg_pc, effective_addr, cpureg_spr_sr, can_interrupt );
         else
           start_wishbone_data_read_cycle( effective_addr,
                                           wishbone_half_word_sel_from_addr( effective_addr[1:0] ),  // {WISHBONE_SEL_WIDTH{1'b1}}
                                           dest_register,
                                           0,
                                           is_lhz ? WOPW_16_Z : WOPW_16_S,
                                           can_interrupt );
      end
   endtask


   // ----------------- State machine logic -----------------

   task automatic complete_wishbone_data_read_cycle;
      reg [DW-1:0] result;
      begin
         case ( wishdat_load_op_type )
           WOPW_32:
             begin
                result = wb_dat_i;
                // $display( "Wishbone data read cycle complete, result: 0x%08h", result );
             end

           WOPW_8_Z, WOPW_8_S:
             begin
                `UNIQUE case ( wishdat_addr[1:0] )
                          2'b00: result = { 24'h000000, wb_dat_i[31:24] };
                          2'b01: result = { 24'h000000, wb_dat_i[23:16] };
                          2'b10: result = { 24'h000000, wb_dat_i[15: 8] };
                          2'b11: result = { 24'h000000, wb_dat_i[ 7: 0] };
                        endcase

                // Sign-extend if necessary.
                if ( wishdat_load_op_type == WOPW_8_S )
                  result[31:8] = {24{result[7]}};
             end

           WOPW_16_Z, WOPW_16_S:
             begin
                case ( wishdat_addr[1:0] )
                  2'b00: result = { 16'h0000, wb_dat_i[31:16] };
                  2'b10: result = { 16'h0000, wb_dat_i[15: 0] };
                  default:
                    begin
                       `ASSERT_FALSE;
                       result = {DW{1'bx}};
                    end
                endcase

                // Sign-extend if necessary.
                if ( wishdat_load_op_type == WOPW_16_S )
                  result[31:16] = {16{result[15]}};
             end

           default:
             begin
                `ASSERT_FALSE;
                result = {DW{1'bx}};
             end
         endcase

         schedule_register_write_during_next_cycle( wishdat_dest_gpr, result );
      end
   endtask


   task automatic execute_instruction;

      inout [`OR10_PC_ADDR] next_pc;
      inout [DW-1:0]        next_sr;
      inout                 can_interrupt;

      reg [5:0] instruction_opcode_prefix;
      reg       should_raise_illegal_exception;

      begin
         instruction_opcode_prefix = wb_dat_i[`OR10_IOP_PREFIX];

         should_raise_illegal_exception = 0;

         case ( instruction_opcode_prefix )
           OR10_INST_BF:    execute_bf( 0, next_pc );
           OR10_INST_BNF:   execute_bf( 1, next_pc );
           OR10_INST_J:     execute_j( 0, next_pc );
           OR10_INST_JAL:   execute_j( 1, next_pc );
           OR10_INST_JR:    execute_jr( 0, next_pc, can_interrupt );
           OR10_INST_JALR:  execute_jr( 1, next_pc, can_interrupt );
           OR10_INST_ADDI:  execute_add_instruction( OR10_ADDINST_ADDI , next_sr, can_interrupt );
           OR10_INST_ADDIC: execute_add_instruction( OR10_ADDINST_ADDIC, next_sr, can_interrupt );
           OR10_INST_SB:    execute_sb( can_interrupt );
           OR10_INST_SH:    execute_sh( can_interrupt );
           OR10_INST_SW:    execute_sw( can_interrupt );
           OR10_INST_LBZ:   execute_lbz_lbs( 1, can_interrupt );
           OR10_INST_LBS:   execute_lbz_lbs( 0, can_interrupt );
           OR10_INST_LHZ:   execute_lhz_lhs( 1, can_interrupt );
           OR10_INST_LHS:   execute_lhz_lhs( 0, can_interrupt );
           OR10_INST_LWZ:   execute_lwz_lws( 1, can_interrupt );
           OR10_INST_LWS:   execute_lwz_lws( 0, can_interrupt );
           OR10_INST_MTSPR: execute_mtspr( next_pc, next_sr, can_interrupt );
           OR10_INST_MFSPR: execute_mfspr( can_interrupt );
           OR10_INST_RFE:   execute_rfe( next_pc, next_sr );
           OR10_INST_NOP:       execute_nop( can_interrupt );
           OR10_INST_MOVHI:     execute_movhi( can_interrupt );
           OR10_INST_PREFIX_38: execute_prefix_38_instruction( next_sr, can_interrupt );
           OR10_INST_ORI:       execute_ori;
           OR10_INST_MULI:      if ( ENABLE_INSTRUCTION_MUL ) execute_mul_instruction( 0, 1, next_sr, can_interrupt ); else should_raise_illegal_exception = 1;
           OR10_INST_SYS_TRAP:  execute_sys_trap( can_interrupt );
           OR10_INST_ANDI:      execute_andi;
           OR10_INST_XORI:      execute_xori;
           OR10_INST_SHIFT_I:   execute_shift_instruction_immediate( can_interrupt );
           OR10_INST_SFXX, OR10_INST_SFXXI: execute_sf( next_sr, can_interrupt );

           default: should_raise_illegal_exception = 1;
         endcase

         if ( should_raise_illegal_exception )
           begin
              if ( TRACE_ASM_EXECUTION )
                $display( "0x%08h: Illegal instruction exception raised for 6-bit instruction_opcode_prefix=0x%02h.",
                          `OR10_TRACE_PC_VAL, instruction_opcode_prefix );
              raise_illegal_instruction_exception( can_interrupt );
           end
      end
   endtask


   task automatic update_tick_timer;
      reg match;
      reg increment;

      begin
         // $display( "Timer counter: 0x%08h", cpureg_spr_ttcr );

         match = ( cpureg_spr_ttmr[`OR1200_TT_TTMR_TP] == cpureg_spr_ttcr[`OR1200_TT_TTMR_TP] ) ? 1'b1 : 1'b0;

         `UNIQUE case ( cpureg_spr_ttmr[`OR1200_TT_TTMR_M] )
                   2'b00:
                     begin
                        // Tick Timer disabled.
                        increment = 0;
                     end
                   2'b01:
                     begin
                        // Timer is restarted when TTMR[TP] matches TTCR[TP]
                        if ( match )
                          begin
                             increment = 0;
                             cpureg_spr_ttcr[`OR1200_TT_TTMR_TP] <= 0;
                          end
                        else
                          begin
                             increment = 1;
                          end
                     end
                   2'b10:
                     begin
                        // Timer stops when TTMR[TP] matches TTCR[27:0] (change TTCR to resume counting).
                        // Note that the OpenRISC specification states that the timer cannot be restarted
                        // by changing the value in TTCR. However, both the OR1200 implementation and this one
                        // differ in this point from the specification.
                        increment = ~match;
                     end
                   2'b11:
                     begin
                        // Timer does not stop when TTMR[TP] matches TTCR[27:0].
                        increment = 1;
                     end
                 endcase

         if ( increment )
           cpureg_spr_ttcr <= cpureg_spr_ttcr + 1;

         // Set the Interrupt Pending bit if the timer counter matches.
	     if ( cpureg_spr_ttmr[`OR1200_TT_TTMR_IE] )
	       cpureg_spr_ttmr[`OR1200_TT_TTMR_IP] <= cpureg_spr_ttmr[`OR1200_TT_TTMR_IP] | match;
      end
   endtask


   task check_interrupt;

      input [`OR10_PC_ADDR] next_pc;
      input [DW-1:0]        next_sr;
      inout                 was_interrupt_triggered;

      reg can_interrupt_ignored;  // The value placed here is ignored in this task.

      begin
         can_interrupt_ignored = 1;

         // Note that the order of the following 'if' statements determine the interrupt priority.

         if ( ENABLE_PIC_UNIT &&
              cpureg_spr_sr[ `OR1200_SR_IEE ] &&
              0 != ( pic_ints_i & cpureg_spr_picmr ) )
           begin
              raise_exception_without_eear( EXTERNAL_INTERRUPT_VECTOR_ADDR, next_pc, next_sr, can_interrupt_ignored );
              was_interrupt_triggered = 1;
           end
         else if ( cpureg_spr_sr[ `OR1200_SR_TEE ] &&
                   0 != cpureg_spr_ttmr[`OR1200_TT_TTMR_IP] )
           begin
              raise_exception_without_eear( TICK_TIMER_VECTOR_ADDR, next_pc, next_sr, can_interrupt_ignored );
              was_interrupt_triggered = 1;
           end
         else
           begin
              was_interrupt_triggered = 0;
           end
      end
   endtask


   task automatic do_state_reset;
      integer watchpoint_index;
      begin
         // On FPGAs, the reset signal 'wb_rst_i' might be hard-wired to 0 in an 'initial' section
         // and most of the reset logic could be optimised away by the synthesiser. However, we still need
         // a STATE_RESET state in case the wb_rst_i is actually used. The Wishbone B4 specification states
         // that wb_cyc_o and wb_stb_o must be deasserted following a reset, so we cannot start a new Wishbone
         // transaction immediately upon receiving a reset indication, we have to wait for the next clock cycle
         // where reset is not asserted any more.
         //
         // In order to help the FPGA synthesiser optimise as much reset logic as possible away,
         // we could move most of the initialisation statements below to an 'initial' section.
         // If the reset signal is actually used, we would need to initialise the same values
         // again in a separate "if ( wb_rst_i )" statement.
         //
         // If you modify this code, keep in mind that the GdbToJtagBridge tool manually resets the CPU
         // by writing to SPRs, so that tool may need to be modified too.

         cpureg_spr_sr   <= RESET_SPR_SR;

         // The exception registers should be initialised to 0 according to the OpenRISC spec,
         // although it probably does not matter.
         cpureg_spr_epcr <= 0;
         cpureg_spr_eear <= 0;
         cpureg_spr_esr  <= 0;

         cpureg_spr_picmr <= 0;

         cpureg_spr_ttmr <= 0;
         cpureg_spr_ttcr <= 0;

         is_trap_debug_unit_enabled <= 0;
         is_stop_reason_trap <= 0;
         stop_at_next_instruction_1 <= 0;
         stop_at_next_instruction_2 <= 0;

         dbg_is_stalled_o <= 0;

         for ( watchpoint_index = 0; watchpoint_index < WATCHPOINT_COUNT; watchpoint_index = watchpoint_index + 1 )
           watchpoints[ watchpoint_index ] <= 0;


         // If we catch a reset signal, make sure the external divider does not start taking new data randomly.
         div_din_tvalid <= 1;

         // Note that the General Purpose Registers are not cleared at this point.
         // According to the OpenRISC specification, it is not necessary to initialise them.

         // Note also that anything not initialised here may hold old values,
         // which constitutes a security risk: after a reset the software could read
         // the register values from the previous run.

         // We are not going to react to any pending interrupts before the first fetch,
         // but that does not really matter, as all interrupts are disabled at this stage.

         start_wishbone_instruction_fetch_cycle( RESET_VECTOR );
      end
   endtask

   task automatic stop_debug_transaction;
      begin
         dbg_ack_o  <= 0;
         dbg_data_o <= {DW{1'bx}};
      end
   endtask

   task automatic do_state_debug_waiting_for_ack_assert;
      begin
         // We could abort here a little earlier if synchronised_dbg_stb_i is not longer asserted.
         dbg_ack_o <= 1;

         current_state <= STATE_DEBUG_WAITING_FOR_STB_DEASSERT;
      end
   endtask


   task automatic do_state_debug_waiting_for_stb_deassert;
      begin
         if ( !synchronised_dbg_stb_i )
           begin
              stop_debug_transaction;

              if ( dbg_is_stalled_o )
                begin
                   // This is a probably-unnecessary optimisation. We could let the CPU issue
                   // the next instruction fetch, and then it will check the "is stalled" flag
                   // and stall itself there.
                   current_state <= STATE_DEBUG_STALLED;
                end
              else
                begin
                   start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc ) );
                end
           end
      end
   endtask


   task automatic do_state_debug_waiting_for_reg_file_read;

      reg [DW-1:0]        spr_val;
      reg                 spr_is_invalid_spr_group;
      reg                 spr_should_raise_range_exception;
      reg                 error_flag;

      begin
         read_cpu_spr( dbg_spr_number_i[`OR10_SPR_GRP_NUMBER],
                       dbg_spr_number_i[`OR10_SPR_REG_NUMBER],
                       spr_val,
                       spr_is_invalid_spr_group,
                       spr_should_raise_range_exception );

         error_flag = spr_is_invalid_spr_group || spr_should_raise_range_exception;

         if ( TRACE_DEBUG_INTERFACE )
           $display( "%sDebug Interface SPR read: SPR group number: %0d, SPR register number: %0d, value read: 0x%08h, error: %1d",
                     TRACE_ASM_INDENT,
                     dbg_spr_number_i[`OR10_SPR_GRP_NUMBER],
                     dbg_spr_number_i[`OR10_SPR_REG_NUMBER],
                     spr_val,
                     error_flag );

         dbg_data_o <= spr_val;
         dbg_err_o  <= error_flag;

         current_state <= STATE_DEBUG_WAITING_FOR_ACK_ASSERT;
      end
   endtask


   task automatic start_debug_interface_operation;

      reg [`OR10_PC_ADDR] next_pc;
      reg [DW-1:0] next_sr;

      reg          is_invalid_spr_group;
      reg          is_invalid_spr_number;
      reg          should_raise_alignment_exception;

      reg          can_interrupt_ignored;  // The value placed here is ignored in this task.
      reg          error_flag;

      begin
         can_interrupt_ignored = 1;

         if ( dbg_we_i )
           begin
              if ( dbg_spr_number_i[`OR10_SPR_GRP_NUMBER] == `OR1200_SPR_GROUP_DU &&
                   dbg_spr_number_i[`OR10_SPR_REG_NUMBER] == `OR1200_DU_READ_MEM_ADDR )
                begin
                  if ( TRACE_DEBUG_INTERFACE )
                    $display( "%sDebug Interface Wishbone read from memory address 0x%08h.",
                              TRACE_ASM_INDENT,
                              dbg_data_i );

                   start_wishbone_data_read_cycle( dbg_data_i,
                                                   {WISHBONE_SEL_WIDTH{1'b1}},
                                                   {GPR_NUMBER_WIDTH{1'bx}},
                                                   1,
                                                   WOPW_32,
                                                   can_interrupt_ignored );
                end
              else if ( dbg_spr_number_i[`OR10_SPR_GRP_NUMBER] == `OR1200_SPR_GROUP_DU &&
                        dbg_spr_number_i[`OR10_SPR_REG_NUMBER] == `OR1200_DU_WRITE_MEM_DATA )
                begin
                   if ( TRACE_DEBUG_INTERFACE )
                    $display( "%sDebug Interface Wishbone write to memory address 0x%08h, data 0x%08h.",
                              TRACE_ASM_INDENT,
                              pc_addr_to_32( dbg_write_mem_addr ),
                              dbg_data_i );

                   start_wishbone_data_write_cycle( pc_addr_to_32( dbg_write_mem_addr ),
                                                    dbg_data_i,
                                                    {WISHBONE_SEL_WIDTH{1'b1}},
                                                    1,
                                                    can_interrupt_ignored );
                end
              else
                begin
                   // An SPR write operation can start straight away.

                   next_sr = cpureg_spr_sr;
                   next_pc = cpureg_pc;

                   write_cpu_spr( dbg_spr_number_i[`OR10_SPR_GRP_NUMBER],
                                  dbg_spr_number_i[`OR10_SPR_REG_NUMBER],
                                  dbg_data_i,
                                  is_invalid_spr_group,
                                  is_invalid_spr_number,
                                  should_raise_alignment_exception,
                                  next_pc,
                                  next_sr );

                   cpureg_spr_sr <= next_sr;
                   cpureg_pc     <= next_pc;

                   error_flag = is_invalid_spr_group || is_invalid_spr_number || should_raise_alignment_exception;

                   if ( TRACE_DEBUG_INTERFACE )
                     $display( "%sDebug Interface SPR write: SPR group number: %0d, SPR register number: %0d, SPR value: 0x%08h, error: %1d",
                               TRACE_ASM_INDENT,
                               dbg_spr_number_i[`OR10_SPR_GRP_NUMBER],
                               dbg_spr_number_i[`OR10_SPR_REG_NUMBER],
                               dbg_data_i,
                               error_flag );

                   dbg_data_o <= {DW{1'bx}};
                   dbg_err_o  <= error_flag;

                   current_state <= STATE_DEBUG_WAITING_FOR_ACK_ASSERT;
                end
           end
         else
           begin
              // The tracing is done a little later, in STATE_DEBUG_WAITING_FOR_REG_FILE_READ,
              // where the value read is known.

              // Delay the reading in order to keep the Register File's address logic simple.
              current_state <= STATE_DEBUG_WAITING_FOR_REG_FILE_READ;
           end
      end
   endtask


   task automatic do_state_debug_stalled;
      begin
        if ( synchronised_dbg_stb_i )
          start_debug_interface_operation;
        else if ( !dbg_is_stalled_o )
          begin
             start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc ) );
          end
     end
   endtask


   task automatic check_debug_unit_operation_start;

      inout   is_debug_unit_active;

      integer watchpoint_index;

      begin
         if ( synchronised_dbg_stb_i )
           begin
              start_debug_interface_operation;
              stop_at_next_instruction_2 <= 0;
              is_debug_unit_active = 1;
           end
         else if ( dbg_is_stalled_o )
           begin
              // We never hit this code path with JTAG, as the stall register is set
              // over the Debug Interface, which goes to STATE_STALL directly afterwards
              // without coming back to STATE_WAITING_FOR_INSTRUCTION_FETCH.
              // However, the software might write to the stall register too, which
              // would then make the CPU land here. Whether the software should be allowed
              // so stall the CPU in this way is another interesting question. After all,
              // there is already the "l.trap" way.
              current_state <= STATE_DEBUG_STALLED;
              stop_at_next_instruction_2 <= 0;
              is_debug_unit_active = 1;
           end
         else
           begin
              // According to the OpenRISC specification, hardware breakpoints are only enabled if
              // bit WGB in DMR2 is set. However, it is a waste of FPGA resources to implement DMR2
              // just for that reason, so we are reusing bit `OR1200_DU_DSR_TE here.
              //
              // Don't check hardware breakpoints if we are single-stepping. That allows the user
              // to single-step out of a hardware breakpoint that has just been hit.

              if ( ENABLE_WATCHPOINTS && is_trap_debug_unit_enabled && !stop_at_next_instruction_1 )
                for ( watchpoint_index = 0; watchpoint_index < WATCHPOINT_COUNT; watchpoint_index = watchpoint_index + 1 )
                  begin
                     if ( addr_32_to_pc( watchpoints[ watchpoint_index ] ) == cpureg_pc )
                       begin
                          if ( TRACE_ASM_EXECUTION )
                            $display( "0x%08h: The CPU has been stalled by watchpoint %0d.", `OR10_TRACE_PC_VAL, watchpoint_index );

                          is_stop_reason_trap <= 1;
                          dbg_is_stalled_o <= 1;
                          current_state <= STATE_DEBUG_STALLED;
                          stop_at_next_instruction_2 <= 0;
                          is_debug_unit_active = 1;
                       end
                  end
           end
      end
   endtask


   task automatic do_state_sleep;

      reg is_debug_unit_active;
      reg was_interrupt_triggered_ignored;  // Ignored in this task.

      begin
         is_debug_unit_active = 0;

         check_debug_unit_operation_start( is_debug_unit_active );

         if ( !is_debug_unit_active )
           begin
              was_interrupt_triggered_ignored = 0;
              // The "cpureg_pc + 1" makes the CPU skip the current l.sleep instruction
              // after the interrupt has been processed.
              check_interrupt( cpureg_pc + 1, cpureg_spr_sr, was_interrupt_triggered_ignored );
           end
      end
   endtask


   task automatic do_state_waiting_for_instruction_fetch;

      // If we raise an interrupt exception after executing a jump or an arithmetic instruction,
      // we need the new PC and SR values. See comment in the "Exception management" section
      // about why we need to pass these variables around all over the place.
      reg [`OR10_PC_ADDR] next_pc;
      reg [DW-1:0]        next_sr;
      reg                 can_interrupt;

      reg                 is_debug_unit_active;
      reg                 was_interrupt_triggered;

      begin
         // Checking for Debug Interface operations here wastes the instruction opcode just fetched,
         // as we'll have to fetch it again in the future. However, if the exception vector
         // happens to lie on an invalid memory address, we want the Debug Interface to be able to stop
         // the CPU even if it is caught in a [fetch, wishbone bus error, fetch] infinite loop.

         is_debug_unit_active = 0;

         if ( ENABLE_DEBUG_UNIT && ( wb_ack_i || wb_err_i || wb_rty_i ) )
           begin
              if ( stop_at_next_instruction_2 )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "0x%08h: The CPU has been stalled by the single-step mode after executing one instruction.", `OR10_TRACE_PC_VAL );

                   dbg_is_stalled_o <= 1;
                   stop_at_next_instruction_2 <= 0;
                   current_state <= STATE_DEBUG_STALLED;
                   is_debug_unit_active = 1;
                end
              else
                begin
                   check_debug_unit_operation_start( is_debug_unit_active );
                end
           end

         if ( !is_debug_unit_active )
           begin
              can_interrupt = 1;

              if ( wb_ack_i )
                begin
                   stop_at_next_instruction_2 <= stop_at_next_instruction_1;

                   // $display( "Read instruction opcode: 0x%08h", wb_dat_i );
                   next_pc = cpureg_pc + 1'b1;
                   next_sr = cpureg_spr_sr;

                   execute_instruction( next_pc, next_sr, can_interrupt );

                   cpureg_spr_sr <= next_sr;

                   if ( can_interrupt )
                     begin
                        was_interrupt_triggered = 0;
                        check_interrupt( next_pc, next_sr, was_interrupt_triggered );
                        if ( !was_interrupt_triggered )
                          start_wishbone_instruction_fetch_cycle( pc_addr_to_32( next_pc ) );
                     end
                   else
                     begin
                        // If we cannot interrupt at this point, the next instruction fetch has already been issued,
                        // or the current instruction is issuing a Wishbone data read or write.
                        // In any case, we don't need to do anything else here.
                     end
                end
              else if ( wb_err_i )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "%sWishbone wb_err_i bus error at address 0x%08h during a Wishbone instruction fetch cycle.",
                               TRACE_ASM_INDENT,
                               pc_addr_to_32( cpureg_pc ) );
                   raise_exception_with_eear( BUS_ERROR_VECTOR_ADDR, cpureg_pc, pc_addr_to_32( cpureg_pc ), cpureg_spr_sr, can_interrupt );
                end
              else if ( wb_rty_i )
                begin
                   if ( TRACE_ASM_EXECUTION )
                     $display( "%sWishbone wb_rty_i bus error at address 0x%08h during a Wishbone instruction fetch cycle.",
                               TRACE_ASM_INDENT,
                               pc_addr_to_32( cpureg_pc ) );
                   raise_exception_with_eear( BUS_ERROR_VECTOR_ADDR, cpureg_pc, pc_addr_to_32( cpureg_pc ), cpureg_spr_sr, can_interrupt );
                end
              else
                begin
                   // We must keep Wishbone signals in the same state until we get an answer.
                   start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc ) );
                end
           end
      end
   endtask


   task do_state_waiting_for_wishbone_data_cycle;

      reg can_interrupt_ignored;  // Ignored in this task.
      reg was_interrupt_triggered;

      begin
         can_interrupt_ignored = 1;  // The value in this variable gets ignored in this task.

        if ( wb_ack_i )
          begin
             if ( wishdat_write_enable )
               begin
                  // $display( "Wishbone write operation complete.");
               end
             else
               begin
                  // The instruction trace already printed did not contain the value read from memory,
                  // as it was not available at the time. Print it now, as it's quite handy for debugging purposes.
                  if ( TRACE_ASM_EXECUTION )
                    $display( "%sWishbone read operation complete, register R%0d set with value read of 0x%08h.",
                              TRACE_ASM_INDENT,
                              wishdat_dest_gpr,
                              wb_dat_i  );

                  complete_wishbone_data_read_cycle;
               end

             was_interrupt_triggered = 0;
             check_interrupt( cpureg_pc + 1, cpureg_spr_sr, was_interrupt_triggered );
             if ( !was_interrupt_triggered )
               start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc + 1 ) );
          end
        else if ( wb_err_i )
          begin
             if ( TRACE_ASM_EXECUTION )
               $display( "%sWishbone wb_err_i bus error at address 0x%08h during a Wishbone data cycle.",
                         TRACE_ASM_INDENT,
                         wishdat_addr );
             raise_exception_with_eear( BUS_ERROR_VECTOR_ADDR, cpureg_pc, wishdat_addr, cpureg_spr_sr, can_interrupt_ignored );
          end
        else if ( wb_rty_i )
          begin
             if ( TRACE_ASM_EXECUTION )
               $display( "%sWishbone wb_rty_i bus error at address 0x%08h during a Wishbone data cycle.",
                         TRACE_ASM_INDENT,
                         wishdat_addr );
             raise_exception_with_eear( BUS_ERROR_VECTOR_ADDR, cpureg_pc, wishdat_addr, cpureg_spr_sr, can_interrupt_ignored );
          end
        else
          begin
             // We must keep Wishbone signals in the same state until we get an answer.
             keep_wishbone_data_cycle;
          end
     end
   endtask


   task automatic do_state_shifting;

      reg [DW-1:0] res;
      reg          was_interrupt_triggered;

      begin
         res = {DW{1'bx}};  // Place this before the 'case' statement to prevent a C++ compilation warning with Verilator.

         `UNIQUE case ( shift_operation )

           OR10_SHIFTINST_SLL, OR10_SHIFTINST_SLLI:  res = shift_result << 1;
           OR10_SHIFTINST_SRL, OR10_SHIFTINST_SRLI:  res = shift_result >> 1;
           OR10_SHIFTINST_SRA, OR10_SHIFTINST_SRAI:  res = $signed(shift_result) >>> 1;
           OR10_SHIFTINST_ROR, OR10_SHIFTINST_RORI:
             if ( ENABLE_INSTRUCTION_ROR )
               begin
                  res = shift_result >> 1;
                  res[DW-1] = shift_result[0];
               end
             else
               begin
                  `ASSERT_FALSE;
               end
         endcase

         if ( shift_bit_count == 5'b1 )
           begin
              schedule_register_write_during_next_cycle( shift_dest_reg, res );

             if ( TRACE_ASM_EXECUTION )
               $display( "%sShift/Rotate instruction result: 0x%08h.",
                         TRACE_ASM_INDENT,
                         res );

             was_interrupt_triggered = 0;
             check_interrupt( cpureg_pc + 1, cpureg_spr_sr, was_interrupt_triggered );
             if ( !was_interrupt_triggered )
               start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc + 1 ) );

              shift_result    <= {DW{1'bx}};
              shift_bit_count <= {5{1'bx}};
           end
         else
           begin
              shift_result    <= res;
              shift_bit_count <= shift_bit_count - 5'b1;
           end
      end
   endtask


   task automatic do_state_multiplying;

      reg [DW-1:0] next_sr;
      reg          can_interrupt;
      reg          was_interrupt_triggered;

      begin
         /*
         $display("Result: 0x%08h * 0x%08h = 0x%016h, delay left: %0d",
                  muldiv_operand_a,
                  muldiv_operand_b,
                  muldiv_result,
                  muldiv_mul_delay );
         */

         if ( mul_delay == 0 )
           begin
              mul_delay <= {4{1'bx}};  // We don't need the counter any more.

              next_sr = cpureg_spr_sr;

              calculate_multiplication_carry_overflow( muldiv_is_unsigned, mul_result, next_sr );

              cpureg_spr_sr <= next_sr;

              schedule_register_write_during_next_cycle( muldiv_dest_reg, mul_result[DW-1:0] );

              if ( TRACE_ASM_EXECUTION )
                $display( "%sMultiplication instruction result: 0x%08h * 0x%08h = 0x%08h, CY=%d, OV=%d.",
                          TRACE_ASM_INDENT,
                          muldiv_operand_a[DW-1:0],
                          muldiv_operand_b[DW-1:0],
                          mul_result[DW-1:0],
                          next_sr[ `OR1200_SR_CY ],
                          next_sr[ `OR1200_SR_OV ] );

              can_interrupt = 1;

              raise_ov_range_exception_if_necessary( next_sr, can_interrupt );

              if ( can_interrupt )
                begin
                   was_interrupt_triggered = 0;
                   check_interrupt( cpureg_pc + 1, next_sr, was_interrupt_triggered );
                   if ( !was_interrupt_triggered )
                     start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc + 1 ) );
                end
              else
                begin
                   // An exception has been raised, so we don't need to do anything else here.
                end
           end
         else
           begin
              mul_delay <= mul_delay - 4'b1;
           end
      end
   endtask


   task automatic do_state_dividing;

      reg [DW:0]   result33;
      reg [DW-1:0] remainder32;
      reg          prevent_unused_warning_with_verilator;

      reg          was_interrupt_triggered;

      begin
         prevent_unused_warning_with_verilator = &{ 1'b0,
                                                    div_dout_tdata[79:73],
                                                    div_dout_tdata[39:32],
                                                    1'b0 };
         remainder32 = div_dout_tdata[DW-1:0];
         result33    = div_dout_tdata[72:40];

         /*
         $display("Result: 0x%08h / 0x%08h = 0x%8h (remainder 0x%08h for debug only), result available: %0d, tready a: %0d, tready b: %0d",
                  muldiv_operand_a,
                  muldiv_operand_b,
                  result33[DW-1:0],
                  remainder32,
                  div_dout_tvalid,
                  div_tready_a,
                  div_tready_b );
          */

         // div_tready_a and div_tready_b should actually be the same signal.
         if ( div_tready_a != div_tready_b )
           begin
              `ASSERT_FALSE;
           end

         if ( div_tready_a )
           begin
              if ( div_din_tvalid == 0 )
              begin
                 `ASSERT_FALSE;
              end

              div_din_tvalid <= 0;
           end


         if ( div_dout_tvalid )
           begin
              // If I have understood 2's complement correctly, we only need sign extension
              // for unsigned 32-bit numbers. Check that the results match the expectations.
              if ( muldiv_is_unsigned )
                begin
                   if ( result33[DW] != 0 )
                     begin
                        `ASSERT_FALSE;
                     end
                end
              else
                begin
                   if ( result33[DW] != result33[DW-1] )
                     begin
                        `ASSERT_FALSE;
                     end
                end

              schedule_register_write_during_next_cycle( muldiv_dest_reg, result33[DW-1:0] );

              if ( TRACE_ASM_EXECUTION )
                $display( "%sDivision instruction result: 0x%08h / 0x%08h = 0x%08h (remainder 0x%08h for debug only), CY=0, OV=0.",
                          TRACE_ASM_INDENT,
                          muldiv_operand_a[DW-1:0],
                          muldiv_operand_b[DW-1:0],
                          result33[DW-1:0],
                          remainder32 );

              was_interrupt_triggered = 0;
              check_interrupt( cpureg_pc + 1, cpureg_spr_sr, was_interrupt_triggered );
              if ( !was_interrupt_triggered )
                start_wishbone_instruction_fetch_cycle( pc_addr_to_32( cpureg_pc + 1 ) );
           end
      end
   endtask


   task automatic do_state_debug_waiting_for_wishbone_debug_interface_cycle;
      begin
        if ( wb_ack_i )
          begin
             if ( wishdat_write_enable )
               begin
                  // $display( "Debug Interface Wishbone write operation complete." );
                  dbg_data_o    <= {DW{1'bx}};
                  dbg_err_o     <= 0;
                  current_state <= STATE_DEBUG_WAITING_FOR_ACK_ASSERT;
               end
             else
               begin
                  // The instruction trace already printed did not contain the value read from memory,
                  // as it was not available at the time. Print it now, as it's quite handy for debugging purposes.
                  if ( TRACE_DEBUG_INTERFACE )
                    $display( "%sDebug Interface Wishbone read operation complete, the value read is 0x%08h.",
                              TRACE_ASM_INDENT,
                              wb_dat_i  );

                  dbg_data_o    <= wb_dat_i;
                  dbg_err_o     <= 0;
                  current_state <= STATE_DEBUG_WAITING_FOR_ACK_ASSERT;
               end
          end
        else if ( wb_err_i )
          begin
             if ( TRACE_ASM_EXECUTION )
               $display( "%sWishbone wb_err_i bus error at address 0x%08h during a Debug Interface Wishbone cycle.",
                         TRACE_ASM_INDENT,
                         wishdat_addr );
             dbg_data_o    <= {DW{1'bx}};
             dbg_err_o     <= 1;
             current_state <= STATE_DEBUG_WAITING_FOR_ACK_ASSERT;
          end
        else if ( wb_rty_i )
          begin
             if ( TRACE_ASM_EXECUTION )
               $display( "%sWishbone wb_rty_i bus error at address 0x%08h during a Debug Interface Wishbone cycle.",
                         TRACE_ASM_INDENT,
                         wishdat_addr );
             dbg_data_o    <= {DW{1'bx}};
             dbg_err_o     <= 1;
             current_state <= STATE_DEBUG_WAITING_FOR_ACK_ASSERT;
          end
        else
          begin
             // We must keep Wishbone signals in the same state until we get an answer.
             keep_wishbone_data_cycle;
          end
      end
   endtask


   task automatic step_state_machine;
      begin
         // Do not update the Tick Timer if the CPU is stalled. That helps
         // when debugging software which makes use of the Tick Timer.
         if ( ENABLE_TICK_TIMER_UNIT && current_state != STATE_RESET && ( !ENABLE_DEBUG_UNIT || current_state != STATE_DEBUG_STALLED ) )
           update_tick_timer;

         case ( current_state )

           STATE_RESET:                            do_state_reset;
           STATE_WAITING_FOR_INSTRUCTION_FETCH:    do_state_waiting_for_instruction_fetch;
           STATE_WAITING_FOR_WISHBONE_DATA_CYCLE:  do_state_waiting_for_wishbone_data_cycle;
           STATE_SLEEP:                            do_state_sleep;
           STATE_SHIFTING:                         if ( ENABLE_SERIAL_SHIFTER )      do_state_shifting;               else begin `ASSERT_FALSE; end
           STATE_MULTIPLYING:                      if ( ENABLE_EXTERNAL_MULTIPLIER ) do_state_multiplying;            else begin `ASSERT_FALSE; end
           STATE_DIVIDING:                         if ( ENABLE_EXTERNAL_DIVIDER    ) do_state_dividing;               else begin `ASSERT_FALSE; end
           STATE_DEBUG_WAITING_FOR_ACK_ASSERT:     if ( ENABLE_DEBUG_UNIT ) do_state_debug_waiting_for_ack_assert;    else begin `ASSERT_FALSE; end
           STATE_DEBUG_WAITING_FOR_STB_DEASSERT:   if ( ENABLE_DEBUG_UNIT ) do_state_debug_waiting_for_stb_deassert;  else begin `ASSERT_FALSE; end
           STATE_DEBUG_WAITING_FOR_REG_FILE_READ:  if ( ENABLE_DEBUG_UNIT ) do_state_debug_waiting_for_reg_file_read; else begin `ASSERT_FALSE; end
           STATE_DEBUG_STALLED:                    if ( ENABLE_DEBUG_UNIT ) do_state_debug_stalled;                   else begin `ASSERT_FALSE; end
           STATE_DEBUG_WAITING_FOR_WISHBONE_DEBUG_INTERFACE_CYCLE:  if ( ENABLE_DEBUG_UNIT ) do_state_debug_waiting_for_wishbone_debug_interface_cycle; else begin `ASSERT_FALSE; end

           default:
             begin
                `ASSERT_FALSE;
             end
         endcase
      end
   endtask


   initial
     begin
        // On FPGAs the reset signal may not be necessary and could be optimised away
        // by setting 'wb_rst_i' to a constant 0. These starting values make sure that
        // everything is initialised correctly on start-up.
        current_state = STATE_RESET;
        wb_cyc_o = 0;
        wb_stb_o = 0;
        gpr_write_enable_1 = 0;  // May not be actually necessary.
        dbg_ack_o = 0;
        div_din_tvalid = 0;    // Prevent that the external divider starts dividing immediately.
        muldiv_operand_a = 0;  // Initialised to zero to prevent assert in FakeExternalComponents/or10_external_multiplier.v when not multiplying.
        muldiv_operand_b = 0;
     end


   // ---- This is the "entry point", the "main" routine of this Verilog core ----

   always @( posedge wb_clk_i )
     begin
        // $display( "%s< CPU clock tick begin, state %0d, reset %d >", TRACE_ASM_INDENT, current_state, wb_rst_i );

        // If the Wishbone signals are not overwritten below,
        // the default is to stop any previous bus transaction.
        // This also helps in the reset case below, as wb_cyc_o and wb_stb_o must be deasserted following a reset.
        stop_wishbone_cycle;

        // The register file does not write by default, or, if it was writing anything on the last cycle,
        // it should stop it now. Note that this can be overwritten down the line, see
        // task 'schedule_register_write_during_next_cycle'.
        stop_register_file_write_operation;

        if ( wb_rst_i )
          current_state <= STATE_RESET;
        else
          step_state_machine();

        `IF_ICARUS_FLUSH_DISPLAY_OUTPUT;

        // $display( "%s< CPU clock tick end, state %0d >", TRACE_ASM_INDENT, current_state );
     end

   always @( synchronised_dbg_stb_i )  // The @(*) syntax does not work with Icarus Verilog (as of Sep 2012) if ENABLE_DEBUG_UNIT is set.
     begin
        if ( !ENABLE_DEBUG_UNIT )
          begin
             // This logic may waste a little bit of FPGA resources,
             // but it helps detect errors when the client tries to use a disabled
             // debug interface. dbg_ack_o must be tied to dbg_stb_i, becuase
             // the client waits for dbg_ack_o to be deasserted before starting a transaction.
             dbg_ack_o  = synchronised_dbg_stb_i;
             dbg_err_o  = 1;
             dbg_data_o = {DW{1'bx}};
          end
     end

endmodule
