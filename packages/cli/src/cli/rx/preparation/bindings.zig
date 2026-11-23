const host = @import("cli_host").rx_preparation;
const project = host.project;
const references = host.references;
const types = host.types;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    project,
    references,
    types,
}).resolve;
