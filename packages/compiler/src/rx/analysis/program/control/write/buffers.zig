const std = @import("std");
const ControlStorage = @import("zx").ir.ControlStorage;

pub fn bind(comptime Columns: type, storage: *const ControlStorage) Columns {
    var view: Columns = undefined;

    inline for (@typeInfo(Columns).@"struct".field_names) |name| {
        @field(view, name) = @ptrCast(&@field(storage, name).items);
    }

    return view;
}
