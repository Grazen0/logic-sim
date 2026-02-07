const std = @import("std");
const rl = @import("raylib");
const deque = @import("./deque.zig");

const screenWidth = 1280;
const screenHeight = 720;
const portRadius = 12;
const topPortRadius = 20;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;
const Deque = deque.Deque;

const ModuleInputInfo = struct {
    mod: usize,
    input: usize,
};

const ModuleOutputInfo = struct {
    mod: usize,
    output: usize,
};

const WireSrc = union(enum) {
    const Self = @This();

    input: usize,
    module: ModuleOutputInfo,

    fn equals(self: *const Self, other: *const Self) bool {
        return switch (self.*) {
            .input => |i| switch (other.*) {
                .input => |j| i == j,
                else => false,
            },
            .module => |info_1| switch (other) {
                .module => |info_2| info_1.input == info_2.input and info_1.mod == info_2.mod,
                else => false,
            },
        };
    }
};

const WireDest = union(enum) {
    const Self = @This();

    output: usize,
    module: ModuleInputInfo,

    fn equals(self: *const Self, other: *const Self) bool {
        return switch (self.*) {
            .output => |i| switch (other.*) {
                .output => |j| i == j,
                else => false,
            },
            .module => |info_1| switch (other.*) {
                .module => |info_2| info_1.input == info_2.input and info_1.mod == info_2.mod,
                else => false,
            },
        };
    }
};

const Wire = struct {
    const Self = @This();

    from: WireSrc,
    to: WireDest,

    fn init(from: WireSrc, to: WireDest) Self {
        return .{ .from = from, .to = to };
    }
};

const BooleanFunc = fn (input: *const ArrayList(bool), output: *ArrayList(bool)) void;

fn interpolate(total_cnt: usize, idx: usize, len: f32) f32 {
    const step = len / @as(f32, @floatFromInt(total_cnt + 1));
    return @as(f32, @floatFromInt(idx + 1)) * step;
}

fn top_input_pos(input_cnt: usize, input: usize) Vector2 {
    return .init(
        2 * topPortRadius,
        interpolate(input_cnt, input, screenHeight),
    );
}

fn top_output_pos(output_cnt: usize, input: usize) Vector2 {
    return .init(
        screenWidth - (2 * topPortRadius),
        interpolate(output_cnt, input, screenHeight),
    );
}

const Module = struct {
    const Self = @This();

    name: [:0]const u8,
    input_cnt: usize,
    output_cnt: usize,
    size: Vector2,
    color: Color,
    body: ModuleBody,

    fn input_pos(self: *const Self, base_pos: Vector2, idx: usize) Vector2 {
        return .init(
            base_pos.x,
            base_pos.y - portRadius + interpolate(self.input_cnt, idx, self.size.y + (2 * portRadius)),
        );
    }

    fn output_pos(self: *const Self, base_pos: Vector2, idx: usize) Vector2 {
        return .init(
            base_pos.x + self.size.x,
            base_pos.y - portRadius + interpolate(self.output_cnt, idx, self.size.y + (2 * portRadius)),
        );
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
        mod_idx: usize,
    }),
    wires: ArrayList(Wire),

    /// Adds a wire to the body, removing at most one other if there already
    /// exists a wire connected to the same output.
    /// Returns the removed wire.
    fn add_wire(self: *Self, gpa: Allocator, wire: Wire) !?Wire {
        var removed_wire: ?Wire = null;

        for (0.., self.wires.items) |i, other_wire| {
            if (wire.to.equals(&other_wire.to)) {
                removed_wire = self.wires.swapRemove(i);
                break;
            }
        }

        try self.wires.append(gpa, wire);
        return removed_wire;
    }

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

    fn fromModule(gpa: Allocator, modules: []const Module, idx: usize) !Self {
        const blueprint = &modules[idx];

        var out: Self = .{
            .mod_idx = idx,
            .inputs = .empty,
            .outputs = .empty,
            .body = switch (blueprint.body) {
                .primitive => .primitive,
                .custom => |*blueprint_body| blk: {
                    var children: ArrayList(Self) = try .initCapacity(gpa, blueprint_body.children.items.len);

                    for (blueprint_body.children.items) |*child_blueprint| {
                        const child_instance = try Self.fromModule(gpa, modules, child_blueprint.mod_idx);
                        try children.append(gpa, child_instance);
                    }

                    break :blk .{ .custom = children };
                },
            },
        };

        try out.inputs.appendNTimes(gpa, false, blueprint.input_cnt);
        try out.outputs.appendNTimes(gpa, false, blueprint.output_cnt);

        for (0..blueprint.input_cnt) |i|
            try propagateLogic(gpa, modules, &out, i);

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

    primitive,
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
    return .init(r.x, r.y);
}

