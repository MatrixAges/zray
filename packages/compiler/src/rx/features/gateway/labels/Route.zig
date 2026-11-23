const schema = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");
pub const Method = enum(u8) { GET, HEAD, POST, PUT, DELETE, CONNECT, OPTIONS, TRACE, PATCH };

const RouteBase = schema.element("Route", struct {
    path: []const u8,
    service: []const u8,
    method: ?Method = null,
}, schema.empty);

pub const Route = checks.attributeSchema(RouteBase, .Route);
