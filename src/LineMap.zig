const std = @import("std");
const Allocator = std.mem.Allocator;
const SourcePos = @import("node.zig").SourcePos;

/// Maps byte offsets in joined inline text back to original source positions.
/// Built when content lines are joined for inline parsing. Used by the inline
/// parser to set source positions on nodes without fragile string searching.
segments: []const Segment = &.{},

const LineMap = @This();

pub const Segment = struct {
    joined_start: u32,
    orig_line: u32,
    orig_col: u32,
    orig_offset: u32,
};

/// Resolve a byte offset in the joined text to a source position.
pub fn resolve(self: LineMap, joined_offset: u32) SourcePos {
    if (self.segments.len == 0) return .{ .line = 1, .col = 1, .offset = joined_offset };

    var best: usize = 0;
    for (self.segments, 0..) |seg, i| {
        if (seg.joined_start <= joined_offset) {
            best = i;
        } else break;
    }

    const seg = self.segments[best];
    const delta = joined_offset - seg.joined_start;
    return .{
        .line = seg.orig_line,
        .col = seg.orig_col + delta,
        .offset = seg.orig_offset + delta,
    };
}

/// Build a LineMap from content lines and their original positions.
/// `lines` are the stripped content lines that will be joined.
/// `orig_lines` are the 0-based original line indices.
/// `col_offsets` are the 0-based column where content starts in the original line.
/// `line_byte_offsets` are the byte offsets of each original line in the full input.
/// `base_line` is the 1-based line number for the first original line.
/// `base_offset` is the byte offset adjustment.
pub fn build(
    a: Allocator,
    lines: []const []const u8,
    orig_lines: []const usize,
    col_offsets: []const u32,
    line_byte_offsets: []const u32,
    base_line: u32,
    base_offset: u32,
) Allocator.Error!LineMap {
    if (lines.len == 0) return .{};

    var segs: std.ArrayList(Segment) = .{};
    var joined_pos: u32 = 0;

    for (lines, 0..) |line, i| {
        const orig_idx = if (i < orig_lines.len) orig_lines[i] else 0;
        const col_off = if (i < col_offsets.len) col_offsets[i] else 0;
        const line_off = if (orig_idx < line_byte_offsets.len) line_byte_offsets[orig_idx] else 0;

        try segs.append(a, .{
            .joined_start = joined_pos,
            .orig_line = base_line + @as(u32, @intCast(orig_idx)),
            .orig_col = col_off + 1,
            .orig_offset = base_offset + line_off + col_off,
        });

        joined_pos += @intCast(line.len + 1); // +1 for the joining newline
    }

    return .{ .segments = try segs.toOwnedSlice(a) };
}
