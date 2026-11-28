const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Builder = @import("../builder.zig");
const access = @import("access/emit.zig");
const projection_read = @import("access/projection/read.zig");
const ir = zx.ir;
const Self = @This();
const generated = @import("genz_options").generated_analysis;
const blocks = @import("../node/blocks.zig");
pub const Error = std.mem.Allocator.Error;

allocator: std.mem.Allocator,
workspace: std.mem.Allocator,
program: ir.Program,
entry_flags: @import("entry_flags.zig").Flags,
self_function: ?ir.FunctionId = null,
builder: Builder,
types: []node.ExpressionId,
layouts: []node.ExpressionId,
abi_types: []node.ExpressionId = &.{},
abi_layouts: []node.ExpressionId = &.{},
state_types: []node.ExpressionId = &.{},
state_layouts: []node.ExpressionId = &.{},
view_types: []node.ExpressionId = &.{},
type_scratch: ?*@import("types/scratch.zig") = null,
state_plan: @import("state_value/analysis.zig"),
state_active: bool = false,
deferred_lists: bool = false,
state_symbols: @import("members.zig") = .empty,
names: [][]const u8 = &.{},
native_names: []const []const u8 = &.{},
used: []bool = &.{},
cache_reads: []u64 = &.{},
cache: @import("expression_map.zig").Map(ir.ExprId) = .empty,
plans: []const @import("uniqueness/root.zig").Plan = &.{},
plan: @import("uniqueness/root.zig").Plan = .{ .flags = &.{} },
serial: usize = 0,
capture: ?@import("capture.zig").Boundary = null,
uses_allocator: bool = false,
allows_allocation: bool = false,
uses_io: bool = false,
uses_process: bool = false,
io_functions: []const bool = &.{},
process_functions: []const bool = &.{},
task_functions: []const bool,
value_functions: []const bool = &.{},
/// The errors each function raises, joined at calls instead of visiting the callee; null visits callees.
function_errors: ?[]const ?[]const []const u8 = null,
error_cache: ?@import("error_effects.zig").Cache = null,
pure_functions: []const bool = &.{},
/// The pure functions that compare no represented aggregates by identity, themselves or through their callees.
identity_free_functions: []const bool = &.{},
local_functions: []const bool = &.{},
fresh_outputs: []const bool = &.{},
constructed_outputs: []const bool = &.{},
value_output: bool = false,
public_value_output: bool = false,
stack_symbols: @import("members.zig") = .empty,
reference_storage: if (generated) std.ArrayList(u64) else std.ArrayList(node.Statement) = .empty,
projected_symbols: ?[]const bool = null,
input_aliases: ?[]const bool = null,
iteration_value: ?*@import("iteration_value/root.zig") = null,
loop_fields: ?*const @import("iteration/fields/root.zig") = null,
layout_types: []const @import("iteration_layout/generated.zig").Type = &.{},
slot_counts: []const u32 = &.{},
growth_functions: []const bool = &.{},
may_grow: bool = true,
uses_context: bool = false,
uses_parallel: bool = false,
shared_types: bool = false,
pending_name: []const u8 = "zx_pending",
type_names: ?[]const []const u8 = null,
function_modules: ?[]const []const u8 = null,

local_regular_function: bool = false,
function_requests: *@import("functions/requests.zig") = undefined,
comparisons: *@import("collections/workflow.zig").Comparisons = undefined,
task_declarations: *@import("auxiliary.zig") = undefined,
pub fn refreshEntry(self: *Self) Error!void {
    self.error_cache = null;
    self.entry_flags = try @import("entry_flags.zig").analyze(self.workspace, self.program, .{ .local = self.local_functions, .pure = self.pure_functions, .io = self.io_functions, .process = self.process_functions, .tasks = self.task_functions, .self_function = self.self_function });
}

/// Select a function body while retaining the program's shared type and function tables.
pub fn selectFunction(self: *Self, id: ir.FunctionId) Error!void {
    const index = @backingInt(id);

    if (generated) {
        @import("functions/scope.zig").installFunction(&self.program, index, .Function);
    } else {
        const selected = self.program.functions.at(index);

        self.program.symbols = selected.symbols;
        self.program.expressions = selected.expressions;
        self.program.body = selected.body;
        self.program.input_type = selected.input_type;
        self.program.output_type = selected.output_type;
        self.program.stores = selected.stores;
        self.program.store_mode = selected.store_mode;
        self.program.contracts = selected.contracts;
    }

    self.self_function = id;

    try self.refreshEntry();
    try @import("error_effects.zig").forFunction(self, id);
}

const ModuleDeclarations = @import("../node/stored.zig").Declarations;

pub fn declarations(self: *Self) Error!ModuleDeclarations {
    return @import("module/execution/entry.zig").lower(self);
}

pub fn functionValue(self: *Self, name: []const u8) Error!node.Declaration {
    return @import("functions/value.zig").lower(self, name, false);
}

pub fn valuePrototype(self: *Self, name: []const u8) Error!node.Function {
    return (try @import("functions/value.zig").lower(self, name, true)).function;
}

