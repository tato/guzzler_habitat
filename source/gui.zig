const std = @import("std");
const rl = @import("raylib");

var gui: Gui = undefined;
const Gui = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    frame_index: u64 = 0,
    blocks: BlockMap = .{},

    primordial_parent: *Block,
    current_parent: *Block,
    last_inserted: *Block,

    font: rl.Font,
};

const BlockMap = std.AutoHashMapUnmanaged(Key, *Block);

const Block = struct {
    // tree links
    first: ?*Block,
    last: ?*Block,
    next: ?*Block,
    prev: ?*Block,
    parent: ?*Block,

    // key+generation info
    key: Key,
    last_frame_touched_index: u64,

    // per-frame info provided by builders
    flags: BlockFlags,
    string: ?[:0]const u8,
    semantic_size: [Axis.len]Size,
    layout_axis: Axis = .x,

    // computed every frame
    computed_rel_position: [Axis.len]f32,
    computed_size: [Axis.len]f32,
    rect: rl.Rectangle,

    // persistent data
    hot_t: f32 = 0,
    active_t: f32 = 0,

    pub fn clearPerFrameInfo(block: *Block) void {
        block.flags = .{};
        block.string = null;
        block.semantic_size[0] = .{ .kind = .text_content, .value = 0, .strictness = 0 };
        block.semantic_size[1] = .{ .kind = .text_content, .value = 0, .strictness = 0 };
        block.layout_axis = .x;

        block.first = null;
        block.last = null;
        block.next = null;
        block.prev = null;
        block.parent = null;
    }
};

const BlockFlags = packed struct {
    border: bool = false,
    _padding: u31 = 0,

    comptime {
        std.debug.assert(@bitSizeOf(BlockFlags) == 32);
    }
};

const SizeKind = enum {
    pixels,
    text_content,
    percent_of_parent,
    children_sum,
};

pub const Size = struct {
    kind: SizeKind,
    value: f32,
    strictness: f32,

    pub fn init(kind: SizeKind, value: f32, strictness: f32) Size {
        return Size{ .kind = kind, .value = value, .strictness = strictness };
    }
};

const Axis = enum {
    x,
    y,
    const len = @typeInfo(Axis).Enum.fields.len;
};

const Key = u64;

pub fn init(gpa: std.mem.Allocator) void {
    const primordial_parent = gpa.create(Block) catch unreachable;
    primordial_parent.* = std.mem.zeroes(Block);
    gui = Gui{
        .gpa = gpa,
        .arena = undefined,
        .primordial_parent = primordial_parent,
        .current_parent = primordial_parent,
        .last_inserted = primordial_parent,
        .font = rl.GetFontDefault(),
    };
}

pub fn setFont(font: rl.Font) void {
    gui.font = font;
}

pub fn begin() void {
    gui.arena = std.heap.ArenaAllocator.init(gui.gpa);
    gui.frame_index += 1;
    gui.current_parent = gui.primordial_parent;

    gui.primordial_parent.clearPerFrameInfo();
    gui.primordial_parent.semantic_size[0] = .{ .kind = .percent_of_parent, .value = 1, .strictness = 1 };
    gui.primordial_parent.semantic_size[1] = .{ .kind = .percent_of_parent, .value = 1, .strictness = 1 };
    gui.primordial_parent.computed_size = .{ @intToFloat(f32, rl.GetScreenWidth()), @intToFloat(f32, rl.GetScreenHeight()) };
    gui.primordial_parent.computed_rel_position = .{ 0, 0 };
    gui.primordial_parent.rect = rl.Rectangle.init(0, 0, gui.primordial_parent.computed_size[0], gui.primordial_parent.computed_size[1]);
}

pub fn end() void {
    calculateStandaloneSizes(gui.primordial_parent);
    calculateUpwardsDependentSizes(gui.primordial_parent);
    calculateDownwardsDependentSizes(gui.primordial_parent);
    solveViolations(gui.primordial_parent);
    computeRelativePositions(gui.primordial_parent);

    renderTree(gui.primordial_parent);

    pruneWidgets() catch unreachable;

    gui.arena.deinit();
}

