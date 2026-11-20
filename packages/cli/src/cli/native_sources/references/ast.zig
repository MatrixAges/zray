const std = @import("std");
const storage = @import("../storage.zig");
const Context = storage.Context;
const Error = storage.Error;

pub fn openAst(handle: *const anyopaque) Error!void {
    const self = Context.get(handle);

    self.ast = std.zig.Ast.parse(self.allocator, self.bytes, .{}) catch |err| return self.fail(err);
    self.node_index = 0;

    self.references.clearRetainingCapacity();

    if (self.ast.?.errors.len != 0) return self.fail(error.InvalidNativeSource);
}

pub fn closeAst(handle: *const anyopaque) void {
    const self = Context.get(handle);

    if (self.ast) |*tree| tree.deinit(self.allocator);

    self.ast = null;
}

pub fn nextBuiltin(handle: *const anyopaque) bool {
    const self = Context.get(handle);
    const tree = &self.ast.?;

    while (self.node_index < tree.nodes.len) {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(self.node_index));
        self.node_index += 1;

        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const arguments = tree.builtinCallParams(&buffer, node) orelse continue;

        self.builtin = .{
            .name = tree.tokenSlice(tree.nodeMainToken(node)),
            .count = arguments.len,
            .parameter = if (arguments.len == 1) arguments[0] else null,
        };

        return true;
    }

    return false;
}

pub fn builtinName(handle: *const anyopaque) []const u8 {
    return Context.get(handle).builtin.name;
}

pub fn builtinArguments(handle: *const anyopaque) u64 {
    return Context.get(handle).builtin.count;
}

pub fn builtinHasLiteral(handle: *const anyopaque) bool {
    const self = Context.get(handle);
    const parameter = self.builtin.parameter orelse return false;

    return self.ast.?.nodeTag(parameter) == .string_literal;
}

pub fn decodeLiteral(handle: *const anyopaque) Error![]const u8 {
    const self = Context.get(handle);
    const tree = &self.ast.?;
    const text = tree.tokenSlice(tree.nodeMainToken(self.builtin.parameter.?));

    return std.zig.string_literal.parseAlloc(self.allocator, text) catch |err| return self.fail(err);
}

pub fn discardLiteral(handle: *const anyopaque, text: []const u8) void {
    Context.get(handle).allocator.free(text);
}

pub fn recordReference(handle: *const anyopaque, path: []const u8, source: bool) Error!void {
    const self = Context.get(handle);

    self.references.append(self.allocator, .{
        .path = path,
        .kind = if (source) .zig else .asset,
    }) catch |err| return self.fail(err);
}

pub fn invalidBuiltin(handle: *const anyopaque, invalid_import: bool) Error!void {
    const self = Context.get(handle);

    return self.fail(if (invalid_import) error.InvalidNativeImport else error.InvalidNativeSource);
}
