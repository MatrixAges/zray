const host = @import("cli_host").lint_workflow;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    host.command,
    host.source,
    host.semantic,
    host.special,
    host.workspace,
    host.reachable,
    host.configuration,
}).resolve;
