const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const Inputs = @import("watch_inputs").Inputs;
const resources = compiler.project.resources;
const effects = @import("effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").load_source_template;

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    source: compiler.project.Source,
    project: *const compiler.project.Options,
    inputs: ?*Inputs,
    references: []const resources.Reference,
    owner: []const u8,
    reporter: zx.Reporter,
    failure: effects.Failure = .{},
    files: std.ArrayList(compiler.project.Resource) = .empty,
    path: []const u8 = undefined,
};

pub fn prepare(io: std.Io, allocator: std.mem.Allocator, source: compiler.project.Source, project: compiler.project.Options, inputs: ?*Inputs) !compiler.project.Source {
    var reporter: zx.Reporter = .{};

    const references = resources.references(allocator, source.source, &reporter) catch |err| {
        if (err == error.OutOfMemory) return err;

        return source;
    };

    if (references.len == 0) return source;

    var load: State = .{
        .io = io,
        .allocator = allocator,
        .source = source,
        .project = &project,
        .inputs = inputs,
        .references = references,
        .owner = try std.fs.path.resolve(allocator, &.{ project.root_dir, source.path }),
        .reporter = reporter,
    };

    const reference = &load;

    rule.executeIn(allocator, @ptrCast(&reference)) catch |err| return load.failure.unwrap(err);

    return load.source;
}

pub fn templateReferenceCount(handle: *const anyopaque) u64 {
    return effects.state(State, handle).references.len;
}

pub fn resolveTemplateReference(handle: *const anyopaque, index: u64) Error!?[]const u8 {
    const self = effects.state(State, handle);
    const reference = self.references[@intCast(index)];

    const path = resources.resolve(self.allocator, self.owner, reference, self.project.*, &self.reporter) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        return null;
    };

    self.path = path;

    return path;
}

pub fn templateFileCount(handle: *const anyopaque) u64 {
    return effects.state(State, handle).files.items.len;
}

pub fn templateFilePath(handle: *const anyopaque, index: u64) []const u8 {
    return effects.state(State, handle).files.items[@intCast(index)].path;
}

pub fn readTemplateFile(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);
    const path = self.path;
    const io = self.io;
    const allocator = self.allocator;

    if (self.inputs) |inputs| inputs.add(io, path) catch |err| return self.failure.save(err);

    @import("../../package/source.zig").validateWithInputs(io, allocator, path, self.project.package_scopes, self.inputs) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return self.failure.save(err),
    };

    const text = @import("text.zig").read(io, allocator, path, null) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return self.failure.save(err),
    };

    if (self.inputs) |inputs| inputs.record(io, path, text.bytes) catch |err| return self.failure.save(err);

    self.files.append(allocator, .{ .path = path, .source = text.bytes }) catch |err| return self.failure.save(err);
}

pub fn expandSourceTemplate(handle: *const anyopaque) Error!void {
    const self = effects.state(State, handle);

    self.source.templates = self.files.items;

    self.source = resources.expandReferences(self.allocator, self.source, self.references, self.project.*, &self.reporter) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        return;
    };
}
