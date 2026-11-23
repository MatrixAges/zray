const host = @import("cli_host").rx_collection;
const state = host.state;
const files = host.files;
const documents = host.documents;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    state,
    files,
    documents,
}).resolve;
