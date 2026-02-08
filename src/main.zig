const std = @import("std");
const rl = @import("raylib");
const ls = @import("logic_sim");

const screenWidth = 1280;
const screenHeight = 720;
const portRadius = 12;
const topPortRadius = 20;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;
const Deque = ls.Deque;
const SlotMap = ls.SlotMap;
const SecondaryMap = ls.SecondaryMap;

const ModuleKey = SlotMap(Module).Key;
const ChildKey = SlotMap(ModuleChild).Key;
const WireKey = SlotMap(Wire).Key;

const ModuleInputInfo = struct {
    const Self = @This();

    child_key: ChildKey,
    input: usize,

    pub fn equals(self: Self, other: Self) bool {
        return self.child_key.equals(other.child_key) and self.input == other.input;
    }
};

const ModuleOutputInfo = struct {
    const Self = @This();

    child_key: ChildKey,
    output: usize,

    pub fn equals(self: Self, other: Self) bool {
        return self.child_key.equals(other.child_key) and self.output == other.output;
    }
};

const WireSrc = union(enum) {
    const Self = @This();

    top_input: usize,
    mod_output: ModuleOutputInfo,

    fn equals(self: *const Self, other: *const Self) bool {
        return switch (self.*) {
            .top_input => |i| switch (other.*) {
                .top_input => |j| i == j,
                else => false,
            },
            .mod_output => |info_1| switch (other.*) {
                .mod_output => |info_2| info_1.equals(info_2),
                else => false,
            },
        };
    }
};

