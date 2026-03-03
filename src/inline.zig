//! Inline parsing using an opener stack. Handles emphasis, links, images,
//! smart quotes, super/subscript, insert/delete/mark, math, verbatim,
//! raw spans, symbols, autolinks, and inline attributes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("node.zig").Node;
const Tag = @import("node.zig").Tag;
const attrs = @import("attributes.zig");
const BlockAttrs = attrs.BlockAttrs;

pub fn parseInlines(a: Allocator, lines: []const []const u8) ![]const Node {
    if (lines.len == 0) return &.{};
    const src = try joinLines(a, lines);
    return parseInlineContent(a, src);
}

const InlineItem = union(enum) {
    node: Node,
    opener: OpenerInfo,
    pending_attrs: BlockAttrs,
};

const OpenerInfo = struct {
    char: u8,
    item_idx: usize,
    src_pos: usize,
    marked: bool = false,
};

pub fn parseInlineContent(a: Allocator, src: []const u8) anyerror![]const Node {
    var items: std.ArrayList(InlineItem) = .{};
    var openers: std.ArrayList(OpenerInfo) = .{};
    var pos: usize = 0;
    var text_start: usize = 0;

    while (pos < src.len) {
        const c = src[pos];
        switch (c) {
            '\\' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 >= src.len) {
                    try items.append(a, .{ .node = .{ .tag = .str, .text = "\\" } });
                    pos += 1;
                } else {
                    const next = src[pos + 1];
                    if (next == '\n') {
                        stripTrailingSpacesFromLastStr(&items);
                        try items.append(a, .{ .node = .{ .tag = .hard_break } });
                        pos += 2;
                    } else if (next == ' ' or next == '\t') {
                        var skip = pos + 1;
                        while (skip < src.len and (src[skip] == ' ' or src[skip] == '\t')) skip += 1;
                        if (skip < src.len and src[skip] == '\n') {
                            stripTrailingSpacesFromLastStr(&items);
                            try items.append(a, .{ .node = .{ .tag = .hard_break } });
                            pos = skip + 1;
                        } else if (next == ' ') {
                            try items.append(a, .{ .node = .{ .tag = .non_breaking_space } });
                            pos += 2;
                        } else {
                            try items.append(a, .{ .node = .{ .tag = .str, .text = "\\" } });
                            pos += 1;
                        }
                    } else if (isEscapable(next)) {
                        try items.append(a, .{ .node = .{ .tag = .str, .text = src[pos + 1 .. pos + 2] } });
                        pos += 2;
                    } else {
                        try items.append(a, .{ .node = .{ .tag = .str, .text = "\\" } });
                        pos += 1;
                    }
                }
                text_start = pos;
            },
            '`' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                const tick_len = countRunAt(src, pos, '`');
                const after = pos + tick_len;
                if (findClosingTicks(src, after, tick_len)) |close_pos| {
                    const raw = src[after..close_pos];
                    const content = trimVerbatimContent(raw);
                    const after_close = close_pos + tick_len;
                    if (after_close < src.len and src[after_close] == '{' and
                        after_close + 1 < src.len and src[after_close + 1] == '=')
                    {
                        const fmt_end = std.mem.indexOfScalarPos(u8, src, after_close, '}');
                        if (fmt_end) |fe| {
                            const format = src[after_close + 2 .. fe];
                            if (format.len > 0 and std.mem.indexOfScalar(u8, format, ' ') == null) {
                                try items.append(a, .{ .node = .{ .tag = .raw_inline, .text = content, .lang = format } });
                                pos = fe + 1;
                            } else {
                                try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                                pos = after_close;
                            }
                        } else {
                            try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                            pos = after_close;
                        }
                    } else {
                        try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                        pos = after_close;
                    }
                } else {
                    const content = trimVerbatimContent(src[after..]);
                    try items.append(a, .{ .node = .{ .tag = .verbatim, .text = content } });
                    pos = src.len;
                }
                text_start = pos;
            },
            '\n' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try items.append(a, .{ .node = .{ .tag = .soft_break } });
                pos += 1;
                text_start = pos;
            },
            '*', '_' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleEmphDelimiter(a, &items, &openers, src, &pos, c, false);
                text_start = pos;
            },
            '{' => {
                if (pos + 1 < src.len) {
                    const next = src[pos + 1];
                    if (next == '_' or next == '*') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        pos += 1;
                        try handleEmphDelimiter(a, &items, &openers, src, &pos, next, true);
                        text_start = pos;
                        continue;
                    } else if (next == '+' or next == '-' or next == '=') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        try handleBracedSpan(a, &items, &openers, src, &pos);
                        text_start = pos;
                        continue;
                    } else if (next == '~' or next == '^') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        try handleBracedSpan(a, &items, &openers, src, &pos);
                        text_start = pos;
                        continue;
                    } else if (next == '\'' or next == '"') {
                        if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                        pos += 1;
                        try handleSmartQuote(a, &items, &openers, src, &pos, next, true);
                        text_start = pos;
                        continue;
                    }
                }
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (attrs.parseInlineAttrs(a, src, pos)) |parsed| {
                    try applyInlineAttrs(a, &items, parsed.attrs);
                    pos = parsed.end;
                } else {
                    try addTextItem(a, &items, "{");
                    pos += 1;
                }
                text_start = pos;
            },
            '[' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 < src.len and src[pos + 1] == '^') {
                    if (findMatchingBracket(src, pos)) |close| {
                        const label = src[pos + 2 .. close];
                        try items.append(a, .{ .node = .{ .tag = .footnote_reference, .text = label } });
                        pos = close + 1;
                        text_start = pos;
                        continue;
                    }
                }
                try openers.append(a, .{ .char = '[', .item_idx = items.items.len, .src_pos = pos });
                try items.append(a, .{ .node = .{ .tag = .str, .text = "[" } });
                pos += 1;
                text_start = pos;
            },
            '!' => {
                if (pos + 1 < src.len and src[pos + 1] == '[') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    try openers.append(a, .{ .char = '!', .item_idx = items.items.len, .src_pos = pos });
                    try items.append(a, .{ .node = .{ .tag = .str, .text = "![" } });
                    pos += 2;
                    text_start = pos;
                } else {
                    pos += 1;
                }
            },
            ']' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleCloseBracket(a, &items, &openers, src, &pos);
                text_start = pos;
            },
            '<' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (try handleAutolink(a, &items, src, &pos)) {
                    text_start = pos;
                } else {
                    try addTextItem(a, &items, "<");
                    pos += 1;
                    text_start = pos;
                }
            },
            '^' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 < src.len and src[pos + 1] == '}') {
                    if (try handleBracedClose(a, &items, &openers, '^', pos)) {
                        pos += 2;
                        text_start = pos;
                        continue;
                    }
                }
                try handleSuperSubscript(a, &items, &openers, src, &pos, '^', .superscript);
                text_start = pos;
            },
            '~' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (pos + 1 < src.len and src[pos + 1] == '}') {
                    if (try handleBracedClose(a, &items, &openers, '~', pos)) {
                        pos += 2;
                        text_start = pos;
                        continue;
                    }
                }
                try handleSuperSubscript(a, &items, &openers, src, &pos, '~', .subscript);
                text_start = pos;
            },
            '$' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                var dollar_count: usize = 1;
                if (pos + 1 < src.len and src[pos + 1] == '$') dollar_count = 2;
                const tick_start = pos + dollar_count;
                if (tick_start < src.len and src[tick_start] == '`') {
                    const tick_len = countRunAt(src, tick_start, '`');
                    const content_start = tick_start + tick_len;
                    if (findClosingTicks(src, content_start, tick_len)) |close_pos| {
                        const content = src[content_start..close_pos];
                        const tag: Tag = if (dollar_count == 2) .display_math else .inline_math;
                        try items.append(a, .{ .node = .{ .tag = tag, .text = content } });
                        pos = close_pos + tick_len;
                        text_start = pos;
                        continue;
                    }
                }
                try addTextItem(a, &items, src[pos .. pos + dollar_count]);
                pos += dollar_count;
                text_start = pos;
            },
            ':' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                if (handleSymbol(a, &items, src, &pos)) {
                    text_start = pos;
                } else {
                    pos += 1;
                    text_start = pos - 1;
                }
            },
            '"' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleSmartQuote(a, &items, &openers, src, &pos, '"', false);
                text_start = pos;
            },
            '\'' => {
                if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                try handleSmartQuote(a, &items, &openers, src, &pos, '\'', false);
                text_start = pos;
            },
            '-', '+', '=' => {
                if (pos + 1 < src.len and src[pos + 1] == '}') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    if (try handleBracedClose(a, &items, &openers, c, pos)) {
                        pos += 2;
                    } else {
                        try addTextItem(a, &items, src[pos .. pos + 2]);
                        pos += 2;
                    }
                    text_start = pos;
                } else if (c == '-' and pos + 1 < src.len and src[pos + 1] == '-') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    var dash_count: usize = 0;
                    var dp = pos;
                    while (dp < src.len and src[dp] == '-') : (dp += 1) dash_count += 1;
                    if (dp < src.len and src[dp] == '}' and dash_count >= 2) {
                        dash_count -= 1;
                        dp -= 1;
                    }
                    try emitDashes(a, &items, dash_count);
                    pos = dp;
                    text_start = pos;
                } else {
                    pos += 1;
                }
            },
            '.' => {
                if (pos + 2 < src.len and src[pos + 1] == '.' and src[pos + 2] == '.') {
                    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
                    try items.append(a, .{ .node = .{ .tag = .ellipsis } });
                    pos += 3;
                    text_start = pos;
                } else {
                    pos += 1;
                }
            },
            else => {
                pos += 1;
            },
        }
    }

    if (pos > text_start) try addTextItem(a, &items, src[text_start..pos]);
    trimTrailingWhitespace(&items);
    return resolveItems(a, items.items);
}