pub fn pushParent(block: *Block) void {
    gui.current_parent = block;
}

pub fn popParent() void {
    gui.current_parent = gui.current_parent.parent.?;
}

pub fn label(comptime string: [:0]const u8) void {
    const block = getOrInsertBlock(string);

    block.string = string;
    block.semantic_size[@enumToInt(Axis.x)].kind = .text_content;
    block.semantic_size[@enumToInt(Axis.y)].kind = .text_content;
}

pub fn button(comptime string: [:0]const u8) bool {
    const block = getOrInsertBlock(string);

    block.string = string;
    block.semantic_size[@enumToInt(Axis.x)].kind = .text_content;
    block.semantic_size[@enumToInt(Axis.y)].kind = .text_content;
    block.flags.border = true;

    const mouse_position = rl.GetMousePosition();
    return rl.CheckCollisionPointRec(mouse_position, block.rect) and rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
}

pub fn withBorder() void {
    gui.last_inserted.flags.border = true;
}

pub fn withSize(x: Size, y: Size) void {
    gui.last_inserted.semantic_size = .{ x, y };
}

pub fn blockLayout(comptime string: [:0]const u8, axis: Axis) *Block {
    const block = getOrInsertBlock(string);

    block.semantic_size[@enumToInt(Axis.x)].kind = .children_sum;
    block.semantic_size[@enumToInt(Axis.y)].kind = .children_sum;
    block.layout_axis = axis;

    return block;
}

fn getOrInsertBlock(comptime string: [:0]const u8) *Block {
    const key = keyFromString(string);

    const entry = gui.blocks.getOrPut(gui.gpa, key) catch unreachable;
    if (!entry.found_existing) {
        const block = gui.gpa.create(Block) catch unreachable;
        block.* = std.mem.zeroInit(Block, .{
            .key = key,
        });
        entry.value_ptr.* = block;
    }

    const block = entry.value_ptr.*;
    block.clearPerFrameInfo();

    block.prev = gui.current_parent.last;
    block.parent = gui.current_parent;

    if (block.prev) |previous_sibling| previous_sibling.next = block;

    if (gui.current_parent.first == null) gui.current_parent.first = block;
    gui.current_parent.last = block;

    block.last_frame_touched_index = gui.frame_index;
    gui.last_inserted = block;

    return block;
}

fn pruneWidgets() !void {
    var remove_blocks = std.ArrayList(Key).init(gui.arena.allocator());
    defer remove_blocks.deinit();

    var blocks_iterator = gui.blocks.iterator();
    while (blocks_iterator.next()) |entry| {
        if (entry.value_ptr.*.last_frame_touched_index < gui.frame_index) {
            gui.gpa.destroy(entry.value_ptr.*);
            try remove_blocks.append(entry.key_ptr.*);
        }
    }

    for (remove_blocks.items) |key| _ = gui.blocks.remove(key);
}

fn keyFromString(string: []const u8) Key {
    return std.hash.Wyhash.hash(420, string);
}

fn calculateStandaloneSizes(first_sibling: *Block) void {
    var current_sibling: ?*Block = first_sibling;
    while (current_sibling) |block| : (current_sibling = block.next) {
        for (block.semantic_size) |semantic_size, i| {
            switch (semantic_size.kind) {
                .pixels => block.computed_size[i] = semantic_size.value,
                .text_content => {
                    block.computed_size[i] = if (block.string) |string| switch (@intToEnum(Axis, i)) {
                        .x => @intToFloat(f32, rl.MeasureText(string, gui.font.baseSize)),
                        .y => @intToFloat(f32, gui.font.baseSize),
                    } else 0;
                },
                else => {},
            }
        }

        if (block.first) |first| calculateStandaloneSizes(first);
    }
}

