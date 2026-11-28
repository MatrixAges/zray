const std = @import("std");
const storage = @import("native_sources/storage.zig");
const collection = @import("native_sources/collect.zig");
const bundle = @import("native_sources/bundle/storage.zig");
const ast = @import("native_sources/references/ast.zig");
const includes = @import("native_sources/include/storage.zig");
const rule = @import("cli_source").native_bundle;
pub const File = storage.File;
pub const Include = storage.Include;
const Store0 = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));
const Store1 = std.meta.Child(@FieldType(rule.zx_pending, "store_1"));

const StoreHost = struct {
    store_0: *Store0,
    store_1: *Store1,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
        if (pending.store_1) |next| self.store_1.* = next;
    }
};

fn initEmptyStore(comptime Pointer: type) std.meta.Child(Pointer) {
    const T = std.meta.Child(Pointer);

    if (comptime @hasField(T, "paths")) {
        return .{ .paths = &.{}, .sources = &.{}, .from_present = &.{}, .from_paths = &.{} };
    }

    return .{
        .relative_paths = &.{},
        .is_asset = &.{},
        .parsed = &.{},
        .contents = &.{},
        .from_present = &.{},
        .from_paths = &.{},
    };
}

pub const Result = struct {
    entry: ?[]const u8,
    include_paths: []const []const u8,
    include_relocations: []const Include,
    files: []const File,
    dynamic_resources: bool,
    c_imports: bool,
};

pub fn write(io: std.Io, allocator: std.mem.Allocator, directory: []const u8, project_root: []const u8, options: storage.Options, inputs: ?*@import("watch_inputs").Inputs) !Result {
    var context: storage.Context = .{
        .io = io,
        .allocator = allocator,
        .inputs = inputs,
    };

    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var store_0_value = initEmptyStore(Store0);
    var store_1_value = initEmptyStore(Store1);
    var store_0: Store0 = &store_0_value;
    var store_1: Store1 = &store_1_value;
    var host: StoreHost = .{ .store_0 = &store_0, .store_1 = &store_1 };
    const effects = &context;

    const input: std.meta.Child(rule.Input) = .{
        .collection = @ptrCast(&effects),
        .directory = directory,
        .project_root = project_root,
        .name = options.name,
        .entry_path = options.path,
        .bundle_files = options.bundle_files,
        .header = options.header != null,
        .header_absolute = if (options.header) |header| std.fs.path.isAbsolute(header) else false,
        .include_paths = options.include_paths,
        .separator = std.fs.path.sep,
        .windows = @import("builtin").os.tag == .windows,
    };

    const raw = rule.execute(&arena, &input, &host, io) catch |err| return if (err == error.NativeResourceFailure) context.failure.? else err;
    const result = if (@typeInfo(@TypeOf(raw)) == .pointer) raw.* else raw;

    switch (result.status) {
        .Published => {},
        .AbsoluteHeader => return error.AbsoluteNativeHeaderCannotBeBundled,
        .OutputOverlap => return error.NativeBundleContainsOutput,
        .MissingBundle => return error.NativeBundleRequiresFiles,
        .IncompleteInclude => return error.IncompleteNativeIncludeBundle,
    }

    const files = try allocator.alloc(File, result.files.len);

    for (result.files, files) |entry, *file| {
        file.* = .{
            .path = try allocator.dupe(u8, entry.path),
            .kind = if (entry.asset) .asset else .zig,
            .sha256 = try allocator.dupe(u8, entry.sha256),
            .referenced_from = if (entry.referenced_from) |path| try allocator.dupe(u8, path) else null,
        };
    }

    const layout = result.includes.?;
    const include_paths = try allocator.alloc([]const u8, layout.paths.len);

    for (layout.paths, include_paths) |path, *owned| owned.* = try allocator.dupe(u8, path);

    const relocations = try allocator.alloc(Include, layout.relocations.len);

    for (layout.relocations, relocations) |row, *owned| {
        owned.* = .{
            .source = try allocator.dupe(u8, row.source),
            .destination = include_paths[@intCast(row.index)],
        };
    }

    return .{
        .entry = if (result.entry) |entry| try allocator.dupe(u8, entry) else null,
        .include_paths = include_paths,
        .include_relocations = relocations,
        .files = files,
        .dynamic_resources = result.dynamic_resources,
        .c_imports = result.c_imports,
    };
}

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @This(),
    bundle,
    collection,
    includes,
    ast,
}).resolve;
