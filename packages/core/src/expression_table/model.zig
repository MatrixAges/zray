const schema = @import("../ir/schema.zig");
const Layout = schema.Expressions;

pub const ExpressionKind = if (schema.generated) schema.Columns.ExpressionKind else enum {
    Integer,
    NegativeInteger,
    Float,
    String,
    Boolean,
    None,
    Unit,
    Some,
    Capture,
    Task,
    AwaitTask,
    CancelTask,
    Parallel,
    OptionalValue,
    EnumValue,
    ErrorValue,
    Reference,
    StoreGet,
    Field,
    Index,
    Length,
    List,
    Tuple,
    TupleField,
    Template,
    ListOperation,
    Transform,
    Scope,
    Iteration,
    ListUpdate,
    Call,
    Unary,
    Binary,
    Conditional,
    Match,
    Object,
};

pub const CollectionKind = if (schema.generated) schema.Columns.CollectionKind else enum {
    Push,
    Pop,
    Sort,
    Reverse,
    Splice,
    Concat,
    Slice,
};

pub const TransformKind = if (schema.generated) schema.Columns.TransformKind else enum {
    Map,
    Filter,
    Reduce,
    Every,
    Some,
    Sort,
};

pub const UnaryOperator = if (schema.generated) schema.Columns.UnaryOperator else enum {
    Negate,
    Not,
};

pub const BinaryOperator = if (schema.generated) schema.Columns.BinaryOperator else enum {
    Coalesce,
    Add,
    Subtract,
    Multiply,
    Divide,
    Remainder,
    Equal,
    NotEqual,
    Less,
    LessEqual,
    Greater,
    GreaterEqual,
    LogicalAnd,
    LogicalOr,
};