fn stripTrailingSpacesFromLastStr(items: *std.ArrayList(InlineItem)) void {
    if (items.items.len == 0) return;
    switch (items.items[items.items.len - 1]) {
        .node => |*n| {
            if (n.tag == .str) {
                n.text = std.mem.trimRight(u8, n.text, " \t");
                if (n.text.len == 0) _ = items.pop();
            }
        },
        else => {},
    }
}

fn handleBracedClose(a: Allocator, items: *std.ArrayList(InlineItem), openers: *std.ArrayList(OpenerInfo), char: u8, _: usize) !bool {
    var i = openers.items.len;
    while (i > 0) {
        i -= 1;
        const op = openers.items[i];
        if (op.char == char and op.marked) {
            if (op.item_idx + 1 < items.items.len) {
                const tag: Tag = switch (char) {
                    '-' => .delete,
                    '+' => .insert,
                    '=' => .mark,
                    '~' => .subscript,
                    '^' => .superscript,
                    else => .span,
                };
                const children = try collectChildren(a, items, op.item_idx);
                try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                openers.items.len = i;
                return true;
            }
        }
    }
    return false;
}

fn applyInlineAttrs(a: Allocator, items: *std.ArrayList(InlineItem), ba: BlockAttrs) !void {
    if (ba.id == null and ba.classes == null and ba.attrs.len == 0) return;
    try items.append(a, .{ .pending_attrs = ba });
}

