const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const function_link = @import("functions.zig");
const Schedule = @import("statements/schedule.zig");
const Self = @This();
const StoreInitializer = @import("frontend").project.compiled.StoreInitializer;
pub const Error = std.mem.Allocator.Error || error{ InvalidModule, UnreachableFlow, IncompleteFlow };

allocator: std.mem.Allocator,
types: ir.TypeTable,
native_modules: ir.NativeModuleTable,
symbols: ir.SymbolStorage = .{},
expressions: ir.ExpressionStorage = .{},
functions: ir.FunctionStorage = .{},
base_functions: ir.FunctionTable = .{},
store_initializers: @import("initializers.zig") = .{},
stores: ir.StoreStorage = .{},
bindings: std.ArrayList(ir.SymbolId) = .empty,
linking_scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
pub fn symbol(self: *Self, name: []const u8, type_id: ir.TypeId, span: zx.Span) std.mem.Allocator.Error!ir.SymbolId {
    const id: ir.SymbolId = @fromBackingInt(@intCast(self.symbols.count()));

    try self.symbols.append(self.allocator, .{ .name = try self.allocator.dupe(u8, name), .type_id = type_id, .span = span });

    return id;
}

pub fn seedExpression(self: *Self, value: ir.Expression) std.mem.Allocator.Error!ir.ExprId {
    const id: ir.ExprId = @fromBackingInt(@intCast(self.expressions.count()));
    _ = try self.expressions.append(self.allocator, value);

    return id;
}

pub fn expressionSpan(self: *const Self, id: ir.ExprId) zx.Span {
    const index = @backingInt(id);

    return .{ .start = @intCast(self.expressions.span_start.items[index]), .end = @intCast(self.expressions.span_end.items[index]) };
}

pub fn expressionType(self: *const Self, id: ir.ExprId) ir.TypeId {
    return @fromBackingInt(self.expressions.types.items[@backingInt(id)]);
}

pub fn importFunction(self: *Self, program: ir.Program, suffix: ?*const ir.FunctionTable, initializers: []const StoreInitializer, existing: ?ir.FunctionId) Error!ir.FunctionId {
    if (existing) |id| {
        if (suffix != null) return error.InvalidModule;

        const checked = self.store_initializers.alreadyChecked(initializers);

        switch (function_link.shared(&self.base_functions, @backingInt(id), &program, checked)) {
            .Invalid => return error.InvalidModule,
            .Checked => {},
            .CheckInitializers => for (initializers) |initial| try self.initializer(initial),
        }

        return id;
    }

    if (initializers.len == 0) return self.appendFunction(.ImportFunctions, program, suffix, initializers);

    return self.appendFunction(.ImportFunctionsAndInitializers, program, suffix, initializers);
}

fn appendFunction(self: *Self, comptime form: Schedule.Form, program: ir.Program, suffix: ?*const ir.FunctionTable, initializers: []const StoreInitializer) Error!ir.FunctionId {
    const prefix = self.base_functions;
    const base_count = prefix.count();
    const table = @import("frontend").project.artifact.function_table;
    const tail = table.appendTail(program.functions, prefix, suffix) orelse return error.InvalidModule;
    const Nodes = @import("frontend").ArtifactNodes;
    const first = std.math.add(usize, base_count, self.functions.count()) catch return error.OutOfMemory;
    const count = std.math.add(usize, base_count, tail.count()) catch return error.OutOfMemory;
    const range = try table.range(first, count, base_count, self.types.count(), self.native_modules.count());

    var nodes = Nodes{
        .allocator = self.allocator,
        .types = .{ .identity = range.types },
        .functions = .{ .range = .{
            .first = range.first,
            .count = range.count,
            .prefix = range.prefix,
        } },
        .native_modules = .{ .range = .{ .first = 0, .count = range.native_modules } },
    };

    inline for (comptime Schedule.steps(form)) |step| {
        switch (step) {
            .Done => {},
            .AppendFunctionTail => nodes.appendFunctions(&self.functions, tail) catch |err| return linkFailure(err),
            .LinkInitializers => for (initializers) |initial| {
                const mapped = nodes.remapInitializer(initial, false) catch |err| return linkFailure(err);

                try self.initializer(mapped);
            },
            .AppendFunctionEntry => nodes.appendFunction(&self.functions, &.{
                .file_name = program.file_name,
                .stores = program.stores,
                .store_mode = program.store_mode,
                .input_type = program.input_type,
                .output_type = program.output_type,
                .output_ownership = program.output_ownership,
                .symbols = program.symbols,
                .expressions = program.expressions,
                .body = program.body,
                .contracts = program.contracts,
            }) catch |err| return linkFailure(err),
            else => unreachable,
        }
    }

    return @fromBackingInt(range.root);
}

fn linkFailure(err: anyerror) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidModule;
}

pub fn store(self: *Self, value: ir.StoreSlot) Error!u32 {
    if (self.stores.count() != 0) {
        if (comptime @import("rx_options").generated_graph) {
            if (try self.mergeStore(value)) |row| return row;
        } else if (try self.mergeStoreSeed(value)) |row| return row;
    }

    const id: u32 = @intCast(self.stores.count());

    try self.stores.append(self.allocator, .{ .path = try self.allocator.dupe(u8, value.path), .type_id = value.type_id, .readable = value.readable, .writable = value.writable });

    return id;
}

fn mergeStore(self: *Self, value: ir.StoreSlot) Error!?u32 {
    const rule = @import("generated_rx_program_store_merge");
    const Input = std.meta.Child(rule.Input);

    const input: Input = .{
        .paths = self.stores.paths.items,
        .types = self.stores.types.items,
        .read = self.stores.readable.items,
        .write = self.stores.writable.items,
        .identity = value.path,
        .type_id = @backingInt(value.type_id),
        .readable = value.readable,
        .writable = value.writable,
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
    const index = result.row orelse return null;

    if (!result.compatible) return error.InvalidModule;

    self.stores.readable.items[@intCast(index)] = result.readable;
    self.stores.writable.items[@intCast(index)] = result.writable;

    return @intCast(index);
}

fn mergeStoreSeed(self: *Self, value: ir.StoreSlot) Error!?u32 {
    for (0..self.stores.count()) |index| {
        const slot = self.stores.at(index);

        if (!std.mem.eql(u8, slot.path, value.path)) continue;
        if (slot.type_id != value.type_id) return error.InvalidModule;

        self.stores.readable.items[index] = slot.readable or value.readable;
        self.stores.writable.items[index] = slot.writable or value.writable;

        return @intCast(index);
    }

    return null;
}

fn lookupFunction(self: *const Self, id: ir.FunctionId) ir.Function {
    const index = @backingInt(id);

    return if (index < self.base_functions.count()) self.base_functions.at(index) else self.functions.at(index - self.base_functions.count());
}

pub fn initializer(self: *Self, value: StoreInitializer) Error!void {
    if (@backingInt(value.function) >= self.base_functions.count() + self.functions.count()) return error.InvalidModule;

    const previous = (try self.store_initializers.add(self.allocator, value)) orelse return;
    const compare = @import("frontend").compare_ir.initializer;

    switch (compare.linkedAction(previous, value)) {
        .Reuse => return,
        .Conflict => return error.InvalidModule,
        .Compare => {},
    }

    const before = self.lookupFunction(previous.function);
    const after = self.lookupFunction(value.function);

    if (!compare.matches(&before, &after, previous.schema_version, value.schema_version, null)) return error.InvalidModule;
}
