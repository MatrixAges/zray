const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Module = @import("module.zig");
const Prepared = @import("project/flow.zig");
const Flow = @import("program/flow.zig");
const expression = @import("expression.zig");
const Captures = @import("task_captures.zig");
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{InvalidFlow};
const Call = @import("flow_compile/call.zig");

allocator: std.mem.Allocator,
scratch: std.mem.Allocator,
binding_allocator: std.mem.Allocator,
retain_metadata: bool = false,
root_return: ?*const zx.ir.Program = null,
owner: []const u8,
aliases: frontend.expressions.BindingColumns = .{},
types: zx.ir.TypeTable,
/// What the expressions extend in place while `types` views it whole.
type_storage: zx.ir.TypeStorage = .{},
native_modules: zx.ir.NativeModuleTable = .{},
shared_functions: zx.ir.FunctionTable,
verified_functions: zx.ir.FunctionTable = .{},
output_type: zx.ir.TypeId,
inputs: *const @import("module_compile.zig").Options,
results: Module.Bindings,
tasks: []const zx.ir.TypeId = &.{},
plan: *const Prepared.Plan,
compiled: Flow = .{},
captures: ?*Captures = null,
bindings: frontend.expressions.BindingStorage = .empty,
nonnull: std.ArrayList([]const u8) = .empty,
calls: std.ArrayList(Module.Call) = .empty,
next_binding: usize = 0,
unit_input: bool = false,
issue: ?expression.Diagnostic = null,
pub fn root(self: *Self, sequence: Prepared.Unit) Error!u32 {
    return @import("flow_compile/traversal.zig").run(self, sequence);
}

pub const TaskOutput = struct {
    body: u32,
    value: ?*const zx.ir.Program = null,
    result: ?Result = null,
    pub fn name(self: *const TaskOutput) ?[]const u8 {
        return if (self.result) |binding| binding.name else null;
    }

    pub fn evaluate(self: *TaskOutput, compiler: *Self, attribute: rx.ast.Attribute, result: Result) Error!void {
        self.value = try compiler.keep(try compiler.value(attribute, result.type_id, false));
        self.result = result;
    }

    pub fn publish(self: *const TaskOutput, compiler: *Self) Error!?bool {
        const result = self.result orelse return null;

        try result.publish(compiler.binding_allocator, &compiler.bindings);

        return result.name != null;
    }
};

pub fn checkSelection(self: *Self, subject: *const zx.ir.Program, attribute: rx.ast.Attribute, alternatives: []const Prepared.Case, first: u32, count: u32) Error!bool {
    const labels = self.compiled.cases.items(.value)[first..][0..count];
    const checked = try @import("selection.zig").check(self.allocator, subject, attribute, labels, alternatives);

    if (checked == .diagnostic) {
        self.issue = checked.diagnostic;

        return error.InvalidFlow;
    }

    return checked.exhaustive;
}

pub fn checkParallelCall(self: *Self, index: u32, id: u32) Error!void {
    if (try frontend.isParallelSafe(self.allocator, self.calls.items[id].callee)) return;

    const location = self.inputs.calls.items(.node)[index].location;

    self.issue = .{ .location = location, .issue = .{ .code = .unsupported, .span = .{ .start = location.offset, .end = location.offset }, .message = "Parallel branches require pure functions without Store capabilities or native external calls" } };

    return error.InvalidFlow;
}

pub fn keep(self: *Self, program: zx.ir.Program) std.mem.Allocator.Error!*const zx.ir.Program {
    const result = try self.binding_allocator.create(zx.ir.Program);

    result.* = program;

    return result;
}

pub fn value(self: *Self, attribute: rx.ast.Attribute, expected: ?zx.ir.TypeId, retain: bool) Error!zx.ir.Program {
    var parsed = try @import("attribute.zig").parseBorrowed(self.scratch, attribute, self.owner);

    defer parsed.deinit();

    return self.valueParsed(&parsed, attribute, expected, retain);
}

pub fn valueParsed(self: *Self, parsed: *const frontend.ExpressionInput.Result, attribute: rx.ast.Attribute, expected: ?zx.ir.TypeId, retain: bool) Error!zx.ir.Program {
    return self.compileValue(parsed, attribute, expected, retain, null);
}

pub fn loopPredicate(self: *Self, attribute: rx.ast.Attribute, state: zx.ir.TypeId) Error!zx.ir.Program {
    var parsed = try @import("attribute.zig").parseBorrowed(self.scratch, attribute, self.owner);

    defer parsed.deinit();

    return self.compileValue(&parsed, attribute, frontend.types.scalarId(.bool), false, state);
}

