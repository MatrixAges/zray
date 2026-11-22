const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const Requests = @import("requests.zig");
const generated = @import("genz_options").generated_analysis;
const scope = @import("scope.zig");
const Output = @import("../../node/declarations.zig").Output;

pub fn native(self: *Lower, output: *Output, id: ir.FunctionId) Lower.Error!void {
    const index = @backingInt(id);
    const signature = ir.SignatureTable.read(&self.program.functions, index);

    try output.append(self.allocator, try @import("../external.zig").lower(self, &signature, index));
}

pub fn open(self: *Lower, helper: *Lower, id: ir.FunctionId) Lower.Error!void {
    const index = @backingInt(id);

    helper.* = if (generated) scope.inherit(self, .Function) else self.*;

    try helper.selectFunction(id);
    @import("context.zig").selectPlan(helper, id);
    helper.pending_name = try std.fmt.allocPrint(self.allocator, "zx_pending_{d}", .{index});

    try @import("context.zig").reserve(helper);

    if (!generated) {
        helper.cache = .empty;
        helper.stack_symbols = .empty;
        helper.state_symbols = .empty;
        helper.state_active = false;
        helper.value_output = false;
        helper.public_value_output = false;
        helper.iteration_value = null;
        helper.loop_fields = null;
        helper.capture = null;
        helper.serial = 0;
    }
}

pub fn body(helper: *Lower, output: *Output, id: ir.FunctionId, variant: Requests.Variant) Lower.Error!void {
    const name = try variant.name(helper.allocator, id);

    const declaration = switch (variant) {
        .regular => try helper.function(name, false),
        .value => try helper.functionValue(name),
    };

    try output.append(helper.allocator, declaration);
}

pub fn publish(self: *Lower, helper: *const Lower) void {
    if (generated) {
        scope.publish(self, helper, .Function);
    } else {
        self.uses_parallel = self.uses_parallel or helper.uses_parallel;
    }
}
