const std = @import("std");
const compiler = @import("compiler");
const lint = @import("lint");
const rx = @import("rx");
const zx = @import("zx");
const Compile = @import("../compile.zig");
const effects = @import("../sources/effects.zig");
const Error = effects.Error;

const State = struct {
    context: *const Compile.Context,
    source: []const u8,
    parsed: ?rx.document.Parsed = null,
    formatted: ?[]u8 = null,
    failure: effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.formatted) |formatted| self.context.allocator.free(formatted);

        rx.document.release(&self.parsed);
    }
};

pub fn check(context: Compile.Context, source: []const u8) !Compile.Status {
    var state: State = .{ .context = &context, .source = source };
    const reference = &state;

    defer state.deinit();

    const valid = @import("cli_source").lint_source.executeIn(context.allocator, &.{
        .host = @ptrCast(&reference),
        .input_path = context.options.input,
    }) catch |err| return state.failure.unwrap(err);

    return if (valid) .success else .failed;
}

pub fn parseLintRx(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    self.parsed = rx.document.parse(self.context.allocator, self.source, true) catch |err| return self.failure.save(err);

    if (self.parsed.?.value != .diagnostic) return true;

    return reportRx(self, self.parsed.?.value.diagnostic);
}

pub fn validateLintRx(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const node = rx.document.schemaRoot(&self.parsed.?);
    var checked = rx.validateView(self.context.allocator, self.context.options.input, node) catch |err| return self.failure.save(err);

    defer checked.deinit();

    if (checked.value != .diagnostic) return true;

    return reportRx(self, checked.value.diagnostic);
}

fn reportRx(self: *State, issue: rx.Diagnostic) Error!bool {
    self.context.stderr.print("{s}:{d}:{d}: {t}: {s}\n", .{ self.context.options.input, issue.location.line, issue.location.column, issue.code, issue.message }) catch |err| return self.failure.save(err);

    return false;
}

pub fn checkLintRxValues(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const path = self.context.options.input;
    const node = rx.document.schemaRoot(&self.parsed.?);
    const diagnostic = (@import("rx_analysis").expression.checkValues(self.context.allocator, node, path) catch |err| return self.failure.save(err)) orelse return true;

    defer diagnostic.issue.deinit();
    self.context.stderr.print("{s}:{d}:{d}: {t}: {s}\n", .{ path, diagnostic.location.line, diagnostic.location.column, diagnostic.issue.code, diagnostic.issue.message }) catch |err| return self.failure.save(err);

    return false;
}

pub fn formatLintRx(handle: *const anyopaque) Error!void {
    const self = State.get(handle);

    self.formatted = rx.document.formatParsed(self.context.allocator, self.source, &self.parsed) catch |err| return self.failure.save(err);
}

pub fn checkLintZx(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const path = self.context.options.input;
    const diagnostic = (compiler.checkSource(self.context.allocator, self.source, path) catch |err| return self.failure.save(err)) orelse return true;

    defer diagnostic.deinit();

    const location = zx.source.locate(self.source, diagnostic.span.start);

    self.context.stderr.print("{s}:{d}:{d}: {t}: {s}\n", .{ path, location.line, location.column, diagnostic.code, diagnostic.message }) catch |err| return self.failure.save(err);

    return false;
}

pub fn formatLintZx(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const formatted = compiler.format(self.context.allocator, self.source, self.context.options.input) catch |err| return self.failure.save(err);

    self.formatted = formatted.source;
}

pub fn checkLintFormatting(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);

    if (std.mem.eql(u8, self.source, self.formatted.?)) return true;

    self.context.stderr.print("{s}: {s}\n", .{ self.context.options.input, lint.source.formatting_required }) catch |err| return self.failure.save(err);

    return false;
}

pub fn checkLintLength(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const options = &self.context.options;
    const exceeded = lint.length.check(self.source, options.max_lines orelse lint.length.default_maximum) orelse return true;

    self.context.stderr.print("{s}: length: {d} lines exceed the lint limit of {d}; split by responsibility or pass --max-lines\n", .{ options.input, exceeded.lines, exceeded.maximum }) catch |err| return self.failure.save(err);

    return false;
}
