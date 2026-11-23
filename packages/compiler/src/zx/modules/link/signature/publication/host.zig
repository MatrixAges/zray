const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const FunctionImport = @import("../../../function_import.zig");
const function_target = @import("destination.zig");

pub fn Stage(comptime Input: type) type {
    const Destination = std.meta.Child(@FieldType(Input, "destination"));
    const MemberTarget = std.meta.Child(@FieldType(Input, "members"));

    return struct {
        const Self = @This();

        functions: function_target.View(Destination),
        output: FunctionImport.Output(MemberTarget),
        pub fn init(self: *Self, resource: *const std.mem.Allocator, functions: *ir.FunctionStorage) void {
            self.functions.init(resource, functions);
            self.output.init();
        }

        pub fn members(self: *const Self) []const FunctionImport {
            return self.output.rows();
        }
    };
}
