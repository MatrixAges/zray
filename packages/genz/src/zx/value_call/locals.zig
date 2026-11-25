const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Members = @import("../members.zig");
const seed = @import("locals_seed.zig");
const generated = @import("genz_options").generated_analysis;

pub const Registered = struct {
    state: Members.Checkpoint,
    stack: Members.Checkpoint,
    pub fn release(self: Registered, lowering: *Lower) void {
        lowering.stack_symbols.restore(self.stack);
        lowering.state_symbols.restore(self.state);
    }
};

pub fn register(self: *Lower, statements: ir.Block) Lower.Error!Registered {
    const entry = @import("generated_value_block_register");
    const Parameter = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;
    const Input = Child(Parameter);
    const Facts = std.meta.Child(@FieldType(Input, "source"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const data = facts(self, Facts, &types);

    const input: Input = .{
        .source = &data,
        .control = zx.columns.pointer(@FieldType(Input, "control"), statements.control),
        .first = statements.first,
        .count = statements.len,
        .storage = storage(self, @FieldType(Input, "storage")),
    };

    return apply(self, entry.executeState, &input);
}

pub fn scope(self: *Lower, value: ir.ScopeRow, layout: bool) Lower.Error!Registered {
    if (!generated) {
        const state = try @import("../state_value/locals_seed.zig").scope(self, value);

        errdefer self.state_symbols.removeMany(state);

        return .{ .state = state, .stack = try seed.scope(self, value, layout) };
    }

    const entry = @import("generated_value_scope_register");
    const Parameter = @typeInfo(@TypeOf(entry.executeState)).@"fn".param_types[1].?;
    const Input = Child(Parameter);
    const Description = Child(@FieldType(Input, "source"));
    const Facts = Child(@FieldType(Description, "source"));
    const types = ir.TypeTable.borrow(Child(@FieldType(Facts, "types")), self.program.types);
    const data = facts(self, Facts, &types);

    const description: Description = .{
        .source = &data,
        .layouts = read(@FieldType(Description, "layouts"), self.layout_types),
        .symbols = read(@FieldType(Description, "symbols"), value.bindings.symbols),
        .values = read(@FieldType(Description, "values"), value.bindings.values),
        .borrows = read(@FieldType(Description, "borrows"), value.bindings.borrows),
        .result = @backingInt(value.result),
        .layout = layout,
    };

    const input: Input = .{
        .source = &description,
        .storage = storage(self, @FieldType(Input, "storage")),
    };

    return apply(self, entry.executeState, &input);
}

fn apply(self: *Lower, comptime execute: anytype, input: anytype) Lower.Error!Registered {
    const Parameter = @typeInfo(@TypeOf(execute)).@"fn".param_types[1].?;
    const before: Registered = .{ .state = self.state_symbols.checkpoint(), .stack = self.stack_symbols.checkpoint() };

    const value = execute(self.allocator, if (@typeInfo(Parameter) == .pointer) input else input.*) catch |err| {
        // Registration only appends keys. The old counts and key prefixes still define both indexes.
        self.stack_symbols.restoreBuckets();
        self.state_symbols.restoreBuckets();

        return failure(err);
    };

    install(&self.state_symbols, value.state_count, value.state_keys, value.state_buckets);
    install(&self.stack_symbols, value.stack_count, value.stack_keys, value.stack_buckets);

    self.input_aliases = if (value.aliases) |items| items.items else null;
    self.projected_symbols = if (value.projected) |items| items.items else null;

    return before;
}

fn install(members: *Members, count: u64, keys: anytype, buckets: @TypeOf(keys)) void {
    const index = members.current();

    index.* = .{ .count = count, .keys = zx.columns.view(@TypeOf(index.keys), keys), .buckets = zx.columns.view(@TypeOf(index.buckets), buckets) };
}

pub fn optionalCall(self: *Lower, body: if (generated) *@import("../../node/blocks.zig").Sequence else *std.ArrayList(node.Statement), symbol: ir.SymbolId, value: ir.ExprId, boundary: ir.TypeId) Lower.Error!?node.ExpressionId {
    if (!generated) return seed.optionalCall(self, body, symbol, value, boundary);

    const entry = @import("generated_value_local_optional");
    const Input = std.meta.Child(entry.Input);
    const Facts = std.meta.Child(@FieldType(Input, "source"));
    const types = ir.TypeTable.borrow(std.meta.Child(@FieldType(Facts, "types")), self.program.types);
    const data = facts(self, Facts, &types);
    const Lookup = std.meta.Child(@FieldType(Input, "cache"));
    const cached: Lookup = .{ .count = self.cache.state.count, .metadata = self.cache.state.metadata.items, .keys = self.cache.state.keys.items, .key = @backingInt(value) };
    const flags = self.plan.get(value);

    const input: Input = .{
        .source = &data,
        .cache = &cached,
        .value = @backingInt(value),
        .boundary = @backingInt(boundary),
        .used = self.used[@backingInt(symbol)],
        .normalize = flags.normalize,
        .renew = flags.renew,
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});
    const selected = zx.columns.invoke(entry.executeValue, fixed.allocator(), &input) catch |err| return failure(err);

    if (!selected) return null;

    return try @import("root.zig").borrowInvocation(self, body, self.program.expression(value).value.call);
}

fn read(comptime Target: type, values: anytype) Target {
    if (@typeInfo(Target) == .pointer) return zx.columns.slice(Target, values);

    return .{ .items = zx.columns.slice(@FieldType(Target, "items"), values), .storage = .plain };
}

fn storage(self: *Lower, comptime Storage: type) Storage {
    const state = self.state_symbols.current();
    const stack = self.stack_symbols.current();

    return .{
        .state_count = state.count,
        .state_keys = zx.columns.view(@FieldType(Storage, "state_keys"), state.keys),
        .state_buckets = zx.columns.view(@FieldType(Storage, "state_buckets"), state.buckets),
        .stack_count = stack.count,
        .stack_keys = zx.columns.view(@FieldType(Storage, "stack_keys"), stack.keys),
        .stack_buckets = zx.columns.view(@FieldType(Storage, "stack_buckets"), stack.buckets),
        .aliases = if (self.input_aliases) |items| .{ .items = items, .storage = .plain } else null,
        .projected = if (self.projected_symbols) |items| .{ .items = items, .storage = .plain } else null,
    };
}

fn facts(self: *const Lower, comptime Facts: type, types: anytype) Facts {
    return .{
        .types = types,
        .expressions = zx.columns.pointer(@FieldType(Facts, "expressions"), &self.program.expressions),
        .symbol_types = self.program.symbols.types,
        .names = self.program.symbols.names,
        .control = zx.columns.pointer(@FieldType(Facts, "control"), self.program.body.control),
        .queries = zx.columns.slice(@FieldType(Facts, "queries"), self.state_plan.queries),
        .selected = self.state_plan.selected,
        .native_modules = self.program.functions.native_modules,
        .constructed_outputs = self.constructed_outputs,
        .value_functions = self.value_functions,
        .active = self.state_active,
        .value_output = self.value_output,
        .scalar = self.entry_flags.scalar,
        .tasks = self.entry_flags.tasks,
        .output_type = @backingInt(self.program.output_type),
    };
}

fn Child(comptime Value: type) type {
    return if (@typeInfo(Value) == .pointer) std.meta.Child(Value) else Value;
}

fn failure(err: anyerror) Lower.Error {
    return switch (err) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => error.OutOfMemory,
        else => @panic("invalid local value registration"),
    };
}
