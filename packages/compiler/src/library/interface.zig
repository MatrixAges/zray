const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const TypeMap = frontend.ArtifactNodes.TypeMap;
const Error = frontend.project.artifact.Error || error{ConflictingInterface};
const generated = @import("parser_options").generated_parser;

pub fn complete(owned: std.mem.Allocator, program: ir.Program, types: TypeMap) Error![]const ir.Export {
    if (!generated) return completeSeed(owned, program, types);

    const entry = @import("generated_library_public_types");
    const mapping = types.mapped;
    const memory = @import("zx").memory;
    const rows = memory.borrowNamedRows("type_id", program.exports);
    var output: []memory.NamedId = &.{};

    const input: std.meta.Child(entry.Input) = .{
        .source = @ptrCast(&rows),
        .count = rows.len,
        .target = @ptrCast(&output),
        .mapping = @ptrCast(mapping),
        .input_type = if (program.type_only) 0 else @backingInt(try types.include(program.input_type)),
        .output_type = if (program.type_only) 0 else @backingInt(try types.include(program.output_type)),
        .executable = !program.type_only,
    };

    const status = @import("zx").columns.invoke(entry.executeValue, owned, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    return switch (status) {
        .Valid => @ptrCast(output),
        .ConflictingInterface => error.ConflictingInterface,
        .InvalidModule => error.InvalidModule,
    };
}

fn completeSeed(allocator: std.mem.Allocator, program: ir.Program, types: TypeMap) Error![]const ir.Export {
    var exports: std.ArrayList(ir.Export) = .empty;

    for (program.exports) |item| try exports.append(allocator, .{ .name = try allocator.dupe(u8, item.name), .type_id = try types.include(item.type_id) });

    if (!program.type_only) {
        for ([_]ir.Export{ .{ .name = "Input", .type_id = program.input_type }, .{ .name = "Output", .type_id = program.output_type } }) |signature| {
            const type_id = try types.include(signature.type_id);
            var found = false;

            for (exports.items) |item| if (std.mem.eql(u8, item.name, signature.name)) {
                if (item.type_id != type_id) return error.ConflictingInterface;

                found = true;
            };

            if (!found) try exports.append(allocator, .{ .name = try allocator.dupe(u8, signature.name), .type_id = type_id });
        }
    }

    return exports.items;
}
