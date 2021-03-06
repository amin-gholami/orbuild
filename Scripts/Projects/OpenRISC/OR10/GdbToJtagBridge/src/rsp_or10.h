
#ifndef RSP_OR10_H_INCLUDED
#define RSP_OR10_H_INCLUDED

#include <stdint.h>


#define MAX_WATCHPOINT_COUNT 8
#define WATCHPOINT_ADDR_DISABLED 0  // This means you cannot set a hardware breakpoint at address 0.


enum cpu_poll_speed_enum
{
  CPS_SLOW = 1,
  CPS_MIDDLE,
  CPS_FAST
};

struct rsp_struct
{
  int   proto_num;     // Number of the protocol used (normally TCP).
  int   server_fd;     // Socket file handle for new connections (listening socket). It is closed
                       // once a client connection is accepted, and re-open when the client connection is closed or lost.
  int   client_fd;     // Socket file handle for talking to GDB (connection to the client).
  bool  is_first_packet;

  uint32_t spr_upr;  // Unit presence register.
  uint32_t spr_vr;   // Version register.
  unsigned watchpoint_count;
  uint32_t watchpoint_addr[ MAX_WATCHPOINT_COUNT ];

  // Whether the GDB client issued a run command, the target CPU is running,
  // and GDB is waiting for a response packet that indicates the CPU stalled at a breakpoint or similar.
  bool  is_target_running;

  bool  is_in_single_step_mode;

  cpu_poll_speed_enum cpu_poll_speed;

  int   sigval;        // OpenRISC CPU exceptions are translated to GDB signal numbers.
};

extern rsp_struct rsp;

void enable_or10_jtag_trace ( bool enable_jtag_trace );
void attach_to_cpu ( void );
void detach_from_cpu ( void );
void process_client_command ( const struct rsp_buf * buf );
void poll_cpu ( void );
void check_connection_with_cpu_is_still_there ( void );

#endif	// Include this header file only once.
