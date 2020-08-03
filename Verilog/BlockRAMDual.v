// Dual-port block RAM
// ===================

module BlockRAMDual (
  CLK,     // Clock
  DI,      // Data in
  RD_ADDR, // Read address
  WR_ADDR, // Write address
  WE,      // Write enable
  DO       // Data out
  );

  parameter ADDR_WIDTH = 1;
  parameter DATA_WIDTH = 1;
  parameter INIT_FILE  = "UNUSED";

  input [(DATA_WIDTH-1):0] DI;
  input [(ADDR_WIDTH-1):0] RD_ADDR, WR_ADDR;
  input WE, CLK;
  output reg [(DATA_WIDTH-1):0] DO;
  reg [DATA_WIDTH-1:0] RAM[2**ADDR_WIDTH-1:0];

  generate
    if (INIT_FILE != "UNUSED") begin
      initial $readmemh(INIT_FILE, RAM);
    end
  endgenerate

  always @(posedge CLK)
  begin
    // Write port
    if (WE) begin
      RAM[WR_ADDR] <= DI;
    end
    // Read port
    DO <= (WE && RD_ADDR == WR_ADDR) ? {DATA_WIDTH{1'hx}} : RAM[RD_ADDR];
  end 

endmodule