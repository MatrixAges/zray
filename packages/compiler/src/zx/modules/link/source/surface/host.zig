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
const InitTarget = std.meta.Child(@typeInfo(@FieldType(Initializers, "target")).optional.child);
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

    var initializers: Initializers = .{
        .source = &.{ .identity = @ptrCast(&left), .function = @ptrCast(&initial_ids), .schema_version = @ptrCast(&schemas) },
        .functions = zx.columns.pointer(@FieldType(Initializers, "functions"), &functions),
        .start = 0,
        .end = values.len,
        .prefix = if (prefix) |*found| found else null,
        .target = null,
        .done = false,
    };

    const member_source = input.members;
    const names = memory.borrowTextColumn("name", member_source);
    const intrinsics = memory.borrowOptionalU8Column("intrinsic", member_source);
    const ids = memory.borrowOptionalU32Column("id", member_source);
    const inputs = memory.borrowOptionalU32Column("input_type", member_source);
    const outputs = memory.borrowOptionalU32Column("output_type", member_source);

    var members: Members = .{
        .source = &.{
            .names = @ptrCast(&names),
            .intrinsics = @ptrCast(&intrinsics),
            .ids = @ptrCast(&ids),
            .inputs = @ptrCast(&inputs),
            .outputs = @ptrCast(&outputs),
            .count = member_source.len,
        },
        .target = &empty_target,
        .entry = if (entry) |id| @backingInt(id) else null,
        .type_ids = if (member_source.len == 0) &.{} else @ptrCast(nodes.types.mapped),
        .functions = zx.columns.pointer(@FieldType(Members, "functions"), &functions),
    };

    var request: Input = .{
        .initializers = &initializers,
        .members = &members,
        .member_storage = false,
        .ports = &.{
            .declared = &.{ .input_type = @backingInt(input.program.input_type), .output_type = @backingInt(input.program.output_type) },
            .inputs = storage.input_types.items,
            .outputs = storage.output_types.items,
            .types = &types,
        },
    };

    var initial_columns: InitColumns = undefined;
    var member_columns: MemberColumns = undefined;
    var owned_initializers: []Initializer = &.{};
    var owned_members: []Binding = &.{};
    var initial_target: InitTarget = undefined;
    var member_target: MemberTarget = undefined;

    errdefer allocator.free(owned_initializers);
    errdefer allocator.free(owned_members);

    while (true) {
        const selected = zx.columns.invoke(generated.executeValue, allocator, @as(*const Input, &request)) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        const stage = selected orelse return error.InvalidModule;
        const first: usize = @intCast(stage.initializer_prefix);

        switch (stage.allocation) {
            .Initializers => {
                owned_initializers = try allocator.alloc(Initializer, values.len);

                @memcpy(owned_initializers[0..first], shared[0..first]);

                initial_columns = .{
                    .identity = memory.borrowWriteColumn([]const u8, "identity", owned_initializers),
                    .function = memory.borrowWriteColumn(u32, "function", owned_initializers),
                    .schema_version = memory.borrowWriteColumn(u32, "schema_version", owned_initializers),
                };

                initial_target = view(InitTarget, &initial_columns);
                initializers.target = &initial_target;
                initializers.start = first;
            },
            .Members => {
                owned_members = try allocator.alloc(Binding, member_source.len);

                member_columns = .{
                    .names = memory.borrowWriteColumn([]const u8, "name", owned_members),
                    .intrinsics = memory.borrowWriteColumn(?u8, "intrinsic", owned_members),
                    .ids = memory.borrowWriteColumn(?u32, "id", owned_members),
                    .inputs = memory.borrowWriteColumn(?u32, "input_type", owned_members),
                    .outputs = memory.borrowWriteColumn(?u32, "output_type", owned_members),
                    .namespaces = memory.borrowWriteColumn(?[]const u8, "namespace", owned_members),
                };

                member_target = view(MemberTarget, &member_columns);
                members.target = &member_target;
                request.member_storage = true;
                initializers.done = true;
                initializers.start = first;
            },
            .None => {
                const published = stage.published.?;
                result.function = if (published.entry) |id| @fromBackingInt(id) else null;
                result.input_type = @fromBackingInt(published.input_type);
                result.output_type = @fromBackingInt(published.output_type);
                result.store_initializers = if (owned_initializers.len != 0) owned_initializers else if (first != 0) shared[0..first] else &.{};
                result.members = owned_members[0..@intCast(published.written)];

                return;
            },
        }
    }
}

const InitColumns = struct {
    identity: memory.WriteColumn,
    function: memory.WriteColumn,
    schema_version: memory.WriteColumn,
};

const MemberColumns = struct {
    names: memory.WriteColumn,
    intrinsics: memory.WriteColumn,
    ids: memory.WriteColumn,
    inputs: memory.WriteColumn,
    outputs: memory.WriteColumn,
    namespaces: memory.WriteColumn,
};

const empty_rows: []Binding = &.{};

const empty_columns: MemberColumns = .{
    .names = memory.borrowWriteColumn([]const u8, "name", empty_rows),
    .intrinsics = memory.borrowWriteColumn(?u8, "intrinsic", empty_rows),
    .ids = memory.borrowWriteColumn(?u32, "id", empty_rows),
    .inputs = memory.borrowWriteColumn(?u32, "input_type", empty_rows),
    .outputs = memory.borrowWriteColumn(?u32, "output_type", empty_rows),
    .namespaces = memory.borrowWriteColumn(?[]const u8, "namespace", empty_rows),
};

const empty_target = view(MemberTarget, &empty_columns);

fn view(comptime Target: type, columns: anytype) Target {
    var result: Target = undefined;

    inline for (@typeInfo(Target).@"struct".field_names) |name| {
        @field(result, name) = @ptrCast(&@field(columns, name));
    }

    return result;
}
