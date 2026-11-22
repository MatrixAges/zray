const ir = @import("ir.zig");

pub fn validate(module: ir.Module) bool {
    if (comptime !@import("parser_options").generated_parser) return @import("graph/seed.zig").validate(module);

    var view: @import("graph/view.zig") = undefined;

    view.init(module);

    return view.validate();
}
