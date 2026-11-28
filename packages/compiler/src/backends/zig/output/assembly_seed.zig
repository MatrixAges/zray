const std = @import("std");
const assembly = @import("assembly.zig");
const Bundle = @import("../library.zig").Bundle;
const File = @import("../partition.zig").File;
pub const hash_batch = 32;

pub fn positions(counts: assembly.Counts) assembly.Sections {
    const adapters = 1;
    const support = adapters + counts.public_count;
    const public_files = support + counts.support_count;
    const signatures = public_files + counts.public_count;
    const originals = signatures + 1;
    const original_root = originals + counts.function_count;
    const root = if (counts.partitioned) original_root + 1 else signatures;

    return .{ .adapters = adapters, .support = support, .public_files = public_files, .signatures = signatures, .originals = originals, .original_root = original_root, .root = root, .length = root + 1 };
}

pub fn fill(allocator: std.mem.Allocator, bundle: *const Bundle, support: []const File, tree: assembly.Assembly, partitioned: bool) !void {
    const slots = tree.sections;
    const files = tree.files;
    files[0] = .{ .path = "types.zig", .source = bundle.types };
    files[slots.root].path = "root.zig";

    @memcpy(files[slots.support..slots.public_files], support);

    for (bundle.public_modules, tree.modules, 0..) |module, *exported, index| {
        const path = try std.fmt.allocPrint(allocator, "{s}.zig", .{module.file.name});

        files[slots.public_files + index] = .{ .path = path, .source = module.file.source };
        files[slots.adapters + index].path = try std.fmt.allocPrint(allocator, "{s}.zig", .{module.name});
        exported.* = .{ .name = module.name, .file = path };
    }

    if (partitioned) {
        files[slots.signatures] = .{ .path = "signatures.zig", .source = bundle.signatures orelse "" };
        files[slots.original_root].path = "original/root.zig";
    }
}
