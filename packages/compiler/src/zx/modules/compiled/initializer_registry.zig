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
    const source_columns = readRows(values);
    const source = source_columns.bind(std.meta.Child(@FieldType(Input, "source")));
    var writer: Writer(std.meta.Child(@FieldType(Input, "registry"))) = undefined;

    writer.init(self, own);

    defer writer.finish(self);

    const FunctionView = @import("../../ir/compare/linked/host.zig").View(std.meta.Child(@FieldType(Input, "functions")));
    var function_view: FunctionView = undefined;

    function_view.init(functions.prefix, functions.local);

    const input: Input = .{
        .source = &source,
        .registry = &writer.input,
        .range = &.{ .first = range.first, .count = range.count, .prefix = range.prefix, .available = available },
        .functions = &function_view.input,
        .end = values.len,
    };

    const result = zx.columns.invoke(rule.executeValue, allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow => return error.OutOfMemory,
        else => return error.InvalidModule,
    };

    switch (result) {
        .Done => return,
        .Conflict => return error.ConflictingInitializer,
        .InvalidModule => return error.InvalidModule,
    }
}

pub fn Writer(comptime Storage: type) type {
    const Target = std.meta.Child(@FieldType(Storage, "target"));
    const Published = std.meta.Child(@FieldType(Storage, "published"));

    return struct {
        target: memory.RowOutput(Entry, Target, .{}),
        reads: [@typeInfo(Target).@"struct".field_names.len]memory.ReadColumn,
        growth: memory.RowGrowth,
        published: Published,
        progress: [1]u64,
        progress_view: []u64,
        input: Storage,
        pub fn init(self: *@This(), registry: *Self, own: bool) void {
            self.target.init();

            const storage = registry.rows.allocatedSlice();

            self.target.bind(storage);

            self.growth = .{ .target = &self.target.buffer, .reads = &self.reads };

            inline for (@typeInfo(Target).@"struct".field_names, 0..) |name, index| {
                self.growth.refreshCell(index, storage.len);
                @field(self.published, name) = @ptrCast(&self.reads[index]);
            }

            self.progress = .{registry.rows.items.len};
            self.progress_view = &self.progress;

            self.input = .{
                .published = &self.published,
                .target = &self.target.view,
                .growth = @ptrCast(&self.growth),
                .buckets = @ptrCast(&registry.buckets.items),
                .scratch = @ptrCast(&registry.buckets),
                .capacity = registry.buckets.items.len,
                .count = registry.rows.items.len,
                .space = registry.rows.capacity,
                .own = own,
                .progress = @ptrCast(&self.progress_view),
            };
        }
        pub fn finish(self: *const @This(), registry: *Self) void {
            const rows = self.target.rows();

            registry.rows.items = rows[0..@intCast(self.progress[0])];
            registry.rows.capacity = rows.len;
        }
    };
}

pub fn readRows(values: []const Entry) memory.ReadFields(fields) {
    return memory.borrowReadFields(fields, values);
}