fn calculateUpwardsDependentSizes(first_sibling: *Block) void {
    var current_sibling: ?*Block = first_sibling;
    while (current_sibling) |parent| : (current_sibling = parent.next) {
        var current_child = parent.first;
        while (current_child) |child| : (current_child = child.next) {
            for (child.semantic_size) |semantic_size, i| switch (semantic_size.kind) {
                .percent_of_parent => child.computed_size[i] = switch (parent.semantic_size[i].kind) {
                    .pixels, .text_content, .percent_of_parent => parent.computed_size[i] * semantic_size.value,
                    else => 0,
                },
                else => {},
            };
        }

        if (parent.first) |first| calculateUpwardsDependentSizes(first);
    }
}

fn calculateDownwardsDependentSizes(first_sibling: *Block) void {
    var current_sibling: ?*Block = first_sibling;
    while (current_sibling) |block| : (current_sibling = block.next) {
        if (block.first) |first| calculateDownwardsDependentSizes(first);

        for (block.semantic_size) |semantic_size, i| {
            switch (semantic_size.kind) {
                .children_sum => {
                    block.computed_size[i] = 0;

                    var current_child = block.first;
                    while (current_child) |child| : (current_child = child.next) {
                        if (@enumToInt(block.layout_axis) == i)
                            block.computed_size[i] += child.computed_size[i]
                        else
                            block.computed_size[i] = @maximum(block.computed_size[i], child.computed_size[i]);
                    }
                },
                else => {},
            }
        }
    }
}

fn solveViolations(block: *Block) void {
    var children_size = [Axis.len]f32{ 0, 0 };

    var current_child = block.first;
    while (current_child) |child| : (current_child = child.next) {
        for (child.computed_size) |computed_size, i| {
            if (@enumToInt(block.layout_axis) == i) {
                children_size[i] += computed_size;
            } else {
                children_size[i] = @maximum(children_size[i], computed_size);
            }
        }
    }

    current_child = block.first;
    while (current_child) |child| : (current_child = child.next) {
        for (child.computed_size) |*child_computed_size, i| {
            if (children_size[i] > block.computed_size[i]) {
                const strictness = child.semantic_size[i].strictness;
                child_computed_size.* *= block.computed_size[i] / children_size[i] * (1 - strictness);
            }
        }

        if (child.first) |first| solveViolations(first);
    }
}

fn computeRelativePositions(block: *Block) void {
    const parent_rect = if (block.parent) |parent| parent.rect else rl.Rectangle.init(0, 0, 0, 0);
    block.rect.x = parent_rect.x + block.computed_rel_position[0];
    block.rect.y = parent_rect.y + block.computed_rel_position[1];
    block.rect.width = block.computed_size[0];
    block.rect.height = block.computed_size[1];

    var current_position = [Axis.len]f32{ 0, 0 };
    var current_child = block.first;
    while (current_child) |child| : (current_child = child.next) {
        child.computed_rel_position = current_position;
        current_position[@enumToInt(block.layout_axis)] += child.computed_size[@enumToInt(block.layout_axis)];
    }

    if (block.first) |first| computeRelativePositions(first);
    if (block.next) |next| computeRelativePositions(next);
}

fn renderTree(block: *Block) void {
    if (block.string) |string| {
        const position = rl.Vector2.init(block.rect.x, block.rect.y);
        rl.DrawTextEx(gui.font, string, position, @intToFloat(f32, gui.font.baseSize), 0, rl.BLACK);
    }

    if (block.flags.border) {
        rl.DrawLineStrip(&.{
            rl.Vector2.init(block.rect.x, block.rect.y),
            rl.Vector2.init(block.rect.x + block.rect.width, block.rect.y),
            rl.Vector2.init(block.rect.x + block.rect.width, block.rect.y + block.rect.height),
            rl.Vector2.init(block.rect.x, block.rect.y + block.rect.height),
            rl.Vector2.init(block.rect.x, block.rect.y),
        }, rl.BLACK);
    }

    if (block.first) |first| renderTree(first);
    if (block.next) |next| renderTree(next);
}
