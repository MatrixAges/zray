const std = @import("std");
const zx = @import("zx");
const generating = @import("genz").zx.modules;

pub fn header(allocator: std.mem.Allocator, unit: generating.Unit, version: u32, flags: generating.Analysis.Entry.Flags, value_function: ?bool) std.mem.Allocator.Error![]const u8 {
    const rule = @import("generated_generation_key_header");
    const fields = @typeInfo(@TypeOf(flags)).@"struct".field_names;
    var entry_flags: [fields.len]u8 = undefined;
    var encoded: []const u8 = &.{};

    if (unit == .entry) {
        inline for (fields, &entry_flags) |field, *byte| byte.* = @intFromBool(@field(flags, field));

        encoded = &entry_flags;
    }

    return execute(rule, allocator, .{
        .unit = @fromBackingInt(@intFromEnum(std.meta.activeTag(unit))),
        .version = version,
        .entry_flags = encoded,
        .value_function = value_function,
    });
}

pub fn plan(allocator: std.mem.Allocator, value: generating.Analysis.Uniqueness.Plan) std.mem.Allocator.Error![]const u8 {
    const rule = @import("generated_generation_key_plan");

    return execute(rule, allocator, .{
        .flags = std.mem.sliceAsBytes(value.flags),
        .transfers = std.mem.sliceAsBytes(value.transfers),
        .slot_first = std.mem.sliceAsBytes(value.slot_first),
        .keys = value.renewals.keys,
        .paths = value.renewals.paths,
    });
}

pub fn function(allocator: std.mem.Allocator, state: anytype, index: usize) std.mem.Allocator.Error![]const u8 {
    const rule = @import("generated_generation_key_function");
    const Input = std.meta.Child(rule.Input);
    const Context = std.meta.Child(@FieldType(Input, "context"));
    const facts: Facts(Context) = .init(state);
    const context = facts.borrow();
    const program: *const zx.ir.Program = &state.program;
    const functions = zx.columns.columns(std.meta.Child(@FieldType(Input, "functions")), program.functions);

    return execute(rule, allocator, .{
        .context = &context,
        .functions = &functions,
        .modules = zx.columns.pointer(@FieldType(Input, "modules"), &program.native_modules),
        .index = index,
    });
}

pub fn entry(allocator: std.mem.Allocator, hash: *zx.Sha256, state: anytype) std.mem.Allocator.Error!void {
    const rule = @import("generated_generation_key_entry");
    const Input = std.meta.Child(rule.Input);
    const Context = std.meta.Child(@FieldType(Input, "context"));
    const Ports = std.meta.Child(@FieldType(Input, "ports"));
    const Exported = std.meta.Child(@FieldType(Input, "exported"));
    const facts: Facts(Context) = .init(state);
    const context = facts.borrow();
    const program: *const zx.ir.Program = &state.program;
    const view = zx.memory.borrowNamedRows("type_id", program.exports);

    const ports: Ports = .{
        .prefix = context.prefix,
        .file = program.file_name,
        .input_type = @backingInt(program.input_type),
        .output_type = @backingInt(program.output_type),
    };

    const exported: Exported = .{ .prefix = context.prefix, .rows = @ptrCast(&view), .count = view.len };

    hash.update(try execute(rule, allocator, .{
        .context = &context,
        .ports = &ports,
        .exported = &exported,
        .contracts = zx.columns.pointer(@FieldType(Input, "contracts"), &program.contracts),
        .stores = zx.columns.pointer(@FieldType(Input, "stores"), &program.stores),
        .symbols = zx.columns.pointer(@FieldType(Input, "symbols"), &program.symbols),
        .expressions = zx.columns.pointer(@FieldType(Input, "expressions"), &program.expressions),
        .control = zx.columns.pointer(@FieldType(Input, "control"), program.body.control),
        .root = if (program.body.root) |id| @backingInt(id) else null,
        .mode = @fromBackingInt(@backingInt(program.store_mode)),
        .type_only = program.type_only,
    }));

    try constants(allocator, hash, context.prefix, program.constant_exports);
}

