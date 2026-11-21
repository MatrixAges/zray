const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const rows = @import("../../node/import_rows.zig");
const schedule = @import("../scope/schedule.zig");
const recursive_scratch_bytes = 1024;

pub fn lower(self: *Context, scope: ir.ScopeRow) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("scope_seed.zig").lower(self, scope);

    const lowering = self.lowering;
    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [recursive_scratch_bytes]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const entered = try locals(self, temporary, scope.bindings.symbols);

    defer self.symbols.removeMany(entered);

    const result = try lowering.expr(scope.result);
    const bindings = try prepare(self, temporary, scope);

    return emit(lowering, temporary, result, &bindings);
}

fn locals(self: *Context, temporary: std.mem.Allocator, symbols: []const ?u32) Lower.Error![]const ir.SymbolId {
    if (symbols.len == 0) return &.{};

    const entry = @import("generated_iteration_scope_locals");
    const Input = std.meta.Child(entry.Input);
    const lowering = self.lowering;
    const index = self.symbols.view(std.meta.Child(@FieldType(Input, "index")));

    const input: Input = .{
        .symbols = symbols,
        .symbol_types = lowering.program.symbols.types,
        .type_kinds = lowering.program.types.kinds,
        .layouts = zx.columns.slice(@FieldType(Input, "layouts"), lowering.layout_types),
        .inline_lists = self.inline_lists,
        .index = &index,
    };

    const keys = entry.executeIn(temporary, &input) catch |err| return failure(err);

    comptime std.debug.assert(@typeInfo(ir.SymbolId).@"enum".tag_type == u32);

    const entered = @as([*]const ir.SymbolId, @ptrCast(keys.ptr))[0..keys.len];

    try self.symbols.addMany(lowering.allocator, entered);

    return entered;
}

const scope_entry = @import("generated_iteration_scope");
const ScopeInput = std.meta.Child(scope_entry.Input);
const Bindings = std.meta.Child(@FieldType(ScopeInput, "bindings"));

fn prepare(self: *Context, temporary: std.mem.Allocator, scope: ir.ScopeRow) Lower.Error!Bindings {
    const lowering = self.lowering;

    const tables: schedule.Values = .{
        .values = try temporary.alloc(?u32, scope.bindings.len),
        .types = try temporary.alloc(?u32, scope.bindings.len),
        .names = try temporary.alloc([]const u8, scope.bindings.len),
    };

    var request = schedule.begin(scope.bindings.len);
    var emitted: node.Block = .{};

    while (true) {
        request = schedule.advance(lowering, scope, &.{}, &tables, &request, emitted);

        switch (request.action) {
            .Done => break,
            .Iteration => emitted.start = @backingInt(try lowering.expr(@fromBackingInt(request.value))),
            .Type => emitted.start = @backingInt(try @import("types.zig").get(self, @fromBackingInt(request.type_id.?))),
            else => unreachable,
        }
    }

    return .{ .symbols = scope.bindings.symbols, .values = tables.values, .types = tables.types, .names = tables.names };
}

noinline fn emit(lowering: *Lower, temporary: std.mem.Allocator, result: node.ExpressionId, bindings: *const Bindings) Lower.Error!node.ExpressionId {
    const input: ScopeInput = .{
        .bindings = bindings,
        .result = @backingInt(result),
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(lowering.builder.nodes.statements.tags.items.len),
        .serial = lowering.serial,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, temporary);
    const output = scope_entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);
    const block = output.block;

    if (!block.valid) return error.OutOfMemory;

    const name = try lowering.allocator.dupe(u8, block.name);
    const names = [_][]const u8{name};
    var expressions = block.expressions.*;
    var statements = block.statements.*;
    expressions.block_label = &names;
    statements.break_value_label = &names;

    rows.appendBorrowed(lowering.allocator, &lowering.builder.nodes.statements, output.rows) catch |err| return failure(err);
    rows.appendBorrowed(lowering.allocator, &lowering.builder.nodes.statements, &statements) catch |err| return failure(err);
    rows.appendBorrowed(lowering.allocator, &lowering.builder.nodes.expressions, &expressions) catch |err| return failure(err);

    lowering.serial = @intCast(block.serial);

    return @fromBackingInt(block.root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
