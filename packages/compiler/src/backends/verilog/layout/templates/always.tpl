    .fault(core_fault)
);

assign input_ready = !reset && (!output_valid || output_ready);

always @(posedge clk) begin
    if (reset) begin
        output_valid <= 1'b0;
        fault <= 1'b0;
