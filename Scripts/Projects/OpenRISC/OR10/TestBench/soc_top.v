
/* SoC for the OR10 CPU, designed to run the Test Suite.

   Copyright (C) 2011, Raul Fajardo, rfajardo@gmail.com
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

`include "or1200_defines.v"


module soc_top ( input wire         wb_clk_i,
                 input wire         wb_rst_i,

                 // ------ UART Wishbone signals ------
                 output wire [31:0] wb_uart_dat_o,
                 input wire [31:0]  wb_uart_dat_i,
                 output wire [23:0] wb_uart_adr_o,
                 output wire [3:0]  wb_uart_sel_o,
                 output wire        wb_uart_we_o,
                 output wire        wb_uart_cyc_o,
                 output wire        wb_uart_stb_o,
                 input wire         wb_uart_ack_i,
                 input wire         wb_uart_err_i,
                 input wire         uart_int_i,

                 // ------ Ethernet Wishbone signals ------
                 output wire [31:0] wb_eth_dat_o,
                 input wire [31:0]  wb_eth_dat_i,
                 output wire [31:0] wb_eth_adr_o,
                 output wire [3:0]  wb_eth_sel_o,
                 output wire        wb_eth_we_o,
                 output wire        wb_eth_cyc_o,
                 output wire        wb_eth_stb_o,
                 input wire         wb_eth_ack_i,
                 input wire         wb_eth_err_i,

                 input wire [31:0]  wb_ethm_adr_i,
                 output wire [31:0] wb_ethm_dat_o,
                 input wire [31:0]  wb_ethm_dat_i,
                 input wire [3:0]   wb_ethm_sel_i,
                 input wire         wb_ethm_we_i,
                 input wire         wb_ethm_stb_i,
                 input wire         wb_ethm_cyc_i,
                 output wire        wb_ethm_ack_o,
                 output wire        wb_ethm_err_o,

                 input wire         eth_int_i,

                 // ------ JTAG Debug Interface ------
                 input wire         jtag_tck_i,
                 input wire         jtag_tdi_i,

                 input wire         is_tap_state_test_logic_reset_i,
                 input wire         is_tap_state_shift_dr_i,
                 input wire         is_tap_state_update_dr_i,
                 input wire         is_tap_current_instruction_debug_i,
                 output wire        debug_tdo_o
               );

   parameter MEMORY_FILENAME = "";
   parameter integer MEMORY_FILESIZE = 0;
   parameter GET_MEMORY_FILENAME_FROM_SIM_ARGS = 0;
   parameter MEMORY_ADR_WIDTH = 2;

   // CPU Wishbone bus.
   wire [31:0]  wb_cpu_adr_o;
   wire         wb_cpu_cyc_o;
   wire [31:0]  wb_cpu_dat_i;
   wire [31:0]  wb_cpu_dat_o;
   wire [3:0]   wb_cpu_sel_o;
   wire         wb_cpu_ack_i;
   wire         wb_cpu_err_i;
   wire         wb_cpu_rty_i = 1'b0;
   wire         wb_cpu_we_o;
   wire         wb_cpu_stb_o;

   // SRAM controller Wishbone bus
   wire [31:0]  wb_ss_dat_to_sram;
   wire [31:0]  wb_ss_dat_from_sram;
   wire [31:0]  wb_ss_adr;
   wire [3:0]   wb_ss_sel;
   wire         wb_ss_we;
   wire         wb_ss_cyc;
   wire         wb_ss_stb;
   wire         wb_ss_ack;
   wire         wb_ss_err;


   // If you update this list, remember to update the APP_INT_REST_x constants below.
   localparam APP_INT_UART = 2;
   localparam APP_INT_ETH  = 4;

   reg [31:0] pic_ints;

   always @(*)
     begin
        pic_ints = 0;
        pic_ints[APP_INT_ETH  ] = eth_int_i;
        pic_ints[APP_INT_UART ] = uart_int_i;
     end


   // CPU debug interface.
   wire [15:0] cpu_dbg_spr_number;
   wire [31:0] cpu_dbg_data_to_cpu;
   wire [31:0] cpu_dbg_data_from_cpu;
   wire        cpu_dbg_stb;
   wire        cpu_dbg_we;
   wire        cpu_dbg_ack;
   wire        cpu_dbg_err;
   wire        cpu_dbg_is_stalled;

   or10_top
    #(
       // The test suite checks all corner cases and needs these asserts turned off.
       .ENABLE_ASSERT_ON_ATYPICAL_EXCEPTIONS( 0 )
     )
   or10_top_instance
    (
     .wb_clk_i  ( wb_clk_i ),
     .wb_rst_i  ( wb_rst_i ),
     .wb_cyc_o  ( wb_cpu_cyc_o ),
     .wb_adr_o  ( wb_cpu_adr_o ),
     .wb_dat_i  ( wb_cpu_dat_i ),
     .wb_dat_o  ( wb_cpu_dat_o ),
     .wb_sel_o  ( wb_cpu_sel_o ),
     .wb_ack_i  ( wb_cpu_ack_i ),
     .wb_err_i  ( wb_cpu_err_i ),
     .wb_rty_i  ( wb_cpu_rty_i ),
     .wb_we_o   ( wb_cpu_we_o  ),
     .wb_stb_o  ( wb_cpu_stb_o ),

     .pic_ints_i( pic_ints ),

     .dbg_spr_number_i( cpu_dbg_spr_number ),
     .dbg_data_i      ( cpu_dbg_data_to_cpu ),
     .dbg_data_o      ( cpu_dbg_data_from_cpu ),
     .dbg_stb_i       ( cpu_dbg_stb ),
     .dbg_we_i        ( cpu_dbg_we ),
     .dbg_ack_o       ( cpu_dbg_ack ),
     .dbg_err_o       ( cpu_dbg_err ),
     .dbg_is_stalled_o( cpu_dbg_is_stalled )
   );


   `ifdef __ICARUS__
     generic_single_port_synchronous_ram_32_simulation_only
   `else
     generic_single_port_synchronous_ram_32
   `endif
     #(
      .ADR_WIDTH( MEMORY_ADR_WIDTH ),
      .MEMORY_FILENAME( MEMORY_FILENAME ),
      .MEMORY_FILESIZE( MEMORY_FILESIZE ),
      .GET_MEMORY_FILENAME_FROM_SIM_ARGS( GET_MEMORY_FILENAME_FROM_SIM_ARGS )
     )
   soc_memory (

    // WISHBONE common
    .wb_clk_i( wb_clk_i ),
    .wb_rst_i( wb_rst_i ),

    // WISHBONE slave
    .wb_dat_i( wb_ss_dat_to_sram ),
    .wb_dat_o( wb_ss_dat_from_sram ),
    .wb_adr_i( wb_ss_adr ),
    .wb_sel_i( wb_ss_sel ),
    .wb_we_i ( wb_ss_we  ),
    .wb_cyc_i( wb_ss_cyc ),
    .wb_stb_i( wb_ss_stb ),
    .wb_ack_o( wb_ss_ack ),
    .wb_err_o( wb_ss_err )
   );


   // Address map (most of it not used by the Test Suite).
  `define APP_ADDR_DEC_W      8
  `define APP_ADDR_SRAM       `APP_ADDR_DEC_W'h00
  `define APP_ADDR_FLASH      `APP_ADDR_DEC_W'h04
  `define APP_ADDR_DECP_W     4
  `define APP_ADDR_PERIP      `APP_ADDR_DECP_W'h9
  `define APP_ADDR_SPI        `APP_ADDR_DEC_W'h97
  `define APP_ADDR_ETH        `APP_ADDR_DEC_W'h92
  `define APP_ADDR_AUDIO      `APP_ADDR_DEC_W'h9d
  `define APP_ADDR_UART       `APP_ADDR_DEC_W'h90
  `define APP_ADDR_PS2        `APP_ADDR_DEC_W'h94
  `define APP_ADDR_JSP        `APP_ADDR_DEC_W'h9e
  `define APP_ADDR_RES2       `APP_ADDR_DEC_W'h9f

   wire [31:0] wb_uart_adr_o_32;  // The upper byte [31:24] is always `APP_ADDR_UART.
   assign wb_uart_adr_o = wb_uart_adr_o_32[23:0];

   wire prevent_unused_warning_with_verilator = &{ 1'b0,
                                                   wb_uart_adr_o_32[31:24],
                                                   1'b0 };

   // Note that the MinSoC Wishbone switch is known to hand when accessing invalid addresses.
   localparam USE_MINSOC_TC = 0;

   generate if ( USE_MINSOC_TC )
     begin

        // Given that the OR10 CPU has only one Wishbone interface,
        // we could use a simpler Wishbone Traffic Switch (Interconnect).
        minsoc_tc_top #( .t0_addr_w( `APP_ADDR_DEC_W ),
                         .t0_addr( `APP_ADDR_FLASH ),
                         .t1_addr_w( `APP_ADDR_DEC_W ),
                         .t1_addr( `APP_ADDR_SRAM ),
                         .t28c_addr_w( `APP_ADDR_DECP_W ),
                         .t28_addr( `APP_ADDR_PERIP ),
                         .t28i_addr_w( `APP_ADDR_DEC_W ),
                         .t2_addr( `APP_ADDR_SPI ),
                         .t3_addr( `APP_ADDR_ETH ),
                         .t4_addr( `APP_ADDR_AUDIO ),
                         .t5_addr( `APP_ADDR_UART ),
                         .t6_addr( `APP_ADDR_PS2 ),
                         .t7_addr( `APP_ADDR_JSP ),
                         .t8_addr( `APP_ADDR_RES2 )
                         ) tc_top (

                                   // WISHBONE common
                                   .wb_clk_i   ( wb_clk_i ),
                                   .wb_rst_i   ( wb_rst_i ),

                                   // WISHBONE Initiator 0 (unused)
                                   // Initiator 0 has the highest priority.
                                   .i0_wb_cyc_i    ( 1'b0 ),
                                   .i0_wb_stb_i    ( 1'b0 ),
                                   .i0_wb_adr_i    ( 32'h0000_0000 ),
                                   .i0_wb_sel_i    ( 4'b0000 ),
                                   .i0_wb_we_i     ( 1'b0 ),
                                   .i0_wb_dat_i    ( 32'h0000_0000 ),
                                   .i0_wb_dat_o    ( ),
                                   .i0_wb_ack_o    ( ),
                                   .i0_wb_err_o    ( ),

                                   // WISHBONE Initiator 1 (Ethernet Wishbone master for DMA transfers).
                                   // This master should generally have a higher priority than the CPU or it may never get hold of the bus for its DMA transfers.
                                   .i1_wb_cyc_i    ( wb_ethm_cyc_i ),
                                   .i1_wb_stb_i    ( wb_ethm_stb_i ),
                                   .i1_wb_adr_i    ( wb_ethm_adr_i ),
                                   .i1_wb_sel_i    ( wb_ethm_sel_i ),
                                   .i1_wb_we_i     ( wb_ethm_we_i  ),
                                   .i1_wb_dat_i    ( wb_ethm_dat_i ),
                                   .i1_wb_dat_o    ( wb_ethm_dat_o ),
                                   .i1_wb_ack_o    ( wb_ethm_ack_o ),
                                   .i1_wb_err_o    ( wb_ethm_err_o ),

                                   // WISHBONE Initiator 2 (unused)
                                   .i2_wb_cyc_i    ( 1'b0 ),
                                   .i2_wb_stb_i    ( 1'b0 ),
                                   .i2_wb_adr_i    ( 32'h0000_0000 ),
                                   .i2_wb_sel_i    ( 4'b0000 ),
                                   .i2_wb_we_i     ( 1'b0 ),
                                   .i2_wb_dat_i    ( 32'h0000_0000 ),
                                   .i2_wb_dat_o    ( ),
                                   .i2_wb_ack_o    ( ),
                                   .i2_wb_err_o    ( ),

                                   // WISHBONE Initiator 3 (unused)
                                   .i3_wb_cyc_i    ( 1'b0 ),
                                   .i3_wb_stb_i    ( 1'b0 ),
                                   .i3_wb_adr_i    ( 32'h0000_0000 ),
                                   .i3_wb_sel_i    ( 4'b0000 ),
                                   .i3_wb_we_i     ( 1'b0 ),
                                   .i3_wb_dat_i    ( 32'h0000_0000 ),
                                   .i3_wb_dat_o    ( ),
                                   .i3_wb_ack_o    ( ),
                                   .i3_wb_err_o    ( ),

                                   // WISHBONE Initiator 4 (unused)
                                   .i4_wb_cyc_i    ( 1'b0 ),
                                   .i4_wb_stb_i    ( 1'b0 ),
                                   .i4_wb_adr_i    ( 32'h0000_0000 ),
                                   .i4_wb_sel_i    ( 4'b0000 ),
                                   .i4_wb_we_i     ( 1'b0 ),
                                   .i4_wb_dat_i    ( 32'h0000_0000 ),
                                   .i4_wb_dat_o    ( ),
                                   .i4_wb_ack_o    ( ),
                                   .i4_wb_err_o    ( ),

                                   // WISHBONE Initiator 5 (the OR10 CPU)
                                   .i5_wb_cyc_i    ( wb_cpu_cyc_o ),
                                   .i5_wb_stb_i    ( wb_cpu_stb_o ),
                                   .i5_wb_adr_i    ( wb_cpu_adr_o ),
                                   .i5_wb_sel_i    ( wb_cpu_sel_o ),
                                   .i5_wb_we_i     ( wb_cpu_we_o  ),
                                   .i5_wb_dat_i    ( wb_cpu_dat_o ),
                                   .i5_wb_dat_o    ( wb_cpu_dat_i ),
                                   .i5_wb_ack_o    ( wb_cpu_ack_i ),
                                   .i5_wb_err_o    ( wb_cpu_err_i ),

                                   // WISHBONE Initiator 6 (unused)
                                   .i6_wb_cyc_i    ( 1'b0 ),
                                   .i6_wb_stb_i    ( 1'b0 ),
                                   .i6_wb_adr_i    ( 32'h0000_0000 ),
                                   .i6_wb_sel_i    ( 4'b0000 ),
                                   .i6_wb_we_i     ( 1'b0 ),
                                   .i6_wb_dat_i    ( 32'h0000_0000 ),
                                   .i6_wb_dat_o    ( ),
                                   .i6_wb_ack_o    ( ),
                                   .i6_wb_err_o    ( ),

                                   // WISHBONE Initiator 7 (unused)
                                   .i7_wb_cyc_i    ( 1'b0 ),
                                   .i7_wb_stb_i    ( 1'b0 ),
                                   .i7_wb_adr_i    ( 32'h0000_0000 ),
                                   .i7_wb_sel_i    ( 4'b0000 ),
                                   .i7_wb_we_i     ( 1'b0 ),
                                   .i7_wb_dat_i    ( 32'h0000_0000 ),
                                   .i7_wb_dat_o    ( ),
                                   .i7_wb_ack_o    ( ),
                                   .i7_wb_err_o    ( ),

                                   // WISHBONE Target 0 (unused)
                                   // NOTE: This target has its own bus and can be accessed in parallel
                                   //       to the other targets. Left unconnected in the hope that the synthesis tool
                                   //       will optimise the bus completely away.
                                   .t0_wb_cyc_o    ( ),
                                   .t0_wb_stb_o    ( ),
                                   .t0_wb_adr_o    ( ),
                                   .t0_wb_sel_o    ( ),
                                   .t0_wb_we_o     ( ),
                                   .t0_wb_dat_o    ( ),
                                   .t0_wb_dat_i    ( 32'h0000_0000 ),
                                   .t0_wb_ack_i    ( 1'b0 ),
                                   .t0_wb_err_i    ( 1'b1 ),

                                   // WISHBONE Target 1 - SRAM controller
                                   .t1_wb_cyc_o    ( wb_ss_cyc ),
                                   .t1_wb_stb_o    ( wb_ss_stb ),
                                   .t1_wb_adr_o    ( wb_ss_adr ),
                                   .t1_wb_sel_o    ( wb_ss_sel ),
                                   .t1_wb_we_o     ( wb_ss_we  ),
                                   .t1_wb_dat_o    ( wb_ss_dat_to_sram ),
                                   .t1_wb_dat_i    ( wb_ss_dat_from_sram ),
                                   .t1_wb_ack_i    ( wb_ss_ack ),
                                   .t1_wb_err_i    ( wb_ss_err ),

                                   // WISHBONE Target 2 (unused)
                                   .t2_wb_cyc_o    ( ),
                                   .t2_wb_stb_o    ( ),
                                   .t2_wb_adr_o    ( ),
                                   .t2_wb_sel_o    ( ),
                                   .t2_wb_we_o     ( ),
                                   .t2_wb_dat_o    ( ),
                                   .t2_wb_dat_i    ( 32'h0000_0000 ),
                                   .t2_wb_ack_i    ( 1'b0 ),
                                   .t2_wb_err_i    ( 1'b1 ),

                                   // WISHBONE Target 3 (Ethernet)
                                   .t3_wb_cyc_o    ( wb_eth_cyc_o ),
                                   .t3_wb_stb_o    ( wb_eth_stb_o ),
                                   .t3_wb_adr_o    ( wb_eth_adr_o ),
                                   .t3_wb_sel_o    ( wb_eth_sel_o ),
                                   .t3_wb_we_o     ( wb_eth_we_o  ),
                                   .t3_wb_dat_o    ( wb_eth_dat_o ),
                                   .t3_wb_dat_i    ( wb_eth_dat_i ),
                                   .t3_wb_ack_i    ( wb_eth_ack_i ),
                                   .t3_wb_err_i    ( wb_eth_err_i ),

                                   // WISHBONE Target 4 (unused)
                                   .t4_wb_cyc_o    ( ),
                                   .t4_wb_stb_o    ( ),
                                   .t4_wb_adr_o    ( ),
                                   .t4_wb_sel_o    ( ),
                                   .t4_wb_we_o     ( ),
                                   .t4_wb_dat_o    ( ),
                                   .t4_wb_dat_i    ( 32'h0000_0000 ),
                                   .t4_wb_ack_i    ( 1'b0 ),
                                   .t4_wb_err_i    ( 1'b1 ),

                                   // WISHBONE Target 5 (UART)
                                   .t5_wb_cyc_o    ( wb_uart_cyc_o ),
                                   .t5_wb_stb_o    ( wb_uart_stb_o ),
                                   .t5_wb_adr_o    ( wb_uart_adr_o_32 ),
                                   .t5_wb_sel_o    ( wb_uart_sel_o ),
                                   .t5_wb_we_o     ( wb_uart_we_o  ),
                                   .t5_wb_dat_o    ( wb_uart_dat_o ),
                                   .t5_wb_dat_i    ( wb_uart_dat_i ),
                                   .t5_wb_ack_i    ( wb_uart_ack_i ),
                                   .t5_wb_err_i    ( wb_uart_err_i ),

                                   // WISHBONE Target 6 (unused)
                                   .t6_wb_cyc_o    ( ),
                                   .t6_wb_stb_o    ( ),
                                   .t6_wb_adr_o    ( ),
                                   .t6_wb_sel_o    ( ),
                                   .t6_wb_we_o     ( ),
                                   .t6_wb_dat_o    ( ),
                                   .t6_wb_dat_i    ( 32'h0000_0000 ),
                                   .t6_wb_ack_i    ( 1'b0 ),
                                   .t6_wb_err_i    ( 1'b1 ),

                                   // WISHBONE Target 7 (unused)
                                   .t7_wb_cyc_o    ( ),
                                   .t7_wb_stb_o    ( ),
                                   .t7_wb_adr_o    ( ),
                                   .t7_wb_sel_o    ( ),
                                   .t7_wb_we_o     ( ),
                                   .t7_wb_dat_o    ( ),
                                   .t7_wb_dat_i    ( 32'h0000_0000 ),
                                   .t7_wb_ack_i    ( 1'b0 ),
                                   .t7_wb_err_i    ( 1'b1 ),

                                   // WISHBONE Target 8 (unused)
                                   .t8_wb_cyc_o    ( ),
                                   .t8_wb_stb_o    ( ),
                                   .t8_wb_adr_o    ( ),
                                   .t8_wb_sel_o    ( ),
                                   .t8_wb_we_o     ( ),
                                   .t8_wb_dat_o    ( ),
                                   .t8_wb_dat_i    ( 32'h0000_0000 ),
                                   .t8_wb_ack_i    ( 1'b0 ),
                                   .t8_wb_err_i    ( 1'b1 )
                                  );

     end
   else
     begin
        simple_wishbone_switch
          #(
            .DW( 32 ),
            .AW( 32 ),
            .SELW( 4 ),
            .SLAVE_1_ADDR_PREFIX( `APP_ADDR_ETH ),
            .SLAVE_2_ADDR_PREFIX( `APP_ADDR_UART )
            )
        simple_wishbone_switch_instance
          (
           .wb_clk_i   ( wb_clk_i ),
           .wb_rst_i   ( wb_rst_i ),

           // Wishbone Master 0 (Ethernet Wishbone master for DMA transfers).
           // This master should generally have a higher priority than the CPU or it may never get hold of the bus for its DMA transfers.
           .m0_wb_cyc_i    ( wb_ethm_cyc_i ),
           .m0_wb_stb_i    ( wb_ethm_stb_i ),
           .m0_wb_adr_i    ( wb_ethm_adr_i ),
           .m0_wb_sel_i    ( wb_ethm_sel_i ),
           .m0_wb_we_i     ( wb_ethm_we_i  ),
           .m0_wb_dat_i    ( wb_ethm_dat_i ),
           .m0_wb_dat_o    ( wb_ethm_dat_o ),
           .m0_wb_ack_o    ( wb_ethm_ack_o ),
           .m0_wb_err_o    ( wb_ethm_err_o ),

           // Wishbone Master 1 (the OR10 CPU)
           .m1_wb_cyc_i    ( wb_cpu_cyc_o ),
           .m1_wb_stb_i    ( wb_cpu_stb_o ),
           .m1_wb_adr_i    ( wb_cpu_adr_o ),
           .m1_wb_sel_i    ( wb_cpu_sel_o ),
           .m1_wb_we_i     ( wb_cpu_we_o  ),
           .m1_wb_dat_i    ( wb_cpu_dat_o ),
           .m1_wb_dat_o    ( wb_cpu_dat_i ),
           .m1_wb_ack_o    ( wb_cpu_ack_i ),
           .m1_wb_err_o    ( wb_cpu_err_i ),

           // Wishbone Slave 0 (SRAM controller)
           .s0_wb_cyc_o    ( wb_ss_cyc ),
           .s0_wb_stb_o    ( wb_ss_stb ),
           .s0_wb_adr_o    ( wb_ss_adr ),
           .s0_wb_sel_o    ( wb_ss_sel ),
           .s0_wb_we_o     ( wb_ss_we  ),
           .s0_wb_dat_o    ( wb_ss_dat_to_sram ),
           .s0_wb_dat_i    ( wb_ss_dat_from_sram ),
           .s0_wb_ack_i    ( wb_ss_ack ),
           .s0_wb_err_i    ( wb_ss_err ),

           // Wishbone Slave 1 (Ethernet controller)
           .s1_wb_cyc_o    ( wb_eth_cyc_o ),
           .s1_wb_stb_o    ( wb_eth_stb_o ),
           .s1_wb_adr_o    ( wb_eth_adr_o ),
           .s1_wb_sel_o    ( wb_eth_sel_o ),
           .s1_wb_we_o     ( wb_eth_we_o  ),
           .s1_wb_dat_o    ( wb_eth_dat_o ),
           .s1_wb_dat_i    ( wb_eth_dat_i ),
           .s1_wb_ack_i    ( wb_eth_ack_i ),
           .s1_wb_err_i    ( wb_eth_err_i ),

           // Wishbone Slave 2 (UART)
           .s2_wb_cyc_o    ( wb_uart_cyc_o ),
           .s2_wb_stb_o    ( wb_uart_stb_o ),
           .s2_wb_adr_o    ( wb_uart_adr_o_32 ),
           .s2_wb_sel_o    ( wb_uart_sel_o ),
           .s2_wb_we_o     ( wb_uart_we_o  ),
           .s2_wb_dat_o    ( wb_uart_dat_o ),
           .s2_wb_dat_i    ( wb_uart_dat_i ),
           .s2_wb_ack_i    ( wb_uart_ack_i ),
           .s2_wb_err_i    ( wb_uart_err_i )
          );
     end
     endgenerate

   // ----------- Instanciate the JTAG cable simulation when running under Verilator -----------

   tap_or10 tap_or10_instance
     (
      .jtag_tck_i( jtag_tck_i ),
      .jtag_tdi_i( jtag_tdi_i ),
      .jtag_tdo_o( debug_tdo_o ),

      .is_tap_state_test_logic_reset_i( is_tap_state_test_logic_reset_i ),
      .is_tap_state_shift_dr_i        ( is_tap_state_shift_dr_i   ),
      .is_tap_state_update_dr_i       ( is_tap_state_update_dr_i  ),

      .is_tap_current_instruction_debug_i( is_tap_current_instruction_debug_i ),

      .cpu_spr_number_o( cpu_dbg_spr_number    ),
      .cpu_data_i      ( cpu_dbg_data_from_cpu ),
      .cpu_data_o      ( cpu_dbg_data_to_cpu   ),
      .cpu_stb_o       ( cpu_dbg_stb           ),
      .cpu_we_o        ( cpu_dbg_we            ),
      .cpu_ack_i       ( cpu_dbg_ack           ),
      .cpu_err_i       ( cpu_dbg_err           ),
      .cpu_is_stalled_i( cpu_dbg_is_stalled    )
      );

endmodule
