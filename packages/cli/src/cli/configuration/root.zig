const std = @import("std");
const Compile = @import("../compile.zig");
const kinds = @import("kind.zig");
const pkgs = @import("pkgs");
const yaml = @import("yaml.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const Layout = @import("cli_abi").native.@"zig:lint_workflow_host".Layout;

const State = struct {
    context: *const Compile.Context,
    source: ?[]u8 = null,
    formatted: ?yaml.Formatted = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.formatted) |result| {
            if (result.allocated) self.context.allocator.free(result.bytes);
        }

        if (self.source) |source| self.context.allocator.free(source);
    }
};

pub fn run(context: Compile.Context) !Compile.Status {
    return execute(context) catch |err| {
        if (err == error.OutOfMemory or err == error.Canceled) return err;
        try context.stderr.print("{s}: configuration: {s}\n", .{ context.options.input, @errorName(err) });

        return .failed;
    };
}

fn execute(context: Compile.Context) !Compile.Status {
    var state: State = .{ .context = &context };
    const reference = &state;

    defer state.deinit();

    const valid = @import("cli_source").configuration_workflow.executeIn(context.allocator, @ptrCast(&reference)) catch |err| return state.failure.unwrap(err);

    return if (valid) .success else .failed;
}

pub fn configurationLayout(handle: *const anyopaque) Layout {
    const options = &State.get(handle).context.options;
    const kind = options.config_kind orelse kinds.infer(options.input) orelse return .Unknown;

    return switch (kind) {
        .manifest => .Manifest,
        .index => .Index,
        .lock => .Lock,
    };
}

pub fn reportConfigurationKind(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("configuration kind is unknown; use --kind manifest, index or lock\n") catch |err| return self.failure.save(err);
}

pub fn readConfiguration(handle: *const anyopaque, layout: Layout) Error!void {
    const self = State.get(handle);
    const context = self.context;

    const kind: kinds.Kind = switch (layout) {
        .Manifest => .manifest,
        .Index => .index,
        .Lock => .lock,
        .Unknown => unreachable,
    };

    self.source = std.Io.Dir.cwd().readFileAlloc(context.io, context.options.input, context.allocator, .limited(kinds.maximumBytes(kind))) catch |err| return self.failure.save(err);
}

pub fn formatConfigurationManifest(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.formatted = yaml.format(context.allocator, self.source.?, context.options.input, context.stderr) catch |err| return self.failure.save(err);

    return self.formatted != null;
}

pub fn validateConfigurationIndex(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const checked = pkgs.Index.parse(self.context.allocator, self.source.?) catch |err| return self.failure.save(err);

    checked.deinit();
}

pub fn formatConfigurationIndex(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const result = @import("lint").configuration.json.format(self.context.allocator, self.source.?) catch |err| return self.failure.save(err);

    self.formatted = .{ .bytes = result };
}

pub fn validateConfigurationLock(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const checked = pkgs.Lock.parse(self.context.allocator, self.source.?) catch |err| return self.failure.save(err);

    checked.deinit();
}

pub fn configurationLinting(handle: *const anyopaque) bool {
    return State.get(handle).context.options.linting;
}

pub fn reportManagedLock(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("pkg.lock.json is managed by zxc pkg install; use zxc lint for read-only validation\n") catch |err| return self.failure.save(err);
}

pub fn configurationChecking(handle: *const anyopaque) bool {
    const options = &State.get(handle).context.options;

    return options.linting or options.check;
}

pub fn checkConfigurationFormatting(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    if (std.mem.eql(u8, self.source.?, self.formatted.?.bytes)) return true;

    self.context.stderr.print("{s}: configuration formatting required; run zxc fmt with the same --kind selection\n", .{self.context.options.input}) catch |err| return self.failure.save(err);

    return false;
}

pub fn configurationWriting(handle: *const anyopaque) bool {
    return State.get(handle).context.options.write;
}

pub fn writeConfiguration(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    @import("../artifacts.zig").write(context.io, context.options.input, self.formatted.?.bytes) catch |err| return self.failure.save(err);
}

pub fn printConfiguration(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stdout.writeAll(self.formatted.?.bytes) catch |err| return self.failure.save(err);
}
