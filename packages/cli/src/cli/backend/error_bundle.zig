const std = @import("std");
const Bundle = std.zig.ErrorBundle;
const source = @import("backend_source");
const rule = source.validate;
const layout = source.diagnostic_constants.@"zx.constants";
const Visit = @import("backend_abi").native.@"zig:backend_diagnostics".Visit;

const Record = struct {
    start: usize,
    count: usize,
    metrics: u64 = 0,
};

const Context = struct {
    allocator: std.mem.Allocator,
    records: std.AutoHashMapUnmanaged(u64, Record) = .empty,
    edges: std.ArrayList(u64) = .empty,
    pending: std.ArrayList(u64) = .empty,
    child_start: usize = 0,
    finishing: *Record = undefined,
    fn get(handle: *const anyopaque) *Context {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

comptime {
    checkLayout(Bundle.ErrorMessageList, &.{ "len", "start", "compile_log_text" }, layout.root_words);
    checkLayout(Bundle.ErrorMessage, &.{ "msg", "count", "src_loc", "notes_len" }, layout.message_words);
    checkLayout(Bundle.SourceLocation, &.{ "src_path", "line", "column", "span_start", "span_main", "span_end", "source_line", "reference_trace_len" }, layout.source_words);
    checkLayout(Bundle.ReferenceTrace, &.{ "decl_name", "src_loc" }, layout.trace_words);
}

fn checkLayout(comptime T: type, comptime names: []const []const u8, comptime width: u64) void {
    const fields = @typeInfo(T).@"struct".field_names;

    if (fields.len != width or fields.len != names.len) @compileError("Unexpected Zig diagnostic record width");

    inline for (fields, names) |actual, expected| {
        if (!std.mem.eql(u8, actual, expected)) @compileError("Unexpected Zig diagnostic record field order");
    }
}

pub fn validate(allocator: std.mem.Allocator, bundle: Bundle) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    var context: Context = .{ .allocator = arena.allocator() };

    const status = try rule.executeValue(context.allocator, &.{
        .graph = @ptrCast(&context),
        .words = bundle.extra,
        .strings = bundle.string_bytes,
    });

    switch (status) {
        .Valid => {},
        .InvalidBackendProtocol => return error.InvalidBackendProtocol,
        .BackendDiagnosticsTooComplex => return error.BackendDiagnosticsTooComplex,
    }
}

pub fn schedule(handle: *const anyopaque, key: u64) error{OutOfMemory}!void {
    const self = Context.get(handle);

    try self.pending.append(self.allocator, key);
}

pub fn pop(handle: *const anyopaque) ?u64 {
    return Context.get(handle).pending.pop();
}

pub fn visitStatus(handle: *const anyopaque, key: u64) Visit {
    const previous = Context.get(handle).records.get(key) orelse return .New;

    return if (previous.metrics != 0) .Finished else .Visiting;
}

pub fn startChildren(handle: *const anyopaque) void {
    const self = Context.get(handle);

    self.child_start = self.edges.items.len;
}

pub fn appendChild(handle: *const anyopaque, child: u64) error{OutOfMemory}!void {
    const self = Context.get(handle);

    try self.edges.append(self.allocator, child);
}

pub fn record(handle: *const anyopaque, key: u64) error{OutOfMemory}!void {
    const self = Context.get(handle);

    try self.records.put(self.allocator, key, .{
        .start = self.child_start,
        .count = self.edges.items.len - self.child_start,
    });
}

pub fn newChildren(handle: *const anyopaque) []const u64 {
    const self = Context.get(handle);

    return self.edges.items[self.child_start..];
}

pub fn finishChildren(handle: *const anyopaque, key: u64) []const u64 {
    const self = Context.get(handle);
    const entry = self.records.getPtr(key).?;

    self.finishing = entry;

    return self.edges.items[entry.start..][0..entry.count];
}

pub fn metrics(handle: *const anyopaque, key: u64) u64 {
    return Context.get(handle).records.get(key).?.metrics;
}

pub fn finish(handle: *const anyopaque, value: u64) void {
    Context.get(handle).finishing.metrics = value;
}
