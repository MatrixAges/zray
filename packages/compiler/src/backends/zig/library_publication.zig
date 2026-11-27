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

    if (comptime !@import("parser_options").generated_parser) {
        const sizes = try capacity(exports, &ids);
        const regular = try workspace.alloc(u8, if (sizes.members == 0) 0 else function_count);

        @memset(regular, 0);

        return @import("library_publication_seed.zig").collect(exports, .{
            .roots = try workspace.alloc(FunctionId, sizes.roots),
            .member_ids = try workspace.alloc(FunctionId, sizes.members),
            .members = try workspace.alloc(PublicMember, sizes.members),
            .ends = try workspace.alloc(u64, exports.len),
            .regular = regular,
        });
    }

    const rule = @import("generated_library_publication");
    const Input = std.meta.Child(rule.Input);
    const Source = std.meta.Child(@FieldType(Input, "source"));
    const defaults = memory.borrowOptionalU32Column("function", exports);
    const names = memory.borrowListColumn([]const u8, "members", "name", exports);

    const input: Input = .{
        .source = &Source{
            .count = exports.len,
            .defaults = @ptrCast(&defaults),
            .member_ids = @ptrCast(&ids),
            .member_names = @ptrCast(&names),
        },
    };

    const collected = zx.columns.invoke(rule.executeValue, workspace, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    const regular = try workspace.alloc(u8, if (collected.member_ids.len == 0) 0 else function_count);

    @memset(regular, 0);

    const members = try workspace.alloc(PublicMember, collected.members.len);
    const ids_typed: []const FunctionId = @ptrCast(collected.member_ids);

    for (collected.members, ids_typed, members) |item, id, *slot| {
        slot.* = .{ .name = item.name, .function = id };

        regular[@backingInt(id)] = 1;
    }

    return .{
        .roots = try workspace.dupe(FunctionId, @ptrCast(collected.roots)),
        .member_ids = try workspace.dupe(FunctionId, ids_typed),
        .members = members,
        .ends = try workspace.dupe(u64, collected.ends),
        .regular = regular,
    };
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

pub fn complete(allocator: std.mem.Allocator, exports: []const Export, type_only: bool, modules: []@import("library.zig").PublicModule, sources: []const []const u8) std.mem.Allocator.Error!void {
    for (modules, sources) |*module, source| module.file.source = source;

    if (comptime !@import("parser_options").generated_parser) {
        for (exports, modules) |*exported, *module| {
            module.constant_only = type_only and exported.function == null and exported.constants.len != 0 and exported.types.len == 0 and exported.members.len == 0;
        }

        return;
    }

    const rule = @import("generated_library_publication_complete");
    const members = memory.borrowListColumn(?u32, "members", "id", exports);
    const types = memory.borrowListColumn([]const u8, "types", "name", exports);
    const constants = memory.borrowListColumn([]const u8, "constants", "name", exports);
    const defaults = memory.borrowOptionalU32Column("function", exports);

    const input: std.meta.Child(rule.Input) = .{
        .count = exports.len,
        .member_ids = @ptrCast(&members),
        .types = @ptrCast(&types),
        .constants = @ptrCast(&constants),
        .defaults = @ptrCast(&defaults),
        .type_only = type_only,
    };

    const flags = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    for (modules, flags) |*module, flag| module.constant_only = flag;
}

pub fn fileNames(allocator: std.mem.Allocator, names: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (names.len == 0) return &.{};

    if (comptime !@import("parser_options").generated_parser) {
        const target = try allocator.alloc([]const u8, names.len);

        errdefer allocator.free(target);

        for (names, target) |name, *path| path.* = try std.fmt.allocPrint(allocator, "{s}.zig", .{name});

        return target;
    }

    const publish = @import("generated_library_function_file_names");

    return publish.executeValue(allocator, names) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}
