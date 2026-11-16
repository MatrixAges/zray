const std = @import("std");
const zx = @import("zx");
const generating = @import("genz").zx.modules;
const Writer = std.Io.Writer;

pub fn header(out: *Writer, unit: generating.Unit, version: u32, flags: generating.Analysis.Entry.Flags) void {
    const rule = @import("generated_generation_key_header");
    const fields = @typeInfo(@TypeOf(flags)).@"struct".field_names;
    var entry_flags: [fields.len]u8 = undefined;
    var encoded: []const u8 = &.{};

    if (unit == .entry) {
        inline for (fields, &entry_flags) |field, *byte| byte.* = @intFromBool(@field(flags, field));

        encoded = &entry_flags;
    }

    execute(rule, .{
        .out = @ptrCast(out),
        .unit = @fromBackingInt(@intFromEnum(std.meta.activeTag(unit))),
        .version = version,
        .entry_flags = encoded,
    });
}

pub fn plan(out: *Writer, value: generating.Analysis.Uniqueness.Plan) void {
    const rule = @import("generated_generation_key_plan");

    execute(rule, .{
        .out = @ptrCast(out),
        .flags = std.mem.sliceAsBytes(value.flags),
        .transfers = std.mem.sliceAsBytes(value.transfers),
        .slot_first = std.mem.sliceAsBytes(value.slot_first),
        .keys = value.renewals.keys,
        .paths = value.renewals.paths,
    });
}

pub fn reference(out: *Writer, state: anytype, id: zx.ir.FunctionId) void {
    const rule = @import("generated_generation_key_reference");
    const Input = std.meta.Child(rule.Input);
    const Type = std.meta.Child(@FieldType(Input, "input"));
    const index = @backingInt(id);
    const functions = &state.program.functions;
    const in = functions.input_types[index];
    const output = functions.output_types[index];
    const input_identity: Type = .{ .name = state.names.types[in], .digest = &state.state_plan.keys[in] };
    const output_identity: Type = .{ .name = state.names.types[output], .digest = &state.state_plan.keys[output] };

    execute(rule, .{
        .out = @ptrCast(out),
        .earlier = if (state.current_function) |owner| index < @backingInt(owner) else null,
        .name = state.names.functions[index],
        .stores = zx.columns.pointer(@FieldType(Input, "stores"), functions.stores[index]),
        .input = &input_identity,
        .output = &output_identity,
        .errors = state.errors[index],
        .value = state.value_functions[index],
        .pure = state.pure_functions[index],
        .local = state.local_functions[index],
        .io = state.io_functions[index],
        .process = state.process_functions[index],
        .tasks = state.task_functions[index],
        .identity_free = state.identity_free[index],
        .fresh = state.fresh_outputs[index],
        .constructed = state.constructed_outputs[index],
    });
}

pub fn native(out: *Writer, module: zx.ir.NativeModule) void {
    const rule = @import("generated_generation_key_native");

    execute(rule, .{
        .out = @ptrCast(out),
        .specifier = module.specifier,
        .identity = module.identity,
        .import_name = module.import_name,
        .namespace = module.type_namespace,
    });
}

pub fn types(out: *Writer, names: []const []const u8, keys: []const [32]u8) void {
    const rule = @import("generated_generation_key_types");

    execute(rule, .{ .out = @ptrCast(out), .key_count = keys.len, .keys = std.mem.sliceAsBytes(keys), .names = names });
}

pub fn members(out: *Writer, digest: *const [32]u8, rows: []const generating.PublicMember, names: []const []const u8) void {
    const rule = @import("generated_generation_key_members");
    const view = zx.memory.borrowNamedRows("function", rows);

    execute(rule, .{
        .out = @ptrCast(out),
        .digest = digest,
        .count = rows.len,
        .members = @ptrCast(&view),
        .names = names,
        .word_width = @sizeOf(usize),
        .little_endian = @import("builtin").cpu.arch.endian() == .little,
    });
}

fn execute(comptime rule: type, input: std.meta.Child(rule.Input)) void {
    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;
}
