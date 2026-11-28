const std = @import("std");
const Compile = @import("../compile.zig");
const workspace = @import("../../package/workspace.zig");
const graph = @import("../../package/graph.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const rule = @import("cli_source").lint_workspace;
const abi = @import("cli_abi").layouts.@"zig:lint_workflow_host";
const Plan = abi.WorkspacePlan;
const Member = abi.WorkspaceMember;

const State = struct {
    context: *const Compile.Context,
    workspace: ?workspace.Result = null,
    graph: ?graph.Result = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.graph) |*resolved| resolved.deinit();
        if (self.workspace) |*discovered| discovered.deinit();
    }
    fn memberContext(self: *const State, path: []const u8, root_manifest: []const u8) Compile.Context {
        var context = self.context.*;

        context.options.input = path;
        context.options.project = root_manifest;
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
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();
    defer state.deinit();

    const outcome = rule.executeIn(arena.allocator(), &.{
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

pub fn resolveLintWorkspace(allocator: std.mem.Allocator, handle: *const anyopaque) (Error || std.mem.Allocator.Error)!?*const Plan {
    const self = State.get(handle);
    const context = self.context;

    self.graph = graph.loadPrepared(context.io, context.allocator, .{ .path = context.options.input }, &self.workspace.?) catch |err| return self.failure.save(err);

    if (self.graph.?.diagnostic) |message| {
        context.stderr.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return null;
    }

    const root_manifest = std.Io.Dir.cwd().realPathFileAlloc(context.io, context.options.input, allocator) catch |err| return self.failure.save(err);
    const packages = self.workspace.?.packages;
    const values = try allocator.alloc(Member, packages.len);
    const rows = try allocator.alloc(*const Member, packages.len);

    for (packages, values, rows) |member, *value, *row| {
        value.* = .{ .path = member.path, .entry = member.manifest.entry, .export_count = member.manifest.exports.len };
        row.* = value;
    }

    const plan = try allocator.create(Plan);

    plan.* = .{
        .root = self.graph.?.root,
        .root_manifest = root_manifest,
        .members = rows,
    };

    return plan;
}

pub fn lintMemberSemantics(handle: *const anyopaque, path: []const u8, root_manifest: []const u8) Error!bool {
    const self = State.get(handle);
    const status = @import("semantic.zig").run(self.memberContext(path, root_manifest)) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn lintMemberConfiguration(handle: *const anyopaque, path: []const u8, root_manifest: []const u8) Error!bool {
    const self = State.get(handle);
    const status = @import("../configuration/root.zig").run(self.memberContext(path, root_manifest)) catch |err| return self.failure.save(err);

    return status == .success;
}
