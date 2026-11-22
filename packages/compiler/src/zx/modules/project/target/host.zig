const std = @import("std");
const builtin = @import("builtin");
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

const SeedFilePlan = struct {
    kind: enum { Relative, Root, Extension, Invalid },
    prefix: u64,
    path: []const u8,
    suffix: []const u8,
    directory: bool,
    rx: bool,
};

const ResolvedFile = struct { path: []const u8, fallback: bool };
const SeedShape = enum { Source, Compiled, InvalidSource, InvalidCompiled, Duplicate };

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
    return (try resolveFile(allocator, from, path, root, false, false, reporter, span)).path;
}

fn resolveFile(allocator: std.mem.Allocator, from: []const u8, path: []const u8, root: []const u8, allow_rx: bool, check_direction: bool, reporter: *zx.Reporter, span: zx.Span) zx.Error!ResolvedFile {
    if (comptime enabled) {
        const rule = @import("generated_project_file_target");

        const input: std.meta.Child(rule.Input) = .{
            .path = path,
            .from = from,
            .root = root,
            .basename = std.fs.path.basename(path),
            .extension = std.fs.path.extension(path).len != 0,
            .allow_rx = allow_rx,
            .check_direction = check_direction,
        };

        const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
            else => unreachable,
        };

        if (result.issue) |issue| return reporter.fail(.module, span, issue);

        return .{ .path = result.path.?, .fallback = result.fallback };
    }

    if (check_direction) try checkImportDirection(allow_rx, path, reporter, span);

    const plan = seedFilePlan(path, allow_rx);

    try reportPath(plan.kind, reporter, span);

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

fn reportPath(kind: anytype, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    switch (kind) {
        .Extension => return reporter.fail(.module, span, "project imports must omit the .zx extension; runtime and RX imports are forbidden"),
        .Invalid => return reporter.fail(.module, span, "imports require ./, ../ or @/ paths; external interfaces require explicit registration"),
        .Relative, .Root => {},
    }
}

fn seedFilePlan(path: []const u8, allow_rx: bool) SeedFilePlan {
    const rx = allow_rx and std.mem.endsWith(u8, path, ".rx");
    const stem = if (rx) path[0 .. path.len - ".rx".len] else path;
    const directory = paths.directoryReference(stem);

    const kind: @FieldType(SeedFilePlan, "kind") = if (!directory and std.fs.path.extension(stem).len != 0)
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

    const allow_rx = std.mem.endsWith(u8, from, ".rx");

    switch (route) {
        .File => {
            const allocator = memory.source;
            const root = scope.root(options.root_dir);
            const file = try resolveFile(allocator, from, path, root, allow_rx, true, reporter, span);

            if (comptime enabled) return finishFile(keep_row, allocator, file, options.source_index, scope, reporter, span);

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

            return .{ .target = try dependency(memory, options.root_dir, dependencies, package, allow_rx, reporter, span) };
        },
        .Intrinsic, .Interface => return reporter.fail(.module, span, "native and standard imports must use the interface registry"),
        .Invalid => unreachable,
    }
}

pub fn checkImportDirection(allow_rx: bool, target: []const u8, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    if (comptime enabled) {
        const rule = @import("generated_project_import_direction");
        const input: std.meta.Child(rule.Input) = .{ .path = target, .allow_rx = allow_rx };
        var empty = std.heap.FixedBufferAllocator.init(&.{});
        const issue = zx.columns.invoke(rule.executeValue, empty.allocator(), &input) catch unreachable;

        if (issue) |message| return reporter.fail(.module, span, message);

        return;
    }

    if (!allow_rx and std.mem.endsWith(u8, target, ".rx")) {
        return reporter.fail(.module, span, "ZX cannot import RX modules; compose RX calls in an RX module");
    }
}

