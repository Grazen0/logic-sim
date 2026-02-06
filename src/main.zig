const std = @import("std");
const rl = @import("raylib");

const screenWidth = 960;
const screenHeight = 540;
const portRadius = 12;
const topPortRadius = 20;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;

const Wire = struct {
    from: union(enum) {
        input: usize,
        module: struct {
            mod: usize,
            output: usize,
        },
    },
    to: union(enum) {
        output: usize,
        module: struct {
            mod: usize,
            input: usize,
        },
    },
};

const BooleanFunc = fn (input: *const ArrayList(bool), output: *ArrayList(bool)) void;

fn interpolate(total_cnt: usize, idx: usize, len: f32) f32 {
    const step = len / @as(f32, @floatFromInt(total_cnt + 1));
    return @as(f32, @floatFromInt(idx + 1)) * step;
}

fn top_input_pos(input_cnt: usize, input: usize) Vector2 {
    return .{
        .x = 2 * topPortRadius,
        .y = interpolate(input_cnt, input, screenHeight),
    };
}

fn top_output_pos(output_cnt: usize, input: usize) Vector2 {
    return .{
        .x = screenWidth - (2 * topPortRadius),
        .y = interpolate(output_cnt, input, screenHeight),
    };
}

const Module = struct {
    const Self = @This();

    name: [:0]const u8,
    input_cnt: usize,
    output_cnt: usize,
    size: Vector2,
    color: Color,
    body: ModuleBody,

    fn input_offset(self: *const Self, idx: usize) Vector2 {
        return .{
            .x = 0,
            .y = -portRadius + interpolate(self.input_cnt, idx, self.size.y + (2 * portRadius)),
        };
    }

    fn output_offset(self: *const Self, idx: usize) Vector2 {
        return .{
            .x = self.size.x,
            .y = -portRadius + interpolate(self.output_cnt, idx, self.size.y + (2 * portRadius)),
        };
    }

    fn deinit(self: *Self, gpa: Allocator) void {
        self.body.deinit(gpa);
    }
};

const ModuleBody = union(enum) {
    const Self = @This();

    primitive: *const BooleanFunc,
    custom: CustomModuleBody,

    fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .primitive => {},
            .custom => |*body| body.deinit(gpa),
        }
    }
};

const CustomModuleBody = struct {
    const Self = @This();

    children: ArrayList(struct {
        pos: Vector2,
        mod: usize, // index within modules list
    }),
    wires: ArrayList(Wire),

    fn deinit(self: *Self, gpa: Allocator) void {
        self.children.deinit(gpa);
        self.wires.deinit(gpa);
    }
};

const ModuleInstance = struct {
    const Self = @This();

    mod_idx: usize,
    inputs: ArrayList(bool),
    outputs: ArrayList(bool),
    body: ModuleInstanceBody,

    fn fromList(gpa: Allocator, module_list: []const Module, idx: usize) !Self {
        const blueprint = &module_list[idx];

        var out = Self{
            .mod_idx = idx,
            .inputs = try .initCapacity(gpa, blueprint.input_cnt),
            .outputs = try .initCapacity(gpa, blueprint.output_cnt),
            .body = switch (blueprint.body) {
                .primitive => .{ .primitive = {} },
                .custom => |*blueprint_body| blk: {
                    var children: ArrayList(Self) = .empty;

                    for (blueprint_body.children.items) |*child_blueprint| {
                        const child_instance = try Self.fromList(gpa, module_list, child_blueprint.mod);
                        try children.append(gpa, child_instance);
                    }

                    break :blk .{ .custom = children };
                },
            },
        };

        for (0..blueprint.input_cnt) |_|
            try out.inputs.append(gpa, false);

        for (0..blueprint.output_cnt) |_|
            try out.outputs.append(gpa, false);

        return out;
    }

    fn deinit(self: *Self, gpa: Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.body.deinit(gpa);
    }
};

const ModuleInstanceBody = union(enum) {
    const Self = @This();

    primitive: void,
    custom: ArrayList(ModuleInstance),

    fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .primitive => {},
            .custom => |*children| {
                for (children.items) |*child|
                    child.deinit(gpa);
                children.deinit(gpa);
            },
        }
    }
};

fn checkVec2RectCollision(v: Vector2, r: Rectangle) bool {
    return v.x >= r.x and v.x < r.x + r.width and v.y >= r.y and v.y < r.y + r.height;
}

fn rectPosition(r: Rectangle) Vector2 {
    return .{ .x = r.x, .y = r.y };
}

fn andFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] and input.items[1];
}

fn orFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] or input.items[1];
}

