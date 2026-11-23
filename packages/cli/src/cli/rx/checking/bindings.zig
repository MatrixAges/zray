const host = @import("cli_host").rx_checking;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    host.project,
    host.store,
    host.function,
}).resolve;
