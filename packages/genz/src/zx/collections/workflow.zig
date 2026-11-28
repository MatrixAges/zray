const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const node = @import("../../node.zig");
const Lower = @import("../lower.zig");
const Sequence = @import("../../node/blocks.zig").Sequence;
const lists = @import("../state_value/list.zig");
const elements = @import("../state_value/elements.zig");
const evaluation = @import("../expressions/evaluate.zig");
const publication = @import("../construction/publication.zig");
const entry = @import("generated_run_collection_operation");
const Input = std.meta.Child(entry.Input);
const Ast = std.meta.Child(@FieldType(Input, "ast"));
const Elements = std.meta.Child(@FieldType(Ast, "elements"));
const Capacity = std.meta.Child(@typeInfo(@FieldType(Input, "capacity")).optional.child);
const Conversion = std.meta.Child(@FieldType(Input, "conversion"));
const ConversionSource = std.meta.Child(@FieldType(Conversion, "source"));
const element_emission = @import("../state_value/element_emission.zig");
const Error = Lower.Error;
const Work = @import("branch.zig");
const generated = @import("genz_options").generated_analysis;
const ComparisonRows = if (generated) std.meta.Child(@FieldType(entry.zx_pending, "store_1")) else void;

pub const Comparisons = struct {
    rows: std.ArrayList(ir.TypeId) = .empty,
    view: if (generated) std.meta.Child(ComparisonRows) else void = if (generated) .{
        .types = &.{},
        .next = null,
    } else {},
    pub fn append(self: *Comparisons, allocator: std.mem.Allocator, child: ir.TypeId) Error!void {
        try self.rows.append(allocator, child);
        if (generated) self.view.types = @ptrCast(self.rows.items);
    }
};

const Host = struct {
    owner: *Comparisons,
    work: *Work,
    allocator: std.mem.Allocator,
    store_0: *const Work.View,
    store_1: *const ComparisonRows,
    pub fn commit(self: Host, pending: anytype) Error!void {
        try self.work.runCollectionWork(pending.store_0);

        const rows = pending.store_1 orelse return;

        if (rows.next) |child| try self.owner.append(self.allocator, @fromBackingInt(child));
    }
};

pub fn run(self: *Lower, id: ir.ExprId, layout: ?node.ExpressionId, removed_only: bool) Error!node.ExpressionId {
    const row = self.program.expression(id);
    const operation = row.value.list_operation;
    const flags = self.plan.get(id);
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const source_type: ir.TypeId = @fromBackingInt(self.program.expressions.types[@backingInt(operation.target)]);
    var body = self.builder.statementSequence(self.workspace);

    defer body.deinit();

    var types: std.meta.Child(@FieldType(Elements, "types")) = undefined;
    const element_source = element_emission.borrowSource(Elements, self, &types);
    const context = if (operation.kind == .push or operation.kind == .concat) self.loop_fields else null;

    const capacity: Capacity = if (context) |fields| .{
        .types = element_source.types,
        .type_id = @backingInt(fields.type_id),
        .value = @backingInt(fields.seed),
        .capacity = if (fields.capacity) |limit| &.{ .operation = @backingInt(limit.operation), .source = limit.source } else null,
        .active = self.state_active,
        .selected = self.state_plan.selected,
    } else undefined;

    const input: Input = .{
        .id = @backingInt(id),
        .ast = &.{
            .lower = @ptrCast(self),
            .writer = @ptrCast(self),
            .sequence = @ptrCast(&body),
            .elements = &element_source,
        },
        .represented = lists.selected(self, source_type),
        .kind = @fromBackingInt(@backingInt(operation.kind)),
        .target = @backingInt(operation.target),
        .source_type = @backingInt(source_type),
        .expression_types = self.program.expressions.types,
        .result_type = @backingInt(row.type_id),
        .conversion = &.{
            .source = &.{
                .types = element_source.types,
                .queries = zx.columns.slice(@FieldType(ConversionSource, "queries"), self.state_plan.queries),
                .selected = self.state_plan.selected,
                .element_storage = self.state_plan.element_storage,
            },
            .resources = &.{
                .frame = @ptrCast(self),
                .types = &.{
                    .abi_types = @ptrCast(self.abi_types),
                    .abi_layouts = @ptrCast(self.abi_layouts),
                    .state_types = @ptrCast(self.state_types),
                    .state_layouts = @ptrCast(self.state_layouts),
                    .views = @ptrCast(self.view_types),
                },
                .table = element_source.types,
                .referenced = self.state_plan.borrowed,
            },
            .shared = self.shared_types,
        },
        .arguments = @import("../../node/view.zig").slice([]const u32, operation.arguments),
        .frontier = flags.frontier,
        .in_place = flags.in_place,
        .grow = flags.grow,
        .lazy = flags.lazy,
        .retract = flags.retract,
        .shared = self.shared_types,
        .removed_only = removed_only,
        .capacity = if (context != null) &capacity else null,
        .state_active = self.state_active,
        .result_selected = self.state_active and self.state_plan.selected[@backingInt(row.type_id)],
        .named = self.type_names != null,
        .layout = if (layout) |target| @backingInt(target) else null,
    };

    const comparisons = self.comparisons;
    const comparison_view: ComparisonRows = &comparisons.view;
    var work: Work = .{ .lowering = self, .sequence = &body };
    const work_view: Work.View = &work.state;

    const host: Host = .{
        .owner = comparisons,
        .work = &work,
        .allocator = self.allocator,
        .store_0 = &work_view,
        .store_1 = &comparison_view,
    };

    return @fromBackingInt(entry.executeIn(memory.allocator(), &input, host) catch |err| return publication.failure(err));
}

pub fn clipCollectionTarget(frame: *anyopaque, body: *anyopaque, target: u32, value: u32) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try @import("../state_value/ownership.zig").clip(lowering, sequence, @fromBackingInt(target), @fromBackingInt(value)));
}

pub fn writeCollectionElement(frame: *anyopaque, body: *anyopaque, list_type: u32, value: u32) Error!u32 {
    const lowering = evaluation.borrow(frame);
    const sequence: *Sequence = @ptrCast(@alignCast(body));

    return @backingInt(try elements.write(lowering, sequence, @fromBackingInt(list_type), @fromBackingInt(value)));
}
