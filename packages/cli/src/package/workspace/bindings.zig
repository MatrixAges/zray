const host = @import("cli_host").package_workspace;
const collection = host.collection;
const discovery = host.discovery;
const source = host.source;
const project = host.project;
const scope = project.scope;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    collection,
    discovery,
    source,
    project,
    scope,
}).resolve;
