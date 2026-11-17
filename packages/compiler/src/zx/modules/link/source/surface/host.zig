const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const Source = @import("../../source.zig");
const Nodes = @import("../../../artifact/nodes.zig");
const Binding = @import("../../../function_import.zig");
const Initializer = @import("../../../compiled.zig").StoreInitializer;
const Error = @import("../../program.zig").Error;
const remap = @import("../../../artifact/nodes/remap.zig");
const generated = @import("generated_source_surface");
const Input = std.meta.Child(generated.Input);
const Initializers = std.meta.Child(@FieldType(Input, "initializers"));
const Members = std.meta.Child(@FieldType(Input, "members"));
const Ports = std.meta.Child(@FieldType(Input, "ports"));
const Mapping = std.meta.Child(@FieldType(Ports, "types"));
const Prefix = std.meta.Child(@typeInfo(@FieldType(Initializers, "prefix")).optional.child);
const InitTarget = std.meta.Child(@FieldType(Initializers, "target"));
const MemberTarget = std.meta.Child(@FieldType(Members, "target"));

pub fn publish(input: *const Source.Input, storage: *const ir.FunctionStorage, nodes: *const Nodes, entry: ?ir.FunctionId, result: *Source.Loaded) Error!void {
    const allocator = nodes.allocator;
    const functions = remap.idMapping(Mapping, nodes.functions);
    const types = remap.typeMapping(Mapping, nodes.types);
    const values = input.store_initializers;
    const shared = input.shared_initializers;
    const left = memory.borrowTextColumn("identity", values);
    const right = memory.borrowTextColumn("identity", shared);
    const initial_ids = memory.borrowReadColumn(ir.FunctionId, "function", values);
    const schemas = memory.borrowReadColumn(u32, "schema_version", values);

    const prefix: ?Prefix = if (values.len == 0 or shared.len == 0 or nodes.functions != .range) null else .{
        .left = &.{ .names = @ptrCast(&left), .data = left.bytes, .count = values.len },
        .right = &.{ .names = @ptrCast(&right), .data = right.bytes, .count = shared.len },
        .stride = @sizeOf(Initializer),
        .function_id = @offsetOf(Initializer, "function"),
        .schema_version = @offsetOf(Initializer, "schema_version"),
        .little_endian = @import("builtin").target.cpu.arch.endian() == .little,
        .shared = values.ptr == shared.ptr,
        .identity = true,
        .function_prefix = nodes.functions.range.prefix,
    };

    var initial_output: memory.RowOutput(Initializer, InitTarget, .{
        .identity = &.{"identity"},
        .function = &.{"function"},
        .schema_version = &.{"schema_version"},
    }) = undefined;

    initial_output.init();

    const initializers: Initializers = .{
        .source = &.{ .identity = @ptrCast(&left), .function = @ptrCast(&initial_ids), .schema_version = @ptrCast(&schemas) },
        .functions = zx.columns.pointer(@FieldType(Initializers, "functions"), &functions),
        .end = values.len,
        .prefix = if (prefix) |*found| found else null,
        .target = &initial_output.view,
        .storage = @ptrCast(&initial_output.buffer),
        .shared = std.mem.sliceAsBytes(shared),
    };

    const member_source = input.members;
    const names = memory.borrowTextColumn("name", member_source);
    const intrinsics = memory.borrowOptionalU8Column("intrinsic", member_source);
    const ids = memory.borrowOptionalU32Column("id", member_source);
    const inputs = memory.borrowOptionalU32Column("input_type", member_source);
    const outputs = memory.borrowOptionalU32Column("output_type", member_source);

    var member_output: memory.RowOutput(Binding, MemberTarget, .{
        .names = &.{"name"},
        .intrinsics = &.{"intrinsic"},
        .ids = &.{"id"},
        .inputs = &.{"input_type"},
        .outputs = &.{"output_type"},
        .namespaces = &.{"namespace"},
    }) = undefined;

    member_output.init();

    const members: Members = .{
        .source = &.{
            .names = @ptrCast(&names),
            .intrinsics = @ptrCast(&intrinsics),
            .ids = @ptrCast(&ids),
            .inputs = @ptrCast(&inputs),
            .outputs = @ptrCast(&outputs),
            .count = member_source.len,
        },
        .target = &member_output.view,
        .entry = if (entry) |id| @backingInt(id) else null,
        .type_ids = if (member_source.len == 0) &.{} else @ptrCast(nodes.types.mapped),
        .functions = zx.columns.pointer(@FieldType(Members, "functions"), &functions),
    };

    const request: Input = .{
        .initializers = &initializers,
        .members = &members,
        .member_storage = @ptrCast(&member_output.buffer),
        .ports = &.{
            .declared = &.{ .input_type = @backingInt(input.program.input_type), .output_type = @backingInt(input.program.output_type) },
            .inputs = storage.input_types.items,
            .outputs = storage.output_types.items,
            .types = &types,
        },
    };

    errdefer allocator.free(initial_output.rows());
    errdefer allocator.free(member_output.rows());

    const selected = zx.columns.invoke(generated.executeValue, allocator, &request) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    const published = selected orelse return error.InvalidModule;
    const first: usize = @intCast(published.initializer_prefix);
    const owned = initial_output.rows();

    result.function = if (published.entry) |id| @fromBackingInt(id) else null;
    result.input_type = @fromBackingInt(published.input_type);
    result.output_type = @fromBackingInt(published.output_type);
    result.store_initializers = if (owned.len != 0) owned else if (first != 0) shared[0..first] else &.{};
    result.members = member_output.rows()[0..@intCast(published.written)];
}
