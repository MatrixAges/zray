const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Context = @import("root.zig");
const Lower = @import("../lower.zig");
const recursive_scratch_bytes = 1024;

pub fn lower(self: *Context, scope: ir.ScopeRow) Lower.Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("scope_seed.zig").lower(self, scope);

    const lowering = self.lowering;
    var scratch = std.heap.ArenaAllocator.init(lowering.workspace);
    var buffer: [recursive_scratch_bytes]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const temporary = memory.allocator();
    const before = self.symbols.checkpoint();

    try locals(self, temporary, scope.bindings.symbols);

    defer self.symbols.restore(before);

    return @import("../scope/execute.zig").iteration(self, temporary, scope);
}

fn locals(self: *Context, temporary: std.mem.Allocator, symbols: []const ?u32) Lower.Error!void {
    if (symbols.len == 0) return;

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

    return self.symbols.addMany(lowering.allocator, entered);
}

const scope_entry = @import("generated_iteration_scope");
const ScopeInput = std.meta.Child(scope_entry.Input);
const Bindings = @import("../expressions/evaluate.zig").Api.IterationScopeBindings;

pub noinline fn emit(lowering: *Lower, temporary: std.mem.Allocator, result: node.ExpressionId, bindings: *const Bindings) Lower.Error!node.ExpressionId {
    const input: ScopeInput = .{
        .writer = @ptrCast(lowering),
        .frame = @ptrCast(lowering),
        .bindings = zx.columns.pointer(@FieldType(ScopeInput, "bindings"), bindings),
        .result = @backingInt(result),
        .expression_base = @intCast(lowering.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(lowering.builder.nodes.statements.tags.items.len),
        .serial = lowering.serial,
    };

    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, temporary);
    const root = scope_entry.executeIn(memory.allocator(), &input) catch |err| return failure(err);

    return @fromBackingInt(root);
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => unreachable,
    };
}
