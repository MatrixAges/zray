const std = @import("std");
const compiler = @import("compiler");
const Context = @import("compile.zig").Context;
const artifacts = @import("artifacts.zig");
const Effects = @import("sources/effects.zig");
const Error = Effects.Error;

const State = struct {
    context: *const Context,
    program: *const compiler.ir.Program,
    sources: []const compiler.project.Source,
    entry: []const u8,
    generated: ?compiler.hardware.CircuitResult = null,
    text: ?[]const u8 = null,
    failure: Effects.Failure = .{},
    fn get(handle: *const anyopaque) *State {
        return Effects.state(State, handle);
    }
    fn deinit(self: *State) void {
        if (self.text) |text| self.context.allocator.free(text);
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

    return @import("cli_source").run_fpga_program.executeIn(owned, &.{
        .program = @ptrCast(&reference),
        .local_required = program.contracts.count() != 0 or context.options.solver != null,
        .function_contracts = function_contracts,
    }) catch |err| state.failure.unwrap(err);
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

pub fn renderFpgaProgram(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;

    self.text = compiler.verilog.emitCircuit(context.allocator, self.generated.?.value.module, context.options.clocked) catch |err| return self.failure.save(err);
}

pub fn publishFpgaProgram(handle: *const anyopaque) Error!void {
    const self = State.get(handle);
    const context = self.context;
    const allocator = context.allocator;
    const options = &context.options;
    const output = options.output.?;

    const manifest = std.json.Stringify.valueAlloc(allocator, .{
        .format_version = 1,
        .source_ir_version = self.program.version,
        .top = "zxc_kernel",
        .clocked = options.clocked,
        .latency_cycles = @as(u32, if (options.clocked) 1 else 0),
        .initiation_interval = @as(?u32, if (options.clocked) 1 else null),
        .handshake = if (options.clocked) @as(?[]const u8, "accept on input_valid && input_ready; output becomes valid after the accepting edge and remains stable until output_ready; reset requires a clock edge") else null,
        .reset = if (options.clocked) @as(?[]const u8, "synchronous_active_high") else null,
        .fault = "output data is invalid when fault is high",
        .sources = self.sources,
        .hardware = self.generated.?.value.module,
    }, .{ .whitespace = .indent_2 }) catch |err| return self.failure.save(err);

    defer allocator.free(manifest);
    artifacts.write(context.io, output, self.text.?) catch |err| return self.failure.save(err);

    const path = std.fmt.allocPrint(allocator, "{s}.json", .{output}) catch |err| return self.failure.save(err);

    artifacts.write(context.io, path, manifest) catch |err| return self.failure.save(err);
    context.stderr.print("fpga: generated {s} and port/graph manifest\n", .{output}) catch |err| return self.failure.save(err);
}
