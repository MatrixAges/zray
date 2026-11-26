const std = @import("std");
const Compile = @import("../compile.zig");
const workspace = @import("../../package/workspace.zig");
const graph = @import("../../package/graph.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    workspace: ?workspace.Result = null,
    graph: ?graph.Result = null,
    root_manifest: ?[]const u8 = null,
    member: ?[]const u8 = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn releaseMember(self: *State) void {
        if (self.member) |path| self.context.allocator.free(path);

        self.member = null;
    }

    fn deinit(self: *State) void {
        self.releaseMember();

        if (self.root_manifest) |path| self.context.allocator.free(path);
        if (self.graph) |*resolved| resolved.deinit();
        if (self.workspace) |*discovered| discovered.deinit();
    }
    fn memberContext(self: *const State) Compile.Context {
        var context = self.context.*;

        context.options.input = self.member.?;
        context.options.project = self.root_manifest.?;
        context.options.workspace_lint = false;
        context.options.semantic_lint = true;

        return context;
    }
};

pub fn run(context: Compile.Context) !Compile.Status {
    return execute(context) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: workspace lint: {s}\n", .{ context.options.input, @errorName(err) });

        return .failed;
    };
}

fn execute(context: Compile.Context) !Compile.Status {
    var state: State = .{ .context = &context };
    const reference = &state;

    defer state.deinit();

    const outcome = @import("cli_source").lint_workspace.executeIn(context.allocator, &.{
        .host = @ptrCast(&reference),
        .input_path = context.options.input,
    }) catch |err| return state.failure.unwrap(err);

    return switch (outcome) {
        .Valid => .success,
        .Invalid => .failed,
        .ManifestRequired => error.WorkspaceManifestRequired,
    };
}

pub fn discoverLintWorkspace(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.workspace = workspace.load(context.io, context.allocator, context.options.input) catch |err| return self.failure.save(err);

    if (self.workspace.?.diagnostic) |message| {
        context.stderr.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

pub fn resolveLintWorkspace(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.graph = graph.loadPrepared(context.io, context.allocator, .{ .path = context.options.input }, &self.workspace.?) catch |err| return self.failure.save(err);

    if (self.graph.?.diagnostic) |message| {
        context.stderr.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return false;
    }

    return true;
}

pub fn locateLintWorkspace(handle: *const anyopaque) Error!u64 {
    const self = State.get(handle);
    const context = self.context;

    self.root_manifest = std.Io.Dir.cwd().realPathFileAlloc(context.io, context.options.input, context.allocator) catch |err| return self.failure.save(err);

    return self.workspace.?.packages.len;
}

pub fn selectLintWorkspaceMember(handle: *const anyopaque, index: u64) Error!bool {
    const self = State.get(handle);
    const package = &self.workspace.?.packages[@intCast(index)];
    self.member = std.fs.path.resolve(self.context.allocator, &.{ self.graph.?.root, package.path, "pkg.yaml" }) catch |err| return self.failure.save(err);

    return package.manifest.entry != null or package.manifest.exports.len != 0;
}

pub fn lintMemberSemantics(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = @import("semantic.zig").run(self.memberContext()) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn lintMemberConfiguration(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const status = @import("../configuration/root.zig").run(self.memberContext()) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn releaseLintWorkspaceMember(handle: *const anyopaque) void {
    State.get(handle).releaseMember();
}
