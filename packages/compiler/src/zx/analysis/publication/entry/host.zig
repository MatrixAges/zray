const std = @import("std");
const zx = @import("zx");
const ir = zx.ir;
const function_body = @import("../../../modules/function_body.zig");
const native_context = @import("../../../modules/native_context.zig");
const checks = @import("../../../ir/validate.zig");
const Resolved = @import("../../../modules/resolved.zig");
const Initializer = @import("../../../modules/compiled.zig").StoreInitializer;
const rule = @import("generated_analysis_finish_entry");
const StoreState = std.meta.Child(@FieldType(rule.zx_pending, "store_0"));

const Publication = struct {
    allocator: std.mem.Allocator,
    program: *ir.Program,
    verified: ?*const ir.FunctionTable,
    store_0: *StoreState,
    issue: ?zx.Diagnostic = null,
    suffix: ?*const ir.FunctionTable = null,
    pub fn commit(self: *Publication, pending: anytype) zx.Error!void {
        const next = pending.store_0 orelse return;

        if (next.split) |split| try self.register(split);

        if (next.own_natives == true) {
            self.program.native_modules = try native_context.copy(self.allocator, self.program.native_modules);
        }

        if (next.check_prefix == true) try self.validatePrefix();

        if (next.issue) |message| {
            self.issue = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = message };
        }

        if (next.forwarded) |body| {
            try @import("../../../modules/entry_body/host.zig").applyForward(self.allocator, self.program, body);
        }

        self.store_0.* = next;
    }

    fn register(self: *Publication, split: bool) std.mem.Allocator.Error!void {
        const row = try function_body.single(self.allocator, self.program.*);

        if (split) {
            const tail = try self.allocator.create(ir.FunctionTable);

            tail.* = row;
            self.suffix = tail;
        } else {
            self.program.functions = row;
        }
    }
    fn validatePrefix(self: *Publication) zx.Error!void {
        var checked = self.program.*;
        var temporary = std.heap.ArenaAllocator.init(self.allocator);

        defer temporary.deinit();

        if (self.suffix) |suffix| checked.functions = try @import("../../../modules/link/function_table.zig").join(temporary.allocator(), checked.functions, suffix.*);

        self.issue = try checks.validateExtending(temporary.allocator(), checked, self.verified.?.*);

        if (self.issue != null) return error.InvalidSource;
    }
};

const Output = struct {
    entry: ?ir.FunctionId,
    issue: ?zx.Diagnostic,
    suffix: ?*const ir.FunctionTable,
};

pub fn finish(allocator: std.mem.Allocator, program: *ir.Program, resolved: ?*const Resolved.Input, declared: bool, initializers: []const Initializer) std.mem.Allocator.Error!Output {
    const column = zx.memory.borrowReadColumn(ir.FunctionId, "function", initializers);
    const Input = std.meta.Child(rule.Input);
    const symbols = zx.columns.borrow(std.meta.Child(@FieldType(Input, "symbols")), @as(*const ir.SymbolTable, &program.symbols));

    const input: Input = .{
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

    var store_value: std.meta.Child(StoreState) = .{
        .split = null,
        .own_natives = null,
        .check_prefix = null,
        .issue = null,
        .forwarded = null,
    };

    var store_ptr: StoreState = &store_value;

    var publication: Publication = .{
        .allocator = allocator,
        .program = program,
        .verified = if (resolved) |bindings| &bindings.verified_functions else null,
        .store_0 = &store_ptr,
    };

    const entry = rule.executeIn(allocator, &input, &publication) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory, error.IntegerOverflow, error.Overflow => return error.OutOfMemory,
        error.InvalidSource => null,
        else => unreachable,
    };

    return .{
        .entry = if (entry) |id| @fromBackingInt(id) else null,
        .issue = publication.issue,
        .suffix = publication.suffix,
    };
}
