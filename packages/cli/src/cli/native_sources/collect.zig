const std = @import("std");
const references = @import("../native_references.zig");
const paths = @import("publication_host").paths;
const rules = @import("cli_source");
const Inputs = @import("watch_inputs").Inputs;
const NativeModule = @import("../project.zig").NativeModule;
pub const File = struct { path: []const u8, kind: references.Kind, bytes: [:0]const u8, referenced_from: ?[]const u8 };

pub const Result = struct {
    root: []const u8,
    entry: ?[]const u8,
    files: []const File,
    index: std.StringHashMapUnmanaged(Seen),
    dynamic_resources: bool,
    c_imports: bool,
};

const Pending = struct { path: []const u8, kind: references.Kind, from: ?[]const u8 };
const Seen = struct { index: usize, parsed: bool };

pub fn read(io: std.Io, allocator: std.mem.Allocator, project_root: []const u8, module: NativeModule, inputs: ?*Inputs) !Result {
    const entry = if (module.path) |path| try std.fs.path.resolve(allocator, &.{ project_root, path }) else null;

    if (entry) |path| if (inputs) |observed| try observed.add(io, path);

    const root = if (entry) |path| std.fs.path.dirname(path).? else try std.fs.path.resolve(allocator, &.{project_root});
    const canonical_root = try std.Io.Dir.cwd().realPathFileAlloc(io, root, allocator);
    var pending: std.ArrayList(Pending) = .empty;
    var files: std.ArrayList(File) = .empty;
    var seen: std.StringHashMapUnmanaged(Seen) = .empty;

    errdefer seen.deinit(allocator);

    var dynamic_resources = false;
    var c_imports = module.header != null;
    var memory = std.heap.FixedBufferAllocator.init(&.{});

    if (entry) |path| try pending.append(allocator, .{ .path = path, .kind = .zig, .from = null });

    for (module.bundle_files) |path| {
        const absolute = try referencedPath(allocator, root, root, path);

        if (inputs) |observed| try observed.add(io, absolute);

        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, absolute, allocator);

        _ = try relativePath(allocator, canonical_root, canonical);

        for (try @import("resources.zig").files(io, allocator, absolute, inputs)) |file| {
            try pending.append(allocator, .{ .path = file, .kind = .asset, .from = null });
        }
    }

    var cursor: usize = 0;

    while (cursor < pending.items.len) : (cursor += 1) {
        const item = pending.items[cursor];
        const relative = try relativePath(allocator, root, item.path);
        const previous = seen.getPtr(relative);

        const action = rules.native_resource_visit.executeValue(memory.allocator(), &.{
            .previous_parsed = if (previous) |value| value.parsed else null,
            .source = item.kind == .zig,
        }) catch unreachable;

        if (action == .Skip) continue;
        if (inputs) |observed| try observed.add(io, item.path);

        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, item.path, allocator);

        _ = try relativePath(allocator, canonical_root, canonical);

        const bytes = if (action == .Promote)
            files.items[previous.?.index].bytes
        else
            try std.Io.Dir.cwd().readFileAllocOptions(io, item.path, allocator, .unlimited, .of(u8), 0);

        if (inputs) |observed| try observed.record(io, item.path, bytes);

        if (action == .Promote) {
            files.items[previous.?.index].kind = .zig;
            previous.?.parsed = true;
        } else {
            try seen.put(allocator, relative, .{ .index = files.items.len, .parsed = action == .ReadSource });
            try files.append(allocator, .{ .path = relative, .kind = item.kind, .bytes = bytes, .referenced_from = item.from });
        }

        if (action == .ReadAsset) continue;

        const parsed = try references.read(allocator, bytes);

        const scan = rules.native_resource_scan.executeValue(memory.allocator(), &.{
            .found = &.{ .dynamic_resources = parsed.dynamic_resources, .c_imports = parsed.c_imports },
            .accumulated = &.{ .dynamic_resources = dynamic_resources, .c_imports = c_imports },
            .has_bundle = module.bundle_files.len != 0,
        }) catch unreachable;

        if (!scan.valid) return error.NativeBundleRequiresFiles;

        dynamic_resources = scan.dynamic_resources;
        c_imports = scan.c_imports;

        for (parsed.references) |reference| {
            const path = try referencedPath(allocator, root, std.fs.path.dirname(item.path).?, reference.path);

            try pending.append(allocator, .{ .path = path, .kind = reference.kind, .from = relative });
        }
    }

    return .{
        .root = root,
        .entry = if (entry) |path| std.fs.path.basename(path) else null,
        .files = files.items,
        .index = seen,
        .dynamic_resources = dynamic_resources,
        .c_imports = c_imports,
    };
}

pub fn referencedPath(allocator: std.mem.Allocator, root: []const u8, parent: []const u8, path: []const u8) ![]const u8 {
    if (!paths.validReference(path)) return error.InvalidNativeResourcePath;

    const absolute = try std.fs.path.resolve(allocator, &.{ parent, path });
    _ = try relativePath(allocator, root, absolute);

    return absolute;
}

fn relativePath(allocator: std.mem.Allocator, root: []const u8, absolute: []const u8) ![]const u8 {
    const relative = try std.fs.path.relative(allocator, root, null, root, absolute);

    if (!paths.within(relative)) return error.NativeResourceOutsideModule;

    return relative;
}
