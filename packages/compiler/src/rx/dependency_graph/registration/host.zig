const std = @import("std");
const dsl = @import("dsl");
const modules = @import("../../modules.zig");
const schema = @import("../../flow.zig").Module;

const Frame = struct {
    allocator: std.mem.Allocator,
    schemas: std.mem.Allocator,
    data: ?[]modules.Module,
    sources: []const modules.Source,
    source_index: *usize,
    reporter: *dsl.Reporter,
    fn borrow(handle: *const anyopaque) *Frame {
        return @ptrCast(@alignCast(@constCast(handle)));
    }
};

pub fn run(allocator: std.mem.Allocator, schemas: std.mem.Allocator, data: ?[]modules.Module, sources: []const modules.Source, registry: *modules.Registry, source_index: *usize, reporter: *dsl.Reporter) dsl.Error!void {
    const rule = @import("generated_rx_register_graph_modules");
    const zx = @import("zx");
    const paths = zx.memory.borrowTextColumn("path", sources);

    var frame: Frame = .{
        .allocator = allocator,
        .schemas = schemas,
        .data = data,
        .sources = sources,
        .source_index = source_index,
        .reporter = reporter,
    };

    var path: []u8 = &.{};

    const input: std.meta.Child(rule.Input) = .{
        .frame = @ptrCast(&frame),
        .paths = &.{
            .source = @ptrCast(&paths),
            .count = sources.len,
            .slots = @ptrCast(&registry.keys),
            .path = @ptrCast(&path),
            .registry = &.{
                .keys = registry.keys,
                .buckets = @ptrCast(&registry.buckets),
                .capacity = registry.buckets.len,
            },
            .allocator = @ptrCast(&allocator),
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});

    zx.columns.invoke(rule.executeIn, empty.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.InvalidDsl => return error.InvalidDsl,
        error.OutOfMemory, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };
}

pub fn rejectGraphModuleRegistration(handle: *const anyopaque, index: u64, message: []const u8) dsl.Error!void {
    const frame = Frame.borrow(handle);
    const row: usize = @intCast(index);
    const node = frame.sources[row].node;

    frame.source_index.* = row;

    return frame.reporter.fail(.{ .code = .context, .location = node.location, .element = node.name, .message = message });
}

pub fn validateRegisteredGraphModule(handle: *const anyopaque, index: u64, path: []const u8) dsl.Error!void {
    const frame = Frame.borrow(handle);
    const row: usize = @intCast(index);
    const source = &frame.sources[row];

    frame.source_index.* = row;

    if (frame.data) |data| {
        data[row] = .{ .path = path, .data = try schema.decode(frame.allocator, source.node, frame.reporter, source.callSequence()) };
    } else if (!source.hasSchema()) {
        _ = try schema.decode(frame.schemas, source.node, frame.reporter, source.callSequence());
    }
}
