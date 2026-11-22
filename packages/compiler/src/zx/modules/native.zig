const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Native = @import("interface.zig").Native;
const Members = @import("native/members.zig");
const Types = @import("../analysis/types.zig");
pub const Member = Members.Member;

pub const PublishedMembers = if (@import("parser_options").generated_parser)
    []const @import("function_import.zig")

else
    []const Member;

pub const Result = struct {
    types: ir.TypeTable,
    exports: []const ir.Export,
    members: PublishedMembers,
    namespace: ?[]const []const u8 = null,
};

pub const Target = struct {
    types: *ir.TypeStorage,
    origins: ?*@import("nominal_origins.zig") = null,
    functions: ?*ir.FunctionStorage = null,
    owner: ?[]const u8 = null,
};

pub fn load(arena: *std.heap.ArenaAllocator, entry: Native, module: ir.NativeModuleId, target: Target, reporter: *zx.Reporter, span: zx.Span) zx.Error!Result {
    const allocator = arena.allocator();
    var local: zx.Reporter = .{};

    const analyzed = (if (comptime @import("parser_options").generated_parser)
        @import("native/interface.zig").analyze(allocator, entry, module, target, &local)
    else
        analyzeSeed(arena, entry, module, target, &local)) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        const issue = local.diagnostic.?;
        const location = zx.source.locate(entry.source, issue.span.start);
        const message = try std.fmt.allocPrint(allocator, "{s}:{d}:{d}: {s}", .{ entry.path, location.line, location.column, issue.message });

        return reporter.fail(issue.code, span, message);
    };

    return .{ .types = target.types.view(), .exports = analyzed.exports, .members = analyzed.members, .namespace = analyzed.namespace };
}

fn analyzeSeed(arena: *std.heap.ArenaAllocator, entry: Native, module: ir.NativeModuleId, target: Target, reporter: *zx.Reporter) zx.Error!@import("native/interface.zig").Result {
    var types = Types{ .native_interface = true, .allocator = arena.allocator(), .reporter = reporter, .declarations = &.{}, .shared = if (target.origins) |items| Types.Shared{ .origins = items, .origin = .{ .native = entry.key() } } else null };

    types.items = target.types.*;
    target.types.* = .{};
    defer target.types.* = types.items;

    return @import("native/seed.zig").analyze(arena, &types, entry, module);
}
