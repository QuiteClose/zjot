const std = @import("std");
const zjot = @import("zjot");

pub fn main() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("zjot: not yet implemented\n", .{});
}
