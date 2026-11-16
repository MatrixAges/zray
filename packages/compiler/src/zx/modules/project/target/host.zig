const std = @import("std");
const zx = @import("zx");
const paths = @import("../../module_path.zig");
const scopes = @import("../../package_scope.zig");
const specifier = @import("../../specifier.zig");
const intrinsic = @import("../../intrinsic.zig").specifier;
const source_index = @import("../../source_index.zig");
const compiled = @import("../../compiled.zig");
const registry = @import("registry.zig");
const enabled = @import("parser_options").generated_parser;
pub const Target = union(enum) { source: []const u8, compiled: compiled.Target };
pub const Resolved = struct { target: Target, source_row: ?usize = null };
pub const SourceSelection = struct { path: []const u8, row: ?usize = null };
pub const Route = if (enabled) Output(@import("generated_project_import_route")) else enum { File, Package, Intrinsic, Interface, Invalid };
pub const Scope = @import("scope.zig");

pub const Memory = struct {
    source: std.mem.Allocator,
    compiled: std.mem.Allocator,
};

const FilePlan = if (enabled) Output(@import("generated_project_file_target")) else struct {
    kind: enum { Relative, Root, Extension, Invalid },
    prefix: u64,
    path: []const u8,
    suffix: []const u8,
    directory: bool,
    rx: bool,
};

const ResolvedFile = struct { path: []const u8, fallback: bool };
const Shape = if (enabled) Output(@import("generated_project_package_shape")) else enum { Source, Compiled, InvalidSource, InvalidCompiled };

fn Output(comptime module: type) type {
    return @typeInfo(@TypeOf(module.executeValue(undefined, undefined))).error_union.payload;
}

pub fn classify(path: []const u8) Route {
    if (comptime enabled) {
        const generated = @import("generated_project_import_route");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const input: std.meta.Child(generated.Input) = .{ .path = path, .intrinsic = intrinsic };

        return zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;
    }

    return switch (specifier.classify(path) catch return .Invalid) {
        .file => .File,
        .package => .Package,
        else => if (std.mem.eql(u8, path, intrinsic)) .Intrinsic else .Interface,
    };
}

pub fn resolvePath(allocator: std.mem.Allocator, from: []const u8, path: []const u8, root: []const u8, reporter: *zx.Reporter, span: zx.Span) zx.Error![]const u8 {
    return (try resolveFile(allocator, from, path, root, false, reporter, span)).path;
}

fn resolveFile(allocator: std.mem.Allocator, from: []const u8, path: []const u8, root: []const u8, allow_rx: bool, reporter: *zx.Reporter, span: zx.Span) zx.Error!ResolvedFile {
    const plan = filePlan(path, allow_rx);

    switch (plan.kind) {
        .Extension => return reporter.fail(.module, span, "project imports must omit the .zx extension; runtime and RX imports are forbidden"),
        .Invalid => return reporter.fail(.module, span, "imports require ./, ../ or @/ paths; external interfaces require explicit registration"),
        .Relative, .Root => {},
    }

    var buffer: [512]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, allocator);
    const temporary = scratch.allocator();

    const source = if (plan.directory)
        try paths.directoryFor(temporary, plan.path, plan.rx)
    else
        try std.fmt.allocPrint(temporary, "{s}{s}", .{ plan.path, plan.suffix });

    defer temporary.free(source);

    const base = switch (plan.kind) {
        .Root => root,
        .Relative => std.fs.path.dirname(from) orelse ".",
        else => unreachable,
    };

    return .{
        .path = try std.fs.path.resolve(allocator, &.{ base, source[@intCast(plan.prefix)..] }),
        .fallback = !plan.directory and !plan.rx,
    };
}

fn filePlan(path: []const u8, allow_rx: bool) FilePlan {
    if (comptime enabled) {
        const generated = @import("generated_project_file_target");
        var empty = std.heap.FixedBufferAllocator.init(&.{});

        const input: std.meta.Child(generated.Input) = .{
            .path = path,
            .basename = std.fs.path.basename(path),
            .extension = std.fs.path.extension(path).len != 0,
            .allow_rx = allow_rx,
        };

        return zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;
    }

    const rx = allow_rx and std.mem.endsWith(u8, path, ".rx");
    const stem = if (rx) path[0 .. path.len - ".rx".len] else path;
    const directory = paths.directoryReference(stem);

    const kind: @FieldType(FilePlan, "kind") = if (!directory and std.fs.path.extension(stem).len != 0)
        .Extension

    else if (std.mem.startsWith(u8, stem, "@/"))
        .Root
    else if (std.mem.eql(u8, stem, ".") or std.mem.eql(u8, stem, "..") or std.mem.startsWith(u8, stem, "./") or std.mem.startsWith(u8, stem, "../"))
        .Relative
    else
        .Invalid;

    return .{
        .kind = kind,
        .prefix = if (kind == .Root) "@/".len else 0,
        .path = stem,
        .suffix = if (rx) ".rx" else ".zx",
        .directory = directory,
        .rx = rx,
    };
}

pub fn resolve(allocator: std.mem.Allocator, from: []const u8, path: []const u8, route: Route, options: anytype, reporter: *zx.Reporter, span: zx.Span) zx.Error!Target {
    if (route == .Invalid) return reporter.fail(.module, span, "invalid or unknown import specifier");

    return resolveScoped(.{ .source = allocator, .compiled = allocator }, from, path, route, options, Scope.init(options.package_scopes, from), null, reporter, span);
}

