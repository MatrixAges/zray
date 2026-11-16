const std = @import("std");
const frontend = @import("frontend");
const Module = frontend.project.signature_project.Module;
const Map = frontend.project.source_index.Map;
const Sources = @import("../source_graph/model.zig").Sources;
const memory = @import("zxc_standard").memory;
const rule = @import("generated_rx_publish_signature_index");
const Input = std.meta.Child(rule.Input);

pub fn publish(allocator: std.mem.Allocator, modules: []const Module, indices: []i64, paths: *const Map, sources: Sources) std.mem.Allocator.Error![]const u64 {
    if (modules.len == 0) return &.{};

    const Signature = @FieldType(Module, "signature");
    const base = @offsetOf(Module, "signature");
    const word = @sizeOf(u64);
    const bytes = std.mem.sliceAsBytes(modules);
    const words = std.mem.bytesAsSlice(u64, bytes);
    const store = base + @offsetOf(Signature, "has_store");
    const deferred = base + @offsetOf(Signature, "has_deferred_source");
    const source = @divExact(@offsetOf(Module, "source_row"), word);
    const path_offset = base + @offsetOf(Signature, "deferred_source");

    comptime {
        if (@sizeOf(@FieldType(Module, "source_row")) != word or @alignOf(Module) < @alignOf(u64) or
            @sizeOf(@FieldType(Signature, "has_store")) != @sizeOf(u8) or
            @sizeOf(@FieldType(Signature, "has_deferred_source")) != @sizeOf(u8) or
            @FieldType(Signature, "deferred_source") != []const u8)
        {
            @compileError("Incompatible layout for borrowing source signature rows");
        }
    }

    const deferred_paths: memory.TextColumn = .{
        .bytes = bytes,
        .count = modules.len,
        .stride = @sizeOf(Module),
        .offset = path_offset,
    };

    const input_rows: std.meta.Child(@FieldType(Input, "modules")) = .{
        .count = modules.len,
        .sources = words[source..],
        .word_stride = @divExact(@sizeOf(Module), word),
        .byte_stride = @sizeOf(Module),
        .store = bytes[store..],
        .deferred = bytes[deferred..],
        .paths = @ptrCast(&deferred_paths),
    };

    const index_words: []u64 = @ptrCast(indices);

    var input: Input = .{
        .modules = &input_rows,
        .start = 0,
        .indices = @ptrCast(&index_words),
        .forwards = null,
        .forwarding = &.{
            .keys = paths.keys,
            .buckets = @ptrCast(&paths.buckets),
            .capacity = paths.buckets.len,
            .sources = &.{ .zx_count = sources.zx_count, .rx_end = sources.rx_end },
        },
    };

    var empty = std.heap.FixedBufferAllocator.init(&.{});
    const first = rule.executeValue(empty.allocator(), &input) catch unreachable;

    if (first == modules.len) return &.{};

    const forwards = try allocator.alloc(u64, modules.len);

    @memset(forwards, 0);

    input.start = first;
    input.forwards = @ptrCast(&forwards);

    const end = rule.executeValue(empty.allocator(), &input) catch unreachable;

    std.debug.assert(end == modules.len);

    return forwards;
}