/// Appends a text node, merging with the previous one if both are contiguous
/// slices of the same source buffer (avoids allocating a new node per character).
fn addTextItem(a: Allocator, items: *std.ArrayList(InlineItem), text: []const u8) !void {
    if (items.items.len > 0) {
        switch (items.items[items.items.len - 1]) {
            .node => |*n| {
                if (n.tag == .str) {
                    if (n.text.ptr + n.text.len == text.ptr) {
                        n.text = n.text.ptr[0 .. n.text.len + text.len];
                        return;
                    }
                }
            },
            else => {},
        }
    }
    try items.append(a, .{ .node = .{ .tag = .str, .text = text } });
}

fn trimTrailingWhitespace(items: *std.ArrayList(InlineItem)) void {
    while (items.items.len > 0) {
        switch (items.items[items.items.len - 1]) {
            .node => |*n| {
                if (n.tag == .str) {
                    n.text = std.mem.trimRight(u8, n.text, " \t");
                    if (n.text.len == 0) {
                        _ = items.pop();
                        continue;
                    }
                }
                break;
            },
            else => break,
        }
    }
}

fn handleEmphDelimiter(a: Allocator, items: *std.ArrayList(InlineItem), openers: *std.ArrayList(OpenerInfo), src: []const u8, pos: *usize, char: u8, marked: bool) !void {
    const p = pos.*;

    if (!marked and p + 1 < src.len and src[p + 1] == '}') {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and op.marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '*') .strong else .emph;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 2;
                    return;
                }
            }
        }
        try addTextItem(a, items, src[p .. p + 2]);
        pos.* = p + 2;
        return;
    }

    const can_close = canCloseDelim(src, p) and !marked;
    if (can_close) {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and op.marked == marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '*') .strong else .emph;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 1;
                    return;
                }
                break;
            }
        }
    }

    const can_open = marked or canOpenDelim(src, p);
    if (can_open) {
        const idx = items.items.len;
        try openers.append(a, .{ .char = char, .item_idx = idx, .src_pos = p, .marked = marked });
        try items.append(a, .{ .opener = .{ .char = char, .item_idx = idx, .src_pos = p, .marked = marked } });
        pos.* = p + 1;
        return;
    }

    try addTextItem(a, items, src[p .. p + 1]);
    pos.* = p + 1;
}

