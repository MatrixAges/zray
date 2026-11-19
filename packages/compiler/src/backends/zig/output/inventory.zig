const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const available = @import("../output.zig").available;
const File = @import("../partition/placement.zig").File;
const ModuleFile = @import("../modules.zig").File;
const Module = @import("../partition.zig").Module;

pub const Groups = struct { functions: []File, support: []File };

pub fn group(allocator: std.mem.Allocator, modules: []const ModuleFile, public_count: usize) !Groups {
    const files = try allocator.alloc(File, modules.len + public_count);

    errdefer allocator.free(files);

    const destinations = files[0..modules.len];
    const count = if (comptime available) try split(allocator, modules, destinations) else seedSplit(modules, destinations);

    return .{ .functions = files[0..count], .support = files[count..] };
}

fn split(allocator: std.mem.Allocator, modules: []const ModuleFile, files: []File) !usize {
    const entry = @import("generated_output_inventory");
    const names = memory.borrowTextColumn("name", modules);
    const bodies = memory.borrowTextColumn("source", modules);
    const paths = memory.borrowWriteColumn([]const u8, "path", files);
    const sources = memory.borrowWriteColumn([]const u8, "source", files);

    const input: std.meta.Child(entry.Input) = .{
        .names = @ptrCast(&names),
        .bodies = @ptrCast(&bodies),
        .paths = @ptrCast(&paths),
        .sources = @ptrCast(&sources),
        .length = modules.len,
    };

    return @intCast(try zx.columns.invoke(entry.executeValue, allocator, &input));
}

fn seedSplit(modules: []const ModuleFile, files: []File) usize {
    const prefix = "zxc_module_";
    var count: usize = 0;

    for (modules) |module| count += @intFromBool(std.mem.startsWith(u8, module.name, prefix));

    var function: usize = 0;
    var support = count;

    for (modules) |module| {
        const file: File = .{ .path = module.name, .source = module.source };

        if (std.mem.startsWith(u8, module.name, prefix)) {
            files[function] = file;

            function += 1;
        } else {
            files[support] = file;
            support += 1;
        }
    }

    return count;
}

pub fn originals(allocator: std.mem.Allocator, functions: []const File, files: []File, roots: []Module) !void {
    if (comptime !available) {
        for (functions, files, roots) |function, *file, *root| {
            root.* = .{ .name = std.fs.path.stem(function.path), .file = function.path };
            file.* = .{ .path = try std.fs.path.join(allocator, &.{ "original", function.path }), .source = function.source };
        }

        return;
    }

    const entry = @import("generated_output_originals");
    const names = memory.borrowTextColumn("path", functions);
    const bodies = memory.borrowTextColumn("source", functions);
    const paths = memory.borrowWriteColumn([]const u8, "path", files);
    const sources = memory.borrowWriteColumn([]const u8, "source", files);
    const root_names = memory.borrowWriteColumn([]const u8, "name", roots);
    const root_paths = memory.borrowWriteColumn([]const u8, "file", roots);

    const input: std.meta.Child(entry.Input) = .{
        .names = @ptrCast(&names),
        .bodies = @ptrCast(&bodies),
        .paths = @ptrCast(&paths),
        .sources = @ptrCast(&sources),
        .length = functions.len,
        .separator = std.fs.path.sep_str,
        .root_names = @ptrCast(&root_names),
        .root_paths = @ptrCast(&root_paths),
    };

    try zx.columns.invoke(entry.executeValue, allocator, &input);
}
