const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const memory = zx.memory;
const equality = @import("../../ir/compare/initializer.zig");
const Entry = @import("../compiled.zig").StoreInitializer;
const generated = @import("parser_options").generated_parser;
const Self = @This();

rows: std.ArrayList(Entry) = .empty,
buckets: memory.U32Scratch = .{ .allocator = std.heap.page_allocator },
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
    if (generated) self.buckets.deinit() else self.seed_index.deinit(self.buckets.allocator);
}

pub fn find(self: *const Self, name: []const u8) ?Entry {
    if (self.rows.items.len == 0) return null;
    if (!generated) return if (self.seed_index.get(name)) |row| self.rows.items[row] else null;

    const probe = @import("generated_initializer_registry_lookup");
    const keys = memory.borrowTextColumn("identity", self.rows.items);

    const input: std.meta.Child(probe.Input) = .{
        .keys = @ptrCast(&keys),
        .buckets = @ptrCast(&self.buckets.items),
        .capacity = self.buckets.items.len,
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

            try self.seed_index.ensureUnusedCapacity(self.buckets.allocator, 1);
            try self.rows.ensureUnusedCapacity(allocator, 1);

            const name = if (own) try allocator.dupe(u8, value.identity) else value.identity;

            self.seed_index.putAssumeCapacityNoClobber(name, self.rows.items.len);
            self.rows.appendAssumeCapacity(.{ .identity = name, .schema_version = value.schema_version, .function = id });
        }

        return;
    }

    const rule = @import("generated_initializer_registry");
    const Input = std.meta.Child(rule.Input);
    const source_columns = columns(values);
    const source = source_columns.view(std.meta.Child(@FieldType(Input, "source")));
    const Target = std.meta.Child(@FieldType(Input, "target"));

    var target: memory.RowOutput(Entry, Target, .{
        .identity = &.{"identity"},
        .function = &.{"function"},
        .schema_version = &.{"schema_version"},
    }) = undefined;

    target.init();
    target.bind(self.rows.allocatedSlice());

    var reads: [@typeInfo(Target).@"struct".field_names.len]memory.ReadColumn = undefined;
    const growth: memory.RowGrowth = .{ .target = &target.buffer, .reads = &reads };

    growth.refresh();

    var published: @TypeOf(source) = undefined;

    inline for (@typeInfo(Target).@"struct".field_names, 0..) |name, index| {
        @field(published, name) = @ptrCast(&reads[index]);
    }

    var start: u64 = 0;
    var progress = [_]u64{self.rows.items.len};
    const published_count: []u64 = &progress;

    defer {
        const rows = target.rows();

        self.rows.items = rows[0..@intCast(progress[0])];
        self.rows.capacity = rows.len;
    }

    while (true) {
        const input: Input = .{
            .source = &source,
            .published = &published,
            .target = &target.view,
            .growth = @ptrCast(&growth),
            .range = &.{ .first = range.first, .count = range.count, .prefix = range.prefix, .available = available },
            .buckets = @ptrCast(&self.buckets.items),
            .scratch = @ptrCast(&self.buckets),
            .capacity = self.buckets.items.len,
            .count = progress[0],
            .space = target.buffer.bytes.len / @sizeOf(Entry),
            .start = start,
            .end = values.len,
            .own = own,
            .progress = @ptrCast(&published_count),
        };

        const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
            else => return error.InvalidModule,
        };

        start = result.next;

        switch (result.status) {
            .Done => return,
            .Compare => if (!functions.compare(target.rows()[@intCast(result.previous)], @fromBackingInt(result.function))) return error.ConflictingInitializer,
            .Conflict => return error.ConflictingInitializer,
            .InvalidModule => return error.InvalidModule,
        }
    }
}

const Reader = struct {
    identity: memory.ReadColumn,
    schema_version: memory.ReadColumn,
    function: memory.ReadColumn,
    fn view(self: *const @This(), comptime T: type) T {
        return .{ .identity = @ptrCast(&self.identity), .schema_version = @ptrCast(&self.schema_version), .function = @ptrCast(&self.function) };
    }
};

fn columns(values: []const Entry) Reader {
    var result: Reader = undefined;

    inline for (@typeInfo(Entry).@"struct".field_names) |name| {
        const T = @FieldType(Entry, name);

        @field(result, name) = memory.borrowReadColumn(T, name, values);
    }

    return result;
}