fn constants(allocator: std.mem.Allocator, hash: *zx.Sha256, prefix: anytype, source: []const zx.ir.Constant) std.mem.Allocator.Error!void {
    if (source.len == 0) return;

    const rule = @import("generated_generation_key_constants");
    const Input = std.meta.Child(rule.Input);
    const Values = std.meta.Child(@FieldType(Input, "values"));
    const Literal = std.meta.Child(std.meta.Child(@FieldType(Values, "values")));
    const chunk_size = 32;
    var names: [chunk_size][]const u8 = undefined;
    var literals: [chunk_size]Literal = undefined;
    var pointers: [chunk_size]*const Literal = undefined;
    var remaining = source;
    var total: ?u64 = source.len;

    while (remaining.len > 0) {
        const count = @min(remaining.len, chunk_size);

        for (remaining[0..count], names[0..count], literals[0..count], pointers[0..count]) |row, *name, *literal, *pointer| {
            name.* = row.name;
            literal.* = zx.ir.Constant.borrow(Literal, row);
            pointer.* = literal;
        }

        const values: Values = .{ .names = names[0..count], .values = pointers[0..count] };

        hash.update(try execute(rule, allocator, .{
            .prefix = zx.columns.pointer(@FieldType(Input, "prefix"), prefix),
            .values = &values,
            .total = total,
        }));

        total = null;
        remaining = remaining[count..];
    }
}

fn Facts(comptime Context: type) type {
    return struct {
        const Self = @This();
        const Prefix = std.meta.Child(@FieldType(Context, "prefix"));
        const Calls = std.meta.Child(@FieldType(Context, "calls"));
        prefix: Prefix,
        calls: Calls,
        fn init(state: anytype) Self {
            const functions = &state.program.functions;

            return .{
                .prefix = .{
                    .key_count = state.state_plan.keys.len,
                    .keys = std.mem.sliceAsBytes(state.state_plan.keys),
                    .names = state.names.types,
                },
                .calls = .{
                    .owner = if (state.current_function) |id| @backingInt(id) else null,
                    .names = state.names.functions,
                    .stores = zx.columns.slice(@FieldType(Calls, "stores"), functions.stores),
                    .input_types = functions.input_types,
                    .output_types = functions.output_types,
                    .errors = state.errors,
                    .value = state.value_functions,
                    .pure = state.pure_functions,
                    .local = state.local_functions,
                    .io = state.io_functions,
                    .process = state.process_functions,
                    .tasks = state.task_functions,
                    .identity_free = state.identity_free,
                    .fresh = state.fresh_outputs,
                    .constructed = state.constructed_outputs,
                },
            };
        }
        fn borrow(self: *const Self) Context {
            return .{ .prefix = &self.prefix, .calls = &self.calls };
        }
    };
}

pub fn types(allocator: std.mem.Allocator, program: *const zx.ir.Program, names: []const []const u8, keys: []const [32]u8) std.mem.Allocator.Error![]const u8 {
    const rule = @import("generated_generation_key_types");
    const Input = std.meta.Child(rule.Input);
    const Prefix = std.meta.Child(@FieldType(Input, "prefix"));
    const Table = std.meta.Child(@FieldType(Input, "table"));
    const prefix: Prefix = .{ .key_count = keys.len, .keys = std.mem.sliceAsBytes(keys), .names = names };
    const table = zx.ir.TypeTable.borrow(Table, program.types);
    const functions = zx.columns.columns(std.meta.Child(@FieldType(Input, "functions")), program.functions);

    return execute(rule, allocator, .{
        .prefix = &prefix,
        .table = &table,
        .modules = zx.columns.pointer(@FieldType(Input, "modules"), &program.native_modules),
        .functions = &functions,
    });
}

pub fn members(allocator: std.mem.Allocator, digest: *const [32]u8, rows: []const generating.PublicMember, names: []const []const u8) std.mem.Allocator.Error![32]u8 {
    const rule = @import("generated_generation_key_members");
    const view = zx.memory.borrowNamedRows("function", rows);

    const out = try execute(rule, allocator, .{
        .digest = digest,
        .count = rows.len,
        .members = @ptrCast(&view),
        .names = names,
        .word_width = @sizeOf(usize),
        .little_endian = @import("builtin").cpu.arch.endian() == .little,
    });

    std.debug.assert(out.len == 32);

    return out[0..32].*;
}

fn execute(comptime rule: type, allocator: std.mem.Allocator, input: std.meta.Child(rule.Input)) std.mem.Allocator.Error![]const u8 {
    return zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => error.OutOfMemory,
        else => std.debug.panic("generation fingerprint failed: {s}", .{@errorName(err)}),
    };
}
