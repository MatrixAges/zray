const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const Builder = @import("../builder.zig");
const Mapping = @import("../mapping.zig");
const operands = @import("operands/host.zig");
const fixed = @import("fixed.zig");
const literals = @import("literals/host.zig");
const rule = @import("generated_rx_link_payload_batch");
const Input = std.meta.Child(rule.Input);
const Result = @typeInfo(@TypeOf(rule.executeValue(undefined, undefined))).error_union.payload;
const Progress = if (@typeInfo(Result) == .pointer) std.meta.Child(Result) else Result;
const batch_size = 16;
const Kind = enum(u8) { fixed, sequence, collection, transform, scope, selection, object };

pub fn publish(builder: *Builder, mapping: *Mapping, source: *const ir.ExpressionTable, bases: literals.Bases, base: usize, target: []u32) Builder.Error!void {
    const kinds = zx.columns.slice(@FieldType(Input, "kinds"), source.kinds);
    var source_rows: [batch_size]u32 = undefined;
    var routes: [batch_size]Kind = undefined;
    const pending_rows: []u32 = &source_rows;
    const route_rows: []Kind = &routes;
    const pending_kinds = std.mem.sliceAsBytes(route_rows);
    const LiteralBases = std.meta.Child(@FieldType(Input, "literals"));
    const storage = &builder.expressions;
    const allocator = builder.allocator;
    var literal_bases: LiteralBases = undefined;

    inline for (@typeInfo(LiteralBases).@"struct".field_names) |name| {
        @field(literal_bases, name) = @field(bases, name);
    }

    var next: u64 = 0;

    while (next < mapping.expressions.len) {
        const input: Input = .{
            .kinds = kinds,
            .payloads = source.payloads,
            .rows = mapping.expressions,
            .literals = &literal_bases,
            .base = base,
            .first = next,
            .limit = batch_size,
            .target = @ptrCast(&target),
            .pending_rows = @ptrCast(&pending_rows),
            .pending_kinds = @ptrCast(&pending_kinds),
        };

        var buffer: [@sizeOf(Progress)]u8 align(@alignOf(Progress)) = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&buffer);

        const batch = zx.columns.invoke(rule.executeValue, scratch.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
            error.OutOfMemory => return error.OutOfMemory,
            error.IndexOutOfBounds, error.IntegerOverflow => return error.InvalidModule,
            else => unreachable,
        };

        const count: usize = @intCast(batch.pending);

        for (source_rows[0..count], routes[0..count]) |row, kind| {
            mapping.available = row;

            const operand = source.payloads[row];

            const payload = switch (kind) {
                .fixed => try fixed.append(builder, mapping, source, row, false),
                .sequence => try operands.sequence(storage, allocator, mapping, source, operand),
                .collection => try operands.collection(storage, allocator, mapping, source, operand),
                .transform => try operands.transform(storage, allocator, mapping, source, operand),
                .scope => try operands.scope(storage, allocator, mapping, source, operand),
                .selection => try operands.match(storage, allocator, mapping, source, operand),
                .object => try operands.object(storage, allocator, mapping, source, operand),
            };

            target[mapping.expressions[row] - base] = @intCast(payload);
        }

        next = batch.next;
    }
}