fn handleBracedSpan(a: Allocator, items: *std.ArrayList(InlineItem), openers: *std.ArrayList(OpenerInfo), src: []const u8, pos: *usize) !void {
    const p = pos.*;
    const delim = src[p + 1];
    const idx = items.items.len;
    try openers.append(a, .{ .char = delim, .item_idx = idx, .src_pos = p, .marked = true });
    try items.append(a, .{ .opener = .{ .char = delim, .item_idx = idx, .src_pos = p, .marked = true } });
    pos.* = p + 2;
}

fn handleCloseBracket(a: Allocator, items: *std.ArrayList(InlineItem), openers: *std.ArrayList(OpenerInfo), src: []const u8, pos: *usize) !void {
    const p = pos.*;
    var i = openers.items.len;
    while (i > 0) {
        i -= 1;
        const op = openers.items[i];
        if (op.char == '[' or op.char == '!') {
            const children = try collectChildren(a, items, op.item_idx);
            const is_image = op.char == '!';
            pos.* = p + 1;

            if (pos.* < src.len and src[pos.*] == '(') {
                if (findMatchingParen(src, pos.*)) |close_paren| {
                    const raw_dest = src[pos.* + 1 .. close_paren];
                    const dest = processUrl(a, raw_dest) catch raw_dest;
                    const tag: Tag = if (is_image) .image else .link;
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children, .destination = dest } });
                    pos.* = close_paren + 1;
                    openers.items.len = i;
                    return;
                }
            } else if (pos.* < src.len and src[pos.*] == '[') {
                if (findMatchingBracket(src, pos.*)) |close_ref| {
                    const ref_label = src[pos.* + 1 .. close_ref];
                    const tag: Tag = if (is_image) .image else .link;
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children, .reference = ref_label } });
                    pos.* = close_ref + 1;
                    openers.items.len = i;
                    return;
                }
            } else if (pos.* < src.len and src[pos.*] == '{') {
                if (attrs.parseInlineAttrs(a, src, pos.*)) |parsed| {
                    var span_node = Node{ .tag = .span, .children = children };
                    span_node = applyBlockAttrsToNode(span_node, parsed.attrs);
                    try items.append(a, .{ .node = span_node });
                    pos.* = parsed.end;
                    openers.items.len = i;
                    return;
                }
            }

            var restored: std.ArrayList(InlineItem) = .{};
            const bracket_text: []const u8 = if (is_image) "![" else "[";
            try restored.append(a, .{ .node = .{ .tag = .str, .text = bracket_text } });
            for (children) |child| try restored.append(a, .{ .node = child });
            try restored.append(a, .{ .node = .{ .tag = .str, .text = "]" } });
            items.items.len = op.item_idx;
            for (restored.items) |item| try items.append(a, item);
            openers.items.len = i;
            return;
        }
    }

    try addTextItem(a, items, "]");
    pos.* = p + 1;
}

