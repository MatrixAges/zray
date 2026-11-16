const ir = @import("zx").ir;
const Self = @This();

identity: []const u8,
schema_version: u32,
program: ir.Program,
/// The source definition owns the program for the duration of linking or emission.
pub const Borrowed = struct {
    identity: []const u8,
    schema_version: u32,
    program: *const ir.Program,
};

pub fn borrow(self: *const Self) Borrowed {
    return .{ .identity = self.identity, .schema_version = self.schema_version, .program = &self.program };
}
