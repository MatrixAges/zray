const std = @import("std");
const model = @import("model.zig");
const schema = @import("../ir/schema.zig");
const Self = @This();

kinds: schema.storage(model.Table, "kinds") = .empty,
types: schema.storage(model.Table, "types") = .empty,
span_start: schema.storage(model.Table, "span_start") = .empty,
span_end: schema.storage(model.Table, "span_end") = .empty,
payloads: schema.storage(model.Table, "payloads") = .empty,
integers: schema.storage(model.Table, "integers") = .empty,
negative_integers: schema.storage(model.Table, "negative_integers") = .empty,
floats: schema.storage(model.Table, "floats") = .empty,
strings: schema.storage(model.Table, "strings") = .empty,
booleans: schema.storage(model.Table, "booleans") = .empty,
some: schema.storage(model.Table, "some") = .empty,
captures: schema.storage(model.Table, "captures") = .empty,
awaits: schema.storage(model.Table, "awaits") = .empty,
cancellations: schema.storage(model.Table, "cancellations") = .empty,
optional_values: schema.storage(model.Table, "optional_values") = .empty,
enumerations: schema.storage(model.Table, "enumerations") = .empty,
errors: schema.storage(model.Table, "errors") = .empty,
references: schema.storage(model.Table, "references") = .empty,
stores: schema.storage(model.Table, "stores") = .empty,
lengths: schema.storage(model.Table, "lengths") = .empty,
sequence_first: schema.storage(model.Table, "sequence_first") = .empty,
sequence_count: schema.storage(model.Table, "sequence_count") = .empty,
sequence_items: schema.storage(model.Table, "sequence_items") = .empty,
projection_targets: schema.storage(model.Table, "projection_targets") = .empty,
projection_indices: schema.storage(model.Table, "projection_indices") = .empty,
index_targets: schema.storage(model.Table, "index_targets") = .empty,
index_values: schema.storage(model.Table, "index_values") = .empty,
task_bodies: schema.storage(model.Table, "task_bodies") = .empty,
task_capture_first: schema.storage(model.Table, "task_capture_first") = .empty,
task_capture_count: schema.storage(model.Table, "task_capture_count") = .empty,
task_captures: schema.storage(model.Table, "task_captures") = .empty,
parallel_first: schema.storage(model.Table, "parallel_first") = .empty,
parallel_count: schema.storage(model.Table, "parallel_count") = .empty,
parallel_tasks: schema.storage(model.Table, "parallel_tasks") = .empty,
parallel_fields: schema.storage(model.Table, "parallel_fields") = .empty,
collection_kinds: schema.storage(model.Table, "collection_kinds") = .empty,
collection_targets: schema.storage(model.Table, "collection_targets") = .empty,
collection_first: schema.storage(model.Table, "collection_first") = .empty,
collection_count: schema.storage(model.Table, "collection_count") = .empty,
collection_arguments: schema.storage(model.Table, "collection_arguments") = .empty,
transform_kinds: schema.storage(model.Table, "transform_kinds") = .empty,
transform_targets: schema.storage(model.Table, "transform_targets") = .empty,
transform_bodies: schema.storage(model.Table, "transform_bodies") = .empty,
transform_initials: schema.storage(model.Table, "transform_initials") = .empty,
transform_first: schema.storage(model.Table, "transform_first") = .empty,
transform_count: schema.storage(model.Table, "transform_count") = .empty,
transform_parameters: schema.storage(model.Table, "transform_parameters") = .empty,
scope_results: schema.storage(model.Table, "scope_results") = .empty,
scope_first: schema.storage(model.Table, "scope_first") = .empty,
scope_count: schema.storage(model.Table, "scope_count") = .empty,
scope_symbols: schema.storage(model.Table, "scope_symbols") = .empty,
scope_values: schema.storage(model.Table, "scope_values") = .empty,
scope_borrows: schema.storage(model.Table, "scope_borrows") = .empty,
iteration_initials: schema.storage(model.Table, "iteration_initials") = .empty,
iteration_condition_parameters: schema.storage(model.Table, "iteration_condition_parameters") = .empty,
iteration_parameters: schema.storage(model.Table, "iteration_parameters") = .empty,
iteration_environment_symbols: schema.storage(model.Table, "iteration_environment_symbols") = .empty,
iteration_conditions: schema.storage(model.Table, "iteration_conditions") = .empty,
iteration_bodies: schema.storage(model.Table, "iteration_bodies") = .empty,
iteration_postconditions: schema.storage(model.Table, "iteration_postconditions") = .empty,
update_targets: schema.storage(model.Table, "update_targets") = .empty,
update_indices: schema.storage(model.Table, "update_indices") = .empty,
update_values: schema.storage(model.Table, "update_values") = .empty,
call_functions: schema.storage(model.Table, "call_functions") = .empty,
call_arguments: schema.storage(model.Table, "call_arguments") = .empty,
call_store_first: schema.storage(model.Table, "call_store_first") = .empty,
call_store_count: schema.storage(model.Table, "call_store_count") = .empty,
call_stores: schema.storage(model.Table, "call_stores") = .empty,
unary_operators: schema.storage(model.Table, "unary_operators") = .empty,
unary_operands: schema.storage(model.Table, "unary_operands") = .empty,
binary_operators: schema.storage(model.Table, "binary_operators") = .empty,
binary_left: schema.storage(model.Table, "binary_left") = .empty,
binary_right: schema.storage(model.Table, "binary_right") = .empty,
conditional_conditions: schema.storage(model.Table, "conditional_conditions") = .empty,
conditional_yes: schema.storage(model.Table, "conditional_yes") = .empty,
conditional_no: schema.storage(model.Table, "conditional_no") = .empty,
match_subjects: schema.storage(model.Table, "match_subjects") = .empty,
match_fallbacks: schema.storage(model.Table, "match_fallbacks") = .empty,
match_first: schema.storage(model.Table, "match_first") = .empty,
match_count: schema.storage(model.Table, "match_count") = .empty,
match_conditions: schema.storage(model.Table, "match_conditions") = .empty,
match_results: schema.storage(model.Table, "match_results") = .empty,
object_first: schema.storage(model.Table, "object_first") = .empty,
object_count: schema.storage(model.Table, "object_count") = .empty,
object_field_indices: schema.storage(model.Table, "object_field_indices") = .empty,
object_field_values: schema.storage(model.Table, "object_field_values") = .empty,
object_evaluation_first: schema.storage(model.Table, "object_evaluation_first") = .empty,
object_evaluation_count: schema.storage(model.Table, "object_evaluation_count") = .empty,
object_evaluation_values: schema.storage(model.Table, "object_evaluation_values") = .empty,
pub fn count(self: *const Self) usize {
    return self.kinds.items.len;
}

