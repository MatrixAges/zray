const dsl = @import("dsl");
const checks = @import("../../../checks.zig");
pub const Method = enum { GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH };

const RouteBase = dsl.element("Route", struct {
    path: []const u8,
    service: []const u8,
    method: ?Method = null,
}, dsl.empty);

pub const Route = checks.attributeSchema(RouteBase, .Route);
