const std = @import("std");
const zx = @import("zx");
const lint = @import("lint");
const frontend = @import("frontend");
pub const ir = zx.ir;
pub const bytes = zx.bytes;
pub const parallel = zx.parallel;
pub const input_snapshot = @import("inputs/snapshot.zig");
pub const input_fingerprint = @import("inputs/fingerprint.zig");
pub const input_generation = @import("inputs/generation.zig");
pub const parsed_inputs = @import("inputs/parsed.zig");
pub const file_versions = @import("inputs/file_versions.zig");
pub const source_inputs = @import("inputs/collection.zig");
pub const SourceIndex = frontend.SourceIndex;
pub const cache_retention = frontend.cache_retention;
pub const resident_modules = @import("inputs/module_versions.zig");
pub const resident_protocol = @import("inputs/resident.zig");
pub const Sha256 = zx.Sha256;
pub const parse = frontend.parse;
pub const ParseResult = frontend.ParseResult;
pub const parseExpression = frontend.parseExpression;
pub const ExpressionParseResult = frontend.ExpressionParseResult;
pub const expressions = frontend.expressions;
pub const analyze = frontend.analyze;
pub const Context = frontend.Context;
pub const analyzeWithContext = frontend.analyzeWithContext;
pub const AnalysisResult = frontend.AnalysisResult;
pub const library = @import("library/root.zig");
pub const zig = @import("backends/zig.zig");
const library_entries = @import("backends/zig/library_entries.zig");
pub const analyzeLibraryExport = library_entries.analyzeLibraryExport;
pub const publishLibraryExport = library_entries.publishLibraryExport;
const function_sources = @import("backends/zig/function_sources/cache_updates.zig");
pub const recordCachedSource = function_sources.recordCachedSource;
pub const tryRecordCachedSource = function_sources.tryRecordCachedSource;
pub const accountCachedSources = function_sources.accountCachedSources;
pub const commitGeneratedSource = function_sources.commitGeneratedSource;
const source_batches = @import("backends/zig/function_sources.zig");
pub const readFunctionSources = source_batches.readFunctionSources;
pub const restoreFunctionSources = source_batches.restoreFunctionSources;
pub const generateFunctionSources = source_batches.generateFunctionSources;
pub const publishFunctionSources = source_batches.publishFunctionSources;
const application_initializers = @import("backends/zig/store_initializers.zig");
pub const readApplicationInitializer = application_initializers.readApplicationInitializer;
pub const emitApplicationInitializer = application_initializers.emitApplicationInitializer;
pub const emitLibraryInitializer = @import("backends/zig/library_initializers.zig").emitLibraryInitializer;
const bootstrap_tree = @import("backends/zig/output/tree.zig");
pub const renderBootstrapAdapter = bootstrap_tree.renderBootstrapAdapter;
pub const renderBootstrapOriginals = bootstrap_tree.renderBootstrapOriginals;
pub const renderBootstrapRoot = bootstrap_tree.renderBootstrapRoot;
pub const placeBootstrapPartitions = bootstrap_tree.placeBootstrapPartitions;
const bootstrap_mirror = @import("backends/zig/output/mirror.zig");
pub const hashBootstrapFiles = bootstrap_mirror.hashBootstrapFiles;
pub const compareBootstrapFiles = bootstrap_mirror.compareBootstrapFiles;
pub const createBootstrapParents = bootstrap_mirror.createBootstrapParents;
pub const writeBootstrapChanges = bootstrap_mirror.writeBootstrapChanges;
pub const trimBootstrapFiles = bootstrap_mirror.trimBootstrapFiles;
pub const commitBootstrapManifest = bootstrap_mirror.commitBootstrapManifest;
const bootstrap_partition = @import("backends/zig/partition/build.zig");
pub const scanPartitionBodies = bootstrap_partition.scanPartitionBodies;
pub const scanPartitionSupport = bootstrap_partition.scanPartitionSupport;
pub const planPartitionLayout = bootstrap_partition.planPartitionLayout;
pub const placePartitionFiles = bootstrap_partition.placePartitionFiles;
pub const emitPartitionJobs = bootstrap_partition.emitPartitionJobs;
pub const renderPartitionFile = bootstrap_partition.renderPartitionFile;
const generation_cache = @import("backends/zig/cache.zig");
pub const finishCacheWriting = generation_cache.finishCacheWriting;
pub const startCacheWriting = generation_cache.startCacheWriting;
pub const Diagnostic = zx.Diagnostic;
pub const formatRx = frontend.formatXml;
pub const validateIr = frontend.validateIr;
pub const verification = @import("verification/root.zig");
const symbolic_values = @import("verification/graph/selection.zig");
pub const symbolicText = symbolic_values.symbolicText;
pub const symbolicFieldCount = symbolic_values.symbolicFieldCount;
pub const sameSymbolicFields = symbolic_values.sameSymbolicFields;
pub const symbolicField = symbolic_values.symbolicField;
pub const targetSymbolicField = symbolic_values.targetSymbolicField;
pub const reuseSymbolicFields = symbolic_values.reuseSymbolicFields;
pub const reserveSymbolicFields = symbolic_values.reserveSymbolicFields;
pub const publishSymbolicText = symbolic_values.publishSymbolicText;
const symbolic_execution = @import("verification/execution/context.zig");
pub const evaluateClause = symbolic_execution.evaluateClause;
pub const bindSymbolicBoolean = symbolic_execution.bindSymbolicBoolean;
pub const publishClauseViolation = symbolic_execution.publishClauseViolation;
pub const selectSymbolicReturn = symbolic_execution.selectSymbolicReturn;
const symbolic_block = @import("verification/execution/block.zig");
pub const evaluateSymbolicStatement = symbolic_block.evaluateSymbolicStatement;
pub const symbolicStatementText = symbolic_block.symbolicStatementText;
pub const bindSymbolicStatement = symbolic_block.bindSymbolicStatement;
pub const bindSymbolicStatementField = symbolic_block.bindSymbolicStatementField;
pub const publishSymbolicStatementReturn = symbolic_block.publishSymbolicStatementReturn;
pub const runSymbolicChild = symbolic_block.runSymbolicChild;
pub const runSymbolicParallel = symbolic_block.runSymbolicParallel;
pub const reserveSymbolicParallel = symbolic_block.reserveSymbolicParallel;
pub const saveSymbolicParallel = symbolic_block.saveSymbolicParallel;
pub const bindSymbolicParallel = symbolic_block.bindSymbolicParallel;
pub const rejectSymbolicStatement = symbolic_block.rejectSymbolicStatement;
const symbolic_expression = @import("verification/execution/expression.zig");
pub const rejectSymbolicExpression = symbolic_expression.rejectSymbolicExpression;
pub const loadSymbolicReference = symbolic_expression.loadSymbolicReference;
pub const symbolicLiteralWidth = symbolic_expression.symbolicLiteralWidth;
pub const writeSymbolicLiteral = symbolic_expression.writeSymbolicLiteral;
pub const evaluateSymbolicOperand = symbolic_expression.evaluateSymbolicOperand;
pub const symbolicOperandText = symbolic_expression.symbolicOperandText;
pub const symbolicOperandSafety = symbolic_expression.symbolicOperandSafety;
pub const projectSymbolicOperand = symbolic_expression.projectSymbolicOperand;
pub const writeSymbolicUnary = symbolic_expression.writeSymbolicUnary;
pub const writeSymbolicBinary = symbolic_expression.writeSymbolicBinary;
pub const selectSymbolicExpression = symbolic_expression.selectSymbolicExpression;
pub const retainSymbolicExpression = symbolic_expression.retainSymbolicExpression;
pub const bindSymbolicExpressionSafety = symbolic_expression.bindSymbolicExpressionSafety;
pub const writeSymbolicSafety = symbolic_expression.writeSymbolicSafety;
pub const reserveSymbolicAggregate = symbolic_expression.reserveSymbolicAggregate;
pub const writeSymbolicAggregateField = symbolic_expression.writeSymbolicAggregateField;
const symbolic_call = @import("verification/execution/call.zig");
pub const runSymbolicExpressionCall = symbolic_call.runSymbolicExpressionCall;
pub const describeSymbolicCall = symbolic_call.describeSymbolicCall;
pub const rejectSymbolicCall = symbolic_call.rejectSymbolicCall;
pub const evaluateSymbolicCallArgument = symbolic_call.evaluateSymbolicCallArgument;
pub const findSymbolicCallee = symbolic_call.findSymbolicCallee;
pub const evaluateSymbolicCallee = symbolic_call.evaluateSymbolicCallee;
pub const publishSymbolicCallee = symbolic_call.publishSymbolicCallee;
pub const symbolicCalleeSafety = symbolic_call.symbolicCalleeSafety;
pub const writeSymbolicCallSafety = symbolic_call.writeSymbolicCallSafety;
const symbolic_program = @import("verification/execution/program.zig");
pub const ensureSymbolicGraph = symbolic_program.ensureSymbolicGraph;
pub const beginSymbolicCall = symbolic_program.beginSymbolicCall;
pub const rejectSymbolicProgram = symbolic_program.rejectSymbolicProgram;
pub const symbolicProgramPreconditions = symbolic_program.symbolicProgramPreconditions;
pub const markSymbolicQueryPrefix = symbolic_program.markSymbolicQueryPrefix;
pub const runSymbolicProgramBody = symbolic_program.runSymbolicProgramBody;
pub const symbolicProgramReturnsUnit = symbolic_program.symbolicProgramReturnsUnit;
pub const checkSymbolicUnit = symbolic_program.checkSymbolicUnit;
pub const appendSymbolicUnit = symbolic_program.appendSymbolicUnit;
pub const publishSymbolicQuery = symbolic_program.publishSymbolicQuery;
pub const hasSymbolicReturns = symbolic_program.hasSymbolicReturns;
pub const rejectSymbolicReturn = symbolic_program.rejectSymbolicReturn;
pub const publishSymbolicProgramResult = symbolic_program.publishSymbolicProgramResult;
pub const reserveSymbolicParameter = symbolic_program.reserveSymbolicParameter;
pub const symbolicParameterField = symbolic_program.symbolicParameterField;
pub const symbolicEnumWidth = symbolic_program.symbolicEnumWidth;
pub const symbolicScalarWidth = symbolic_program.symbolicScalarWidth;
pub const symbolicPortCount = symbolic_program.symbolicPortCount;
pub const appendSymbolicDeclaration = symbolic_program.appendSymbolicDeclaration;
pub const publishSymbolicParameter = symbolic_program.publishSymbolicParameter;
const symbolic_registration = @import("verification/graph/registration.zig");
pub const reserveSymbolicDefinition = symbolic_registration.reserveSymbolicDefinition;
pub const allocateSymbolicIndex = symbolic_registration.allocateSymbolicIndex;
pub const writeSymbolicDefinition = symbolic_registration.writeSymbolicDefinition;
pub const installSymbolicIndex = symbolic_registration.installSymbolicIndex;
pub const rejectSymbolicDefinition = symbolic_registration.rejectSymbolicDefinition;
const symbolic_query = @import("verification/query/assembly.zig");
pub const reserveQueryBuffer = symbolic_query.reserveQueryBuffer;
pub const appendQueryText = symbolic_query.appendQueryText;
pub const appendQueryDefinitions = symbolic_query.appendQueryDefinitions;
pub const queryWrittenLength = symbolic_query.queryWrittenLength;
pub const publishCorrectnessQuery = symbolic_query.publishCorrectnessQuery;
pub const publishFeasibilityQuery = symbolic_query.publishFeasibilityQuery;
const verification_report = @import("verification/solver.zig");
pub const verificationEvidence = verification_report.verificationEvidence;
pub const finishVerificationDigest = verification_report.finishVerificationDigest;
pub const verificationPathText = verification_report.verificationPathText;
pub const writeVerificationOutput = verification_report.writeVerificationOutput;
const symbolic_call_cache = @import("verification/call_cache.zig");
pub const appendSymbolicCallKey = symbolic_call_cache.appendSymbolicCallKey;
pub const symbolicCallKeyTerms = symbolic_call_cache.symbolicCallKeyTerms;
pub const probeSymbolicCallKey = symbolic_call_cache.probeSymbolicCallKey;
pub const rewindSymbolicCallKey = symbolic_call_cache.rewindSymbolicCallKey;
const hardware_build = @import("backends/hardware/construction/workflow.zig");
pub const reserveHardwareVariables = hardware_build.reserveHardwareVariables;
pub const reserveHardwareCache = hardware_build.reserveHardwareCache;
pub const reserveHardwareInputs = hardware_build.reserveHardwareInputs;
pub const reserveHardwareNodes = hardware_build.reserveHardwareNodes;
pub const hardwareInputType = hardware_build.hardwareInputType;
pub const writeHardwareInput = hardware_build.writeHardwareInput;
pub const bindHardwareInputs = hardware_build.bindHardwareInputs;
pub const hardwareDefinitionFile = hardware_build.hardwareDefinitionFile;
pub const hardwareOriginFile = hardware_build.hardwareOriginFile;
pub const retainHardwareOrigin = hardware_build.retainHardwareOrigin;
pub const setHardwareOrigin = hardware_build.setHardwareOrigin;
pub const clearHardwareOrigin = hardware_build.clearHardwareOrigin;
pub const hardwareTermOffset = hardware_build.hardwareTermOffset;
pub const setHardwareTermOffset = hardware_build.setHardwareTermOffset;
pub const hardwareVariable = hardware_build.hardwareVariable;
pub const hardwareCacheKeys = hardware_build.hardwareCacheKeys;
pub const hardwareCacheValues = hardware_build.hardwareCacheValues;
pub const hardwareCacheFull = hardware_build.hardwareCacheFull;
pub const growHardwareCache = hardware_build.growHardwareCache;
pub const hardwareNodeCount = hardware_build.hardwareNodeCount;
pub const appendHardwareTerm = hardware_build.appendHardwareTerm;
pub const publishHardwareDefinition = hardware_build.publishHardwareDefinition;
pub const hardwareNodeWidth = hardware_build.hardwareNodeWidth;
pub const hardwareNodeIsBoolean = hardware_build.hardwareNodeIsBoolean;
pub const hardwareOutputCount = hardware_build.hardwareOutputCount;
pub const writeHardwareOutput = hardware_build.writeHardwareOutput;
pub const rejectHardwareTerm = hardware_build.rejectHardwareTerm;
const hardware_graph = @import("backends/hardware/graph/view.zig");
pub const readHardwareGraphNode = hardware_graph.readHardwareGraphNode;
pub const hardwareGraphNodeKind = hardware_graph.hardwareGraphNodeKind;
pub const hardwareGraphNodeWidth = hardware_graph.hardwareGraphNodeWidth;
pub const hardwareGraphNodeBoolean = hardware_graph.hardwareGraphNodeBoolean;
pub const hardwareGraphNodeFirst = hardware_graph.hardwareGraphNodeFirst;
pub const hardwareGraphNodeSecond = hardware_graph.hardwareGraphNodeSecond;
pub const hardwareGraphNodeThird = hardware_graph.hardwareGraphNodeThird;
pub const hardwareGraphNodeExtension = hardware_graph.hardwareGraphNodeExtension;
pub const hardwareGraphNodeSigned = hardware_graph.hardwareGraphNodeSigned;
pub const hardwareGraphNodeFamily = hardware_graph.hardwareGraphNodeFamily;
pub const hardwareGraphNodeRendering = hardware_graph.hardwareGraphNodeRendering;
pub const hardwareGraphNodeToken = hardware_graph.hardwareGraphNodeToken;
pub const hardwareTermOperator = hardware_graph.hardwareTermOperator;
pub const hardwareTermFamily = hardware_graph.hardwareTermFamily;
pub const hardware = @import("backends/hardware/root.zig");
pub const verilog = @import("backends/verilog/root.zig");
pub const reserveVerilogOutput = verilog.reserveVerilogOutput;
pub const compileProjectVerified = @import("verified_compile.zig").compile;
pub const emitProgramVerified = @import("verified_compile.zig").emit;
pub const emitLibraryVerified = @import("verified_compile.zig").emitLibrary;
pub const emitModulesVerified = @import("verified_compile.zig").emitModules;
pub const compileProjectModulesVerified = @import("verified_compile.zig").compileModules;
pub const CompileOptions = @import("verified_compile.zig").Options;

