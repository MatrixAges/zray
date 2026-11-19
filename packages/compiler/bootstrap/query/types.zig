pub const zx_type_11 = opaque {};

pub const zx_type_13 = struct {
    []const u8,
    []const []const u8,
};

pub const zx_type_14 = struct {
    []const u8,
    []const u8,
};

pub const zx_type_15 = struct {
    []const u8,
    []const u8,
    []const u8,
};

pub const zx_type_16 = struct {
    *const zx_type_11,
    []const u8,
};

pub const zx_type_17 = struct {
    *const zx_type_11,
    []const []const u8,
};

pub const zx_type_18 = struct {
    declarations: []const []const u8,
    precondition: []const u8,
    violations: []const []const u8,
};

pub const zx_type_19 = struct {
    correctness: []const u8,
    feasibility: []const u8,
    header: []const u8,
};

pub const zx_type_20 = struct {
    []const []const u8,
};

pub const zx_type_21 = struct {
    []const u8,
};

pub const zx_type_22 = struct {
    *const zx_type_18,
};

pub const value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751 = struct {
    items: []const []const u8,
    storage: enum(usize) {
        plain,
        owned,
        shared,
        exclusive,
    },
};

pub const value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f = struct {
    correctness: []const u8,
    feasibility: []const u8,
    header: []const u8,
    zx_origin: ?*const zx_type_19 = null,
};

pub const view_value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f = value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f;

pub const value_1fdc2785cb3f3434b11f7046ca2993b80f055de8c6f098824221290e2ee76b45 = struct {
    value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751,
    ?*const zx_type_20,
};

pub const view_value_1fdc2785cb3f3434b11f7046ca2993b80f055de8c6f098824221290e2ee76b45 = struct {
    []const []const u8,
    ?*const zx_type_20,
};

pub const value_54afd8bd4b86e7a2247e1c9f53b89734ace4020b2e9e68a6ed2cfa68ebe14c59 = struct {
    []const u8,
    ?*const zx_type_21,
};

pub const view_value_54afd8bd4b86e7a2247e1c9f53b89734ace4020b2e9e68a6ed2cfa68ebe14c59 = value_54afd8bd4b86e7a2247e1c9f53b89734ace4020b2e9e68a6ed2cfa68ebe14c59;

pub const value_eaee42eb0c9f4b6bf2be2e0d5d200a78115c612fbe0d0dbd6028100848e34152 = struct {
    *const zx_type_18,
    ?*const zx_type_22,
};

pub const view_value_eaee42eb0c9f4b6bf2be2e0d5d200a78115c612fbe0d0dbd6028100848e34152 = value_eaee42eb0c9f4b6bf2be2e0d5d200a78115c612fbe0d0dbd6028100848e34152;

pub const ZxHeader = struct {
    capacity: usize,
    committed: usize,
};

pub inline fn zxReserve(comptime T: type, allocator: ((@import("std")).mem).Allocator, items: []const T, count: usize, comptime frontier: bool) error{
    OutOfMemory,
}![]T {
    if ((frontier and ((items).len != 0))) {
        {
            const current: *ZxHeader = @ptrCast(@alignCast((@as([*]u8, @ptrCast(@constCast((items).ptr))) - @sizeOf(ZxHeader))));

            if ((((current).committed == (items).len) and (count <= (current).capacity))) {
                (current).committed = count;

                return (@constCast((items).ptr))[0..count];
            }
        }
    }

    return (try zxAllocate(T, allocator, items, count, false, 0));
}

pub inline fn zxReserveBounded(comptime T: type, allocator: ((@import("std")).mem).Allocator, items: []const T, count: usize, minimum: usize) error{
    OutOfMemory,
}![]T {
    if (((items).len == 0)) {
        return (try zxAllocate(T, allocator, items, count, true, minimum));
    }

    return (try zxReserve(T, allocator, items, count, true));
}

pub fn zxAllocate(comptime T: type, allocator: ((@import("std")).mem).Allocator, items: []const T, count: usize, comptime exact: bool, minimum: usize) error{
    OutOfMemory,
}![]T {
    const offset = (comptime ((((@import("std")).mem).Alignment).of(T)).forward(@sizeOf(ZxHeader)));
    const capacity: usize = (if ((exact or (@max(count, minimum) == 0))) @max(count, minimum) else ((@import("std")).math).ceilPowerOfTwoAssert(usize, @max(@max(count, minimum), 8)));

    const bytes = (try (allocator).alignedAlloc(u8, (comptime ((((@import("std")).mem).Alignment).of(T)).max((((@import("std")).mem).Alignment).of(ZxHeader))), (((@import("std")).math).add(usize, offset, (((@import("std")).math).mul(usize, capacity, @sizeOf(T)) catch {
        return error.OutOfMemory;
    })) catch {
        return error.OutOfMemory;
    })));

    const data: [*]T = @ptrCast(@alignCast(((bytes).ptr + offset)));
    const fresh: *ZxHeader = @ptrCast(@alignCast((@as([*]u8, ((bytes).ptr + offset)) - @sizeOf(ZxHeader))));

    (fresh).* = .{
        .capacity = capacity,
        .committed = count,
    };

    @memcpy((data)[0..(items).len], items);

    return (data)[0..count];
}

