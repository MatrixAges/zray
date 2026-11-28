const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const source = @import("manifest/input.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const rules = @import("cli_source");
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;
const layouts = @import("cli_abi").layouts.@"zig:package_workspace_host";
const Entry = rules.workspace_collect;
const constants = rules.workspace_constants.@"zx.constants";
const Pending = Entry.zx_pending;
const Store2 = std.meta.Child(@FieldType(Pending, "store_2"));
const Store0 = std.meta.Child(@FieldType(Pending, "store_0"));
const Store1 = std.meta.Child(@FieldType(Pending, "store_1"));
pub const Package = struct { path: []const u8, manifest: Manifest };

const StoreHost = struct {
    store_0: *Store0,
    store_1: *Store1,
    store_2: *Store2,
    pub fn commit(self: *StoreHost, pending: anytype) error{}!void {
        if (pending.store_0) |next| self.store_0.* = next;
        if (pending.store_1) |next| self.store_1.* = next;
        if (pending.store_2) |next| self.store_2.* = next;
    }
};

fn initEmptyStore(comptime Pointer: type) std.meta.Child(Pointer) {
    const T = std.meta.Child(Pointer);

    if (comptime @hasField(T, "rows")) {
        return .{ .paths = &.{}, .rows = &.{} };
    }

    if (comptime @hasField(T, "paths")) {
        return .{ .paths = &.{} };
    }

    return .{ .names = &.{}, .locations = &.{} };
}

pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    root: []const u8 = "",
    packages: []const Package = &.{},
    diagnostic: ?[]const u8 = null,
    pub fn deinit(self: *Result) void {
        self.arena.deinit();

        self.* = undefined;
    }
};

pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Result {
    return loadPrepared(io, allocator, .{ .path = path });
}

pub const Request = struct {
    path: []const u8,
    inputs: ?*Inputs = null,
    manifests: ?std.mem.Allocator = null,
    root: ?source.Known = null,
    member: ?source.Known = null,
};

pub fn loadPrepared(io: std.Io, allocator: std.mem.Allocator, request: Request) !Result {
    var result: Result = .{ .arena = .init(allocator) };

    errdefer result.deinit();

    if (request.inputs) |observed| try observed.add(io, request.path);

    result.packages = collect(io, &result, request) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (result.diagnostic == null) result.diagnostic = try std.fmt.allocPrint(result.arena.allocator(), "{s}: {s}", .{ request.path, @errorName(err) });

        return result;
    };

    return result;
}

const State = struct {
    io: std.Io,
    result: *Result,
    request: Request,
    allocator: std.mem.Allocator,
    manifests: std.mem.Allocator,
    failure: effects.Failure = .{},
    packages: std.ArrayList(Package) = .empty,
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
};

fn collect(io: std.Io, result: *Result, request: Request) ![]const Package {
    const allocator = result.arena.allocator();

    var state: State = .{
        .io = io,
        .result = result,
        .request = request,
        .allocator = allocator,
        .manifests = request.manifests orelse allocator,
    };

    const reference = &state;
    var store_arena = std.heap.ArenaAllocator.init(result.arena.child_allocator);

    defer store_arena.deinit();

    const path = request.path;
    const parent = std.fs.path.dirname(path) orelse constants.root_path;
    result.root = try std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator);

    const root = try read(io, result, path, request.inputs, state.manifests, request.root);

    try state.packages.append(allocator, .{ .path = constants.root_path, .manifest = root });

    const store_0_value = initEmptyStore(Store0);
    const store_1_value = initEmptyStore(Store1);
    const store_2_value = initEmptyStore(Store2);
    var store_0: Store0 = &store_0_value;
    var store_1: Store1 = &store_1_value;
    var store_2: Store2 = &store_2_value;
    var host: StoreHost = .{ .store_0 = &store_0, .store_1 = &store_1, .store_2 = &store_2 };

    const outcome = Entry.execute(&store_arena, &.{
        .collection = @ptrCast(&reference),
        .patterns = if (root.workspace) |workspace| workspace.packages else &.{},
        .root_name = root.name,
        .path = path,
    }, &host) catch |err| return state.failure.unwrap(err);

    if (outcome.diagnostic) |message| {
        result.diagnostic = try allocator.dupe(u8, message);

        return error.InvalidWorkspace;
    }

    for (outcome.paths, outcome.rows) |member, row| {
        state.packages.items[@intCast(row)].path = try allocator.dupe(u8, member);
    }

    return state.packages.toOwnedSlice(allocator);
}