pub const Result = union(enum) {
    source: []u8,
    diagnostic: Diagnostic,
    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        switch (self) {
            .source => |source| allocator.free(source),
            .diagnostic => |issue| issue.deinit(),
        }
    }
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!Result {
    return compileWithContext(allocator, source, file_name, .{});
}

pub fn compileWithContext(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8, context: Context) std.mem.Allocator.Error!Result {
    var parsed = try frontend.parseAnalysisModule(allocator, source, file_name);

    defer parsed.deinit();

    if (parsed.diagnostic()) |issue| return .{ .diagnostic = try issue.clone(allocator) };
    if (try parsed.check(allocator)) |issue| return .{ .diagnostic = issue };

    var analyzed = try frontend.analyzeModule(allocator, &parsed, context);

    defer analyzed.deinit();

    return switch (analyzed.value) {
        .diagnostic => |issue| .{ .diagnostic = try issue.clone(allocator) },
        .ir => |program| .{ .source = zig.emit(allocator, program) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIr => return .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "internal compiler error: generated invalid IR" } },
            error.NativeRequiresBundle => return .{ .diagnostic = .{ .code = .module, .span = .{ .start = 0, .end = 0 }, .message = "native modules require shared type output; use analyzeProject with zig.emitBundle" } },
            error.UnverifiedContracts => return .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "formal contract verification is required before code generation" } },
        } },
    };
}

