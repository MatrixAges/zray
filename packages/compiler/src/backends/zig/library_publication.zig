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
    const ids = memory.borrowListColumn(?u32, "members", "id", exports);
    const sizes = try capacity(exports, &ids);
    const capacity_members = sizes.members;
    const total = sizes.roots;
    const regular = try workspace.alloc(u8, if (capacity_members == 0) 0 else function_count);

    @memset(regular, 0);

    var target: Plan = .{
        .roots = try workspace.alloc(FunctionId, total),
        .member_ids = try workspace.alloc(FunctionId, capacity_members),
        .members = try workspace.alloc(PublicMember, capacity_members),
        .ends = try workspace.alloc(u64, exports.len),
        .regular = regular,
    };

    if (comptime !@import("parser_options").generated_parser) return @import("library_publication_seed.zig").collect(exports, target);

    const rule = @import("generated_library_publication");
    const Input = std.meta.Child(rule.Input);
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const Buffers = std.meta.Child(@FieldType(Input, "target"));
    const defaults = memory.borrowOptionalU32Column("function", exports);
    const names = memory.borrowListColumn([]const u8, "members", "name", exports);
    var roots = primitive(target.roots);
    var member_ids = primitive(target.member_ids);
    var members = memory.borrowNamedRows("function", target.members);

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

const Capacity = struct { roots: usize, members: usize };

fn capacity(exports: []const Export, ids: *const memory.ListColumn) std.mem.Allocator.Error!Capacity {
    if (comptime !@import("parser_options").generated_parser) {
        var members: usize = 0;

        for (exports) |*exported| members = std.math.add(usize, members, exported.members.len) catch return error.OutOfMemory;

        return .{ .roots = std.math.add(usize, members, exports.len) catch return error.OutOfMemory, .members = members };
    }

    const rule = @import("generated_library_publication_capacity");
    const input: std.meta.Child(rule.Input) = .{ .count = exports.len, .member_ids = @ptrCast(ids) };
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const sizes = zx.columns.invoke(rule.executeValue, fixed.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .roots = std.math.cast(usize, sizes.roots) orelse return error.OutOfMemory,
        .members = std.math.cast(usize, sizes.members) orelse return error.OutOfMemory,
    };
}

pub fn complete(exports: []const Export, type_only: bool, modules: []@import("library.zig").PublicModule, sources: []const []const u8) void {
    if (comptime !@import("parser_options").generated_parser) {
        for (exports, modules, sources) |*exported, *module, source| {
            module.file.source = source;
            module.constant_only = type_only and exported.function == null and exported.constants.len != 0 and exported.types.len == 0 and exported.members.len == 0;
        }

        return;
    }

    const rule = @import("generated_library_publication_complete");
    const members = memory.borrowListColumn(?u32, "members", "id", exports);
    const types = memory.borrowListColumn([]const u8, "types", "name", exports);
    const constants = memory.borrowListColumn([]const u8, "constants", "name", exports);
    const defaults = memory.borrowOptionalU32Column("function", exports);
    var file_sources = memory.borrowNestedWriteColumn([]const u8, &.{ "file", "source" }, modules);
    var constants_only = memory.borrowWriteColumn(bool, "constant_only", modules);

    const input: std.meta.Child(rule.Input) = .{
        .count = exports.len,
        .member_ids = @ptrCast(&members),
        .types = @ptrCast(&types),
        .constants = @ptrCast(&constants),
        .defaults = @ptrCast(&defaults),
        .type_only = type_only,
        .sources = sources,
        .source_files = @ptrCast(&file_sources),
        .constants_only = @ptrCast(&constants_only),
    };

    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeValue, fixed.allocator(), &input) catch unreachable;
}

pub fn fileNames(allocator: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (names.len == 0) return &.{};

    var target = try allocator.alloc([]const u8, names.len);

    errdefer allocator.free(target);

    if (comptime !@import("parser_options").generated_parser) {
        for (names, target) |name, *path| path.* = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});

        return target;
    }

    const layout = @import("generated_library_function_name_bytes");
    const publish = @import("generated_library_function_file_names");
    var fixed = std.heap.FixedBufferAllocator.init(&.{});

    const bytes = layout.executeValue(fixed.allocator(), names) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    var data = try allocator.alloc(u8, std.math.cast(usize, bytes) orelse return error.OutOfMemory);

    errdefer allocator.free(data);

    const input: std.meta.Child(publish.Input) = .{ .names = names, .data = data, .buffer = @ptrCast(&data), .target = @ptrCast(&target) };

    zx.columns.invoke(publish.executeValue, fixed.allocator(), &input) catch unreachable;

    return target;
}
