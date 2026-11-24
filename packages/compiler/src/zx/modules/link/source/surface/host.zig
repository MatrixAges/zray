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
const Entry = @import("../entry/host.zig").Entry;
const generated = @import("generated_source_surface");
const Input = std.meta.Child(generated.Input);
const Declarations = std.meta.Child(@typeInfo(@FieldType(Input, "declarations")).optional.child);
const Surface = @import("../../../artifact/surface.zig").Publication(std.meta.Child(@FieldType(Declarations, "rows")));
const Initializers = std.meta.Child(@FieldType(Input, "initializers"));
const Members = std.meta.Child(@FieldType(Input, "members"));
const Ports = std.meta.Child(@FieldType(Input, "ports"));
const Mapping = std.meta.Child(@FieldType(Ports, "types"));
const Prefix = std.meta.Child(@typeInfo(@FieldType(Initializers, "prefix")).optional.child);
const InitTarget = std.meta.Child(@FieldType(Initializers, "target"));
const MemberTarget = std.meta.Child(@FieldType(Members, "target"));

pub fn publish(body: *const Source.Body, nodes: *Nodes, tail: *const ir.FunctionTable, type_prefix: usize, values: []const Initializer) Error!void {
    const input = body.input;
    const output = body.output;
    const allocator = nodes.allocator;
    const storage = body.destination.functions;

    var entry: Entry = .{
        .program = &input.program,
        .storage = storage,
        .nodes = nodes,
        .temporary = body.destination.temporary,
    };

    const functions = remap.idMapping(Mapping, nodes.functions);
    const types = remap.typeMapping(Mapping, nodes.types);
    const shared = body.shared_initializers;
    const initial_rows = memory.borrowReadFields(.{ .identity = "identity", .function = "function", .schema_version = "schema_version" }, values);

    const prefix: ?Prefix = if (values.len == 0 or shared.len == 0 or nodes.functions != .range) null else .{
        .left = &.{ .data = initial_rows.column("identity").bytes, .count = values.len },
        .right = &.{ .data = std.mem.sliceAsBytes(shared), .count = shared.len },
        .stride = @sizeOf(Initializer),
        .identity_offset = @offsetOf(Initializer, "identity"),
        .function_id = @offsetOf(Initializer, "function"),
        .schema_version = @offsetOf(Initializer, "schema_version"),
        .little_endian = @import("builtin").target.cpu.arch.endian() == .little,
        .shared = values.ptr == shared.ptr,
        .identity = true,
        .function_prefix = nodes.functions.range.prefix,
    };

    var initial_output: memory.RowOutput(Initializer, InitTarget, .{}) = undefined;

    initial_output.init();

    const initializers: Initializers = .{
        .source = &initial_rows.bind(std.meta.Child(@FieldType(Initializers, "source"))),
        .functions = zx.columns.pointer(@FieldType(Initializers, "functions"), &functions),
        .end = values.len,
        .prefix = if (prefix) |*found| found else null,
        .target = &initial_output.view,
        .storage = @ptrCast(&initial_output.buffer),
        .shared = std.mem.sliceAsBytes(shared),
    };

    const member_source = input.members;
    const member_rows = memory.borrowReadFields(.{ .names = "name", .intrinsics = "intrinsic", .ids = "id", .inputs = "input_type", .outputs = "output_type" }, member_source);

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
        .anonymous = .Entry,
        .first = 0,
        .source = &member_rows.bind(std.meta.Child(@FieldType(Members, "source"))),
        .target = &member_output.view,
        .entry = null,
        .type_ids = if (member_source.len == 0) &.{} else @ptrCast(nodes.types.mapped),
        .functions = zx.columns.pointer(@FieldType(Members, "functions"), &functions),
    };

    const program = &input.program;
    const declared = program.exports.len != 0 or program.constant_exports.len != 0;
    var surface: Surface = undefined;
    var export_types: memory.ReadColumn = undefined;
    var declarations: Declarations = undefined;

    if (declared) {
        surface.init(program.exports, program.constant_exports, nodes.types);

        export_types = memory.borrowReadColumn(ir.TypeId, "type_id", program.exports);
        declarations = .{ .rows = &surface.input, .export_types = @ptrCast(&export_types), .prefix = if (input.owned_declarations) type_prefix else 0 };
    }

    errdefer if (declared) surface.release(allocator);

    const request: Input = .{
        .entry = &entry.bind(tail, body.prefix),
        .function_storage = @ptrCast(&entry),
        .declarations = if (declared) &declarations else null,
        .initializers = &initializers,
        .members = &members,
        .member_storage = @ptrCast(&member_output.buffer),
        .ports = &.{
            .declared = &.{ .input_type = @backingInt(input.program.input_type), .output_type = @backingInt(input.program.output_type) },
            .inputs = @ptrCast(&storage.input_types.items),
            .outputs = @ptrCast(&storage.output_types.items),
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
    const result = output.surface;

    result.exports = if (declared and surface.exports().len != 0) surface.exports() else program.exports;
    result.constant_exports = if (declared and surface.constants().len != 0) surface.constants() else program.constant_exports;
    output.function.* = published.entry;
    result.input_type = @fromBackingInt(published.input_type);
    result.output_type = @fromBackingInt(published.output_type);
    result.store_initializers = if (owned.len != 0) owned else if (first != 0) shared[0..first] else &.{};
    result.members = member_output.rows()[0..@intCast(published.written)];
}
