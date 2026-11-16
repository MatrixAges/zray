const std = @import("std");
const frontend = @import("frontend");
const rx = @import("rx");
const zx = @import("zx");
const Module = @import("module.zig");
const Prepared = @import("project/flow.zig");
const Flow = @import("program/flow.zig");
const expression = @import("expression.zig");
const Captures = @import("task_captures.zig");
const Schedule = @import("flow_compile/schedule.zig");
const condition = @import("condition.zig");
const Self = @This();
pub const Error = std.mem.Allocator.Error || error{InvalidFlow};

allocator: std.mem.Allocator,
scratch: std.mem.Allocator,
binding_allocator: std.mem.Allocator,
retain_metadata: bool = false,
owner: []const u8,
aliases: frontend.expressions.BindingColumns = .{},
types: zx.ir.TypeTable,
/// What the expressions extend in place while `types` views it whole.
type_storage: zx.ir.TypeStorage = .{},
native_modules: zx.ir.NativeModuleTable = .{},
shared_functions: zx.ir.FunctionTable,
verified_functions: zx.ir.FunctionTable = .{},
output_type: zx.ir.TypeId,
loaded: []const Module.Loaded,
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

pub fn finishTask(self: *Self, work: *const Prepared.Task, body: u32, count: usize) Error!Flow.Step {
    var step: Flow.Step = .{ .kind = .Task, .first = body };
    var published: ?Module.Binding = null;

    inline for (comptime Schedule.steps(.Task)) |action| {
        switch (action) {
            .Done, .CompileTaskBody => {},
            .CompileTaskOutput => if (work.output) |attribute| {
                const binding = self.results.at(self.next_binding);

                self.next_binding += 1;
                step.value = try self.keep(try self.value(attribute, binding.type_id, false));

                if (binding.type_id == frontend.types.scalarId(.void)) {
                    step.output = .Evaluate;
                } else {
                    step.output = .Constant;
                    step.name = binding.name;
                    published = binding;
                }
            },
            .RestoreBindings => self.bindings.len = count,
            .PublishTask => if (published) |binding| try self.bindings.append(self.binding_allocator, .{ .name = binding.name, .type_id = binding.type_id }),
            else => unreachable,
        }
    }

    return step;
}

pub const CaseScope = struct { facts: usize, label: ?*const zx.ir.Program };

pub fn enterCase(self: *Self, case: *const Prepared.Case, subject: *const frontend.ExpressionInput.Result, subject_type: zx.ir.TypeId) Error!CaseScope {
    var scope: CaseScope = .{ .label = null, .facts = undefined };

    inline for (comptime Schedule.steps(.Case)) |action| {
        switch (action) {
            .Done, .CompileCaseBody, .RestoreCaseScope, .WriteCase => {},
            .CompileLabel => if (case.label.attribute()) |attribute| {
                scope.label = try self.keep(try self.value(attribute, subject_type, false));
            },
            .RefineSubject => {
                scope.facts = self.nonnull.items.len;

                if (case.truth) |present| {
                    const bindings: condition.Scope = .{
                        .allocator = self.allocator,
                        .bindings = self.bindings.items(.name),
                        .facts = &self.nonnull,
                    };

                    condition.assumeParsed(self.allocator, subject, present, bindings) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.InvalidFlow,
                    };
                }
            },
            else => unreachable,
        }
    }

    return scope;
}

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

    const location = self.loaded[index].node.location;

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
    try self.ensureTypeStorage();

    var arena = std.heap.ArenaAllocator.init(self.scratch);
    var buffer: [std.heap.page_size_min / 8]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, arena.allocator());

    defer arena.deinit();

    const scope = try @import("expression_scope.zig").select(scratch.allocator(), parsed, frontend.expressions.BindingColumns.view(self.bindings.slice()), self.nonnull.items);
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
        .nonnull_bindings = self.nonnull.items,
        .unit_bindings = if (self.unit_input) &.{"$in"} else &.{},
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

    if (self.captures) |captures| captures.observeMapped(program.expressions.references, scope.positions);

    return program;
}

pub fn takeTypeStorage(self: *Self) Error!zx.ir.TypeStorage {
    try self.ensureTypeStorage();

    const storage = self.type_storage;

    self.type_storage = .{};

    return storage;
}

fn ensureTypeStorage(self: *Self) Error!void {
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

pub fn call(self: *Self, loaded: Module.Loaded, outputs: *frontend.expressions.BindingStorage) Error!u32 {
    const count = self.bindings.len;
    const input = loaded.input;
    var argument: zx.ir.Program = undefined;
    var out: ?[]const u8 = undefined;

    inline for (comptime Schedule.steps(.Call)) |action| {
        switch (action) {
            .Done => {},
            .BindGetters => for (loaded.getters) |getter| {
                try self.bindings.append(self.binding_allocator, .{ .name = getter.name, .type_id = getter.slot.type_id });
            },
            .CompileArgument => argument = if (input) |attribute| value: {
                const expected = loaded.function.program.input_type;

                if (loaded.argument) |parsed| break :value try self.valueParsed(parsed, attribute.*, expected, self.retain_metadata);

                break :value try self.value(attribute.*, expected, self.retain_metadata);
            } else try @import("call/unit.zig").create(self.metadataAllocator(), self.owner, self.types, loaded.node.location),
            .RestoreBindings => self.bindings.len = count,
            .PublishCall => out = try self.publishResult(outputs),
            else => unreachable,
        }
    }

    return self.appendCall(.{ .function_id = loaded.function.id, .callee = loaded.function.program, .store_initializers = loaded.function.store_initializers, .argument = argument, .input_omitted = input == null, .out = out, .getters = loaded.getters });
}

pub fn publishResult(self: *Self, outputs: *frontend.expressions.BindingStorage) std.mem.Allocator.Error!?[]const u8 {
    const binding = self.results.at(self.next_binding);

    self.next_binding += 1;

    if (binding.type_id == frontend.types.scalarId(.void)) return null;
    try outputs.append(self.binding_allocator, .{ .name = binding.name, .type_id = binding.type_id });

    return binding.name;
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
