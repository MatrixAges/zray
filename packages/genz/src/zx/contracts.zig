const std = @import("std");
const zx = @import("zx");
const node = @import("../node.zig");
const Lower = @import("lower.zig");
const generated = @import("genz_options").generated_analysis;
const scope = @import("functions/scope.zig");
const publication = @import("construction/publication.zig");
const Error = Lower.Error;
const borrow = @import("expressions/evaluate.zig").borrow;

pub fn preconditions(self: *Lower) Error!node.Block {
    if (!generated) return @import("contracts/seed.zig").lower(self);

    const kinds = self.program.contracts.kinds;

    if (kinds.len == 0) return .{ .start = @intCast(self.builder.nodes.statements.tags.items.len), .len = 0 };

    const entry = @import("generated_lower_preconditions");
    const Input = std.meta.Child(entry.Input);
    var predicate: Lower = undefined;
    var buffer: [std.heap.page_size_min]u8 = undefined;
    var scratch = std.heap.ArenaAllocator.init(self.workspace);
    var memory = std.heap.BufferFirstAllocator.init(&buffer, scratch.allocator());

    defer scratch.deinit();

    const input: Input = .{
        .parent = @ptrCast(self),
        .predicate = @ptrCast(&predicate),
        .writer = @ptrCast(self),
        .kinds = zx.columns.slice(@FieldType(Input, "kinds"), kinds),
        .predicates = self.program.contracts.predicates,
    };

    const span = entry.executeIn(memory.allocator(), &input) catch |err| return publication.failure(err);

    return publication.unpackSpan(span);
}

pub fn openPreconditionScope(parent: *anyopaque, child: *anyopaque, index: u64) Error!void {
    const self = borrow(parent);
    const contracts = &self.program.contracts;
    const row: usize = @intCast(index);
    const predicate = borrow(child);

    predicate.* = scope.inherit(self, .Predicate);

    scope.installPredicate(&predicate.program, contracts, row);

    try predicate.refreshEntry();
    try scope.reserve(predicate, self.allocator, .Predicate);
}

pub fn publishPreconditionScope(parent: *anyopaque, child: *anyopaque) void {
    scope.publish(borrow(parent), borrow(child), .Predicate);
}
