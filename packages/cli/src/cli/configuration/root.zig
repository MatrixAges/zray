const std = @import("std");
const Compile = @import("../compile.zig");
const Options = @import("../options.zig");
const pkgs = @import("pkgs");
const yaml = @import("yaml.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;
const Layout = @import("cli_abi").native.@"zig:lint_workflow_host".Layout;

pub fn toLayout(kind: ?Options.ConfigKind) Layout {
    return switch (kind orelse return .Unknown) {
        .manifest => .Manifest,
        .index => .Index,
        .lock => .Lock,
    };
}

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

    const valid = @import("cli_source").configuration_workflow.executeIn(context.allocator, &.{
        .host = @ptrCast(&reference),
        .input_path = context.options.input,
        .explicit_kind = toLayout(context.options.config_kind),
        .linting = context.options.linting,
        .check = context.options.check,
        .write = context.options.write,
    }) catch |err| return state.failure.unwrap(err);

    return if (valid) .success else .failed;
}

pub fn reportConfigurationKind(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("configuration kind is unknown; use --kind manifest, index or lock\n") catch |err| return self.failure.save(err);
}

pub fn readConfiguration(handle: *const anyopaque, maximum_bytes: u64) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.source = std.Io.Dir.cwd().readFileAlloc(context.io, context.options.input, context.allocator, .limited(@intCast(maximum_bytes))) catch |err| return self.failure.save(err);
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

pub fn reportManagedLock(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.context.stderr.writeAll("pkg.lock.json is managed by zxc pkg install; use zxc lint for read-only validation\n") catch |err| return self.failure.save(err);
}

pub fn checkConfigurationFormatting(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    if (std.mem.eql(u8, self.source.?, self.formatted.?.bytes)) return true;

    self.context.stderr.print("{s}: configuration formatting required; run zxc fmt with the same --kind selection\n", .{self.context.options.input}) catch |err| return self.failure.save(err);

    return false;
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