fn andFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] and input.items[1];
}

fn orFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] or input.items[1];
}

fn xorFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = input.items[0] ^ input.items[1];
}

fn norFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = !(input.items[0] or input.items[1]);
}

fn notFunc(input: *const ArrayList(bool), output: *ArrayList(bool)) void {
    output.items[0] = !input.items[0];
}

fn propagateLogic(gpa: Allocator, modules: []const Module, instance: *ModuleInstance, input_idx: usize) !void {
    const module = &modules[instance.mod_idx];

    switch (module.body) {
        .primitive => |func| func(&instance.inputs, &instance.outputs),
        .custom => |mod_body| {
            const inst_body = instance.body.custom;

            var queue: Deque(WireSrc) = .empty;
            defer queue.deinit(gpa);

            try queue.pushBack(gpa, .{ .input = input_idx });

            while (queue.popFront()) |src| {
                var next_wires: ArrayList(*Wire) = .empty;
                defer next_wires.deinit(gpa);

                switch (src) {
                    .input => |i_1| {
                        for (mod_body.wires.items) |*wire| {
                            switch (wire.from) {
                                .input => |i_2| if (i_1 == i_2) try next_wires.append(gpa, wire),
                                .module => {},
                            }
                        }
                    },
                    .module => |*info| {
                        for (mod_body.wires.items) |*wire| {
                            switch (wire.from) {
                                .input => {},
                                .module => |*from| {
                                    if (info.mod == from.mod and info.output == from.output)
                                        try next_wires.append(gpa, wire);
                                },
                            }
                        }
                    },
                }

                const src_value = switch (src) {
                    .input => |i| instance.inputs.items[i],
                    .module => |from| inst_body.items[from.mod].outputs.items[from.output],
                };

                for (next_wires.items) |wire| {
                    switch (wire.to) {
                        .output => |i| instance.outputs.items[i] = src_value,
                        .module => |to| {
                            const rec_instance = &inst_body.items[to.mod];
                            rec_instance.inputs.items[to.input] = src_value;

                            var prev_outputs = try rec_instance.outputs.clone(gpa);
                            defer prev_outputs.deinit(gpa);

                            try propagateLogic(gpa, modules, &inst_body.items[to.mod], to.input);
                            const new_outputs = &rec_instance.outputs;

                            for (0.., prev_outputs.items, new_outputs.items) |i, prev, new| {
                                if (prev != new) {
                                    try queue.pushBack(gpa, .{
                                        .module = .{
                                            .mod = to.mod,
                                            .output = i,
                                        },
                                    });
                                }
                            }
                        },
                    }
                }
            }
        },
    }
}

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_highdpi = true });
    rl.initWindow(screenWidth, screenHeight, "Logic Simulator");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var modules = [_]Module{ .{
        .name = "and",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .red,
        .body = .{ .primitive = andFunc },
    }, .{
        .name = "or",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .blue,
        .body = .{ .primitive = orFunc },
    }, .{
        .name = "not",
        .input_cnt = 1,
        .output_cnt = 1,
        .size = .init(80, 40),
        .color = .green,
        .body = .{ .primitive = notFunc },
    }, .{
        .name = "xor",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .yellow,
        .body = .{ .primitive = xorFunc },
    }, .{
        .name = "nor",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .purple,
        .body = .{ .primitive = norFunc },
    }, .{
        .name = "mux",
        .input_cnt = 3,
        .output_cnt = 1,
        .size = .init(200, 200),
        .color = .yellow,
        .body = .{
            .custom = .{
                .children = .empty,
                .wires = .empty,
            },
        },
    } };
    defer for (&modules) |*mod|
        mod.deinit(alloc);

    const top_mod = &modules[modules.len - 1];

    try top_mod.body.custom.children.append(alloc, .{
        .pos = .init(300, 119),
        .mod_idx = 4, // nor
    });
    try top_mod.body.custom.children.append(alloc, .{
        .pos = .init(300, 361),
        .mod_idx = 4, // nor
    });
    // try top_mod.body.custom.children.append(alloc, .{
    //     .pos = .init(600, 240),
    //     .mod_idx = 1, // or
    // });
    // try top_mod.body.custom.children.append(alloc, .{
    //     .pos = .init(150, 143),
    //     .mod_idx = 2, // not
    // });

    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .input = 0 },
    //     .to = .{ .module = .{ .mod = 0, .input = 0 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .input = 1 },
    //     .to = .{ .module = .{ .mod = 1, .input = 0 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .input = 2 },
    //     .to = .{ .module = .{ .mod = 3, .input = 0 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .module = .{ .mod = 3, .output = 0 } },
    //     .to = .{ .module = .{ .mod = 0, .input = 1 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .input = 2 },
    //     .to = .{ .module = .{ .mod = 1, .input = 1 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .module = .{ .mod = 0, .output = 0 } },
    //     .to = .{ .module = .{ .mod = 2, .input = 0 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .module = .{ .mod = 1, .output = 0 } },
    //     .to = .{ .module = .{ .mod = 2, .input = 1 } },
    // });
    // try top_mod.body.custom.wires.append(alloc, .{
    //     .from = .{ .module = .{ .mod = 2, .output = 0 } },
    //     .to = .{ .output = 0 },
    // });

    var top = try ModuleInstance.fromModule(alloc, &modules, modules.len - 1);
    defer top.deinit(alloc);

    const font = try rl.getFontDefault();

    const DragInfo = union(enum) {
        none,
        module: struct {
            mod: usize,
            offset: Vector2,
        },
        wire_from: WireSrc,
        wire_to: WireDest,
    };

    const HoverInfo = union(enum) {
        none,
        top_input: usize,
        top_output: usize,
        mod_input: ModuleInputInfo,
        mod_output: ModuleOutputInfo,
        module: usize,
    };

    var drag: DragInfo = .none;
    var last_mouse_press: Vector2 = .init(0, 0);

    while (!rl.windowShouldClose()) {
        const mouse = rl.getMousePosition();

        const hover_info: HoverInfo = blk: {
            for (0..top_mod.input_cnt) |input_idx| {
                const input_pos = top_input_pos(top_mod.input_cnt, input_idx);

                if (mouse.distance(input_pos) <= topPortRadius) {
                    break :blk .{ .top_input = input_idx };
                }
            }

            for (0..top_mod.output_cnt) |output_idx| {
                const output_pos = top_output_pos(top_mod.output_cnt, output_idx);

                if (mouse.distance(output_pos) <= topPortRadius)
                    break :blk .{ .top_output = output_idx };
            }

            for (0.., top_mod.body.custom.children.items) |i, child| {
                const child_mod = &modules[child.mod_idx];

                for (0..child_mod.input_cnt) |input_idx| {
                    const input_pos = child_mod.input_pos(child.pos, input_idx);

                    if (mouse.distance(input_pos) <= portRadius)
                        break :blk .{ .mod_input = .{ .mod = i, .input = input_idx } };
                }

                for (0..child_mod.output_cnt) |output_idx| {
                    const output_pos = child_mod.output_pos(child.pos, output_idx);

                    if (mouse.distance(output_pos) <= portRadius)
                        break :blk .{ .mod_output = .{ .mod = i, .output = output_idx } };
                }

                const rect: Rectangle = .init(child.pos.x, child.pos.y, child_mod.size.x, child_mod.size.y);

                if (checkVec2RectCollision(mouse, rect))
                    break :blk .{ .module = i };
            }
            break :blk .none;
        };

        if (rl.isMouseButtonPressed(.left)) {
            last_mouse_press = mouse;

            switch (hover_info) {
                .none => {},
                .top_input => |idx| drag = .{ .wire_from = .{ .input = idx } },
                .top_output => |idx| drag = .{ .wire_to = .{ .output = idx } },
                .module => |mod| drag = .{
                    .module = .{
                        .mod = mod,
                        .offset = top_mod.body.custom.children.items[mod].pos.subtract(mouse),
                    },
                },
                .mod_input => |info| drag = .{
                    .wire_to = .{ .module = .{ .mod = info.mod, .input = info.input } },
                },
                .mod_output => |info| drag = .{
                    .wire_from = .{ .module = .{ .mod = info.mod, .output = info.output } },
                },
            }
        } else if (rl.isMouseButtonReleased(.left)) {
            if (mouse.equals(last_mouse_press) != 0) {
                switch (hover_info) {
                    .top_input => |input_idx| {
                        top.inputs.items[input_idx] = !top.inputs.items[input_idx];
                        try propagateLogic(alloc, &modules, &top, input_idx);
                    },
                    else => {},
                }
            } else {
                const new_wire: ?Wire = switch (drag) {
                    .none, .module => null,
                    .wire_from => |from| switch (hover_info) {
                        .mod_input => |info| .init(from, .{ .module = info }),
                        .top_output => |idx| .init(from, .{ .output = idx }),
                        else => null,
                    },
                    .wire_to => |to| switch (hover_info) {
                        .mod_output => |info| .init(.{ .module = info }, to),
                        .top_input => |idx| .init(.{ .input = idx }, to),
                        else => null,
                    },
                };

                if (new_wire) |new_wire_v| {
                    const old_wire = try top_mod.body.custom.add_wire(alloc, new_wire_v);

                    if (old_wire) |old_wire_v| {
                        switch (old_wire_v.to) {
                            .output => |idx| top.outputs.items[idx] = false,
                            .module => |info| {
                                const child = &top.body.custom.items[info.mod];
                                child.inputs.items[info.input] = false;
                                try propagateLogic(alloc, &modules, child, info.input);
                            },
                        }
                    }

                    const from_value = switch (new_wire_v.from) {
                        .input => |idx| top.inputs.items[idx],
                        .module => |info| blk: {
                            const child = &top.body.custom.items[info.mod];
                            break :blk child.outputs.items[info.output];
                        },
                    };

                    switch (new_wire_v.to) {
                        .output => |idx| top.outputs.items[idx] = from_value,
                        .module => |info| {
                            const child = &top.body.custom.items[info.mod];
                            child.inputs.items[info.input] = from_value;
                            try propagateLogic(alloc, &modules, child, info.input);
                        },
                    }
                }
            }

            drag = .none;
        }

        switch (drag) {
            .module => |drag_v| {
                const dragged_child = &top_mod.body.custom.children.items[drag_v.mod];
                dragged_child.pos = mouse.add(drag_v.offset);
            },
            else => {},
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

        for (top.body.custom.items, top_mod.body.custom.children.items) |*child, *child_info| {
            const mod = &modules[child.mod_idx];

            rl.drawRectangleV(child_info.pos, mod.size, mod.color);

            for (0..mod.input_cnt) |i|
                rl.drawCircleV(mod.input_pos(child_info.pos, i), portRadius, .gray);

            for (0..mod.output_cnt) |i|
                rl.drawCircleV(mod.output_pos(child_info.pos, i), portRadius, .gray);

            const FONT_SIZE = 30;
            const FONT_SPACING = FONT_SIZE * 0.1;

            const text_size = rl.measureTextEx(font, mod.name, FONT_SIZE, FONT_SPACING);

            rl.drawTextEx(
                font,
                mod.name,
                .init(
                    child_info.pos.x + (mod.size.x / 2) - (text_size.x / 2),
                    child_info.pos.y + (mod.size.y / 2) - (text_size.y / 2),
                ),
                FONT_SIZE,
                FONT_SPACING,
                .white,
            );
        }

        for (top_mod.body.custom.wires.items) |*wire| {
            const from_pos: Vector2 = switch (wire.from) {
                .input => |i| top_input_pos(top_mod.input_cnt, i),
                .module => |*info| blk: {
                    const child = top_mod.body.custom.children.items[info.mod];
                    const child_mod = &modules[child.mod_idx];
                    break :blk child_mod.output_pos(child.pos, info.output);
                },
            };

            const to_pos: Vector2 = switch (wire.to) {
                .output => |i| top_output_pos(top_mod.output_cnt, i),
                .module => |*info| blk: {
                    const child = top_mod.body.custom.children.items[info.mod];
                    const child_mod = &modules[child.mod_idx];
                    break :blk child_mod.input_pos(child.pos, info.input);
                },
            };

            const is_on = switch (wire.from) {
                .input => |i| top.inputs.items[i],
                .module => |*info| top.body.custom.items[info.mod].outputs.items[info.output],
            };

            rl.drawLineEx(from_pos, to_pos, 5, if (is_on) .red else .dark_gray);
        }

        switch (drag) {
            .wire_from => |from| {
                const from_pos = switch (from) {
                    .input => |i| top_input_pos(top_mod.input_cnt, i),
                    .module => |info| blk: {
                        const child = top_mod.body.custom.children.items[info.mod];
                        const child_mod = &modules[child.mod_idx];
                        break :blk child_mod.output_pos(child.pos, info.output);
                    },
                };

                // Only draw when mouse has been moved at least a little bit
                // from where the drag began
                if (mouse.equals(last_mouse_press) == 0)
                    rl.drawLineEx(from_pos, mouse, 5, .dark_gray);
            },
            .wire_to => |to| {
                const to_pos = switch (to) {
                    .output => |i| top_output_pos(top_mod.output_cnt, i),
                    .module => |info| blk: {
                        const child = top_mod.body.custom.children.items[info.mod];
                        const child_mod = &modules[child.mod_idx];
                        break :blk child_mod.input_pos(child.pos, info.input);
                    },
                };

                // Only draw when mouse has been moved at least a little bit
                // from where the drag began
                if (mouse.equals(last_mouse_press) == 0)
                    rl.drawLineEx(mouse, to_pos, 5, .dark_gray);
            },
            else => {},
        }
    }
}
