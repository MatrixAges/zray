const ir = @import("../ir.zig");

pub const Traits = struct {
    smt: []const u8,
    token: []const u8,
    family: enum { Logical, Equality, Arithmetic, Comparison },
    rendering: enum { Plain, Signed, SignedRemainder },
};

pub fn traits(operator: ir.Operator) Traits {
    return switch (operator) {
        .logical_and => .{ .smt = "and", .token = "&&", .family = .Logical, .rendering = .Plain },
        .logical_or => .{ .smt = "or", .token = "||", .family = .Logical, .rendering = .Plain },
        .equal => .{ .smt = "=", .token = "==", .family = .Equality, .rendering = .Plain },
        .add => .{ .smt = "bvadd", .token = "+", .family = .Arithmetic, .rendering = .Plain },
        .subtract => .{ .smt = "bvsub", .token = "-", .family = .Arithmetic, .rendering = .Plain },
        .multiply => .{ .smt = "bvmul", .token = "*", .family = .Arithmetic, .rendering = .Plain },
        .unsigned_divide => .{ .smt = "bvudiv", .token = "/", .family = .Arithmetic, .rendering = .Plain },
        .signed_divide => .{ .smt = "bvsdiv", .token = "/", .family = .Arithmetic, .rendering = .Signed },
        .unsigned_remainder => .{ .smt = "bvurem", .token = "%", .family = .Arithmetic, .rendering = .Plain },
        .signed_remainder => .{ .smt = "bvsrem", .token = "%", .family = .Arithmetic, .rendering = .SignedRemainder },
        .unsigned_less => .{ .smt = "bvult", .token = "<", .family = .Comparison, .rendering = .Plain },
        .unsigned_less_equal => .{ .smt = "bvule", .token = "<=", .family = .Comparison, .rendering = .Plain },
        .unsigned_greater => .{ .smt = "bvugt", .token = ">", .family = .Comparison, .rendering = .Plain },
        .unsigned_greater_equal => .{ .smt = "bvuge", .token = ">=", .family = .Comparison, .rendering = .Plain },
        .signed_less => .{ .smt = "bvslt", .token = "<", .family = .Comparison, .rendering = .Signed },
        .signed_less_equal => .{ .smt = "bvsle", .token = "<=", .family = .Comparison, .rendering = .Signed },
        .signed_greater => .{ .smt = "bvsgt", .token = ">", .family = .Comparison, .rendering = .Signed },
        .signed_greater_equal => .{ .smt = "bvsge", .token = ">=", .family = .Comparison, .rendering = .Signed },
    };
}
