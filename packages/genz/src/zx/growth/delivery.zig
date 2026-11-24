const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const publication = @import("../construction/publication.zig");
const generated = @import("generated_growth_delivery");
const Input = std.meta.Child(generated.Input);
const Normalize = std.meta.Child(std.meta.Child(@FieldType(Input, "normalize")));
const Entry = std.meta.Child(std.meta.Child(@FieldType(Input, "entry")));
const Value = std.meta.Child(std.meta.Child(@FieldType(Input, "value")));
const Source = std.meta.Child(@FieldType(Normalize, "source"));
const Capture = std.meta.Child(std.meta.Child(@FieldType(Source, "capture")));
const Types = std.meta.Child(@FieldType(Entry, "types"));
const Records = std.meta.Child(@FieldType(Entry, "records"));
pub const Target = union(enum) { reference: node.ExpressionId, name: []const u8 };

pub const Entries = struct {
    type_id: ir.TypeId,
    target: Target,
    first: usize,
    end: usize,
    skipped: []const u64,
    filtered_inline: bool,
};

const Result = struct {
    root: node.ExpressionId,
    block: node.Block,
};

pub fn normalize(self: *Lower, body: *Sequence, element: node.ExpressionId, value: node.ExpressionId, selected: bool, layout: ?node.ExpressionId) Lower.Error!node.ExpressionId {
    const capture = captureInput(self);
    const source = prepare(self, .Reserve, element, value, false, &capture);

    const request: Normalize = .{
        .source = &source,
        .selected = selected,
        .layout = if (layout) |expression| @backingInt(expression) else 0,
        .field_base = @intCast(self.builder.nodes.field_columns.count()),
    };

    const delivered = try deliver(self, body, .{
        .normalize = &request,
        .entry = null,
        .value = null,
        .uses_allocator = self.uses_allocator,
    });

    return delivered.root;
}

pub fn entry(self: *Lower, request: Entries) Lower.Error!node.Block {
    const capture = captureInput(self);
    const reference: node.ExpressionId = if (request.target == .reference) request.target.reference else @fromBackingInt(0);
    const source = prepare(self, .Renew, @fromBackingInt(0), reference, !self.may_grow, &capture);
    const types = ir.TypeTable.borrow(Types, self.program.types);
    const records = zx.columns.view(Records, self.plan.renewals);
    const range: std.meta.Child(@FieldType(Entry, "range")) = .{ .first = request.first, .end = request.end };

    const input: Entry = .{
        .source = &source,
        .types = &types,
        .type_id = @backingInt(request.type_id),
        .records = &records,
        .range = &range,
        .skipped = request.skipped,
        .name = if (request.target == .name) request.target.name else null,
        .entry_rows = true,
        .inline_lists = inlineLists(self),
        .filtered_inline = request.filtered_inline,
    };

    const delivered = try deliver(self, null, .{
        .normalize = null,
        .entry = &input,
        .value = null,
        .uses_allocator = self.uses_allocator,
    });

    return delivered.block;
}

pub fn appendValue(self: *Lower, body: *Sequence, id: ir.ExprId, reference: node.ExpressionId) Lower.Error!void {
    const capture = captureInput(self);
    const source = prepare(self, .Renew, @fromBackingInt(0), reference, !self.may_grow, &capture);
    const types = ir.TypeTable.borrow(Types, self.program.types);
    const records = zx.columns.view(Records, self.plan.renewals);

    const input: Value = .{
        .source = &source,
        .types = &types,
        .type_id = @backingInt(self.program.expression(id).type_id),
        .records = &records,
        .owner = @backingInt(id),
        .inline_lists = inlineLists(self),
    };

    _ = try deliver(self, body, .{
        .normalize = null,
        .entry = null,
        .value = &input,
        .uses_allocator = self.uses_allocator,
    });
}

fn prepare(self: *const Lower, operation: @FieldType(Source, "operation"), element: node.ExpressionId, value: node.ExpressionId, flag: bool, capture: *const ?Capture) Source {
    return .{
        .operation = operation,
        .element = @backingInt(element),
        .value = @backingInt(value),
        .count = 0,
        .minimum = 0,
        .flag = flag,
        .shared = self.shared_types,
        .capture = if (capture.*) |*boundary| boundary else null,
        .expression_base = @intCast(self.builder.nodes.expressions.tags.items.len),
        .statement_base = @intCast(self.builder.nodes.statements.tags.items.len),
        .serial = self.serial,
    };
}

fn captureInput(self: *const Lower) ?Capture {
    const capture = self.capture orelse return null;

    return .{ .name = capture.name, .label = capture.label, .failure = @backingInt(capture.failure) };
}

fn inlineLists(self: *const Lower) bool {
    const context = self.iteration_value orelse return false;

    return context.inline_lists;
}

fn deliver(self: *Lower, body: ?*Sequence, input: Input) Lower.Error!Result {
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const fragment = (zx.columns.invoke(generated.executeValue, memory.allocator(), &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    }).?;

    if (input.normalize == null) std.debug.assert(fragment.result.serial == self.serial);
    try publication.write(self, body, &fragment, .Growth);

    return .{
        .root = @fromBackingInt(fragment.result.root),
        .block = .{ .start = @intCast(fragment.start), .len = @intCast(fragment.count) },
    };
}
