const std = @import("std");
const consts = @import("./consts.zig");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const path = std.fs.path;

const allocPrint = std.fmt.allocPrint;

const data_dir_basename = consts.project_name;

fn unixDataDir(gpa: Allocator, comptime data_dir_rel: []const u8) ![]u8 {
    const home = try std.process.getEnvVarOwned(gpa, "HOME");
    defer gpa.free(home);

    return try path.join(gpa, &.{ home, data_dir_rel, data_dir_basename });
}

pub fn dataDir(gpa: Allocator) ![]u8 {
    return switch (builtin.target.os.tag) {
        .linux => try unixDataDir(gpa, ".local/share"),
        .macos => try unixDataDir(gpa, "Library/Application Support"),
        .emscripten => try gpa.dupe(u8, "/data"),
        else => unreachable("Unsupported OS"),
    };
}

pub fn dataDirFile(gpa: Allocator, comptime filename: []const u8) ![:0]u8 {
    const data_dir = try dataDir(gpa);
    defer gpa.free(data_dir);

    return std.fs.path.joinZ(gpa, &.{ data_dir, filename });
}
