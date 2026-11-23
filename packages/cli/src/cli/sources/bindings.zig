const host = @import("cli_host").source_loader;
const discovery = host.discovery;
const templates = host.templates;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    discovery,
    templates,
}).resolve;
