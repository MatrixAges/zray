const std = @import("std");
const ir = @import("zx").ir;
const Lower = @import("../lower.zig");
const Requests = @import("requests.zig");
const generated = @import("genz_options").generated_analysis;
const scope = @import("scope.zig");

pub fn append(self: *Lower, output: *@import("../../node/declarations.zig").Output, request: Requests.Request) Lower.Error!void {
    switch (request.form) {
        .Done => unreachable,
        inline else => |form| try emit(self, output, request.id, form),
    }
}

fn emit(self: *Lower, output: *@import("../../node/declarations.zig").Output, id: ir.FunctionId, comptime form: Requests.Form) Lower.Error!void {
    const index = @backingInt(id);
    const function = self.program.functions.at(index);
    var helper: Lower = undefined;

    inline for (comptime Requests.steps(form)) |step| switch (step) {
        .Native => try output.append(self.allocator, try @import("../external.zig").lower(self, function, index)),
        .Enter => {
            helper = if (generated) scope.inherit(self, .Function) else self.*;

            try helper.selectFunction(id, function);
            @import("context.zig").selectPlan(&helper, id);
            helper.pending_name = try std.fmt.allocPrint(self.allocator, "zx_pending_{d}", .{index});

            try @import("context.zig").reserve(&helper);

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
        },
        .Store => try @import("../store.zig").declaration(&helper, output),
        .Regular, .Value => {
            const variant: Requests.Variant = if (step == .Regular) .regular else .value;
            const name = try variant.name(self.allocator, id);

            const declaration = if (step == .Regular)
                try helper.function(name, false)
            else
                try helper.functionValue(name);
            try output.append(self.allocator, declaration);
        },
        .Parallel => if (generated) scope.publish(self, &helper, .Function) else {
            self.uses_parallel = self.uses_parallel or helper.uses_parallel;
        },
    };
}