pub fn listWorkspaceDirectories(allocator: std.mem.Allocator, handle: *const anyopaque, relative: []const u8) Error![]const []const u8 {
    const self = State.get(handle);
    const root = self.result.root;

    const path = if (relative.len == 0) root else
        std.fs.path.join(allocator, &.{ root, relative }) catch |err| return self.failure.save(err);

    if (self.request.inputs) |observed| observed.add(self.io, path) catch |err| return self.failure.save(err);

    const dir = std.Io.Dir.openDirAbsolute(self.io, path, .{ .iterate = true }) catch |err| return self.failure.save(err);

    defer dir.close(self.io);

    var iterator = dir.iterate();
    var children: std.ArrayList([]const u8) = .empty;

    while (iterator.next(self.io) catch |err| return self.failure.save(err)) |entry| {
        if (entry.kind != .directory) continue;

        const child = std.fs.path.join(allocator, &.{ relative, entry.name }) catch |err| return self.failure.save(err);

        children.append(allocator, child) catch |err| return self.failure.save(err);
    }

    return children.toOwnedSlice(allocator) catch |err| self.failure.save(err);
}

pub fn readMember(handle: *const anyopaque, member: []const u8) Error!?*const layouts.ManifestMember {
    const self = State.get(handle);
    const path = std.fs.path.join(self.allocator, &.{ self.result.root, member, constants.manifest_name }) catch |err| return self.failure.save(err);

    const data = read(self.io, self.result, path, self.request.inputs, self.manifests, self.request.member) catch |err| {
        if (err == error.FileNotFound) return null;
        if (err == error.OutOfMemory) return self.failure.save(err);

        if (self.result.diagnostic == null) {
            self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ path, @errorName(err) }) catch |failure| return self.failure.save(failure);
        }

        return self.failure.save(err);
    };

    const view = self.allocator.create(layouts.ManifestMember) catch |err| return self.failure.save(err);
    const row = self.packages.items.len;

    self.packages.append(self.allocator, .{ .path = "", .manifest = data }) catch |err| return self.failure.save(err);

    view.* = .{ .name = data.name, .path = path, .row = row };

    return view;
}

fn read(io: std.Io, result: *Result, path: []const u8, inputs: ?*Inputs, manifests: std.mem.Allocator, known: ?source.Known) !Manifest {
    const allocator = result.arena.allocator();
    const file = try source.locate(io, allocator, path, inputs);
    const relative = try std.fs.path.relative(allocator, result.root, null, result.root, file.physical);
    var scratch = std.heap.FixedBufferAllocator.init(&.{});

    const within = rules.workspace_manifest_within.executeValue(scratch.allocator(), .{
        .path = relative,
        .absolute = std.fs.path.isAbsolute(relative),
    }) catch unreachable;

    if (!within) {
        result.diagnostic = try std.fmt.allocPrint(allocator, "{s}: manifest escapes the workspace root", .{path});

        return error.InvalidWorkspace;
    }

    if (known) |prepared| {
        if (prepared.matches(file)) return prepared.data;
    }

    return switch (try source.decode(io, manifests, file, inputs)) {
        .data => |data| data,
        .diagnostic => |issue| {
            result.diagnostic = try source.diagnostic(allocator, path, issue);

            return error.InvalidWorkspace;
        },
    };
}

pub fn portablePath(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return rules.workspace_portable_path.executeValue(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
