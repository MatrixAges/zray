const schema = @import("../../../schema.zig").builders;
const checks = @import("../../../checks.zig");
const Entry = @import("../entries.zig").Entry;
pub const Protocol = enum { http, grpc, websocket, tcp, mqtt };

pub const Gateway = checks.attributeSchema(schema.element("Gateway", struct {
    name: []const u8,
    protocol: ?Protocol = null,
    listen: ?[]const u8 = null,
    max_header_bytes: u32 = 8192,
    max_body_bytes: u32 = 1024 * 1024,
}, schema.list(Entry, .{})), .Common);
