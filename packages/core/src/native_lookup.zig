pub const marker = "$zray";
pub const field = "resolveNative";

pub fn Resolver(comptime modules: []const type) type {
    return struct {
        pub fn resolve(comptime name: []const u8) @TypeOf(@field(owner(name), name)) {
            return @field(owner(name), name);
        }
        fn owner(comptime name: []const u8) type {
            @setEvalBranchQuota(10_000);

            if (@hasDecl(modules[0], name)) return modules[0];

            var match: ?type = null;

            inline for (modules[1..]) |module| {
                if (@hasDecl(module, name)) {
                    if (match != null) @compileError("More than one native module exports " ++ name);
                    match = module;
                }
            }

            return match orelse @compileError("No native module exports " ++ name);
        }
    };
}