fn compileValue(self: *Self, parsed: *const frontend.ExpressionInput.Result, attribute: rx.ast.Attribute, expected: ?zx.ir.TypeId, retain: bool, loop_state: ?zx.ir.TypeId) Error!zx.ir.Program {
    try self.ensureTypeStorage();

    var arena = std.heap.ArenaAllocator.init(self.scratch);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const bindings: frontend.expressions.BindingColumns = if (loop_state) |state|
        .{ .names = &.{"$in"}, .types = &.{state} }

    else
        frontend.expressions.BindingColumns.view(self.bindings.slice());

    const facts = if (loop_state == null) self.nonnull.items else &.{};
    const scope = try @import("expression_scope.zig").select(scratch.allocator(), parsed, bindings, facts);
    const backing = if (retain) self.allocator else self.binding_allocator;

    const compiled = try expression.compileParsed(backing, parsed, attribute, .{
        .types = self.types,
        .borrow_types = true,
        .type_storage = &self.type_storage,
        .type_allocator = self.allocator,
        .native_modules = self.native_modules,
        .borrow_native_modules = true,
        .alias_columns = self.aliases,
        .binding_columns = scope.bindings,
        .nonnull_bindings = facts,
        .unit_bindings = if (loop_state == null and self.unit_input) &.{"$in"} else &.{},
        .expected = expected,
        .scratch_backing = self.scratch,
    }, true);

    if (compiled.value == .diagnostic) {
        var issue = compiled.value.diagnostic;
        issue.issue = try issue.issue.clone(self.allocator);
        self.issue = issue;

        return error.InvalidFlow;
    }

    const program = compiled.value.ir;

    self.types = program.types;

    if (loop_state == null) {
        if (self.captures) |captures| captures.observeMapped(program.expressions.references, scope.positions);
    }

    return program;
}

pub fn takeTypeStorage(self: *Self) std.mem.Allocator.Error!zx.ir.TypeStorage {
    try self.ensureTypeStorage();

    const storage = self.type_storage;

    self.type_storage = .{};

    return storage;
}

fn ensureTypeStorage(self: *Self) std.mem.Allocator.Error!void {
    if (viewed(self.type_storage, self.types)) return;

    self.type_storage = try frontend.type_table.columns(self.allocator, self.types);
    self.types = self.type_storage.view();
}

/// Whether `types` is already backed by this flow's append-only storage.
fn viewed(storage: zx.ir.TypeStorage, types: zx.ir.TypeTable) bool {
    inline for (@typeInfo(zx.ir.TypeStorage).@"struct".field_names) |name| {
        const column = @field(storage, name).items;

        if (column.ptr != @field(types, name).ptr or column.len != @field(types, name).len) return false;
    }

    return true;
}

pub fn call(self: *Self, row: u32, outputs: *frontend.expressions.BindingStorage) Error!u32 {
    const count = self.bindings.len;
    var work: Call = undefined;

    try Call.prepare(self, row, &work);
    try work.bindGetters(self);

    if (work.input != null) {
        try work.argument(self);
    } else {
        try work.unit(self);
    }

    self.bindings.len = count;

    return work.publish(self, outputs, self.seedResult());
}

pub const Result = struct {
    name: ?[]const u8,
    type_id: zx.ir.TypeId,
    pub fn publish(self: Result, allocator: std.mem.Allocator, outputs: *frontend.expressions.BindingStorage) std.mem.Allocator.Error!void {
        const name = self.name orelse return;

        try outputs.append(allocator, .{ .name = name, .type_id = self.type_id });
    }
};

pub fn seedResult(self: *Self) Result {
    const row = self.next_binding;

    self.next_binding += 1;

    return self.selectedResult(row, self.results.types[row] != frontend.types.scalarId(.void));
}

pub fn selectedResult(self: *const Self, row: u64, visible: bool) Result {
    const binding = self.results.at(@intCast(row));

    return .{ .name = if (visible) binding.name else null, .type_id = binding.type_id };
}

pub fn appendCall(self: *Self, invocation: Module.Call) std.mem.Allocator.Error!u32 {
    const index = try Flow.index(self.calls.items.len);

    try self.compiled.calls.append(self.binding_allocator, .{
        .getters = try Flow.index(invocation.getters.len),
        .publishes = invocation.out != null,
    });

    try self.calls.append(self.metadataAllocator(), invocation);

    return index;
}

pub fn metadataAllocator(self: *const Self) std.mem.Allocator {
    return if (self.retain_metadata) self.allocator else self.binding_allocator;
}