pub fn at(self: *const Self, index: usize) @import("row.zig").Expression {
    return self.view().at(index);
}

pub const append = @import("append.zig").expression;
pub const appendHeader = @import("append.zig").header;
pub const reserveHeaders = @import("reserve.zig").headers;
pub const reservePayload = @import("reserve.zig").payload;
pub const reserveColumns = @import("reserve.zig").prepare;
pub const reserveObject = @import("reserve.zig").object;
pub const aggregate_payload = @import("append/aggregates.zig");
pub const collection_payload = @import("append/collections.zig");

pub fn view(self: *const Self) model.Table {
    @setEvalBranchQuota(100_000);

    var result: model.Table = .{};

    inline for (@typeInfo(model.Table).@"struct".field_names) |name| @field(result, name) = @field(self, name).items;

    return result;
}

pub fn finish(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error!model.Table {
    @setEvalBranchQuota(100_000);

    var result: model.Table = .{};

    const complete = collect: {
        inline for (@typeInfo(model.Table).@"struct".field_names) |name| {
            @field(result, name) = @field(self, name).toOwnedSlice(allocator) catch break :collect false;
        }

        break :collect true;
    };

    if (!complete) {
        inline for (@typeInfo(model.Table).@"struct".field_names) |name| allocator.free(@field(result, name));
        self.deinit(allocator);

        return error.OutOfMemory;
    }

    return result;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    @setEvalBranchQuota(100_000);
    inline for (@typeInfo(model.Table).@"struct".field_names) |name| @field(self, name).deinit(allocator);

    self.* = .{};
}
