const std = @import("std");
const compiler = @import("compiler");
const Context = @import("compile.zig").Context;
const Manifest = @import("cli_abi").native.@"zig:compilation_host".FpgaManifest;
const Effects = @import("sources/effects.zig");
const Error = Effects.Error;

const State = struct {
    context: *const Context,
    program: *const compiler.ir.Program,
    sources: []const compiler.project.Source,
    entry: []const u8,
    generated: ?compiler.hardware.CircuitResult = null,
    failure: Effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return Effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.generated) |*generated| generated.deinit();
    }
};

pub fn runProgram(context: Context, program: *const compiler.ir.Program, sources: []const compiler.project.Source, entry: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(context.allocator);

    defer arena.deinit();

    const owned = arena.allocator();
    const count = program.functions.count();
    const function_contracts = try owned.alloc(bool, count);

    for (0..count) |index| {
        function_contracts[index] = program.functions.at(index).contracts.count() != 0;
    }

    var state: State = .{ .context = &context, .program = program, .sources = sources, .entry = entry };
    const reference = &state;

    defer state.deinit();

    const notice = @import("cli_source").run_fpga_program.executeIn(owned, &.{
        .program = @ptrCast(&reference),
        .local_required = program.contracts.count() != 0 or context.options.solver != null,
        .function_contracts = function_contracts,
        .output = context.options.output.?,
        .clocked = context.options.clocked,
        .ir_version = program.version,
    }, context.io) catch |err| return state.failure.unwrap(err);

    try context.stderr.writeAll(notice orelse return false);

    return true;
}

pub fn verifyFpgaProgram(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    return compiler.verification.check(context.io, @import("verify.zig").workspace_allocator, self.program.*, self.sources, self.entry, .{
        .solver = context.options.solver,
    }, context.stderr) catch |err| self.failure.save(err);
}

pub fn lowerFpgaProgram(handle: *const anyopaque) Error!bool {
    const self = State.get(handle);
    const context = self.context;

    self.generated = compiler.hardware.generateCircuit(context.allocator, self.program.*) catch |err| return self.failure.save(err);
    const generated = &self.generated.?.value;

    if (generated.* != .diagnostic) return true;

    context.stderr.print("fpga: {s}\n", .{generated.diagnostic.message}) catch |err| return self.failure.save(err);

    return false;
}

pub fn renderFpgaProgram(allocator: std.mem.Allocator, handle: *const anyopaque, clocked: bool) Error![]const u8 {
    const self = State.get(handle);

    return compiler.verilog.emitCircuit(allocator, self.generated.?.value.module, clocked) catch |err| self.failure.save(err);
}

pub fn encodeFpgaManifest(allocator: std.mem.Allocator, handle: *const anyopaque, metadata: Manifest) std.mem.Allocator.Error![]const u8 {
    const self = State.get(handle);

    return std.json.Stringify.valueAlloc(allocator, .{
        .format_version = metadata.format_version,
        .source_ir_version = metadata.source_ir_version,
        .top = metadata.top,
        .clocked = metadata.clocked,
        .latency_cycles = metadata.latency_cycles,
        .initiation_interval = metadata.initiation_interval,
        .handshake = metadata.handshake,
        .reset = metadata.reset,
        .fault = metadata.fault,
        .sources = self.sources,
        .hardware = self.generated.?.value.module,
    }, .{ .whitespace = .indent_2 });
}
