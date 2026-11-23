const host = @import("cli_host").library_workflow;
const build = host.build;
const analysis = host.analysis;
const link = host.link;
const proof = host.proof;

pub const resolveNative = @import("cli_host").native_lookup.Resolver(&.{
    @This(),
    analysis,
    link,
    proof,
    build,
}).resolve;