fn notFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = !input.items[0];
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_highdpi = true });
    rl.initWindow(screenWidth, screenHeight, "Logic Simulator");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var modules = [_]Module{
        .{
            .name = "and",
            .input_cnt = 2,
            .output_cnt = 1,
            .size = .{ .x = 120, .y = 60 },
            .color = .red,
            .body = .{
                .primitive = andFunc,
            },
        },
        .{
            .name = "or",
            .input_cnt = 2,
            .output_cnt = 1,
            .size = .{ .x = 120, .y = 60 },
            .color = .blue,
            .body = .{
                .primitive = orFunc,
            },
        },
        .{
            .name = "not",
            .input_cnt = 1,
            .output_cnt = 1,
            .size = .{ .x = 80, .y = 40 },
            .color = .green,
            .body = .{
                .primitive = notFunc,
            },
        },
        .{
            .name = "mux",
            .input_cnt = 3,
            .output_cnt = 1,
            .size = .{ .x = 200, .y = 200 },
            .color = .yellow,
            .body = .{
                .custom = .{
                    .children = .empty,
                    .wires = .empty,
                },
            },
        },
    };
    defer for (&modules) |*mod|
        mod.deinit(alloc);

    const mux_body = &modules[3].body.custom;

    try mux_body.children.append(alloc, .{
        .pos = .{ .x = 300, .y = 100 },
        .mod = 0, // and
    });
    try mux_body.children.append(alloc, .{
        .pos = .{ .x = 300, .y = 380 },
        .mod = 0, // and
    });
    try mux_body.children.append(alloc, .{
        .pos = .{ .x = 600, .y = 240 },
        .mod = 1, // or
    });
    try mux_body.children.append(alloc, .{
        .pos = .{ .x = 150, .y = 125 },
        .mod = 2, // not
    });

    try mux_body.wires.append(alloc, .{
        .from = .{ .input = 0 },
        .to = .{ .module = .{ .mod = 0, .input = 0 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .input = 1 },
        .to = .{ .module = .{ .mod = 1, .input = 0 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .input = 2 },
        .to = .{ .module = .{ .mod = 3, .input = 0 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .module = .{ .mod = 3, .output = 0 } },
        .to = .{ .module = .{ .mod = 0, .input = 1 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .input = 2 },
        .to = .{ .module = .{ .mod = 1, .input = 1 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .module = .{ .mod = 0, .output = 0 } },
        .to = .{ .module = .{ .mod = 2, .input = 0 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .module = .{ .mod = 1, .output = 0 } },
        .to = .{ .module = .{ .mod = 2, .input = 1 } },
    });
    try mux_body.wires.append(alloc, .{
        .from = .{ .module = .{ .mod = 2, .output = 0 } },
        .to = .{ .output = 0 },
    });

    var top = try ModuleInstance.fromList(alloc, &modules, 3);
    defer top.deinit(alloc);

    const font = try rl.getFontDefault();

    while (!rl.windowShouldClose()) {
        const top_mod = &modules[top.mod_idx];
        const top_children = &top.body.custom;

        if (rl.isMouseButtonPressed(.left)) {
            const mouse = rl.getMousePosition();
            for (0..top_mod.input_cnt) |i| {
                const input_pos = top_input_pos(top_mod.input_cnt, i);
                if (mouse.distance(input_pos) <= topPortRadius) {
                    top.inputs.items[i] = !top.inputs.items[i];
                    // propagate updates
                    break;
                }
            }
        }

        // Drawing starts here
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);

        for (0..top_mod.input_cnt) |i| {
            rl.drawCircleV(
                top_input_pos(top_mod.input_cnt, i),
                topPortRadius,
                if (top.inputs.items[i]) .red else .gray,
            );
        }

        for (0..top_mod.output_cnt) |i| {
            rl.drawCircleV(
                top_output_pos(top_mod.output_cnt, i),
                topPortRadius,
                if (top.outputs.items[i]) .red else .gray,
            );
        }

        for (top_children.items, top_mod.body.custom.children.items) |*child, *child_info| {
            const mod = &modules[child.mod_idx];

            rl.drawRectangleV(child_info.pos, mod.size, mod.color);

            for (0..mod.input_cnt) |i|
                rl.drawCircleV(child_info.pos.add(mod.input_offset(i)), portRadius, .gray);

            for (0..mod.output_cnt) |i|
                rl.drawCircleV(child_info.pos.add(mod.output_offset(i)), portRadius, .gray);

            const FONT_SIZE = 30;
            const FONT_SPACING = FONT_SIZE * 0.1;

            const text_size = rl.measureTextEx(font, mod.name, FONT_SIZE, FONT_SPACING);

            rl.drawTextEx(
                font,
                mod.name,
                .{
                    .x = child_info.pos.x + (mod.size.x / 2) - (text_size.x / 2),
                    .y = child_info.pos.y + (mod.size.y / 2) - (text_size.y / 2),
                },
                FONT_SIZE,
                FONT_SPACING,
                .white,
            );
        }

        for (top_mod.body.custom.wires.items) |*wire| {
            const from_pos: Vector2 = switch (wire.from) {
                .input => |i| top_input_pos(top_mod.input_cnt, i),
                .module => |*info| blk: {
                    const child = top_children.items[info.mod];
                    const mod = modules[child.mod_idx];
                    const pos = top_mod.body.custom.children.items[info.mod].pos.add(mod.output_offset(info.output));
                    break :blk pos;
                },
            };

            const to_pos: Vector2 = switch (wire.to) {
                .output => |i| top_output_pos(top_mod.output_cnt, i),
                .module => |*info| blk: {
                    const child = top_children.items[info.mod];
                    const mod = modules[child.mod_idx];
                    const pos = top_mod.body.custom.children.items[info.mod].pos.add(mod.input_offset(info.input));
                    break :blk pos;
                },
            };

            const is_on = switch (wire.from) {
                .input => |i| top.inputs.items[i],
                .module => |*info| top_children.items[info.mod].outputs.items[info.output],
            };

            rl.drawLineEx(from_pos, to_pos, 5, if (is_on) .red else .dark_gray);
        }
    }
}
