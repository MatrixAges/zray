pub const directory = @import("publication/directory.zig");
pub const application = @import("publication/application.zig");
pub const verification = @import("publication/verification.zig");
pub const library = @import("publication/library.zig");
pub const effects = @import("publication/effects.zig");
pub const Failure = effects.Failure;
pub const inventory = @import("library/inventory.zig");
pub const output = @import("watch/output.zig");
pub const paths = @import("native_sources/path.zig");
pub const resources = @import("native_sources/resources.zig");
const collector = @import("library/inventory/collector.zig");
const retirement = @import("library/retirement/storage.zig");

pub const resolveNative = @import("zx").native_lookup.Resolver(&.{
    @This(),
    directory,
    application,
    verification,
    library,
    output,
    resources,
    collector,
    retirement,
}).resolve;
