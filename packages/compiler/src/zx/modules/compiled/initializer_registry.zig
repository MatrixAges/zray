const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const equality = @import("../../ir/compare/initializer.zig");
const Entry = @import("../compiled.zig").StoreInitializer;
const generated = @import("parser_options").generated_parser;
const Self = @This();
const fields = .{ .identity = "identity", .schema_version = "schema_version", .function = "function" };

rows: std.ArrayList(Entry) = .empty,
allocator: std.mem.Allocator = std.heap.page_allocator,
buckets: []u32 = &.{},
seed_index: if (generated) void else std.StringHashMapUnmanaged(usize) = if (generated) {} else .empty,
pub const Range = struct { first: usize = 0, count: usize, prefix: usize = 0 };

pub const Functions = struct {
    prefix: *const ir.FunctionTable = &.{},
    local: *const ir.FunctionStorage,
    fn at(self: *const Functions, id: ir.FunctionId) ir.Function {
        const row = @backingInt(id);
        const count = self.prefix.count();

        return if (row < count) self.prefix.at(row) else self.local.at(row - count);
    }
    fn compare(self: *const Functions, previous: Entry, next: ir.FunctionId) bool {
        const left = self.at(previous.function);
        const right = self.at(next);

        return equality.matches(&left, &right, previous.schema_version, previous.schema_version, null);
    }
};

pub const Error = std.mem.Allocator.Error || error{ InvalidModule, ConflictingInitializer };

pub fn deinit(self: *Self) void {
    if (generated) self.allocator.free(self.buckets) else self.seed_index.deinit(self.allocator);
}

pub fn adoptBuckets(self: *Self, updated: []const u32) std.mem.Allocator.Error!void {
    const next = try self.allocator.dupe(u32, updated);

    self.allocator.free(self.buckets);

    self.buckets = next;
}

pub fn find(self: *const Self, name: []const u8) ?Entry {
    if (self.rows.items.len == 0) return null;
    if (!generated) return if (self.seed_index.get(name)) |row| self.rows.items[row] else null;

    const probe = @import("generated_initializer_registry_lookup");
    const keys = memory.borrowTextColumn("identity", self.rows.items);

    const input: std.meta.Child(probe.Input) = .{
        .keys = @ptrCast(&keys),
        .buckets = self.buckets,
        .capacity = self.buckets.len,
        .text = name,
    };

    var scratch = std.heap.FixedBufferAllocator.init(&.{});
    const result = zx.columns.invoke(probe.executeValue, scratch.allocator(), &input) catch unreachable;

    return if (result.entry == 0) null else self.rows.items[@intCast(result.entry - 1)];
}

pub fn merge(self: *Self, allocator: std.mem.Allocator, values: []const Entry, range: Range, functions: *const Functions, own: bool) Error!void {
    if (values.len == 0) return;

    const available = functions.prefix.count() + functions.local.count();

    if (!generated) {
        for (values) |value| {
            const index = @backingInt(value.function);

            if (index >= range.count) return error.InvalidModule;

            const mapped = if (index < range.prefix) index else range.first + (index - range.prefix);

            if (mapped >= available) return error.InvalidModule;

            const id: ir.FunctionId = @fromBackingInt(@intCast(mapped));

            if (self.find(value.identity)) |previous| {
                if (previous.schema_version != value.schema_version) return error.ConflictingInitializer;
                if (previous.function != id and !functions.compare(previous, id)) return error.ConflictingInitializer;

                continue;
            }

            try self.seed_index.ensureUnusedCapacity(self.allocator, 1);
            try self.rows.ensureUnusedCapacity(allocator, 1);

            const name = if (own) try allocator.dupe(u8, value.identity) else value.identity;

            self.seed_index.putAssumeCapacityNoClobber(name, self.rows.items.len);
            self.rows.appendAssumeCapacity(.{ .identity = name, .schema_version = value.schema_version, .function = id });
        }

        return;
    }

    const rule = @import("generated_initializer_registry");
    const Input = std.meta.Child(rule.Input);
    const source_columns = readRows(values);
    const source = source_columns.bind(std.meta.Child(@FieldType(Input, "source")));
    const existing = readRows(self.rows.items);
    const published = existing.bind(std.meta.Child(@FieldType(std.meta.Child(@FieldType(Input, "registry")), "published")));
    var arena = std.heap.ArenaAllocator.init(allocator);

    defer arena.deinit();

    const FunctionView = @import("../../ir/compare/linked/host.zig").View(std.meta.Child(@FieldType(Input, "functions")));
    var function_view: FunctionView = undefined;

    function_view.init(functions.prefix, functions.local);

    const input: Input = .{
        .source = &source,
        .registry = &.{
            .published = &published,
            .buckets = self.buckets,
            .capacity = self.buckets.len,
            .count = self.rows.items.len,
        },
        .range = &.{ .first = range.first, .count = range.count, .prefix = range.prefix, .available = available },
        .functions = &function_view.input,
        .end = values.len,
    };

    const result = zx.columns.invoke(rule.executeValue, arena.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    try self.commit(allocator, result, own);

    switch (result.status) {
        .Done => return,
        .Conflict => return error.ConflictingInitializer,
        .InvalidModule => return error.InvalidModule,
    }
}

fn commit(self: *Self, allocator: std.mem.Allocator, result: anytype, own: bool) std.mem.Allocator.Error!void {
    const first = self.rows.items.len;

    try self.rows.ensureUnusedCapacity(allocator, result.rows.len);

    const tail = self.rows.unusedCapacitySlice()[0..result.rows.len];
    var written: usize = 0;

    errdefer if (own) {
        for (tail[0..written]) |row| allocator.free(row.identity);
    };

    for (result.rows, tail) |row, *target| {
        target.* = .{
            .identity = if (own) try allocator.dupe(u8, row.identity) else row.identity,
            .schema_version = row.version,
            .function = @fromBackingInt(row.function),
        };

        written += 1;
    }

    if (result.buckets) |updated| {
        try self.adoptBuckets(updated);
    } else {
        for (result.rows, first..) |row, index| self.buckets[@intCast(row.slot)] = @intCast(index + 1);
    }

    self.rows.items.len += written;
}

pub fn readRows(values: []const Entry) memory.ReadFields(fields) {
    return memory.borrowReadFields(fields, values);
}