fn handleAutolink(a: Allocator, items: *std.ArrayList(InlineItem), src: []const u8, pos: *usize) !bool {
    const p = pos.*;
    const rest = src[p + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '>') orelse return false;
    const content = rest[0..close];

    if (std.mem.startsWith(u8, content, "http://") or
        std.mem.startsWith(u8, content, "https://") or
        std.mem.startsWith(u8, content, "ftp://"))
    {
        try items.append(a, .{ .node = .{ .tag = .url, .text = content } });
        pos.* = p + 1 + close + 1;
        return true;
    }

    if (std.mem.indexOfScalar(u8, content, '@') != null and
        std.mem.indexOfScalar(u8, content, ' ') == null)
    {
        try items.append(a, .{ .node = .{ .tag = .email, .text = content } });
        pos.* = p + 1 + close + 1;
        return true;
    }

    return false;
}

fn handleSuperSubscript(a: Allocator, items: *std.ArrayList(InlineItem), openers: *std.ArrayList(OpenerInfo), src: []const u8, pos: *usize, char: u8, tag: Tag) !void {
    const p = pos.*;
    var i = openers.items.len;
    while (i > 0) {
        i -= 1;
        const op = openers.items[i];
        if (op.char == char) {
            if (op.item_idx + 1 < items.items.len) {
                const children = try collectChildren(a, items, op.item_idx);
                try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                openers.items.len = i;
                pos.* = p + 1;
                return;
            }
        }
    }

    if (canOpenDelim(src, p)) {
        const idx = items.items.len;
        try openers.append(a, .{ .char = char, .item_idx = idx, .src_pos = p });
        try items.append(a, .{ .opener = .{ .char = char, .item_idx = idx, .src_pos = p } });
        pos.* = p + 1;
        return;
    }

    try addTextItem(a, items, src[p .. p + 1]);
    pos.* = p + 1;
}

fn handleSymbol(a: Allocator, items: *std.ArrayList(InlineItem), src: []const u8, pos: *usize) bool {
    const p = pos.*;
    const start = p + 1;
    if (start >= src.len) return false;
    const end = std.mem.indexOfScalarPos(u8, src, start, ':') orelse return false;
    if (end == start) return false;
    const name = src[start..end];
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '+') return false;
    }
    items.append(a, .{ .node = .{ .tag = .symb, .text = name } }) catch return false;
    pos.* = end + 1;
    return true;
}

/// Converts a run of hyphens into em-dashes (---) and en-dashes (--).
/// Strategy: if divisible by 3, all em; if divisible by 2, all en;
/// otherwise prefer em-dashes first, then en-dashes for the remainder.
fn emitDashes(a: Allocator, items: *std.ArrayList(InlineItem), count: usize) !void {
    if (count <= 1) {
        if (count == 1) try addTextItem(a, items, "-");
        return;
    }
    const all_em = count % 3 == 0;
    const all_en = count % 2 == 0;
    var remaining = count;
    while (remaining > 0) {
        if (all_em) {
            try items.append(a, .{ .node = .{ .tag = .em_dash } });
            remaining -= 3;
        } else if (all_en) {
            try items.append(a, .{ .node = .{ .tag = .en_dash } });
            remaining -= 2;
        } else if (remaining >= 3 and (remaining % 2 != 0 or remaining > 4)) {
            try items.append(a, .{ .node = .{ .tag = .em_dash } });
            remaining -= 3;
        } else if (remaining >= 2) {
            try items.append(a, .{ .node = .{ .tag = .en_dash } });
            remaining -= 2;
        } else {
            try addTextItem(a, items, "-");
            remaining -= 1;
        }
    }
}

fn canOpenSingleQuote(src: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    const prev = src[pos - 1];
    return prev == ' ' or prev == '\t' or prev == '\n' or prev == '\r' or
        prev == '"' or prev == '\'' or prev == '-' or prev == '(' or prev == '[';
}