pub fn resolveScoped(memory: Memory, from: []const u8, path: []const u8, route: Route, options: anytype, scope: Scope, matched_package: ?registry.Match, reporter: *zx.Reporter, span: zx.Span) zx.Error!Target {
    return (try resolveIn(false, memory, from, path, route, options, scope, matched_package, reporter, span)).target;
}

pub fn resolveIndexed(memory: Memory, from: []const u8, path: []const u8, route: Route, options: anytype, scope: Scope, matched_package: ?registry.Match, reporter: *zx.Reporter, span: zx.Span) zx.Error!Resolved {
    return resolveIn(true, memory, from, path, route, options, scope, matched_package, reporter, span);
}

fn resolveIn(comptime keep_row: bool, memory: Memory, from: []const u8, path: []const u8, route: Route, options: anytype, scope: Scope, matched_package: ?registry.Match, reporter: *zx.Reporter, span: zx.Span) zx.Error!Resolved {
    if (route == .Invalid) return reporter.fail(.module, span, "invalid or unknown import specifier");
    try scope.checkOwner(reporter, span);

    switch (route) {
        .File => {
            const allocator = memory.source;
            const root = scope.root(options.root_dir);
            const file = try resolveFile(allocator, from, path, root, true, reporter, span);
            var resolved = file.path;

            errdefer allocator.free(resolved);

            const selected: SourceSelection = if (!file.fallback)
                .{ .path = resolved }

            else if (comptime keep_row)
                try selectIndexed(allocator, resolved, options.source_index)
            else
                .{ .path = try select(allocator, resolved, options.source_index) };

            if (selected.path.ptr != resolved.ptr) allocator.free(resolved);

            resolved = selected.path;

            try scope.checkFile(resolved, reporter, span);

            return .{ .target = .{ .source = resolved }, .source_row = selected.row };
        },
        .Package => {
            const dependencies = scope.dependencies(options.packages);
            const package = matched_package orelse registry.package(dependencies, path, true);

            return .{ .target = try dependency(memory, options.root_dir, dependencies, package, reporter, span) };
        },
        .Intrinsic, .Interface => return reporter.fail(.module, span, "native and standard imports must use the interface registry"),
        .Invalid => unreachable,
    }
}

fn dependency(memory: Memory, root: []const u8, packages: []const scopes.Package, selected: registry.Match, reporter: *zx.Reporter, span: zx.Span) zx.Error!Target {
    const index = selected.first orelse return reporter.fail(.module, span, "ZX package is not declared in the project dependencies");
    const package = &packages[index];

    switch (packageShape(package)) {
        .InvalidSource => return reporter.fail(.module, span, "package entry must be a .zx or .rx source file"),
        .InvalidCompiled => return reporter.fail(.module, span, "compiled package target must identify one instance, artifact and public module"),
        .Source, .Compiled => {},
    }

    if (selected.duplicate) return reporter.fail(.module, span, "duplicate ZX package specifier");

    if (package.compiled) |value| {
        const allocator = memory.compiled;
        const instance = try allocator.dupe(u8, value.instance);

        errdefer allocator.free(instance);

        const artifact = try std.fs.path.resolve(allocator, &.{ root, value.artifact });

        errdefer allocator.free(artifact);

        return .{ .compiled = .{
            .instance = instance,
            .artifact = artifact,
            .name = try allocator.dupe(u8, value.name),
        } };
    }

    return .{ .source = try std.fs.path.resolve(memory.source, &.{ root, package.entry }) };
}

fn packageShape(package: *const scopes.Package) Shape {
    if (comptime enabled) {
        const generated = @import("generated_project_package_shape");
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const value = if (package.compiled) |*target| target else null;

        const input: std.meta.Child(generated.Input) = .{
            .entry = package.entry,
            .compiled = value != null,
            .instance = if (value) |target| target.instance.len != 0 else false,
            .artifact = if (value) |target| target.artifact.len != 0 else false,
            .name = if (value) |target| target.name.len != 0 else false,
        };

        return zx.columns.invoke(generated.executeValue, empty.allocator(), &input) catch unreachable;
    }

    if (package.compiled) |value| {
        return if (package.entry.len == 0 and value.instance.len != 0 and value.artifact.len != 0 and value.name.len != 0) .Compiled else .InvalidCompiled;
    }

    return if (std.mem.endsWith(u8, package.entry, ".zx") or std.mem.endsWith(u8, package.entry, ".rx")) .Source else .InvalidSource;
}

pub fn select(allocator: std.mem.Allocator, candidate: []const u8, index: ?*const source_index.Map) std.mem.Allocator.Error![]const u8 {
    return (try selectIndexed(allocator, candidate, index)).path;
}

pub fn selectIndexed(allocator: std.mem.Allocator, candidate: []const u8, index: ?*const source_index.Map) std.mem.Allocator.Error!SourceSelection {
    const known = index orelse return .{ .path = candidate };

    if (comptime enabled) return @import("alias.zig").select(allocator, candidate, known);

    var row: ?usize = null;
    const selected = try paths.select(allocator, candidate, source_index.Known{ .paths = known, .matched_row = &row });

    return .{ .path = selected, .row = row };
}

pub fn checkFile(from: []const u8, target: []const u8, packages: []const scopes.Scope, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    return Scope.init(packages, from).checkFile(target, reporter, span);
}