pub fn function(self: *Self, name: []const u8, exported: bool) Error!node.Declaration {
    @import("functions/context.zig").reset(self, .Body);

    if (generated) return @import("functions/body.zig").lower(self, name, exported);

    const errors = try @import("error_effects.zig").program(self);
    const needs_io = self.entry_flags.io;
    const needs_process = self.entry_flags.process;

    try @import("functions/context.zig").prepare(self, errors);

    const body = try self.statements(self.program.body.block());
    const preconditions = try @import("contracts.zig").preconditions(self);
    const has_stores = self.program.stores.count() != 0;
    const stores = @import("store/transaction.zig");
    const prelude = try @import("functions/prelude/build.zig").lower(self, .{ .exported = exported, .io = needs_io, .process = needs_process });
    const pending = if (has_stores) try stores.initialize(self) else node.Block{};
    const references = try self.referenceBlock();
    const commit = if (has_stores) try stores.finish(self) else node.Block{};
    var declaration = try self.prototypeWithErrors(name, exported, errors);

    declaration.body = try blocks.join(
        self.allocator,
        self.builder.nodes,
        &.{ prelude.start, pending.start, references.start, preconditions.start, body.start, commit.start },
        &.{ prelude.len, pending.len, references.len, preconditions.len, body.len, commit.len },
    );

    return .{ .function = declaration };
}

pub fn hoistReferences(self: *Self, source: anytype) Error!void {
    return @import("functions/references.zig").append(self, source);
}

pub fn referenceBatches(self: *const Self) usize {
    return self.reference_storage.items.len;
}

pub fn referenceBlock(self: *const Self) Error!node.Block {
    if (!generated) return self.builder.statements(self.reference_storage.items);

    return blocks.joinStatementSpans(self.allocator, self.builder.nodes, self.reference_storage.items, false);
}

pub fn prototype(self: *Self, name: []const u8, exported: bool) Error!node.Function {
    const errors = try @import("error_effects.zig").program(self);

    return self.prototypeWithErrors(name, exported, errors);
}

fn prototypeWithErrors(self: *Self, name: []const u8, exported: bool, errors: ?[]const []const u8) Error!node.Function {
    return @import("signature/build.zig").build(self, &.{ .name = name, .exported = exported, .errors = errors });
}

const Probe = @import("expression_map.zig").Probe;

pub fn expr(self: *Self, id: ir.ExprId) Error!node.ExpressionId {
    const value = try evaluate(self, id, null);

    return @import("expressions/growth.zig").finish(self, id, value);
}

pub fn exprWithCache(self: *Self, id: ir.ExprId, probe: Probe) Error!node.ExpressionId {
    if (!probe.checked) return self.expr(id);

    const value = try evaluate(self, id, probe);

    return @import("expressions/growth.zig").finish(self, id, value);
}

inline fn evaluate(self: *Self, id: ir.ExprId, prior: ?Probe) Error!node.ExpressionId {
    if (self.iteration_value) |context| {
        if (generated) return @import("iteration_value/evaluation.zig").lower(context, id, prior orelse .{});
        if (try @import("iteration_value/evaluation_seed.zig").lower(context, id)) |value| return value;
    }

    return if (prior) |probe| regularWithCache(self, id, probe) else self.regular(id);
}

pub fn regular(self: *Self, id: ir.ExprId) Error!node.ExpressionId {
    if (self.cache.read(id, self.cache_reads)) |cached| return cached;

    return lowerUncached(self, id);
}

pub fn regularWithCache(self: *Self, id: ir.ExprId, probe: Probe) Error!node.ExpressionId {
    if (!probe.checked) return self.regular(id);

    if (probe.value) |value| {
        @TypeOf(self.cache).countRead(id, self.cache_reads);

        return @fromBackingInt(value);
    }

    return lowerUncached(self, id);
}

fn lowerUncached(self: *Self, id: ir.ExprId) Error!node.ExpressionId {
    if (generated) return @import("expressions/evaluate.zig").regular(self, id);

    const value = self.program.expression(id);
    const value_type = try self.typeExpr(value.type_id);

    return switch (value.value) {
        .task => @import("tasks/root.zig").start(self, id, false),
        .await_task => |child| @import("tasks/root_seed.zig").wait(self, child),
        .cancel_task => |child| @import("tasks/root_seed.zig").cancel(self, child),
        .parallel => |branches| @import("tasks/root.zig").parallel(self, value.type_id, branches),
        .capture => |child| @import("capture.zig").lower(self, value.type_id, child),
        .optional_value => |child| access.optional(self, null, try self.expr(child)),
        .integer, .negative_integer, .float, .boolean, .string, .unit, .none, .enum_value, .error_value => @import("literals/seed.zig").lower(self, value, value_type),
        .some => |child| access.optional(self, value_type, try self.expr(child)),
        .store_get => |slot| @import("access/store_seed.zig").lower(self, slot, value.type_id),
        .reference => |symbol| @import("access/reference.zig").lower(self, symbol, value.type_id),
        .field => |item| projection_read.field(self, value.type_id, item, false),
        .tuple_field => |item| projection_read.tuple(self, value.type_id, item, false),
        .index => |item| projection_read.index(self, value.type_id, item.target, item.index, false),
        .length => |child| projection_read.length(self, child, value_type, false),
        .unary => |unary| self.builder.expression(.{ .unary = .{ .operator = if (unary.operator == .not) .not else .negate, .operand = try self.expr(unary.operand) } }),
        .binary => |operation| self.binary(operation),
        .match_expr => |selection| @import("match.zig").lower(self, selection),
        .conditional => |conditional| @import("selection/conditional.zig").lower(self, conditional),
        .object => |object| @import("aggregate.zig").object(self, id, object),
        .list, .tuple, .template => |items| @import("aggregate/sequence.zig").lower(self, id, value, items, false),
        .list_operation => @import("collections.zig").lower(self, id),
        .transform => |transform| @import("transform.zig").lower(self, id, transform),
        .scope => |scope| @import("scope.zig").lower(self, scope),
        .iteration => |iteration| @import("iteration.zig").lower(self, id, iteration),
        .list_update => @import("list_update.zig").lower(self, id),
        .call => |invocation| @import("regular_call/root.zig").lower(self, invocation),
    };
}