pub fn checkSource(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!?Diagnostic {
    if (std.mem.endsWith(u8, file_name, ".d.zx")) {
        return switch (try frontend.formatNative(allocator, source)) {
            .diagnostic => |issue| issue,
            .source => |formatted| block: {
                defer allocator.free(formatted.text);

                const span = formatted.first_change orelse break :block null;

                break :block .{
                    .code = .style,
                    .span = span,
                    .message = "enum declarations must use one member per line; run zxc fmt",
                };
            },
        };
    }

    var parsed = try frontend.parseAnalysisModule(allocator, source, file_name);

    defer parsed.deinit();

    if (std.mem.eql(u8, std.fs.path.basename(file_name), "index.zx") and parsed.diagnostic() == null) {
        if (parsed.checkBarrel()) |issue| return issue;
    }

    if (try parsed.check(allocator)) |issue| return try issue.clone(allocator);

    return null;
}

pub fn format(allocator: std.mem.Allocator, source: []const u8, file_name: []const u8) std.mem.Allocator.Error!Result {
    if (std.mem.endsWith(u8, file_name, ".d.zx")) {
        return switch (try frontend.formatNative(allocator, source)) {
            .source => |formatted| .{ .source = formatted.text },
            .diagnostic => |issue| .{ .diagnostic = issue },
        };
    }

    if (std.mem.endsWith(u8, file_name, ".rx")) {
        return switch (try frontend.formatXmlText(allocator, source)) {
            .source => |formatted| .{ .source = formatted },
            .diagnostic => |issue| .{ .diagnostic = issue },
        };
    }

    var parsed = try frontend.parseModule(allocator, source, file_name);

    defer parsed.deinit();

    if (parsed.diagnostic()) |issue| return .{ .diagnostic = try issue.clone(allocator) };

    return .{ .source = try parsed.format(allocator) };
}

pub const project = frontend.project;

pub fn analyzeProject(allocator: std.mem.Allocator, sources: []const project.Source, options: project.Options) std.mem.Allocator.Error!AnalysisResult {
    var cache = project.ParseCache{ .allocator = allocator };

    defer cache.deinit();

    return analyzeProjectWithCache(allocator, sources, options, &cache);
}

pub fn analyzeProjectWithCache(allocator: std.mem.Allocator, sources: []const project.Source, options: project.Options, cache: *project.ParseCache) std.mem.Allocator.Error!AnalysisResult {
    if (try checkProjectSources(allocator, sources, options, cache)) |issue| return analysisDiagnostic(allocator, issue);

    return project.analyzeWithCache(allocator, sources, options, cache);
}

pub fn analyzeProjectIncremental(allocator: std.mem.Allocator, sources: []const project.Source, options: project.Options, cache: *project.SemanticCache) std.mem.Allocator.Error!AnalysisResult {
    if (try checkProjectSources(allocator, sources, options, &cache.parse_cache)) |issue| return analysisDiagnostic(allocator, issue);

    return project.analyzeIncremental(allocator, sources, options, cache);
}

fn analysisDiagnostic(allocator: std.mem.Allocator, issue: Diagnostic) std.mem.Allocator.Error!AnalysisResult {
    defer issue.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);

    errdefer arena.deinit();

    var owned = issue;
    owned.message = try arena.allocator().dupe(u8, issue.message);
    owned.message_allocator = null;

    return .{ .arena = arena, .value = .{ .diagnostic = owned } };
}

