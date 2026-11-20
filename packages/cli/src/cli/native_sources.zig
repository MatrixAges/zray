const std = @import("std");
const columns = @import("zx").columns;
const storage = @import("native_sources/storage.zig");
const collection = @import("native_sources/collect.zig");
const bundle = @import("native_sources/bundle/storage.zig");
const ast = @import("native_sources/references/ast.zig");
const includes = @import("native_sources/include/storage.zig");
const rule = @import("cli_source").native_bundle;
pub const File = storage.File;
pub const Include = storage.Include;

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
        .directory = directory,
        .project_root = project_root,
        .options = options,
        .inputs = inputs,
    };

    defer context.seen.deinit(allocator);
    defer ast.closeAst(@ptrCast(&context));

    const input: std.meta.Child(rule.Input) = .{
        .collection = @ptrCast(&context),
        .bundle_files = options.bundle_files,
        .header = options.header != null,
        .include_paths = options.include_paths,
        .separator = std.fs.path.sep,
        .windows = @import("builtin").os.tag == .windows,
    };

    const result = columns.invoke(rule.executeValue, allocator, &input) catch |err| return if (err == error.NativeResourceFailure) context.failure.? else err;

    switch (result.status) {
        .Published => {},
        .AbsoluteHeader => return error.AbsoluteNativeHeaderCannotBeBundled,
        .OutputOverlap => return error.NativeBundleContainsOutput,
        .MissingBundle => return error.NativeBundleRequiresFiles,
        .IncompleteInclude => return error.IncompleteNativeIncludeBundle,
    }

    return .{
        .entry = if (context.entry) |entry| try std.fs.path.join(allocator, &.{ context.destination, std.fs.path.basename(entry) }) else null,
        .include_paths = context.include_paths,
        .include_relocations = context.relocations.items,
        .files = context.files,
        .dynamic_resources = result.dynamic_resources,
        .c_imports = result.c_imports,
    };
}

pub const absoluteHeader = bundle.absoluteHeader;
pub const prepareBundle = bundle.prepareBundle;
pub const bundlePath = bundle.bundlePath;
pub const logicalOutputInside = bundle.logicalOutputInside;
pub const physicalOutputInside = bundle.physicalOutputInside;
pub const openCollection = collection.openCollection;
pub const entryPath = collection.entryPath;
pub const readBundle = collection.readBundle;
pub const enqueue = collection.enqueue;
pub const pendingCount = collection.pendingCount;
pub const selectPending = collection.selectPending;
pub const sourcePending = collection.sourcePending;
pub const checkPending = collection.checkPending;
pub const readPending = collection.readPending;
pub const reusePending = collection.reusePending;
pub const observePending = collection.observePending;
pub const addPending = collection.addPending;
pub const promotePending = collection.promotePending;
pub const referenceCount = collection.referenceCount;
pub const enqueueReference = collection.enqueueReference;
pub const prepareIncludes = bundle.prepareIncludes;
pub const selectInclude = includes.selectInclude;
pub const includeFiles = includes.includeFiles;
pub const includesFile = includes.includesFile;
pub const writeInclude = includes.writeInclude;
pub const sourceCount = bundle.sourceCount;
pub const sourceIsAsset = bundle.sourceIsAsset;
pub const sourcePath = bundle.sourcePath;
pub const prepareFiles = bundle.prepareFiles;
pub const publishFile = bundle.publishFile;
pub const openAst = ast.openAst;
pub const closeAst = ast.closeAst;
pub const nextBuiltin = ast.nextBuiltin;
pub const builtinName = ast.builtinName;
pub const builtinArguments = ast.builtinArguments;
pub const builtinHasLiteral = ast.builtinHasLiteral;
pub const decodeLiteral = ast.decodeLiteral;
pub const discardLiteral = ast.discardLiteral;
pub const recordReference = ast.recordReference;
pub const invalidBuiltin = ast.invalidBuiltin;