fn handleSmartQuote(a: Allocator, items: *std.ArrayList(InlineItem), openers: *std.ArrayList(OpenerInfo), src: []const u8, pos: *usize, char: u8, marked: bool) !void {
    const p = pos.*;

    if (!marked and p + 1 < src.len and src[p + 1] == '}') {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and op.marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 2;
                    return;
                }
                break;
            }
        }
        const text: []const u8 = if (char == '\'') "\u{2019}" else "\u{201d}";
        try items.append(a, .{ .node = .{ .tag = .str, .text = text } });
        pos.* = p + 2;
        return;
    }

    const can_close = !marked and p > 0 and src[p - 1] != ' ' and src[p - 1] != '\t' and
        src[p - 1] != '\n' and src[p - 1] != '\r';
    const can_open = if (marked)
        true
    else if (p + 1 < src.len and src[p + 1] != ' ' and src[p + 1] != '\t' and
        src[p + 1] != '\n' and src[p + 1] != '\r')
        (if (char == '\'') canOpenSingleQuote(src, p) else true)
    else
        false;

    if (can_close) {
        var i = openers.items.len;
        while (i > 0) {
            i -= 1;
            const op = openers.items[i];
            if (op.char == char and !op.marked) {
                if (op.item_idx + 1 < items.items.len) {
                    const tag: Tag = if (char == '"') .double_quoted else .single_quoted;
                    const children = try collectChildren(a, items, op.item_idx);
                    try items.append(a, .{ .node = .{ .tag = tag, .children = children } });
                    openers.items.len = i;
                    pos.* = p + 1;
                    return;
                }
                break;
            }
        }
    }

    if (can_open) {
        const idx = items.items.len;
        try openers.append(a, .{ .char = char, .item_idx = idx, .src_pos = p, .marked = marked });
        try items.append(a, .{ .opener = .{ .char = char, .item_idx = idx, .src_pos = p, .marked = marked } });
    } else {
        // Can't open or close: emit a typographic quote as literal text.
        // Single quote becomes right curly (') for apostrophe contexts;
        // double quote becomes left curly (") as the more common standalone form.
        const text: []const u8 = if (char == '\'') "\u{2019}" else "\u{201c}";
        try items.append(a, .{ .node = .{ .tag = .str, .text = text } });
    }
    pos.* = p + 1;
}

fn collectChildren(a: Allocator, items: *std.ArrayList(InlineItem), opener_idx: usize) ![]const Node {
    var children: std.ArrayList(Node) = .{};
    for (items.items[opener_idx + 1 ..]) |item| {
        switch (item) {
            .node => |n| try children.append(a, n),
            .opener => |op| {
                const text = try openerText(a, op);
                try children.append(a, .{ .tag = .str, .text = text });
            },
            .pending_attrs => |pa| {
                try applyAttrsToResolved(a, &children, pa);
            },
        }
    }
    items.items.len = opener_idx;
    return children.toOwnedSlice(a);
}

const single_char_strings = blk: {
    var strs: [256][]const u8 = undefined;
    for (0..256) |i| strs[i] = &[_]u8{@intCast(i)};
    break :blk strs;
};

fn openerText(_: Allocator, op: OpenerInfo) ![]const u8 {
    if (op.marked) return switch (op.char) {
        '-' => "{-",
        '+' => "{+",
        '=' => "{=",
        '*' => "{*",
        '_' => "{_",
        '~' => "{~",
        '^' => "{^",
        '\'' => "\u{2018}",
        '"' => "\u{201c}",
        else => single_char_strings[op.char],
    };
    return switch (op.char) {
        '!' => "![",
        '"' => "\u{201c}",
        '\'' => "\u{2019}",
        else => single_char_strings[op.char],
    };
}

fn resolveItems(a: Allocator, items: []const InlineItem) ![]const Node {
    var nodes: std.ArrayList(Node) = .{};
    for (items) |item| {
        switch (item) {
            .node => |n| try nodes.append(a, n),
            .opener => |op| {
                const text = try openerText(a, op);
                try nodes.append(a, .{ .tag = .str, .text = text });
            },
            .pending_attrs => |pa| {
                try applyAttrsToResolved(a, &nodes, pa);
            },
        }
    }
    return nodes.toOwnedSlice(a);
}

