const std = @import("std");
const dsl = @import("dsl");
const schema = @import("../schema.zig").builders;
const checks = @import("../checks.zig");
const Import = @import("Import.zig").Import;
const Type = @import("Type.zig").Type;
const Args = @import("Args.zig").Args;
const Call = @import("Call.zig").Call;
const Task = @import("Task.zig").Sequential;
const Parallel = @import("Parallel.zig").Parallel;
const Switch = @import("Switch.zig").Switch;
const Loop = @import("Loop.zig").Loop;
const If = @import("If.zig").If;
const Emit = @import("Emit.zig").Emit;
const Return = @import("Return.zig").Return;
const StoreReference = @import("../features/store/root.zig").StoreReference;

const ModuleBase = schema.element("Module", struct {
    @"fn": ?[]const u8 = null,
}, schema.list(schema.choice(.{
    .type = Type,
    .args = Args,
    .store = StoreReference,
    .import = Import,
    .call = Call,
    .task = Task,
    .parallel = Parallel,
    .@"switch" = Switch,
    .@"if" = If,
    .loop = Loop,
    .emit = Emit,
    .@"return" = Return,
}), .{}));

pub const Module = dsl.refineAlloc(ModuleBase, checkModule);

fn checkModule(allocator: std.mem.Allocator, data: ModuleBase.Data, input: anytype, context: anytype, reporter: *dsl.Reporter) dsl.Error!void {
    const node = dsl.ast.view(input);

    try checks.validate(.Module, data.attributes, node, reporter);

    if (data.attributes.@"fn" != null) return;
    try @import("../schema/call/sequence.zig").check(allocator, node, context, reporter);

    return @import("../schema/module/adapter.zig").check(allocator, node, reporter);
}