fn checkProjectSources(allocator: std.mem.Allocator, sources: []const project.Source, options: project.Options, cache: *project.ParseCache) std.mem.Allocator.Error!?Diagnostic {
    for (sources, 0..) |source, index| {
        const path = try std.fs.path.resolve(allocator, &.{ options.root_dir, source.path });

        defer allocator.free(path);

        const parsed = try cache.getModule(source.source, path);
        var issue = try parsed.check(allocator);

        if (issue) |*diagnostic| {
            if (source.template_origins.len != 0) {
                const previous = diagnostic.*;
                diagnostic.* = try project.resources.diagnostic(allocator, source, previous);

                if (diagnostic.message.ptr != previous.message.ptr) {
                    previous.deinit();

                    diagnostic.message_allocator = allocator;
                }
            }

            diagnostic.source_index = index;

            return diagnostic.*;
        }
    }

    return null;
}

pub fn compileProject(allocator: std.mem.Allocator, sources: []const project.Source, options: project.Options) std.mem.Allocator.Error!Result {
    var analyzed = try analyzeProject(allocator, sources, options);

    defer analyzed.deinit();

    return switch (analyzed.value) {
        .diagnostic => |issue| .{ .diagnostic = try issue.clone(allocator) },
        .ir => |program| .{ .source = zig.emit(allocator, program) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidIr => return .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "invalid project IR" } },
            error.NativeRequiresBundle => return .{ .diagnostic = .{ .code = .module, .span = .{ .start = 0, .end = 0 }, .message = "native modules require shared type output; use analyzeProject with zig.emitBundle" } },
            error.UnverifiedContracts => return .{ .diagnostic = .{ .code = .contract, .span = .{ .start = 0, .end = 0 }, .message = "formal contract verification is required before code generation" } },
        } },
    };
}
