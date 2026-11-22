const schema = @import("../ir/schema.zig");
const Layout = schema.Control;
pub const Kind = if (schema.generated) schema.Columns.StatementKind else enum { Evaluate, Constant, Parallel, Destructure, Branch, Switch, StoreSet, Result };

pub const Table = struct {
    pub const validStructure = @import("validate.zig").structure;

    block_count: schema.column(Layout, "block_count", []const u32) = &.{},
    block_first: schema.column(Layout, "block_first", []const u32) = &.{},
    branch_conditions: schema.column(Layout, "branch_conditions", []const u32) = &.{},
    branch_no: schema.column(Layout, "branch_no", []const u32) = &.{},
    branch_yes: schema.column(Layout, "branch_yes", []const u32) = &.{},
    case_bodies: schema.column(Layout, "case_bodies", []const u32) = &.{},
    case_values: schema.column(Layout, "case_values", []const ?u32) = &.{},
    constant_symbols: schema.column(Layout, "constant_symbols", []const u32) = &.{},
    constant_values: schema.column(Layout, "constant_values", []const u32) = &.{},
    destructure_count: schema.column(Layout, "destructure_count", []const u32) = &.{},
    destructure_first: schema.column(Layout, "destructure_first", []const u32) = &.{},
    destructure_symbols: schema.column(Layout, "destructure_symbols", []const ?u32) = &.{},
    destructure_values: schema.column(Layout, "destructure_values", []const u32) = &.{},
    evaluations: schema.column(Layout, "evaluations", []const u32) = &.{},
    parallel_count: schema.column(Layout, "parallel_count", []const u32) = &.{},
    parallel_first: schema.column(Layout, "parallel_first", []const u32) = &.{},
    parallel_symbols: schema.column(Layout, "parallel_symbols", []const ?u32) = &.{},
    parallel_values: schema.column(Layout, "parallel_values", []const u32) = &.{},
    results: schema.column(Layout, "results", []const ?u32) = &.{},
    selection_count: schema.column(Layout, "selection_count", []const u32) = &.{},
    selection_exhaustive: schema.column(Layout, "selection_exhaustive", []const bool) = &.{},
    selection_first: schema.column(Layout, "selection_first", []const u32) = &.{},
    selection_subjects: schema.column(Layout, "selection_subjects", []const u32) = &.{},
    setter_slots: schema.column(Layout, "setter_slots", []const u32) = &.{},
    setter_values: schema.column(Layout, "setter_values", []const u32) = &.{},
    statement_kinds: schema.column(Layout, "statement_kinds", []const Kind) = &.{},
    statement_payloads: schema.column(Layout, "statement_payloads", []const u32) = &.{},
};

comptime {
    schema.checkTable(Layout, Table);
}
