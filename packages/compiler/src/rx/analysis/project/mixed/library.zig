const frontend = @import("frontend");
const rx = @import("rx");
const State = @import("state.zig");
const compiled = frontend.project.compiled;
const position = @import("../source_graph/position.zig");

pub fn load(state: *State, target: compiled.Target, location: rx.ast.Location, source: []const u8) State.Error!compiled.Export {
    const exported = compiled.imports.load(state.allocator, &state.options, target, .{
        .types = &state.types.items,
        .origins = &state.types.origins,
        .functions = &state.functions,
        .native_modules = &state.native_modules,
    }, &state.libraries, &state.initializers) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;

        return state.fail(position.locate(location, source), compiled.imports.message(err));
    };

    return exported.*;
}
