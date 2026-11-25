const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const function_body = @import("../../../modules/function_body.zig");
const native_context = @import("../../../modules/native_context.zig");
const checks = @import("../../../ir/validate.zig");
const Resolved = @import("../../../modules/resolved.zig");
const Initializer = @import("../../../modules/compiled.zig").StoreInitializer;

const Frame = struct {
    allocator: std.mem.Allocator,
    program: *ir.Program,
    verified: ?*const ir.FunctionTable,
    issue: ?zx.Diagnostic = null,
    suffix: ?*const ir.FunctionTable = null,
    fn borrow(handle: *anyopaque) *Frame {
        return @ptrCast(@alignCast(handle));
    }
};

const Output = struct {
    entry: ?ir.FunctionId,
    issue: ?zx.Diagnostic,
    suffix: ?*const ir.FunctionTable,
};

pub fn finish(allocator: std.mem.Allocator, program: *ir.Program, resolved: ?*const Resolved.Input, declared: bool, initializers: []const Initializer) std.mem.Allocator.Error!Output {
    const rule = @import("generated_analysis_finish_entry");
    const column = zx.memory.borrowReadColumn(ir.FunctionId, "function", initializers);

    var frame: Frame = .{
        .allocator = allocator,
        .program = program,
        .verified = if (resolved) |bindings| &bindings.verified_functions else null,
    };

    const Input = std.meta.Child(rule.Input);
    const symbols = zx.columns.borrow(std.meta.Child(@FieldType(Input, "symbols")), @as(*const ir.SymbolTable, &program.symbols));

    const input: Input = .{
        .entry = @ptrCast(&frame),
        .program = @ptrCast(program),
        .symbols = &symbols,
        .input_type = @backingInt(program.input_type),
        .output_type = @backingInt(program.output_type),
        .calls = program.expressions.call_functions,
        .base_count = program.functions.count(),
        .declared = declared,
        .type_only = program.type_only,
        .resolved = resolved != null,
        .native_count = program.native_modules.count(),
        .check_prefix = checks.internal and resolved != null,
        .initializers = @ptrCast(&column),
        .initializer_count = initializers.len,
    };

    const entry = rule.executeIn(allocator, &input) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        else => unreachable,
    };

    return .{
        .entry = if (entry) |id| @fromBackingInt(id) else null,
        .issue = frame.issue,
        .suffix = frame.suffix,
    };
}

pub fn registerAnalysisBody(handle: *anyopaque, split: bool) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);
    const program = frame.program;
    const row = try function_body.single(frame.allocator, program.*);

    if (split) {
        const tail = try frame.allocator.create(ir.FunctionTable);

        tail.* = row;
        frame.suffix = tail;
    } else {
        program.functions = row;
    }
}

pub fn ownAnalysisNatives(handle: *anyopaque) std.mem.Allocator.Error!void {
    const frame = Frame.borrow(handle);

    frame.program.native_modules = try native_context.copy(frame.allocator, frame.program.native_modules);
}

pub fn validateAnalysisPrefix(handle: *anyopaque) std.mem.Allocator.Error!bool {
    const frame = Frame.borrow(handle);
    var checked = frame.program.*;
    var temporary = std.heap.ArenaAllocator.init(frame.allocator);

    defer temporary.deinit();

    if (frame.suffix) |suffix| checked.functions = try @import("../../../modules/link/function_table.zig").join(temporary.allocator(), checked.functions, suffix.*);

    frame.issue = try checks.validateExtending(temporary.allocator(), checked, frame.verified.?.*);

    return frame.issue == null;
}

pub fn rejectAnalysisInitializer(handle: *anyopaque, message: []const u8) void {
    Frame.borrow(handle).issue = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = message };
}
