const std = @import("std");
const Inputs = @import("watch_inputs").Inputs;
const source = @import("manifest/input.zig");
const Manifest = @import("manifest/model.zig").Manifest;
const rules = @import("cli_source");
const effects = @import("../cli/sources/effects.zig");
const Error = effects.Error;
const Directory = @import("cli_abi").layouts.@"zig:package_workspace_host".Directory;
const layouts = @import("cli_abi").layouts.@"zig:package_workspace_host";
const RootManifest = layouts.RootManifest;
const constants = rules.workspace_constants.@"zx.constants";
const Pending = rules.workspace_collect.zx_pending;
const Store0 = std.meta.Child(@FieldType(Pending, "store_0"));
const Store1 = std.meta.Child(@FieldType(Pending, "store_1"));
pub const Package = struct { path: []const u8, manifest: Manifest };

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
    directory: ?std.Io.Dir = null,
    walker: ?std.Io.Dir.SelectiveWalker = null,
    current: std.Io.Dir.Walker.Entry = undefined,
    current_view: Directory = undefined,
    root_view: RootManifest = undefined,
    member: Manifest = undefined,
    member_view: layouts.ManifestMember = undefined,
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn closeWalker(self: *State) void {
        if (self.walker) |*walker| {
            while (walker.stack.items.len > 0) walker.leave(self.io);

            walker.deinit();

            self.walker = null;
        }

        if (self.directory) |dir| {
            dir.close(self.io);

            self.directory = null;
        }
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

    defer state.closeWalker();

    const reference = &state;
    var store_arena = std.heap.ArenaAllocator.init(result.arena.child_allocator);

    defer store_arena.deinit();

    var store_0_value = initEmptyStore(Store0);
    var store_1_value = initEmptyStore(Store1);
    var store_0: Store0 = &store_0_value;
    var store_1: Store1 = &store_1_value;
    var host: StoreHost = .{ .store_0 = &store_0, .store_1 = &store_1 };
    const diagnostic = rules.workspace_collect.execute(&store_arena, @ptrCast(&reference), &host) catch |err| return state.failure.unwrap(err);

    if (diagnostic) |message| {
        result.diagnostic = try allocator.dupe(u8, message);

        return error.InvalidWorkspace;
    }

    return try state.packages.toOwnedSlice(allocator);
}

pub fn readRoot(handle: *const anyopaque) Error!*const RootManifest {
    const self = State.get(handle);
    const path = self.request.path;
    const parent = std.fs.path.dirname(path) orelse constants.root_path;
    self.result.root = std.Io.Dir.cwd().realPathFileAlloc(self.io, parent, self.allocator) catch |err| return self.failure.save(err);

    const data = read(self.io, self.result, path, self.request.inputs, self.manifests, self.request.root) catch |err| return self.failure.save(err);

    self.packages.append(self.allocator, .{ .path = constants.root_path, .manifest = data }) catch |err| return self.failure.save(err);

    self.root_view = .{
        .patterns = if (data.workspace) |workspace| workspace.packages else &.{},
        .root_name = data.name,
        .path = path,
    };

    return &self.root_view;
}

pub fn openDirectory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const root = self.result.root;

    if (self.request.inputs) |observed| observed.add(self.io, root) catch |err| return self.failure.save(err);

    const dir = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch |err| return self.failure.save(err);

    self.directory = dir;
    self.walker = dir.walkSelectively(self.allocator) catch |err| return self.failure.save(err);
}

pub fn nextDirectory(handle: *const anyopaque) Error!?*const Directory {
    const self = State.get(handle);
    const walker = &self.walker.?;

    while (walker.next(self.io) catch |err| return self.failure.save(err)) |entry| {
        if (entry.kind != .directory) continue;

        const path = self.allocator.dupe(u8, entry.path) catch |err| return self.failure.save(err);

        self.current = entry;
        self.current_view = .{ .path = path, .name = std.fs.path.basename(path) };

        return &self.current_view;
    }

    self.closeWalker();

    return null;
}

pub fn enterDirectory(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    if (self.request.inputs) |observed| {
        const child = std.fs.path.join(self.allocator, &.{ self.result.root, self.current.path }) catch |err| return self.failure.save(err);

        observed.add(self.io, child) catch |err| return self.failure.save(err);
    }

    self.walker.?.enter(self.io, self.current) catch |err| return self.failure.save(err);
}

pub fn readMember(handle: *const anyopaque, member: []const u8) Error!?*const layouts.ManifestMember {
    const self = State.get(handle);
    const path = std.fs.path.join(self.allocator, &.{ self.result.root, member, constants.manifest_name }) catch |err| return self.failure.save(err);

    self.member = read(self.io, self.result, path, self.request.inputs, self.manifests, self.request.member) catch |err| {
        if (err == error.FileNotFound) return null;
        if (err == error.OutOfMemory) return self.failure.save(err);

        if (self.result.diagnostic == null) {
            self.result.diagnostic = std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ path, @errorName(err) }) catch |failure| return self.failure.save(failure);
        }

        return self.failure.save(err);
    };

    self.member_view = .{ .name = self.member.name, .path = path };

    return &self.member_view;
}

pub fn publishMember(handle: *const anyopaque, path: []const u8) Error!void {
    const self = State.get(handle);
    const owned = self.allocator.dupe(u8, path) catch |err| return self.failure.save(err);

    self.packages.append(self.allocator, .{ .path = owned, .manifest = self.member }) catch |err| return self.failure.save(err);
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