pub fn functionReference(self: *Self, id: ir.FunctionId) Error!node.ExpressionId {
    return self.requestFunction(id, .regular);
}

pub fn requestFunction(self: *Self, id: ir.FunctionId, variant: @import("functions/requests.zig").Variant) Error!node.ExpressionId {
    if (@import("genz_options").generated_analysis) return @import("functions/reference.zig").lower(self, id, variant);

    if (self.function_modules) |modules| {
        const member = variant.member();

        if (id == self.self_function and (variant == .value or self.local_regular_function)) {
            return self.builder.identifier(member);
        }

        return self.field(try self.builtin(.import, &.{try self.builder.string(modules[@backingInt(id)])}), member);
    }

    try self.function_requests.add(self.allocator, id, variant);

    return self.builder.identifier(try variant.name(self.allocator, id));
}

pub fn binary(self: *Self, value: @FieldType(@FieldType(ir.ExpressionRow, "value"), "binary")) Error!node.ExpressionId {
    if (generated) return @import("expressions/evaluate.zig").binary(self, value);

    return @import("operators/seed.zig").binary(self, value);
}

/// The type expression of `id` in the current representation.
pub fn typeExpr(self: *Self, id: ir.TypeId) Error!node.ExpressionId {
    const types = if (generated and self.state_active) self.state_types else self.types;

    return @import("types.zig").get(self, types, id);
}

/// The layout expression of `id` in the current representation.
pub fn layoutExpr(self: *Self, id: ir.TypeId) Error!node.ExpressionId {
    const layouts = if (generated and self.state_active) self.state_layouts else self.layouts;

    return @import("types.zig").get(self, layouts, id);
}

pub fn field(self: *Self, target: node.ExpressionId, name: []const u8) Error!node.ExpressionId {
    return @import("access/emit.zig").field(self, target, name);
}

pub fn call(self: *Self, callee: node.ExpressionId, arguments: []const node.ExpressionId, fallible: bool) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("invocation/seed.zig").call(self, callee, arguments, fallible);

    return @import("invocation/call.zig").lower(self, callee, arguments, fallible);
}

pub fn builtin(self: *Self, name: @FieldType(@FieldType(node.Expression, "builtin"), "name"), arguments: []const node.ExpressionId) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("invocation/seed.zig").builtin(self, name, arguments);

    return @import("invocation/builtin.zig").lower(self, name, arguments);
}

pub fn cast(self: *Self, type_expr: node.ExpressionId, value: node.ExpressionId) Error!node.ExpressionId {
    return self.builtin(.as, &.{ type_expr, value });
}

pub fn construct(self: *Self, type_id: ir.TypeId, value: node.ExpressionId) Error!node.ExpressionId {
    if (!@import("genz_options").generated_analysis) return @import("construction_seed.zig").construct(self, type_id, value);

    return @import("construction/build.zig").lower(self, type_id, value, null);
}

pub fn fresh(self: *Self, prefix: []const u8) Error![]const u8 {
    if (!@import("genz_options").generated_analysis) {
        self.serial += 1;

        return std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ prefix, self.serial });
    }

    const entry = @import("generated_fresh_name_suffix");
    var memory = std.heap.FixedBufferAllocator.init(&.{});
    const output = entry.executeValue(memory.allocator(), self.serial) catch unreachable;

    const words = [_]u64{
        std.mem.nativeToLittle(u64, output.first),
        std.mem.nativeToLittle(u64, output.middle),
        std.mem.nativeToLittle(u64, output.last),
    };

    const suffix = std.mem.asBytes(&words)[0..@intCast(output.length)];
    const name = try std.mem.concat(self.allocator, u8, &.{ prefix, suffix });

    self.serial = @intCast(output.serial);

    return name;
}

pub fn statements(self: *Self, values: ir.Block) Error!node.Block {
    return @import("statements.zig").lower(self, values);
}

pub fn transaction(self: *const Self) bool {
    return @import("store/transaction.zig").active(self);
}