pub fn zxRetract(comptime T: type, items: []const T, length: usize) void {
    const current: *ZxHeader = @ptrCast(@alignCast((@as([*]u8, @ptrCast(@constCast((items).ptr))) - @sizeOf(ZxHeader))));

    (current).committed = length;
}

pub fn zxRenew(allocator: ((@import("std")).mem).Allocator, target: anytype, comptime path: []const [2][]const u8, comptime exact: bool, comptime writable: bool) error{
    OutOfMemory,
}!void {
    const V = @TypeOf((target).*);
    const info = @typeInfo(V);

    if ((info == .optional)) {
        if ((target).*) |*inner| {
            (try zxRenew(allocator, inner, path, exact, writable));
        }
    } else {
        if ((info == .pointer)) {
            if ((((info).pointer).size == .slice)) {
                (target).* = (try zxReserve(((info).pointer).child, allocator, (target).*, ((target).*).len, false));
            } else {
                const fresh = (try (allocator).create(((info).pointer).child));
                (fresh).* = ((target).*).*;
                (try zxRenew(allocator, fresh, path, exact, writable));
                (target).* = fresh;
            }
        } else {
            if (((path).len == 0)) {
                if ((!((((target).*).storage == .exclusive) or (writable and (@rem(@backingInt(((target).*).storage), 2) != 0))))) {
                    ((target).*).items = (try zxAllocate(((@typeInfo(@TypeOf(((target).*).items))).pointer).child, allocator, ((target).*).items, (((target).*).items).len, exact, 0));
                    ((target).*).storage = .exclusive;
                }
            } else {
                if (@hasField(V, ((path)[0])[1])) {
                    @field((target).*, ((path)[0])[1]) = null;
                }

                (try zxRenew(allocator, (&@field((target).*, ((path)[0])[0])), (path)[1..], exact, writable));
            }
        }
    }
}

pub const native_by_identity = struct {
    pub const @"zig:zxc_native_c234b07d5d68a443ba8b017e2bf8bb882e8a62a1141f44f127a7bd1cfa5846ed" = struct {
        pub const StringSet = *const zx_type_11;
        pub const join = struct {
            pub const Input = *const zx_type_13;
            pub const Output = []const u8;
            pub const InputValue = zx_type_13;
            pub const OutputValue = []const u8;
        };
        pub const copy = struct {
            pub const Input = []const u8;
            pub const Output = []const u8;
            pub const InputValue = []const u8;
            pub const OutputValue = []const u8;
        };
        pub const sameStorage = struct {
            pub const Input = *const zx_type_14;
            pub const Output = bool;
            pub const InputValue = zx_type_14;
            pub const OutputValue = bool;
        };
        pub const replaceAll = struct {
            pub const Input = *const zx_type_15;
            pub const Output = []const u8;
            pub const InputValue = zx_type_15;
            pub const OutputValue = []const u8;
        };
        pub const copyList = struct {
            pub const Input = []const []const u8;
            pub const Output = []const []const u8;
            pub const InputValue = []const []const u8;
            pub const OutputValue = []const []const u8;
        };
        pub const setAdd = struct {
            pub const Input = *const zx_type_16;
            pub const Output = void;
            pub const InputValue = zx_type_16;
            pub const OutputValue = void;
        };
        pub const setAddAll = struct {
            pub const Input = *const zx_type_17;
            pub const Output = void;
            pub const InputValue = zx_type_17;
            pub const OutputValue = void;
        };
        pub const setKeys = struct {
            pub const Input = *const zx_type_11;
            pub const Output = []const []const u8;
            pub const InputValue = zx_type_11;
            pub const OutputValue = []const []const u8;
        };
    };
};

pub const layouts_by_identity = struct {
    pub const @"zig:zxc_native_c234b07d5d68a443ba8b017e2bf8bb882e8a62a1141f44f127a7bd1cfa5846ed" = struct {
        pub const StringSet = zx_type_11;
    };
};

pub const native = struct {
    pub const @"zig:string" = (native_by_identity).@"zig:zxc_native_c234b07d5d68a443ba8b017e2bf8bb882e8a62a1141f44f127a7bd1cfa5846ed";
};

pub const layouts = struct {
    pub const @"zig:string" = (layouts_by_identity).@"zig:zxc_native_c234b07d5d68a443ba8b017e2bf8bb882e8a62a1141f44f127a7bd1cfa5846ed";
};
