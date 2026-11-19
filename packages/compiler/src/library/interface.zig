const std = @import("std");
const frontend = @import("frontend");
const ir = @import("zx").ir;
const TypeMap = frontend.ArtifactNodes.TypeMap;
const Error = frontend.project.artifact.Error || error{ConflictingInterface};

pub fn completeSeed(allocator: std.mem.Allocator, program: ir.Program, types: TypeMap) Error![]const ir.Export {
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
