const std = @import("std");
const zx = @import("zx");
const memory = zx.memory;
const available = @import("../output.zig").available;
const File = @import("../partition/placement.zig").File;
const ModuleFile = @import("../modules.zig").File;
const FunctionFiles = @import("../partition/layout.zig").FunctionFiles;

pub const Groups = struct { functions: []File, support: []File };

pub fn group(allocator: std.mem.Allocator, modules: []const ModuleFile) !Groups {
    const files = try allocator.alloc(File, modules.len);

    errdefer allocator.free(files);

    const count = if (comptime available) try split(allocator, modules, files) else seedSplit(modules, files);

    return .{ .functions = files[0..count], .support = files[count..] };
}

fn split(allocator: std.mem.Allocator, modules: []const ModuleFile, files: []File) !usize {
    const entry = @import("generated_output_inventory");
    const source = memory.borrowReadFields(.{ .names = "name", .bodies = "source" }, modules);
    const target = memory.borrowWriteFields(.{ .paths = "path", .sources = "source" }, files);
    const Input = std.meta.Child(entry.Input);
    var input: Input = undefined;

    source.fill(&input);
    target.fill(&input);

    input.length = modules.len;

    return @intCast(try zx.columns.invoke(entry.executeValue, allocator, @as(*const Input, &input)));
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

pub fn originals(allocator: std.mem.Allocator, workspace: std.mem.Allocator, functions: []const File, files: []File) !FunctionFiles {
    const function_paths = try workspace.alloc([]const u8, functions.len);
    const function_names = try workspace.alloc([]const u8, functions.len);
    const function_sizes = try workspace.alloc(u64, functions.len);
    const inventory: FunctionFiles = .{ .paths = function_paths, .names = function_names, .sizes = function_sizes };

    if (comptime !available) {
        for (functions, files, function_paths, function_names, function_sizes) |function, *file, *path, *name, *size| {
            path.* = function.path;
            name.* = std.fs.path.stem(function.path);
            size.* = function.source.len;
            file.* = .{ .path = try std.fs.path.join(allocator, &.{ "original", function.path }), .source = function.source };
        }

        return inventory;
    }

    const entry = @import("generated_output_originals");
    const source = memory.borrowReadFields(.{ .names = "path", .bodies = "source" }, functions);
    const target = memory.borrowWriteFields(.{ .paths = "path", .sources = "source" }, files);
    const Input = std.meta.Child(entry.Input);
    var input: Input = undefined;

    source.fill(&input);
    target.fill(&input);

    input.length = functions.len;
    input.separator = std.fs.path.sep_str;
    input.function_paths = @ptrCast(&function_paths);
    input.function_names = @ptrCast(&function_names);
    input.function_sizes = @ptrCast(&function_sizes);

    try zx.columns.invoke(entry.executeValue, allocator, @as(*const Input, &input));

    return inventory;
}