const WireDest = union(enum) {
    const Self = @This();

    top_output: usize,
    mod_input: ModuleInputInfo,

    fn equals(self: *const Self, other: *const Self) bool {
        return switch (self.*) {
            .top_output => |i| switch (other.*) {
                .top_output => |j| i == j,
                else => false,
            },
            .mod_input => |info_1| switch (other.*) {
                .mod_input => |info_2| info_1.equals(info_2),
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

fn topInputPos(input_cnt: usize, input: usize) Vector2 {
    return .init(
        2 * topPortRadius,
        interpolate(input_cnt, input, screenHeight),
    );
}

fn topOutputPos(output_cnt: usize, input: usize) Vector2 {
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

    fn inputPos(self: *const Self, base_pos: Vector2, idx: usize) Vector2 {
        return .init(
            base_pos.x,
            base_pos.y - portRadius + interpolate(self.input_cnt, idx, self.size.y + (2 * portRadius)),
        );
    }

    fn outputPos(self: *const Self, base_pos: Vector2, idx: usize) Vector2 {
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

const ModuleChild = struct {
    pos: Vector2,
    mod_key: ModuleKey,
};

const CustomModuleBody = struct {
    const Self = @This();

    children: SlotMap(ModuleChild),
    wires: SlotMap(Wire),

    fn addWire(self: *Self, gpa: Allocator, wire: Wire) !void {
        var iter = self.wires.iterator();
        while (iter.nextValue()) |other_wire| {
            if (wire.to.equals(&other_wire.to)) {
                other_wire.from = wire.from;
                return;
            }
        }

        _ = try self.wires.put(gpa, wire);
    }

    fn deinit(self: *Self, gpa: Allocator) void {
        self.children.deinit(gpa);
        self.wires.deinit(gpa);
    }
};

const ModuleInstance = struct {
    const Self = @This();

    mod_key: ModuleKey,
    inputs: ArrayList(bool),
    outputs: ArrayList(bool),
    body: ModuleInstanceBody,

    fn fromModule(gpa: Allocator, modules: *const SlotMap(Module), mod_key: ModuleKey) !Self {
        const mod = modules.get(mod_key) orelse return error.ModuleNotFound;

        var out: Self = .{
            .mod_key = mod_key,
            .inputs = .empty,
            .outputs = .empty,
            .body = switch (mod.body) {
                .primitive => .primitive,
                .custom => |*mod_body| blk: {
                    var inst_children: SecondaryMap(ChildKey, Self) = .empty;

                    var iter = mod_body.children.iterator();

                    while (iter.next()) |entry| {
                        const child_inst = try Self.fromModule(gpa, modules, entry.val.mod_key);
                        _ = try inst_children.put(gpa, entry.key, child_inst);
                    }

                    break :blk .{ .custom = inst_children };
                },
            },
        };

        try out.inputs.appendNTimes(gpa, false, mod.input_cnt);
        try out.outputs.appendNTimes(gpa, false, mod.output_cnt);

        for (0..mod.input_cnt) |i|
            try out.propagateLogic(gpa, modules, .{ .top_input = i });

        return out;
    }

    fn propagateLogic(self: *ModuleInstance, gpa: Allocator, modules: *const SlotMap(Module), start: WireSrc) !void {
        const self_mod = modules.get(self.mod_key) orelse return error.ModuleNotFound;

        switch (self_mod.body) {
            .primitive => |func| func(&self.inputs, &self.outputs),
            .custom => |mod_body| {
                var queue: Deque(WireSrc) = .empty;
                defer queue.deinit(gpa);

                try queue.pushBack(gpa, start);

                while (queue.popFront()) |src| {
                    const src_value = self.readWireSrc(src).?;

                    var wires_iter = mod_body.wires.const_iterator();

                    while (wires_iter.nextValue()) |wire| {
                        if (!wire.from.equals(&src))
                            continue;

                        switch (wire.to) {
                            .top_output => |i| self.outputs.items[i] = src_value,
                            .mod_input => |to| {
                                const child_inst = self.body.custom.get(to.child_key) orelse return error.InstanceNotFound;
                                child_inst.inputs.items[to.input] = src_value;

                                var prev_outputs = try child_inst.outputs.clone(gpa);
                                defer prev_outputs.deinit(gpa);

                                try child_inst.propagateLogic(gpa, modules, .{ .top_input = to.input });

                                for (0.., prev_outputs.items, child_inst.outputs.items) |i, prev, new| {
                                    if (prev != new) {
                                        try queue.pushBack(gpa, .{
                                            .mod_output = .{
                                                .child_key = to.child_key,
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

    fn readChildInput(self: *const Self, info: ModuleInputInfo) ?bool {
        const child = self.body.custom.get(info.child_key) orelse return null;
        return child.inputs.items[info.input];
    }

    fn readChildOutput(self: *const Self, info: ModuleOutputInfo) ?bool {
        const child = self.body.custom.get(info.child_key) orelse return null;
        return child.outputs.items[info.output];
    }

    fn readWireSrc(self: *const Self, src: WireSrc) ?bool {
        return switch (src) {
            .top_input => |i| self.inputs.items[i],
            .mod_output => |info| self.readChildOutput(info),
        };
    }

    fn readWireDest(self: *const Self, dest: WireDest) ?bool {
        return switch (dest) {
            .top_output => |i| self.outputs.items[i],
            .mod_input => |info| self.readChildInput(info),
        };
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
    custom: SecondaryMap(ChildKey, ModuleInstance),

    fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .primitive => {},
            .custom => |*children| {
                var iter = children.iterator();

                while (iter.nextValue()) |child|
                    child.deinit(gpa);

                children.deinit(gpa);
            },
        }
    }
};

fn checkVec2RectCollision(v: Vector2, r: Rectangle) bool {
    return v.x >= r.x and v.x < r.x + r.width and v.y >= r.y and v.y < r.y + r.height;
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

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const alloc = gpa.allocator();

    rl.setConfigFlags(.{ .msaa_4x_hint = true, .window_highdpi = true });
    rl.initWindow(screenWidth, screenHeight, "Logic Simulator");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    var modules: SlotMap(Module) = .empty;
    defer {
        var iter = modules.iterator();
        while (iter.nextValue()) |mod|
            mod.deinit(alloc);

        modules.deinit(alloc);
    }

    _ = try modules.put(alloc, .{
        .name = "and",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .red,
        .body = .{ .primitive = andFunc },
    });

    _ = try modules.put(alloc, .{
        .name = "or",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .blue,
        .body = .{ .primitive = orFunc },
    });

    _ = try modules.put(alloc, .{
        .name = "not",
        .input_cnt = 1,
        .output_cnt = 1,
        .size = .init(80, 40),
        .color = .green,
        .body = .{ .primitive = notFunc },
    });

    const nor_gate = try modules.put(alloc, .{
        .name = "nor",
        .input_cnt = 2,
        .output_cnt = 1,
        .size = .init(120, 60),
        .color = .purple,
        .body = .{ .primitive = norFunc },
    });
    const mux = try modules.put(alloc, .{
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
    });

    const top_mod = modules.get(mux).?;

    _ = try top_mod.body.custom.children.put(alloc, .{
        .pos = .init(300, 119),
        .mod_key = nor_gate,
    });
    _ = try top_mod.body.custom.children.put(alloc, .{
        .pos = .init(300, 361),
        .mod_key = nor_gate,
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

    var top = try ModuleInstance.fromModule(alloc, &modules, mux);
    defer top.deinit(alloc);

    const font = try rl.getFontDefault();

    const DragInfo = union(enum) {
        none,
        module: struct {
            child_key: ChildKey,
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
        module: ChildKey,
    };

    var drag: DragInfo = .none;
    var last_mouse_press: Vector2 = .init(0, 0);

    while (!rl.windowShouldClose()) {
        const mouse = rl.getMousePosition();

        const hover_info: HoverInfo = blk: {
            for (0..top_mod.input_cnt) |input| {
                const input_pos = topInputPos(top_mod.input_cnt, input);

                if (mouse.distance(input_pos) <= topPortRadius)
                    break :blk .{ .top_input = input };
            }

            for (0..top_mod.output_cnt) |output| {
                const output_pos = topOutputPos(top_mod.output_cnt, output);

                if (mouse.distance(output_pos) <= topPortRadius)
                    break :blk .{ .top_output = output };
            }

            var iter = top_mod.body.custom.children.iterator();

            while (iter.next()) |entry| {
                const child = entry.val;
                const child_mod = modules.get(child.mod_key).?;

                for (0..child_mod.input_cnt) |input| {
                    const input_pos = child_mod.inputPos(child.pos, input);

                    if (mouse.distance(input_pos) <= portRadius)
                        break :blk .{ .mod_input = .{ .child_key = entry.key, .input = input } };
                }

                for (0..child_mod.output_cnt) |output| {
                    const output_pos = child_mod.outputPos(child.pos, output);

                    if (mouse.distance(output_pos) <= portRadius)
                        break :blk .{ .mod_output = .{ .child_key = entry.key, .output = output } };
                }

                const rect: Rectangle = .init(child.pos.x, child.pos.y, child_mod.size.x, child_mod.size.y);

                if (checkVec2RectCollision(mouse, rect))
                    break :blk .{ .module = entry.key };
            }

            break :blk .none;
        };

        if (rl.isMouseButtonPressed(.left)) {
            last_mouse_press = mouse;

            switch (hover_info) {
                .none => {},
                .top_input => |idx| drag = .{ .wire_from = .{ .top_input = idx } },
                .top_output => |idx| drag = .{ .wire_to = .{ .top_output = idx } },
                .module => |child_key| drag = .{
                    .module = .{
                        .child_key = child_key,
                        .offset = top_mod.body.custom.children.get(child_key).?.pos.subtract(mouse),
                    },
                },
                .mod_input => |info| drag = .{ .wire_to = .{ .mod_input = info } },
                .mod_output => |info| drag = .{ .wire_from = .{ .mod_output = info } },
            }
        } else if (rl.isMouseButtonReleased(.left)) {
            if (mouse.equals(last_mouse_press) != 0) {
                switch (hover_info) {
                    .top_input => |input| {
                        top.inputs.items[input] = !top.inputs.items[input];
                        try top.propagateLogic(alloc, &modules, .{ .top_input = input });
                    },
                    else => {},
                }
            } else {
                const new_wire: ?Wire = switch (drag) {
                    .none, .module => null,
                    .wire_from => |from| switch (hover_info) {
                        .mod_input => |info| .init(from, .{ .mod_input = info }),
                        .top_output => |idx| .init(from, .{ .top_output = idx }),
                        else => null,
                    },
                    .wire_to => |to| switch (hover_info) {
                        .mod_output => |info| .init(.{ .mod_output = info }, to),
                        .top_input => |idx| .init(.{ .top_input = idx }, to),
                        else => null,
                    },
                };

                if (new_wire) |new_wire_v| {
                    try top_mod.body.custom.addWire(alloc, new_wire_v);
                    try top.propagateLogic(alloc, &modules, new_wire_v.from);
                }
            }

            drag = .none;
        }

        switch (drag) {
            .module => |drag_v| {
                const dragged_child = top_mod.body.custom.children.get(drag_v.child_key).?;
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
                topInputPos(top_mod.input_cnt, i),
                topPortRadius,
                if (top.inputs.items[i]) .red else .gray,
            );
        }

        for (0..top_mod.output_cnt) |i| {
            rl.drawCircleV(
                topOutputPos(top_mod.output_cnt, i),
                topPortRadius,
                if (top.outputs.items[i]) .red else .gray,
            );
        }

        var child_iter = top_mod.body.custom.children.iterator();

        while (child_iter.next()) |entry| {
            const child_key = entry.key;
            const child = entry.val;
            const mod = modules.get(child.mod_key).?;

            rl.drawRectangleV(child.pos, mod.size, mod.color);

            for (0..mod.input_cnt) |i| {
                const value = top.readWireDest(.{ .mod_input = .{ .child_key = child_key, .input = i } }).?;
                rl.drawCircleV(mod.inputPos(child.pos, i), portRadius, if (value) .red else .gray);
            }

            for (0..mod.output_cnt) |i| {
                const value = top.readWireSrc(.{ .mod_output = .{ .child_key = child_key, .output = i } }).?;
                rl.drawCircleV(mod.outputPos(child.pos, i), portRadius, if (value) .red else .gray);
            }

            const FONT_SIZE = 30;
            const FONT_SPACING = FONT_SIZE * 0.1;

            const text_size = rl.measureTextEx(font, mod.name, FONT_SIZE, FONT_SPACING);

            rl.drawTextEx(
                font,
                mod.name,
                .init(
                    child.pos.x + (mod.size.x / 2) - (text_size.x / 2),
                    child.pos.y + (mod.size.y / 2) - (text_size.y / 2),
                ),
                FONT_SIZE,
                FONT_SPACING,
                .white,
            );
        }

        var wire_iter = top_mod.body.custom.wires.iterator();

        while (wire_iter.nextValue()) |wire| {
            const from_pos: Vector2 = switch (wire.from) {
                .top_input => |i| topInputPos(top_mod.input_cnt, i),
                .mod_output => |*info| blk: {
                    const child = top_mod.body.custom.children.get(info.child_key).?;
                    const child_mod = modules.get(child.mod_key).?;
                    break :blk child_mod.outputPos(child.pos, info.output);
                },
            };

            const to_pos: Vector2 = switch (wire.to) {
                .top_output => |i| topOutputPos(top_mod.output_cnt, i),
                .mod_input => |*info| blk: {
                    const child = top_mod.body.custom.children.get(info.child_key).?;
                    const child_mod = modules.get(child.mod_key).?;
                    break :blk child_mod.inputPos(child.pos, info.input);
                },
            };

            const wire_value = top.readWireSrc(wire.from).?;
            rl.drawLineEx(from_pos, to_pos, 5, if (wire_value) .red else .dark_gray);
        }

        switch (drag) {
            .wire_from => |from| {
                const from_pos = switch (from) {
                    .top_input => |i| topInputPos(top_mod.input_cnt, i),
                    .mod_output => |info| blk: {
                        const child = top_mod.body.custom.children.get(info.child_key).?;
                        const child_mod = modules.get(child.mod_key).?;
                        break :blk child_mod.outputPos(child.pos, info.output);
                    },
                };

                // Only draw when mouse has been moved at least a little bit
                // from where the drag began
                if (mouse.equals(last_mouse_press) == 0)
                    rl.drawLineEx(from_pos, mouse, 5, .dark_gray);
            },
            .wire_to => |to| {
                const to_pos = switch (to) {
                    .top_output => |i| topOutputPos(top_mod.output_cnt, i),
                    .mod_input => |info| blk: {
                        const child = top_mod.body.custom.children.get(info.child_key).?;
                        const child_mod = modules.get(child.mod_key).?;
                        break :blk child_mod.inputPos(child.pos, info.input);
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
