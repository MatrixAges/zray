const Lower = @import("../../lower.zig");
const Frame = @import("frame.zig");
const emission = @import("../emitting.zig");
const Error = Lower.Error;

pub fn emitModuleStandard(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    if (frame.function == null) return emission.standard(self, &frame.output);

    const std_import = try self.builtin(.import, &.{try self.builder.string("std")});

    try frame.output.append(self.allocator, .{ .constant = .{ .name = "std", .value = std_import } });
}

pub fn emitModuleImports(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;

    const selected = frame.function orelse {
        self.native_names = try @import("../../imports.zig").lower(self, &frame.output);

        return;
    };

    const external = self.program.functions.native_modules[@backingInt(selected)].?;
    const modules = self.program.native_modules;
    const module = modules.at(external);
    const native_names = try self.allocator.alloc([]const u8, modules.count());

    @memset(native_names, "");

    native_names[external] = "zx_native";
    self.native_names = native_names;

    const value = try self.builtin(.import, &.{try self.builder.string(module.import_name)});

    try frame.output.append(self.allocator, .{ .constant = .{ .name = "zx_native", .value = value } });
}

pub fn emitModuleTypes(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../../types.zig").lower(frame.lowering, &frame.output, false);
}

pub fn emitModuleExports(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return emission.exports(frame.lowering, &frame.output);
}

pub fn emitModuleConstants(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../constants.zig").append(frame.lowering, &frame.output);
}

pub fn emitModuleShape(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../../shape.zig").lower(frame.lowering, &frame.output);
}

pub fn emitModuleAliases(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return emission.contracts(frame.lowering, &frame.output);
}

pub fn emitModuleStore(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../../store.zig").declaration(frame.lowering, &frame.output);
}

pub fn emitModuleEntry(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../../entry.zig").declarations(frame.lowering, &frame.output);
}

pub fn emitModuleValueEntry(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    return @import("../../entry_values.zig").declarations(frame.lowering, &frame.output);
}

pub fn readModuleSuffix(handle: *anyopaque) *const @import("../../expressions/evaluate.zig").Api.ModuleSuffix {
    const frame = Frame.borrow(handle);

    frame.suffix_info = .{
        .uses_parallel = frame.lowering.uses_parallel,
        .comparisons = frame.comparisons.items.len,
    };

    return &frame.suffix_info;
}

pub fn emitModuleParallelAllocator(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);
    const output = if (frame.function == null) &frame.suffix else &frame.output;

    return @import("../../parallel/allocator.zig").append(frame.lowering, output);
}

pub fn emitModuleComparison(handle: *anyopaque, index: u64) Error!void {
    const frame = Frame.borrow(handle);
    const self = frame.lowering;
    const type_id = frame.comparisons.items[@intCast(index)];

    try frame.suffix.append(self.allocator, try @import("../../comparison.zig").ordering(self, type_id));
}

pub fn suffixSeed(handle: *anyopaque) Error!void {
    const frame = Frame.borrow(handle);

    if (frame.lowering.uses_parallel) try emitModuleParallelAllocator(handle);
    for (0..frame.comparisons.items.len) |index| try emitModuleComparison(handle, index);
}
