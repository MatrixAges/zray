const std = @import("std");
const zx_native_0 = @import("zxc_string");
const zx_abi = @import("zxc_abi");
pub const requires_io = false;
pub const requires_process = false;

const zx_shape_0 = .{
    .kind = .string,
};

const zx_shape_1 = .{
    .kind = .list,
    .child = zx_shape_0,
};

const zx_shape_2 = .{
    .kind = .object,
    .fields = .{
        .declarations = zx_shape_1,
        .precondition = zx_shape_0,
        .violations = zx_shape_1,
    },
};

const zx_shape_3 = .{
    .kind = .object,
    .fields = .{
        .correctness = zx_shape_0,
        .feasibility = zx_shape_0,
        .header = zx_shape_0,
    },
};

pub const input_shape = zx_shape_2;
pub const output_shape = zx_shape_3;
pub const Input = *const (zx_abi).zx_type_18;
pub const Output = *const (zx_abi).zx_type_19;

pub fn executeIn(allocator: ((std).mem).Allocator, in: *const (zx_abi).zx_type_18) error{
    OutOfMemory,
}!*const (zx_abi).zx_type_19 {
    @setRuntimeSafety(true);

    const value_1: []const u8 = (try function_8(allocator, (in).declarations));
    const value_2: []const u8 = (try function_9(allocator, value_1));
    const value_3: []const u8 = (try function_12(allocator, (in).violations));
    const value_4: []const u8 = (try function_11(allocator, (in).precondition));
    const value_5: []const u8 = value_4;
    const value_6: []const u8 = (try function_11(allocator, value_3));
    const value_7: []const u8 = value_6;

    return block_6: {
        const operand_1 = value_2;
        const operand_2 = value_5;
        const operand_3 = value_7;

        break :block_6 block_5: {
            const operand_4 = (try (allocator).create((zx_abi).zx_type_19));

            (operand_4).* = @as((zx_abi).zx_type_19, (zx_abi).zx_type_19{
                .header = operand_1,
                .feasibility = operand_2,
                .correctness = operand_3,
            });

            break :block_5 @as(*const (zx_abi).zx_type_19, operand_4);
        };
    };
}

pub fn execute(arena: *((std).heap).ArenaAllocator, in: *const (zx_abi).zx_type_18) error{
    OutOfMemory,
}!*const (zx_abi).zx_type_19 {
    return executeIn((arena).allocator(), in);
}

pub fn executeState(allocator: ((std).mem).Allocator, in: *const (zx_abi).zx_type_18) error{
    OutOfMemory,
}!(zx_abi).value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f {
    @setRuntimeSafety(true);

    const value_1: []const u8 = block_21: {
        var qualified_20: (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751 = (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751{
            .items = (in).declarations,
            .storage = .plain,
        };

        (qualified_20).storage = (if ((@backingInt((qualified_20).storage) >= 2)) .shared else .plain);

        break :block_21 (try function_8_value(allocator, qualified_20));
    };

    const value_2: []const u8 = (try function_9(allocator, block_19: {
        break :block_19 value_1;
    }));

    const value_3: []const u8 = block_18: {
        var qualified_17: (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751 = (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751{
            .items = (in).violations,
            .storage = .plain,
        };

        (qualified_17).storage = (if ((@backingInt((qualified_17).storage) >= 2)) .shared else .plain);

        break :block_18 (try function_12_value(allocator, qualified_17));
    };

    const value_4: []const u8 = (try function_11(allocator, (in).precondition));

    const value_5: []const u8 = block_16: {
        break :block_16 value_4;
    };

    const value_6: []const u8 = (try function_11(allocator, block_15: {
        break :block_15 value_3;
    }));

    const value_7: []const u8 = block_14: {
        break :block_14 value_6;
    };

    return block_13: {
        const operand_7 = block_8: {
            break :block_8 value_2;
        };

        const operand_9 = block_10: {
            break :block_10 value_5;
        };

        const operand_11 = block_12: {
            break :block_12 value_7;
        };

        break :block_13 @as((zx_abi).value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f, (zx_abi).value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f{
            .header = operand_7,
            .feasibility = operand_9,
            .correctness = operand_11,
        });
    };
}

pub fn executeValue(allocator: ((std).mem).Allocator, in: *const (zx_abi).zx_type_18) error{
    OutOfMemory,
}!(zx_abi).value_ae102c4fb67a894894b2d47ff98530386656eb543f5375ebe09f7d62949d5c3f {
    const operand_22 = (try executeState(allocator, in));

    return operand_22;
}

fn function_11(allocator: ((std).mem).Allocator, in: []const u8) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    return block_4: {
        const operand_1 = @as([]const u8, "\n(assert ");
        const operand_2 = in;
        const operand_3 = @as([]const u8, ")\n(check-sat)\n");

        break :block_4 (try ((std).mem).concat(allocator, u8, (&[_][]const u8{
            operand_1,
            operand_2,
            operand_3,
        })));
    };
}

fn function_12(allocator: ((std).mem).Allocator, in: []const []const u8) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    const switch_1 = (@as(u64, (in).len) == @as(u64, 0));

    if ((switch_1 == true)) {
        return @as([]const u8, "false");
    } else {
        const value_1: []const u8 = (try function_10(allocator, in));

        return value_1;
    }
}

fn function_9(allocator: ((std).mem).Allocator, in: []const u8) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    return block_4: {
        const operand_1 = @as([]const u8, "(set-logic QF_BV)\n(set-option :produce-models true)\n(set-option :timeout 10000)\n");
        const operand_2 = in;
        const operand_3 = @as([]const u8, "\n");

        break :block_4 (try ((std).mem).concat(allocator, u8, (&[_][]const u8{
            operand_1,
            operand_2,
            operand_3,
        })));
    };
}

fn function_8(allocator: ((std).mem).Allocator, in: []const []const u8) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    return block_5: {
        const operand_4 = @as((zx_abi).zx_type_13, block_3: {
            const operand_1 = @as([]const u8, "\n");
            const operand_2 = in;

            break :block_3 .{
                operand_1,
                operand_2,
            };
        });

        break :block_5 (try function_0(allocator, (&operand_4)));
    };
}

