const Export = @import("../../library/root.zig").Export;
const Plan = @import("library_publication.zig").Plan;

pub fn collect(exports: []const Export, target: Plan) Plan {
    var roots: usize = 0;
    var members: usize = 0;

    for (exports, target.ends) |*exported, *end| {
        if (exported.function) |id| {
            target.roots[roots] = id;
            roots += 1;
        }

        for (exported.members) |*member| {
            if (member.intrinsic != null) continue;

            const id = member.id.?;

            target.roots[roots] = id;
            target.member_ids[members] = id;
            target.members[members] = .{ .name = member.name, .function = id };

            target.regular[@backingInt(id)] = 1;

            roots += 1;
            members += 1;
        }

        end.* = members;
    }

    var result = target;

    result.roots = target.roots[0..roots];
    result.member_ids = target.member_ids[0..members];
    result.members = target.members[0..members];

    return result;
}
