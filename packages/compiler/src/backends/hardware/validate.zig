const ir = @import("ir.zig");

pub fn validate(module: ir.Module) bool {
    var view: @import("graph/view.zig") = undefined;

    view.init(module);

    return view.validate();
}
