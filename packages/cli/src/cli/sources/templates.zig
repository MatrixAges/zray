const std = @import("std");
const compiler = @import("compiler");
const zx = @import("zx");
const Inputs = @import("watch_inputs").Inputs;
const resources = compiler.project.resources;
const effects = @import("effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").load_source_template;
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const StoreHost = struct {
    store_0: *StoreState,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
    }
};

const State = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    source: compiler.project.Source,
    project: *const compiler.project.Options,
    inputs: ?*Inputs,
    references: []const resources.Reference,
    reporter: zx.Reporter,
    failure: effects.Failure = .{},
    files: std.ArrayList(compiler.project.Resource) = .empty,
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
        .reporter = reporter,
    };

    const reference = &load;
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var loaded: StoreState = &.{ .paths = &.{} };
    var host: StoreHost = .{ .store_0 = &loaded };

    rule.execute(&arena, &.{
        .source = @ptrCast(&reference),
        .root = project.root_dir,
        .path = source.path,
        .count = references.len,
    }, &host) catch |err| return load.failure.unwrap(err);

    return load.source;
}

pub fn resolveTemplateReference(handle: *const anyopaque, owner: []const u8, index: u64) Error!?[]const u8 {
    const self = effects.state(State, handle);
    const reference = self.references[@intCast(index)];

    return resources.resolve(self.allocator, owner, reference, self.project.*, &self.reporter) catch |err| {
        if (err == error.OutOfMemory) return self.failure.save(err);

        return null;
    };
}

pub fn readTemplateFile(handle: *const anyopaque, path: []const u8) Error!void {
    const self = effects.state(State, handle);
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
