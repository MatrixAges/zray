const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const Directory = @import("../publication/directory.zig");
const effects = @import("../publication/effects.zig");
const rule = @import("cli_source").native_directory_files;
const Kind = @import("publication_abi").native.@"zig:publication_host".ResourceKind;
const Error = effects.Error;

const Walk = struct {
    directory: Directory,
    inputs: ?*Inputs,
    paths: std.ArrayList([]const u8) = .empty,
    current: []const u8 = undefined,
};

pub fn files(io: std.Io, allocator: std.mem.Allocator, path: []const u8, inputs: ?*Inputs) ![]const []const u8 {
    var failure: effects.Failure = .{};

    var walk: Walk = .{
        .directory = .{ .io = io, .allocator = allocator, .failure = &failure, .source = path },
        .inputs = inputs,
    };

    defer walk.directory.deinit();
    errdefer walk.paths.deinit(allocator);

    const state = &walk;
    const supported = rule.executeIn(allocator, @ptrCast(&state)) catch |err| return failure.unwrap(err);

    if (!supported) return error.UnsupportedNativeResource;

    std.mem.sort([]const u8, walk.paths.items, {}, lessThan);

    return walk.paths.items;
}

pub fn resourceRoot(handle: *const anyopaque) Error!Kind {
    const self = effects.state(Walk, handle);
    const directory = &self.directory;

    self.current = directory.source;

    if (self.inputs) |observed| observed.add(directory.io, directory.source) catch |err| return directory.failure.save(err);

    const stat = std.Io.Dir.cwd().statFile(directory.io, directory.source, .{}) catch |err| return directory.failure.save(err);

    return classify(stat.kind);
}

pub fn openResources(handle: *const anyopaque) Error!void {
    const self = effects.state(Walk, handle);
    const directory = &self.directory;

    if (self.inputs) |observed| observed.addDirectory(directory.io, directory.source) catch |err| return directory.failure.save(err);

    return directory.open(false);
}

pub fn nextResource(handle: *const anyopaque) Error!Kind {
    const self = effects.state(Walk, handle);
    const directory = &self.directory;
    const kind = (try directory.advance()) orelse return .End;

    // A directory path is used only when an input observer needs it.
    if (kind != .directory or self.inputs != null) {
        self.current = std.fs.path.join(directory.allocator, &.{ directory.source, directory.path }) catch |err| return directory.failure.save(err);
    }

    return classify(kind);
}

pub fn observeResource(handle: *const anyopaque, is_directory: bool) Error!void {
    const self = effects.state(Walk, handle);
    const inputs = self.inputs orelse return;
    const directory = &self.directory;

    (if (is_directory) inputs.addDirectory(directory.io, self.current) else inputs.add(directory.io, self.current)) catch |err| return directory.failure.save(err);
}

pub fn resourceLinkIsFile(handle: *const anyopaque) Error!bool {
    const self = effects.state(Walk, handle);
    const directory = &self.directory;
    const stat = std.Io.Dir.cwd().statFile(directory.io, self.current, .{}) catch |err| return directory.failure.save(err);

    return stat.kind == .file;
}

pub fn keepResource(handle: *const anyopaque) Error!void {
    const self = effects.state(Walk, handle);
    const directory = &self.directory;

    self.paths.append(directory.allocator, self.current) catch |err| return directory.failure.save(err);
}

fn classify(kind: std.Io.File.Kind) Kind {
    return switch (kind) {
        .file => .Regular,
        .directory => .Directory,
        .sym_link => .Symlink,
        else => .Other,
    };
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