fn applyAttrsToResolved(a: Allocator, nodes: *std.ArrayList(Node), ba: BlockAttrs) !void {
    if (nodes.items.len == 0) return;
    const last = &nodes.items[nodes.items.len - 1];
    switch (last.tag) {
        .str => {
            const text = last.text;
            if (text.len == 0) return;
            var word_start = text.len;
            while (word_start > 0 and text[word_start - 1] != ' ' and
                text[word_start - 1] != '\t' and text[word_start - 1] != '\n')
            {
                word_start -= 1;
            }
            if (word_start == text.len) return;

            var gather_start = nodes.items.len - 1;
            if (word_start == 0) {
                while (gather_start > 0) {
                    const prev = nodes.items[gather_start - 1];
                    if (prev.tag != .str) break;
                    const pt = prev.text;
                    if (pt.len == 0) break;
                    const last_ch = pt[pt.len - 1];
                    if (last_ch == ' ' or last_ch == '\t' or last_ch == '\n') break;
                    gather_start -= 1;
                    var ws = pt.len;
                    while (ws > 0 and pt[ws - 1] != ' ' and pt[ws - 1] != '\t' and pt[ws - 1] != '\n') ws -= 1;
                    if (ws > 0) {
                        word_start = ws;
                        break;
                    }
                }
            }

            var span_children: std.ArrayList(Node) = .{};
            if (gather_start < nodes.items.len - 1 or word_start > 0) {
                if (word_start > 0) {
                    const first_text = nodes.items[gather_start].text;
                    try span_children.append(a, .{ .tag = .str, .text = first_text[word_start..] });
                    for (nodes.items[gather_start + 1 ..]) |n| try span_children.append(a, n);
                } else {
                    for (nodes.items[gather_start..]) |n| try span_children.append(a, n);
                }
            } else {
                try span_children.append(a, .{ .tag = .str, .text = text[word_start..] });
            }

            var span_node = Node{ .tag = .span, .children = try span_children.toOwnedSlice(a) };
            span_node = applyBlockAttrsToNode(span_node, ba);

            if (word_start > 0 and gather_start < nodes.items.len - 1) {
                nodes.items[gather_start].text = nodes.items[gather_start].text[0..word_start];
                nodes.items.len = gather_start + 1;
                try nodes.append(a, span_node);
            } else if (word_start > 0) {
                last.text = text[0..word_start];
                try nodes.append(a, span_node);
            } else {
                nodes.items.len = gather_start;
                try nodes.append(a, span_node);
            }
        },
        .span, .link, .image, .emph, .strong, .verbatim, .mark,
        .superscript, .subscript, .insert, .delete,
        .double_quoted, .single_quoted,
        => {
            nodes.items[nodes.items.len - 1] = applyBlockAttrsToNode(last.*, ba);
        },
        else => {},
    }
}

pub fn applyBlockAttrsToNode(node: Node, ba: BlockAttrs) Node {
    var result = node;
    if (ba.id) |id| result.id = id;
    if (ba.classes) |cls| result.classes = cls;
    if (ba.attrs.len > 0) result.attrs = ba.attrs;
    return result;
}

fn canOpenDelim(src: []const u8, pos: usize) bool {
    if (pos + 1 >= src.len) return false;
    const next = src[pos + 1];
    return next != ' ' and next != '\t' and next != '\n' and next != '\r';
}

fn canCloseDelim(src: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    const prev = src[pos - 1];
    return prev != ' ' and prev != '\t' and prev != '\n' and prev != '\r';
}

fn isEscapable(c: u8) bool {
    return switch (c) {
        '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '|', '"', '\'', '~', '^', ':', '<', '>', '$', '%', '=' => true,
        else => false,
    };
}

fn countRunAt(src: []const u8, pos: usize, char: u8) usize {
    var count: usize = 0;
    var i = pos;
    while (i < src.len and src[i] == char) : (i += 1) count += 1;
    return count;
}

fn findClosingTicks(src: []const u8, start: usize, count: usize) ?usize {
    var i = start;
    while (i < src.len) {
        if (src[i] == '`') {
            const run = countRunAt(src, i, '`');
            if (run == count) return i;
            i += run;
        } else {
            i += 1;
        }
    }
    return null;
}

