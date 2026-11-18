module zxc_kernel(
    input wire clk,
    input wire reset,
    input wire input_valid,
    output wire input_ready,
    output reg output_valid,
    input wire output_ready,
