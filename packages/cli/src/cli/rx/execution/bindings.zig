const host = @import("cli_host").rx_execution;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    host.application,
    host.analysis,
    host.gateway,
    host.backend,
    host.backend.preparation,
    host.backend.command,
    host.backend.modules,
    host.compilation,
    host.emit,
    host.cache,
    host.fpga,
}).resolve;
