const std = @import("std");
const Compile = @import("../compile.zig");
const workspace = @import("../../package/workspace.zig");
const graph = @import("../../package/graph.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const memory = @import("zx").memory;
const rule = @import("cli_source").lint_workspace;
const Rows = std.meta.Child(@FieldType(std.meta.Child(rule.Input), "members"));

const State = struct {
    context: *const Compile.Context,
    workspace: ?workspace.Result = null,
    graph: ?graph.Result = null,
    root_manifest: ?[]const u8 = null,
    rows: Rows = undefined,
    paths: memory.TextColumn = undefined,
    entries: memory.ReadColumn = undefined,
    exports: memory.ListColumn = undefined,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.root_manifest) |path| self.context.allocator.free(path);
        if (self.graph) |*resolved| resolved.deinit();
        if (self.workspace) |*discovered| discovered.deinit();
    }
    fn memberContext(self: *const State, path: []const u8) Compile.Context {
        var context = self.context.*;

        context.options.input = path;
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

    const outcome = rule.executeIn(context.allocator, &.{
        .host = @ptrCast(&reference),
        .input_path = context.options.input,
        .members = &state.rows,
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

pub fn resolveLintWorkspace(handle: *const anyopaque) Error!?[]const u8 {
    const self = State.get(handle);
    const context = self.context;

    self.graph = graph.loadPrepared(context.io, context.allocator, .{ .path = context.options.input }, &self.workspace.?) catch |err| return self.failure.save(err);

    if (self.graph.?.diagnostic) |message| {
        context.stderr.print("{s}\n", .{message}) catch |err| return self.failure.save(err);

        return null;
    }

    self.root_manifest = std.Io.Dir.cwd().realPathFileAlloc(context.io, context.options.input, context.allocator) catch |err| return self.failure.save(err);

    const members = self.workspace.?.packages;

    self.paths = memory.borrowTextColumn("path", members);
    self.entries = memory.borrowNestedColumn(?[]const u8, &.{ "manifest", "entry" }, members);
    self.exports = memory.borrowListPath([]const u8, &.{ "manifest", "exports" }, &.{"path"}, members);

    self.rows = .{
        .paths = @ptrCast(&self.paths),
        .entries = @ptrCast(&self.entries),
        .exports = @ptrCast(&self.exports),
        .count = members.len,
    };

    return self.graph.?.root;
}

pub fn lintMemberSemantics(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = State.get(handle);
    const status = @import("semantic.zig").run(self.memberContext(path)) catch |err| return self.failure.save(err);

    return status == .success;
}

pub fn lintMemberConfiguration(handle: *const anyopaque, path: []const u8) Error!bool {
    const self = State.get(handle);
    const status = @import("../configuration/root.zig").run(self.memberContext(path)) catch |err| return self.failure.save(err);

    return status == .success;
}
