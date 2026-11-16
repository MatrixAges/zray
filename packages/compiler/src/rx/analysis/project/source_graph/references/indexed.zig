const std = @import("std");
const rx = @import("rx");
const memory = @import("zxc_standard").memory;
const batch = @import("generated_rx_reference_batch");
const Reference = @import("../model.zig").Reference;
const Entry = rx.dependency_reference.Entry;
const Target = @FieldType(Entry, "target");
const Input = std.meta.Child(batch.Input);
const Rows = std.meta.Child(@FieldType(Input, "references"));
const Response = @typeInfo(@TypeOf(batch.executeValue(undefined, undefined))).error_union.payload;
const Progress = if (@typeInfo(Response) == .pointer) std.meta.Child(Response) else Response;
const Kind = enum(u8) { package, source, store, invalid, missing };
const batch_size = 16;
const inline_path_bytes = 512;

comptime {
    std.debug.assert(@sizeOf(Target) == 1);
    std.debug.assert(@backingInt(Target.Module) == 0 and @backingInt(Target.Function) == 1 and @backingInt(Target.Store) == 2);
}

pub fn collect(collector: anytype, owner: []const u8, entries: []const Entry) @TypeOf(collector.*).Error!void {
    if (entries.len == 0) return;

    const values = memory.borrowIndirectTextColumn("attribute", "value", entries);
    const packages = memory.borrowReadColumn(bool, "package_allowed", entries);
    const specifiers = memory.borrowTextColumn("specifier", collector.dependencies());

    const rows: Rows = .{
        .values = @ptrCast(&values),
        .package_allowed = @ptrCast(&packages),
        .target_codes = std.mem.sliceAsBytes(entries)[@offsetOf(Entry, "target")..],
        .stride = @sizeOf(Entry),
        .count = entries.len,
    };

    const directory = std.fs.path.dirname(owner) orelse ".";
    var inline_path: [inline_path_bytes]u8 = undefined;
    var path: []u8 = &inline_path;
    var output: Columns = undefined;
    var first: usize = 0;

    while (first < entries.len) {
        const count = @min(entries.len - first, batch_size);

        const progress = output.plan(&path, .{
            .directory = directory,
            .packages = &.{ .items = @ptrCast(&specifiers), .length = specifiers.count },
            .references = &rows,
            .first = first,
            .count = count,
            .workspace = undefined,
            .output = undefined,
        });

        const processed: usize = @intCast(progress.processed);

        std.debug.assert(processed != 0 or progress.required > path.len);

        for (0..processed) |index| {
            const entry = &entries[entries.len - first - index - 1];

            try output.load(collector, owner, entry, path, index);
        }

        first += processed;

        if (progress.required > path.len) {
            const length = std.math.cast(usize, progress.required) orelse return error.OutOfMemory;

            path = try collector.temporary.allocator().alloc(u8, length);
        }
    }
}

const Columns = struct {
    kinds: [batch_size]Kind,
    starts: [batch_size]u64,
    lengths: [batch_size]u64,
    packages: [batch_size]u64,
    duplicates: [batch_size]u8,
    fn plan(self: *Columns, path: *const []u8, request: Input) Progress {
        var input = request;
        const kinds: []Kind = &self.kinds;
        const starts: []u64 = &self.starts;
        const lengths: []u64 = &self.lengths;
        const packages: []u64 = &self.packages;
        const duplicates: []u8 = &self.duplicates;
        var bytes: [@sizeOf(Progress)]u8 align(@alignOf(Progress)) = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&bytes);

        input.workspace = &.{ .bytes = path.*, .target = @ptrCast(path), .start = 0 };

        input.output = &.{
            .kinds = @ptrCast(&kinds),
            .starts = @ptrCast(&starts),
            .lengths = @ptrCast(&lengths),
            .packages = @ptrCast(&packages),
            .duplicates = @ptrCast(&duplicates),
        };

        const result = @import("zx").columns.invoke(batch.executeValue, scratch.allocator(), @as(*const Input, &input)) catch unreachable;

        return if (comptime @typeInfo(Response) == .pointer) result.* else result;
    }
    fn load(self: *const Columns, collector: anytype, owner: []const u8, entry: *const Entry, path: []const u8, index: usize) @TypeOf(collector.*).Error!void {
        const kind = self.kinds[index];

        if (kind == .missing) return collector.fail(entry.node.location, "source dependency requires an explicit target");

        const value = entry.attribute.?;
        const role = Reference.fromXml(entry.role);

        switch (kind) {
            .package => try collector.import(value.value, value.value_location, role, .{
                .first = @intCast(self.packages[index]),
                .duplicate = self.duplicates[index] != 0,
            }),
            .source => try collector.local(self.pathAt(path, index), value.value_location, role),
            .store => try collector.store(self.pathAt(path, index), value.value_location, owner),
            .invalid => return collector.fail(value.value_location, "source dependency escapes the project root or is not a valid module path"),
            .missing => unreachable,
        }
    }
    fn pathAt(self: *const Columns, path: []const u8, index: usize) []const u8 {
        return path[@intCast(self.starts[index])..][0..@intCast(self.lengths[index])];
    }
};
