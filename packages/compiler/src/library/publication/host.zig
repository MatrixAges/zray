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
    const type_rows = memory.borrowNamedRows("type_id", program.exports);

    const types: Types = .{
        .source = @ptrCast(&type_rows),
        .count = type_rows.len,
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

    const input: Input = .{
        .types = &types,
        .constants = &constants,
        .members = &member_output.input,
        .row = &.{
            .name = source.name,
            .path = program.file_name,
        },
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (result.status) {
        .Valid => {
            const public_types = try allocator.alloc(ir.Export, result.exports.len);

            for (result.exports, public_types) |item, *slot| {
                slot.* = .{ .name = item.name, .type_id = @fromBackingInt(item.type_id) };
            }

            exports[index] = .{
                .name = result.name,
                .path = result.path,
                .function = entry,
                .types = public_types,
                .constants = constant_output.rows(),
                .members = member_output.output.rows(),
            };
        },
        .ConflictingInterface => return error.ConflictingInterface,
        .InvalidModule => return error.InvalidModule,
    }
}
