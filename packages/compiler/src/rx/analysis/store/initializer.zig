const std = @import("std");
const frontend = @import("frontend");
const zx = @import("zx");
const expression = @import("../expression.zig");
const Layout = @import("layout.zig");
pub const Value = union(enum) { program: zx.ir.Program, diagnostic: expression.Diagnostic };

pub const Options = struct {
    owner: []const u8,
    layout: Layout,
    first: u32,
    field_types: []const zx.ir.TypeId,
    types: *zx.ir.TypeStorage,
    native_modules: zx.ir.NativeModuleTable,
    aliases: frontend.expressions.BindingColumns,
};

pub fn compile(allocator: std.mem.Allocator, backing: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Value {
    var scratch = std.heap.ArenaAllocator.init(backing);

    defer scratch.deinit();

    const State = @import("initializer/state.zig");
    var state = State.init(allocator, backing, scratch.allocator(), &options);

    defer state.deinit();

    if (comptime @import("rx_options").generated_graph) return @import("initializer/host.zig").run(&state);

    return @import("initializer/seed.zig").run(&state);
}
