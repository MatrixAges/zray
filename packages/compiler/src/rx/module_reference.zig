const project = @import("frontend").project;

pub fn dependencies(options: project.Options, owner: []const u8) []const project.Package {
    return project.ImportScope.init(options.package_scopes, owner).dependencies(options.packages);
}

pub fn isPackage(reference: []const u8, packages: []const project.Package) bool {
    return project.matchPackage(packages, reference, false).first != null;
}