pub const Table = struct {
    pub fn count(self: Table) usize {
        return self.kinds.len;
    }

    pub fn at(self: Table, index: usize) @import("row.zig").Expression {
        return @import("read.zig").expression(&self, index);
    }

    pub fn get(self: Table, id: @import("../ir.zig").ExprId) @import("row.zig").Expression {
        return self.at(@backingInt(id));
    }
    /// The function the expression at `index` calls, read without decoding the rest of its row.
    pub fn callee(self: Table, index: usize) ?@import("../ir.zig").FunctionId {
        return if (self.kinds[index] == .Call) @fromBackingInt(self.call_functions[self.payloads[index]]) else null;
    }
    /// Whether the expression at `index` starts, awaits or cancels tasks.
    pub fn concurrent(self: Table, index: usize) bool {
        return switch (self.kinds[index]) {
            .Task, .AwaitTask, .CancelTask, .Parallel => true,
            else => false,
        };
    }

    pub const validStructure = @import("validate.zig").structure;

    pub fn fromValues(allocator: @import("std").mem.Allocator, values: []const @import("../ir.zig").Expression) @import("std").mem.Allocator.Error!Table {
        var storage: @import("storage.zig") = .{};

        errdefer storage.deinit(allocator);

        for (values) |value| _ = try storage.append(allocator, value);

        return storage.finish(allocator);
    }

    awaits: schema.column(Layout, "awaits", []const u32) = &.{},
    binary_left: schema.column(Layout, "binary_left", []const u32) = &.{},
    binary_operators: schema.column(Layout, "binary_operators", []const BinaryOperator) = &.{},
    binary_right: schema.column(Layout, "binary_right", []const u32) = &.{},
    booleans: schema.column(Layout, "booleans", []const bool) = &.{},
    call_arguments: schema.column(Layout, "call_arguments", []const u32) = &.{},
    call_functions: schema.column(Layout, "call_functions", []const u32) = &.{},
    call_store_count: schema.column(Layout, "call_store_count", []const u32) = &.{},
    call_store_first: schema.column(Layout, "call_store_first", []const u32) = &.{},
    call_stores: schema.column(Layout, "call_stores", []const u32) = &.{},
    cancellations: schema.column(Layout, "cancellations", []const u32) = &.{},
    captures: schema.column(Layout, "captures", []const u32) = &.{},
    collection_arguments: schema.column(Layout, "collection_arguments", []const u32) = &.{},
    collection_count: schema.column(Layout, "collection_count", []const u32) = &.{},
    collection_first: schema.column(Layout, "collection_first", []const u32) = &.{},
    collection_kinds: schema.column(Layout, "collection_kinds", []const CollectionKind) = &.{},
    collection_targets: schema.column(Layout, "collection_targets", []const u32) = &.{},
    conditional_conditions: schema.column(Layout, "conditional_conditions", []const u32) = &.{},
    conditional_no: schema.column(Layout, "conditional_no", []const u32) = &.{},
    conditional_yes: schema.column(Layout, "conditional_yes", []const u32) = &.{},
    enumerations: schema.column(Layout, "enumerations", []const u32) = &.{},
    errors: schema.column(Layout, "errors", []const u32) = &.{},
    floats: schema.column(Layout, "floats", []const f64) = &.{},
    index_targets: schema.column(Layout, "index_targets", []const u32) = &.{},
    index_values: schema.column(Layout, "index_values", []const u32) = &.{},
    integers: schema.column(Layout, "integers", []const u64) = &.{},
    iteration_bodies: schema.column(Layout, "iteration_bodies", []const u32) = &.{},
    iteration_condition_parameters: schema.column(Layout, "iteration_condition_parameters", []const u32) = &.{},
    iteration_conditions: schema.column(Layout, "iteration_conditions", []const u32) = &.{},
    iteration_environment_symbols: schema.column(Layout, "iteration_environment_symbols", []const ?u32) = &.{},
    iteration_initials: schema.column(Layout, "iteration_initials", []const u32) = &.{},
    iteration_parameters: schema.column(Layout, "iteration_parameters", []const u32) = &.{},
    iteration_postconditions: schema.column(Layout, "iteration_postconditions", []const bool) = &.{},
    kinds: schema.column(Layout, "kinds", []const ExpressionKind) = &.{},
    lengths: schema.column(Layout, "lengths", []const u32) = &.{},
    match_conditions: schema.column(Layout, "match_conditions", []const u32) = &.{},
    match_count: schema.column(Layout, "match_count", []const u32) = &.{},
    match_fallbacks: schema.column(Layout, "match_fallbacks", []const u32) = &.{},
    match_first: schema.column(Layout, "match_first", []const u32) = &.{},
    match_results: schema.column(Layout, "match_results", []const u32) = &.{},
    match_subjects: schema.column(Layout, "match_subjects", []const ?u32) = &.{},
    negative_integers: schema.column(Layout, "negative_integers", []const u64) = &.{},
    object_count: schema.column(Layout, "object_count", []const u32) = &.{},
    object_evaluation_count: schema.column(Layout, "object_evaluation_count", []const u32) = &.{},
    object_evaluation_first: schema.column(Layout, "object_evaluation_first", []const u32) = &.{},
    object_evaluation_values: schema.column(Layout, "object_evaluation_values", []const u32) = &.{},
    object_field_indices: schema.column(Layout, "object_field_indices", []const u32) = &.{},
    object_field_values: schema.column(Layout, "object_field_values", []const u32) = &.{},
    object_first: schema.column(Layout, "object_first", []const u32) = &.{},
    optional_values: schema.column(Layout, "optional_values", []const u32) = &.{},
    parallel_count: schema.column(Layout, "parallel_count", []const u32) = &.{},
    parallel_fields: schema.column(Layout, "parallel_fields", []const ?u32) = &.{},
    parallel_first: schema.column(Layout, "parallel_first", []const u32) = &.{},
    parallel_tasks: schema.column(Layout, "parallel_tasks", []const u32) = &.{},
    payloads: schema.column(Layout, "payloads", []const u32) = &.{},
    projection_indices: schema.column(Layout, "projection_indices", []const u32) = &.{},
    projection_targets: schema.column(Layout, "projection_targets", []const u32) = &.{},
    references: schema.column(Layout, "references", []const u32) = &.{},
    scope_borrows: schema.column(Layout, "scope_borrows", []const bool) = &.{},
    scope_count: schema.column(Layout, "scope_count", []const u32) = &.{},
    scope_first: schema.column(Layout, "scope_first", []const u32) = &.{},
    scope_results: schema.column(Layout, "scope_results", []const u32) = &.{},
    scope_symbols: schema.column(Layout, "scope_symbols", []const ?u32) = &.{},
    scope_values: schema.column(Layout, "scope_values", []const u32) = &.{},
    sequence_count: schema.column(Layout, "sequence_count", []const u32) = &.{},
    sequence_first: schema.column(Layout, "sequence_first", []const u32) = &.{},
    sequence_items: schema.column(Layout, "sequence_items", []const u32) = &.{},
    some: schema.column(Layout, "some", []const u32) = &.{},
    span_end: schema.column(Layout, "span_end", []const u64) = &.{},
    span_start: schema.column(Layout, "span_start", []const u64) = &.{},
    stores: schema.column(Layout, "stores", []const u32) = &.{},
    strings: schema.column(Layout, "strings", []const []const u8) = &.{},
    task_bodies: schema.column(Layout, "task_bodies", []const u32) = &.{},
    task_capture_count: schema.column(Layout, "task_capture_count", []const u32) = &.{},
    task_capture_first: schema.column(Layout, "task_capture_first", []const u32) = &.{},
    task_captures: schema.column(Layout, "task_captures", []const u32) = &.{},
    transform_bodies: schema.column(Layout, "transform_bodies", []const u32) = &.{},
    transform_count: schema.column(Layout, "transform_count", []const u32) = &.{},
    transform_first: schema.column(Layout, "transform_first", []const u32) = &.{},
    transform_initials: schema.column(Layout, "transform_initials", []const ?u32) = &.{},
    transform_kinds: schema.column(Layout, "transform_kinds", []const TransformKind) = &.{},
    transform_parameters: schema.column(Layout, "transform_parameters", []const u32) = &.{},
    transform_targets: schema.column(Layout, "transform_targets", []const u32) = &.{},
    types: schema.column(Layout, "types", []const u32) = &.{},
    unary_operands: schema.column(Layout, "unary_operands", []const u32) = &.{},
    unary_operators: schema.column(Layout, "unary_operators", []const UnaryOperator) = &.{},
    update_indices: schema.column(Layout, "update_indices", []const u32) = &.{},
    update_targets: schema.column(Layout, "update_targets", []const u32) = &.{},
    update_values: schema.column(Layout, "update_values", []const u32) = &.{},
};

comptime {
    schema.checkTable(Layout, Table);
}
