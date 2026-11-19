const std = @import("std");
const source_rules = @import("cli_source");
pub const Kind = enum { zig, asset };
pub const Reference = struct { path: []const u8, kind: Kind };
pub const Result = struct { references: []const Reference, dynamic_resources: bool, c_imports: bool };

pub fn read(allocator: std.mem.Allocator, source: [:0]const u8) !Result {
    var tree = try std.zig.Ast.parse(allocator, source, .{});

    defer tree.deinit(allocator);

    if (tree.errors.len != 0) return error.InvalidNativeSource;

    var references: std.ArrayList(Reference) = .empty;
    var dynamic_resources = false;
    var c_imports = false;
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    for (0..tree.nodes.len) |index| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(index));
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const parameters = tree.builtinCallParams(&buffer, node) orelse continue;
        const name = tree.tokenSlice(tree.nodeMainToken(node));

        const action = source_rules.native_reference.executeValue(memory.allocator(), &.{
            .name = name,
            .arguments = parameters.len,
            .literal = parameters.len == 1 and tree.nodeTag(parameters[0]) == .string_literal,
        }) catch unreachable;

        const kind: Kind = switch (action) {
            .Ignore => continue,
            .CImport => {
                c_imports = true;

                continue;
            },
            .InvalidSource => return error.InvalidNativeSource,
            .InvalidImport => return error.InvalidNativeImport,
            .DynamicAsset => {
                dynamic_resources = true;

                continue;
            },
            .Zig => .zig,
            .Asset => .asset,
        };

        const literal = tree.tokenSlice(tree.nodeMainToken(parameters[0]));
        const path = try std.zig.string_literal.parseAlloc(allocator, literal);

        if (kind == .zig and !(source_rules.native_local_import.executeValue(memory.allocator(), path) catch unreachable)) {
            allocator.free(path);

            continue;
        }

        try references.append(allocator, .{ .path = path, .kind = kind });
    }

    return .{ .references = references.items, .dynamic_resources = dynamic_resources, .c_imports = c_imports };
}