fn function_12_value(allocator: ((std).mem).Allocator, in: (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    const switch_1 = (@as(u64, ((in).items).len) == @as(u64, 0));

    if ((switch_1 == true)) {
        return @as([]const u8, "false");
    } else {
        const value_1: []const u8 = block_4: {
            var qualified_3: (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751 = in;

            (qualified_3).storage = (if ((@backingInt((qualified_3).storage) >= 2)) .shared else .plain);

            break :block_4 (try function_10_value(allocator, qualified_3));
        };

        return block_2: {
            break :block_2 value_1;
        };
    }
}

fn function_8_value(allocator: ((std).mem).Allocator, in: (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    return block_5: {
        const operand_4 = @as((zx_abi).zx_type_13, block_3: {
            const operand_1 = @as([]const u8, "\n");
            const operand_2 = in;

            break :block_3 .{
                operand_1,
                (operand_2).items,
            };
        });

        break :block_5 (try function_0(allocator, (&operand_4)));
    };
}

fn function_10(allocator: ((std).mem).Allocator, in: []const []const u8) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    const value_1: []const u8 = block_9: {
        const operand_8 = @as((zx_abi).zx_type_13, block_7: {
            const operand_5 = @as([]const u8, " ");
            const operand_6 = in;

            break :block_7 .{
                operand_5,
                operand_6,
            };
        });

        break :block_9 (try function_0(allocator, (&operand_8)));
    };

    return block_4: {
        const operand_1 = @as([]const u8, "(or ");
        const operand_2 = value_1;
        const operand_3 = @as([]const u8, ")");

        break :block_4 (try ((std).mem).concat(allocator, u8, (&[_][]const u8{
            operand_1,
            operand_2,
            operand_3,
        })));
    };
}

fn function_0(allocator: ((std).mem).Allocator, in: *const (zx_abi).zx_type_13) error{
    OutOfMemory,
}![]const u8 {
    const native_result = (try (zx_native_0).join(allocator, (in).@"0", (in).@"1"));

    return native_result;
}

fn function_10_value(allocator: ((std).mem).Allocator, in: (zx_abi).value_e0df66788dd6311027f385a9c2a35992105f755e3fde77d35ca1ee451d105751) error{
    OutOfMemory,
}![]const u8 {
    @setRuntimeSafety(true);

    const value_1: []const u8 = block_10: {
        const operand_9 = @as((zx_abi).zx_type_13, block_8: {
            const operand_6 = @as([]const u8, " ");
            const operand_7 = in;

            break :block_8 .{
                operand_6,
                (operand_7).items,
            };
        });

        break :block_10 (try function_0(allocator, (&operand_9)));
    };

    return block_5: {
        const operand_1 = @as([]const u8, "(or ");

        const operand_3 = block_2: {
            break :block_2 value_1;
        };

        const operand_4 = @as([]const u8, ")");

        break :block_5 (try ((std).mem).concat(allocator, u8, (&[_][]const u8{
            operand_1,
            operand_3,
            operand_4,
        })));
    };
}
