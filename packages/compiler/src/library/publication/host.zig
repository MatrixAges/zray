const std = @import("std");
const zx = @import("zx");
const frontend = @import("frontend");
const ir = zx.ir;
const memory = zx.memory;
const model = @import("../root.zig");
const members = @import("../members.zig");
const Nodes = frontend.ArtifactNodes;
const Error = frontend.project.artifact.Error || error{ConflictingInterface};
const generated = @import("parser_options").generated_parser;

pub fn publish(allocator: std.mem.Allocator, exports: []model.Export, index: usize, source: model.Input, entry: ?ir.FunctionId, nodes: *Nodes) Error!void {
    const program = &source.analysis.value.ir;

    if (comptime !generated) {
        const types = try @import("../interface.zig").completeSeed(allocator, program.*, nodes.types);
        const constants = try nodes.constants(program.constant_exports);
        const bindings = try members.completeSeed(allocator, source.analysis, program.file_name, nodes);

        exports[index] = .{
            .name = try allocator.dupe(u8, source.name),
            .path = try allocator.dupe(u8, program.file_name),
            .function = entry,
            .types = types,
            .constants = constants,
            .members = bindings,
        };

        return;
    }

    const rule = @import("generated_library_source_exports");
    const Input = std.meta.Child(rule.Input);
    const Types = std.meta.Child(@FieldType(Input, "types"));
    const Constants = std.meta.Child(@FieldType(Input, "constants"));
    const ConstantTarget = std.meta.Child(@FieldType(Constants, "target"));
    const Mapping = std.meta.Child(@FieldType(Constants, "types"));
    const MemberInput = std.meta.Child(@FieldType(Input, "members"));
    const Row = std.meta.Child(@FieldType(Input, "row"));
    const Target = std.meta.Child(@FieldType(Row, "target"));
    const type_rows = memory.borrowNamedRows("type_id", program.exports);
    var public_types: []memory.NamedId = &.{};

    const types: Types = .{
        .source = @ptrCast(&type_rows),
        .count = type_rows.len,
        .target = @ptrCast(&public_types),
        .mapping = @ptrCast(nodes.types.mapped),
        .input_type = @backingInt(program.input_type),
        .output_type = @backingInt(program.output_type),
        .executable = !program.type_only,
    };

    const values = frontend.ConstantRows.borrow(program.constant_exports);
    const constant_source = values.view(std.meta.Child(@FieldType(Constants, "source")));
    const mapping = Nodes.typeMapping(Mapping, nodes.types);

    var constant_output: memory.RowOutput(ir.Constant, ConstantTarget, .{
        .names = &.{"name"},
        .types = &.{"type_id"},
        .values = &.{"value"},
    }) = undefined;

    constant_output.init();

    const constants: Constants = .{
        .source = &constant_source,
        .target = &constant_output.view,
        .types = &mapping,
        .storage = @ptrCast(&constant_output.buffer),
    };

    var member_output: members.View(MemberInput) = undefined;

    member_output.init(source.analysis, program.file_name, nodes);

    var names = memory.borrowWriteColumn([]const u8, "name", exports);
    var paths = memory.borrowWriteColumn([]const u8, "path", exports);
    var functions = memory.borrowWriteColumn(?ir.FunctionId, "function", exports);
    var type_lists = memory.borrowWriteColumn([]const ir.Export, "types", exports);
    var constant_lists = memory.borrowWriteColumn([]const ir.Constant, "constants", exports);
    var member_lists = memory.borrowWriteColumn(@FieldType(model.Export, "members"), "members", exports);

    const target: Target = .{
        .name = @ptrCast(&names),
        .path = @ptrCast(&paths),
        .function = @ptrCast(&functions),
        .types = @ptrCast(&type_lists),
        .constants = @ptrCast(&constant_lists),
        .members = @ptrCast(&member_lists),
    };

    const input: Input = .{
        .types = &types,
        .constants = &constants,
        .members = &member_output.input,
        .row = &.{
            .target = &target,
            .name = source.name,
            .path = program.file_name,
            .function = if (entry) |id| @backingInt(id) else null,
            .index = index,
        },
    };

    const status = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Valid => {},
        .ConflictingInterface => error.ConflictingInterface,
        .InvalidModule => error.InvalidModule,
    };
}
