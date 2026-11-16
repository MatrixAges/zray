const std = @import("std");
const zx = @import("zx");
const memory = @import("zx").memory;
const Export = @import("../../library/root.zig").Export;
const FunctionId = zx.ir.FunctionId;
const PublicMember = @import("genz").zx.modules.PublicMember;

pub const Plan = struct {
    roots: []FunctionId,
    member_ids: []FunctionId,
    members: []PublicMember,
    ends: []u64,
    regular: []u8,
};

pub fn create(workspace: std.mem.Allocator, exports: []const Export, function_count: usize) std.mem.Allocator.Error!Plan {
    var capacity: usize = 0;

    for (exports) |*exported| capacity = std.math.add(usize, capacity, exported.members.len) catch return error.OutOfMemory;

    const total = std.math.add(usize, capacity, exports.len) catch return error.OutOfMemory;
    const regular = try workspace.alloc(u8, if (capacity == 0) 0 else function_count);

    @memset(regular, 0);

    const target: Plan = .{
        .roots = try workspace.alloc(FunctionId, total),
        .member_ids = try workspace.alloc(FunctionId, capacity),
        .members = try workspace.alloc(PublicMember, capacity),
        .ends = try workspace.alloc(u64, exports.len),
        .regular = regular,
    };

    if (comptime !@import("parser_options").generated_parser) return @import("library_publication_seed.zig").collect(exports, target);

    const rule = @import("generated_library_publication");
    const Input = std.meta.Child(rule.Input);
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const Buffers = std.meta.Child(@FieldType(Input, "target"));
    const defaults = memory.borrowOptionalU32Column("function", exports);
    const ids = memory.borrowListColumn(?u32, "members", "id", exports);
    const names = memory.borrowListColumn([]const u8, "members", "name", exports);
    const roots = primitive(target.roots);
    const member_ids = primitive(target.member_ids);
    const members = memory.borrowNamedRows("function", target.members);

    const input: Input = .{
        .source = &Source{
            .count = exports.len,
            .defaults = @ptrCast(&defaults),
            .member_ids = @ptrCast(&ids),
            .member_names = @ptrCast(&names),
        },
        .target = &Buffers{
            .roots = @ptrCast(&roots),
            .member_ids = @ptrCast(&member_ids),
            .members = @ptrCast(&members),
            .ends = @ptrCast(&target.ends),
            .regular = @ptrCast(&target.regular),
        },
    };

    const counts = zx.columns.invoke(rule.executeValue, workspace, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    var result = target;

    result.roots = target.roots[0..@intCast(counts.roots)];
    result.members = target.members[0..@intCast(counts.members)];
    result.member_ids = target.member_ids[0..result.members.len];

    return result;
}

fn primitive(ids: []FunctionId) []u32 {
    return @as([*]u32, @ptrCast(ids.ptr))[0..ids.len];
}