fn finishFile(comptime keep_row: bool, allocator: std.mem.Allocator, file: ResolvedFile, index: ?*const source_index.Map, scope: Scope, reporter: *zx.Reporter, span: zx.Span) zx.Error!Resolved {
    const table = if (file.fallback) index orelse &source_index.Map.empty else &source_index.Map.empty;
    const resolved = file.path;

    if (table.buckets.len == 0 and scope.scopes.len == 0) return .{ .target = .{ .source = resolved } };

    errdefer allocator.free(resolved);

    const roots = zx.memory.borrowTextColumn("root", scope.scopes);
    const rule = @import("generated_project_file_selection");

    const input: std.meta.Child(rule.Input) = .{
        .path = resolved,
        .release = @ptrCast(&allocator),
        .roots = &.{ .items = @ptrCast(&roots), .length = roots.count },
        .owner = scope.owner,
        .windows = builtin.os.tag == .windows,
        .index = &.{ .keys = table.keys, .buckets = @ptrCast(&table.buckets), .capacity = table.buckets.len },
    };

    const selected = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        else => unreachable,
    };

    if (selected.issue) |issue| return reporter.fail(.module, span, issue);

    const row = if (keep_row) selected.row else null;

    return .{ .target = .{ .source = selected.path }, .source_row = if (row) |value| @intCast(value) else null };
}

fn dependency(memory: Memory, root: []const u8, packages: []const scopes.Package, selected: registry.Match, allow_rx: bool, reporter: *zx.Reporter, span: zx.Span) zx.Error!Target {
    if (comptime enabled) {
        const package = if (selected.first) |index| &packages[index] else null;

        return resolvePackage(memory, root, package, selected.duplicate, allow_rx, reporter, span);
    }

    const index = selected.first orelse return reporter.fail(.module, span, "ZX package is not declared in the project dependencies");
    const package = &packages[index];

    if (package.compiled == null) try checkImportDirection(allow_rx, package.entry, reporter, span);

    const allocator = if (package.compiled != null) memory.compiled else memory.source;
    const artifact = if (package.compiled) |target| target.artifact else null;

    try reportPackage(seedPackageShape(package, selected.duplicate), reporter, span);

    const resolved = try std.fs.path.resolve(allocator, &.{ root, artifact orelse package.entry });

    errdefer allocator.free(resolved);

    if (package.compiled) |target| {
        const instance = try allocator.dupe(u8, target.instance);

        errdefer allocator.free(instance);

        return .{ .compiled = .{ .instance = instance, .artifact = resolved, .name = try allocator.dupe(u8, target.name) } };
    }

    return .{ .source = resolved };
}

fn reportPackage(kind: anytype, reporter: *zx.Reporter, span: zx.Span) zx.Error!void {
    switch (kind) {
        .InvalidSource => return reporter.fail(.module, span, "package entry must be a .zx or .rx source file"),
        .InvalidCompiled => return reporter.fail(.module, span, "compiled package target must identify one instance, artifact and public module"),
        .Duplicate => return reporter.fail(.module, span, "duplicate ZX package specifier"),
        .Source, .Compiled => {},
    }
}

fn resolvePackage(memory: Memory, root: []const u8, package: ?*const scopes.Package, duplicate: bool, allow_rx: bool, reporter: *zx.Reporter, span: zx.Span) zx.Error!Target {
    const rule = @import("generated_project_package_admission");
    const compiled_target = if (package) |value| value.compiled else null;
    const allocator = if (compiled_target != null) memory.compiled else memory.source;
    var output = [_][]const u8{ "", "", "" };

    errdefer {
        allocator.free(output[2]);
        allocator.free(output[1]);
        allocator.free(output[0]);
    }

    const input: std.meta.Child(rule.Input) = .{
        .present = package != null,
        .entry = if (package) |value| value.entry else "",
        .members = if (compiled_target) |value| &.{
            .instance = value.instance,
            .artifact = value.artifact,
            .name = value.name,
        } else null,
        .duplicate = duplicate,
        .allow_rx = allow_rx,
        .root = root,
        .release = @ptrCast(&allocator),
        .output = &output,
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };

    if (result.issue) |issue| return reporter.fail(.module, span, issue);

    const path, const instance, const name = output;

    return if (compiled_target == null)
        .{ .source = path }

    else
        .{ .compiled = .{ .artifact = path, .instance = instance, .name = name } };
}

fn seedPackageShape(package: *const scopes.Package, duplicate: bool) SeedShape {
    if (package.compiled) |value| {
        if (package.entry.len != 0 or value.instance.len == 0 or value.artifact.len == 0 or value.name.len == 0) return .InvalidCompiled;

        return if (duplicate) .Duplicate else .Compiled;
    }

    if (!std.mem.endsWith(u8, package.entry, ".zx") and !std.mem.endsWith(u8, package.entry, ".rx")) return .InvalidSource;

    return if (duplicate) .Duplicate else .Source;
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
