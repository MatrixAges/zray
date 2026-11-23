const stage = @import("cli_host").library_stage;
const output = stage.output;
const resources = stage.resources;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    stage,
    output,
    resources,
}).resolve;
