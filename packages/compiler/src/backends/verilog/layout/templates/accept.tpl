    end else if (input_ready) begin
        output_valid <= input_valid;

        if (input_valid) begin
            fault <= core_fault;
