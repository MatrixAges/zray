const std = @import("std");
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;
const BuiltinLayout = @import("native_resource_abi").layouts.@"zig:native_resource_host".Builtin;
const Builtin = @import("native_resource_abi").native.@"zig:native_resource_host".Builtin;

pub fn scanBuiltins(handle: *const anyopaque, content: []const u8) Error![]const Builtin {
    const self = Context.get(handle);
    // readPending owns a zero-terminated buffer and the Store retains its slice.
    const source = content.ptr[0..content.len :0];
    var tree = std.zig.Ast.parse(self.allocator, source, .{}) catch |err| return self.fail(err);

    defer tree.deinit(self.allocator);

    if (tree.errors.len != 0) return self.fail(error.InvalidNativeSource);

    var items: std.ArrayList(BuiltinLayout) = .empty;

    errdefer items.deinit(self.allocator);

    var node_index: usize = 0;

    while (node_index < tree.nodes.len) : (node_index += 1) {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(node_index));
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const arguments = tree.builtinCallParams(&buffer, node) orelse continue;

        const literal = if (arguments.len == 1 and tree.nodeTag(arguments[0]) == .string_literal)
            tree.tokenSlice(tree.nodeMainToken(arguments[0]))

        else
            null;

        items.append(self.allocator, .{
            .name = tree.tokenSlice(tree.nodeMainToken(node)),
            .arguments = arguments.len,
            .literal = literal,
        }) catch |err| return self.fail(err);
    }

    const values = items.toOwnedSlice(self.allocator) catch |err| return self.fail(err);
    const ptrs = self.allocator.alloc(Builtin, values.len) catch |err| return self.fail(err);

    for (values, ptrs) |*value, *slot| {
        slot.* = value;
    }

    return ptrs;
}

pub fn decodeLiteral(handle: *const anyopaque, raw: []const u8) Error![]const u8 {
    const self = Context.get(handle);

    return std.zig.string_literal.parseAlloc(self.allocator, raw) catch |err| return self.fail(err);
}

pub fn invalidBuiltin(handle: *const anyopaque, invalid_import: bool) Error!void {
    const self = Context.get(handle);

    return self.fail(if (invalid_import) error.InvalidNativeImport else error.InvalidNativeSource);
}