fn trimVerbatimContent(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;
    if (raw.len >= 2 and raw[0] == ' ' and raw[1] == '`') start = 1;
    if (end > start + 1 and raw[end - 1] == ' ' and raw[end - 2] == '`') end -= 1;
    return raw[start..end];
}

fn findMatchingParen(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '(') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '(') depth += 1;
        if (src[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn findMatchingBracket(src: []const u8, pos: usize) ?usize {
    if (pos >= src.len or src[pos] != '[') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '[') depth += 1;
        if (src[i] == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn processUrl(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_processing = std.mem.indexOfScalar(u8, raw, '\n') != null or
        std.mem.indexOfScalar(u8, raw, '\\') != null;
    if (!needs_processing) return raw;
    var buf: std.ArrayList(u8) = .{};
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\n') {
            i += 1;
            while (i < raw.len and (raw[i] == ' ' or raw[i] == '\t')) : (i += 1) {}
        } else if (raw[i] == '\\' and i + 1 < raw.len and isEscapable(raw[i + 1])) {
            try buf.append(a, raw[i + 1]);
            i += 2;
        } else {
            try buf.append(a, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(a);
}

pub fn normalizeLabel(a: Allocator, raw: []const u8) ![]const u8 {
    const needs_normalization = for (raw) |c| {
        if (c == '\n' or c == '\r' or c == '\t') break true;
    } else false;
    if (!needs_normalization) return raw;
    var buf: std.ArrayList(u8) = .{};
    var in_ws = false;
    for (raw) |c| {
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            if (!in_ws and buf.items.len > 0) {
                try buf.append(a, ' ');
                in_ws = true;
            }
        } else {
            try buf.append(a, c);
            in_ws = false;
        }
    }
    const items = buf.items;
    if (items.len > 0 and items[items.len - 1] == ' ') buf.items.len -= 1;
    return buf.toOwnedSlice(a);
}

pub fn getPlainText(a: Allocator, node: Node) ![]const u8 {
    if (node.text.len > 0) return node.text;
    var buf: std.ArrayList(u8) = .{};
    for (node.children) |child| {
        switch (child.tag) {
            .str => try buf.appendSlice(a, child.text),
            .soft_break => try buf.append(a, ' '),
            else => {
                if (child.children.len > 0) {
                    const sub = try getPlainText(a, child);
                    try buf.appendSlice(a, sub);
                }
            },
        }
    }
    return buf.toOwnedSlice(a);
}

pub fn joinLines(a: Allocator, lines: []const []const u8) ![]const u8 {
    if (lines.len == 0) return "";
    var total: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx > 0) total += 1;
        total += line.len;
    }
    var buf = try a.alloc(u8, total);
    var p: usize = 0;
    for (lines, 0..) |line, idx| {
        if (idx > 0) {
            buf[p] = '\n';
            p += 1;
        }
        @memcpy(buf[p..][0..line.len], line);
        p += line.len;
    }
    return buf;
}

pub fn mergeRefAttrs(node: Node, ref_attrs: BlockAttrs, a: Allocator) Node {
    var result = node;
    if (result.id == null) result.id = ref_attrs.id;
    if (ref_attrs.classes) |ref_cls| {
        if (result.classes) |existing| {
            result.classes = std.fmt.allocPrint(a, "{s} {s}", .{ ref_cls, existing }) catch existing;
        } else {
            result.classes = ref_cls;
        }
    }
    if (ref_attrs.attrs.len > 0) {
        if (result.attrs.len == 0) {
            result.attrs = ref_attrs.attrs;
        } else {
            var merged: std.ArrayList(@import("node.zig").Attr) = .{};
            for (ref_attrs.attrs) |ra| {
                var overridden = false;
                for (result.attrs) |na| {
                    if (std.mem.eql(u8, ra.key, na.key)) {
                        overridden = true;
                        break;
                    }
                }
                if (!overridden) merged.append(a, ra) catch {};
            }
            for (result.attrs) |na| merged.append(a, na) catch {};
            result.attrs = merged.toOwnedSlice(a) catch result.attrs;
        }
    }
    return result;
}
