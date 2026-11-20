const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const view = @import("../../node/view.zig");
const Lower = @import("../lower.zig");

pub fn lower(self: *Lower, statements: ir.Block, index: usize) Lower.Error!node.Block {
    if (!@import("genz_options").generated_analysis) {
        const begin = (try @import("begin_seed.zig").statement(self, statements, index)) orelse return .{};

        return self.builder.statements(&.{begin});
    }

    const entry = @import("generated_store_begin");
    const Input = std.meta.Child(entry.Input);
    const Control = std.meta.Child(@FieldType(Input, "control"));
    const Values = std.meta.Child(@FieldType(Input, "values"));
    const Bases = std.meta.Child(@FieldType(Input, "bases"));

    const control: Control = .{
        .statement_kinds = zx.columns.slice(@FieldType(Control, "statement_kinds"), statements.control.statement_kinds),
        .statement_payloads = statements.control.statement_payloads,
        .evaluations = statements.control.evaluations,
        .constant_values = statements.control.constant_values,
    };

    const values: Values = .{
        .kinds = zx.columns.slice(@FieldType(Values, "kinds"), self.program.expressions.kinds),
        .payloads = self.program.expressions.payloads,
        .stores = self.program.expressions.stores,
        .call_functions = self.program.expressions.call_functions,
        .call_store_first = self.program.expressions.call_store_first,
        .call_store_count = self.program.expressions.call_store_count,
        .call_stores = self.program.expressions.call_stores,
    };

    const bases: Bases = .{
        .capture = if (self.capture) |capture| &.{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) } else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
        .serial = self.serial,
    };

    const input: Input = .{
        .control = &control,
        .values = &values,
        .function_modes = zx.columns.slice(@FieldType(Input, "function_modes"), self.program.functions.store_modes),
        .first = statements.first,
        .count = statements.len,
        .index = index,
        .bases = &bases,
    };

    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const output = (entry.executeIn(memory.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    }) orelse return .{};

    self.uses_context = true;

    if (!output.valid) return error.OutOfMemory;

    const expressions = view.join(output.expressions.*, output.forms.*);
    const rows = @import("../../node/import_rows.zig");

    rows.append(self.allocator, &self.builder.nodes.expressions, &expressions) catch |err| return failure(err);

    const emitted = view.join(output.statements.*, output.variables.*);

    _ = try self.builder.publishStatements(&.{}, &emitted);

    return .{ .start = output.body, .len = 1 };
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
