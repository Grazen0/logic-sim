const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const sim = @import("../simulation.zig");
const math = @import("../math.zig");
const structs = @import("../structs/structs.zig");
const globals = @import("../globals.zig");
const Module = @import("../Module.zig");
const GameContext = @import("../GameContext.zig");

const Allocator = std.mem.Allocator;
const Vector2 = rl.Vector2;
const Rectangle = rl.Rectangle;
const Color = rl.Color;
const SlotMap = structs.SlotMap;
const ModuleInstance = sim.ModuleInstance;

const colors = globals.colors;

const wireThickness = 5;
const portRadius = 12;
const topPortRadius = 20;

const DragInfo = union(enum) {
    none,
    module: struct {
        child_key: Module.ChildKey,
        offset: Vector2,
    },
    wire_from: Module.WireSrc,
    wire_to: Module.WireDest,
};

const HoverInfo = union(enum) {
    none,
    top_input: usize,
    top_output: usize,
    mod_input: Module.InputKey,
    mod_output: Module.OutputKey,
    module: Module.ChildKey,
};

ctx: *GameContext,
top: ModuleInstance,
drag: DragInfo,

pub fn init(gpa: Allocator, ctx: *GameContext, mod_key: Module.Key) !Self {
    return .{
        .ctx = ctx,
        .top = try .fromModule(gpa, &ctx.modules, mod_key),
        .drag = .none,
    };
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.top.deinit(gpa);
    self.* = undefined;
}

pub fn frame(self: *Self, gpa: Allocator) !void {
    const mouse = rl.getMousePosition();
    const hover = self.getHoverInfo(mouse);

    if (rl.isMouseButtonPressed(.left)) {
        self.onClick(hover, mouse);
    } else if (rl.isMouseButtonReleased(.left)) {
        try self.onUnclick(gpa, hover);
    }

    if (rl.isKeyPressed(.caps_lock)) { // TODO: change to escape at some point
        self.ctx.next_scene = .selector;
        return;
    }

    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    switch (self.drag) {
        .module => |drag_v| {
            const dragged_child = top_mod.body.custom.children.get(drag_v.child_key).?;
            dragged_child.pos = mouse.add(drag_v.offset);
        },
        else => {},
    }

    try self.draw(mouse);
}

fn draw(self: *Self, mouse: Vector2) !void {
    rl.clearBackground(colors.background);

    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    var wire_iter = top_mod.body.custom.wires.iterator();

    while (wire_iter.nextValue()) |wire| {
        const wire_value = self.top.readWireSrc(wire.from).?;
        const from_pos = getWireSrcPos(&self.ctx.modules, top_mod, &wire.from);
        const to_pos = getWireDestPos(&self.ctx.modules, top_mod, &wire.to);
        rl.drawLineEx(from_pos, to_pos, wireThickness, logicColor(wire_value));
    }

    switch (self.drag) {
        .wire_from => |from| {
            const from_value = self.top.readWireSrc(from).?;
            const from_pos = getWireSrcPos(&self.ctx.modules, top_mod, &from);
            rl.drawLineEx(from_pos, mouse, wireThickness, logicColor(from_value));
        },
        .wire_to => |to| {
            const to_pos = getWireDestPos(&self.ctx.modules, top_mod, &to);
            rl.drawLineEx(mouse, to_pos, wireThickness, logicColor(false));
        },
        else => {},
    }

    for (0..top_mod.input_cnt) |i| {
        const value = self.top.inputs.items[i];
        const pos = topInputPos(top_mod.input_cnt, i);
        rl.drawCircleV(pos, topPortRadius, logicColor(value));
    }

    for (0..top_mod.output_cnt) |i| {
        const value = self.top.outputs.items[i];
        const pos = topOutputPos(top_mod.output_cnt, i);
        rl.drawCircleV(pos, topPortRadius, logicColor(value));
    }

    var child_iter = top_mod.body.custom.children.iterator();

    while (child_iter.next()) |entry| {
        const child = entry.val;
        const mod = self.ctx.modules.get(child.mod_key).?;

        rl.drawRectangleV(child.pos, mod.size, mod.color);

        for (0..mod.input_cnt) |i|
            rl.drawCircleV(inputPos(mod, child.pos, i), portRadius, colors.port);

        for (0..mod.output_cnt) |i|
            rl.drawCircleV(outputPos(mod, child.pos, i), portRadius, colors.port);

        const font = try rl.getFontDefault();
        const text_size = rl.measureTextEx(font, mod.name, globals.fontSize, globals.fontSpacing);

        rl.drawTextEx(
            font,
            mod.name,
            .init(
                child.pos.x + (mod.size.x / 2) - (text_size.x / 2),
                child.pos.y + (mod.size.y / 2) - (text_size.y / 2),
            ),
            globals.fontSize,
            globals.fontSpacing,
            colors.text,
        );
    }
}

fn onClick(self: *Self, hover: HoverInfo, mouse: Vector2) void {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    switch (hover) {
        .none => {},
        .top_input => |idx| self.drag = .{ .wire_from = .{ .top_input = idx } },
        .top_output => |idx| self.drag = .{ .wire_to = .{ .top_output = idx } },
        .module => |child_key| self.drag = .{
            .module = .{
                .child_key = child_key,
                .offset = top_mod.body.custom.children.get(child_key).?.pos.subtract(mouse),
            },
        },
        .mod_input => |info| self.drag = .{ .wire_to = .{ .mod_input = info } },
        .mod_output => |info| self.drag = .{ .wire_from = .{ .mod_output = info } },
    }
}

fn onUnclick(self: *Self, gpa: Allocator, hover: HoverInfo) !void {
    switch (hover) {
        .top_input => |input| {
            self.top.inputs.items[input] = !self.top.inputs.items[input];
            try self.top.propagateLogic(gpa, &self.ctx.modules, .{ .top_input = input });
        },
        else => {},
    }

    const new_wire: ?Module.Wire = switch (self.drag) {
        .none, .module => null,
        .wire_from => |from| switch (hover) {
            .mod_input => |info| .init(from, .{ .mod_input = info }),
            .top_output => |idx| .init(from, .{ .top_output = idx }),
            else => null,
        },
        .wire_to => |to| switch (hover) {
            .mod_output => |info| .init(.{ .mod_output = info }, to),
            .top_input => |idx| .init(.{ .top_input = idx }, to),
            else => null,
        },
    };

    if (new_wire) |new_wire_v| {
        const top_mod = self.ctx.modules.get(self.top.mod_key).?;
        try top_mod.body.custom.addWire(gpa, new_wire_v);
        try self.top.propagateLogic(gpa, &self.ctx.modules, new_wire_v.from);
    }

    self.drag = .none;
}

fn getHoverInfo(self: *const Self, mouse: Vector2) HoverInfo {
    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    for (0..top_mod.input_cnt) |input| {
        const input_pos = topInputPos(top_mod.input_cnt, input);

        if (mouse.distance(input_pos) <= topPortRadius)
            return .{ .top_input = input };
    }

    for (0..top_mod.output_cnt) |output| {
        const output_pos = topOutputPos(top_mod.output_cnt, output);

        if (mouse.distance(output_pos) <= topPortRadius)
            return .{ .top_output = output };
    }

    var iter = top_mod.body.custom.children.iterator();

    while (iter.next()) |entry| {
        const child = entry.val;
        const child_mod = self.ctx.modules.get(child.mod_key).?;

        for (0..child_mod.input_cnt) |input| {
            const input_pos = inputPos(child_mod, child.pos, input);

            if (mouse.distance(input_pos) <= portRadius)
                return .{ .mod_input = .{ .child_key = entry.key, .input = input } };
        }

        for (0..child_mod.output_cnt) |output| {
            const output_pos = outputPos(child_mod, child.pos, output);

            if (mouse.distance(output_pos) <= portRadius)
                return .{ .mod_output = .{ .child_key = entry.key, .output = output } };
        }

        const rect: Rectangle = .init(child.pos.x, child.pos.y, child_mod.size.x, child_mod.size.y);

        if (math.checkVec2RectCollision(mouse, rect))
            return .{ .module = entry.key };
    }

    return .none;
}

fn inputPos(module: *const Module, base_pos: Vector2, idx: usize) Vector2 {
    return .init(
        base_pos.x,
        base_pos.y - portRadius + math.interpolate(module.input_cnt, idx, module.size.y + (2 * portRadius)),
    );
}

fn outputPos(module: *const Module, base_pos: Vector2, idx: usize) Vector2 {
    return .init(
        base_pos.x + module.size.x,
        base_pos.y - portRadius + math.interpolate(module.output_cnt, idx, module.size.y + (2 * portRadius)),
    );
}

fn topInputPos(input_cnt: usize, input: usize) Vector2 {
    return .init(
        2 * topPortRadius,
        math.interpolate(input_cnt, input, globals.screenHeight),
    );
}

fn topOutputPos(output_cnt: usize, input: usize) Vector2 {
    return .init(
        globals.screenWidth - (2 * topPortRadius),
        math.interpolate(output_cnt, input, globals.screenHeight),
    );
}

fn getWireSrcPos(modules: *const SlotMap(Module), top_mod: *const Module, src: *const Module.WireSrc) Vector2 {
    switch (src.*) {
        .top_input => |i| return topInputPos(top_mod.input_cnt, i),
        .mod_output => |*key| {
            const child = top_mod.body.custom.children.get(key.child_key).?;
            const child_mod = modules.get(child.mod_key).?;
            return outputPos(child_mod, child.pos, key.output);
        },
    }
}

fn getWireDestPos(modules: *const SlotMap(Module), top_mod: *const Module, dest: *const Module.WireDest) Vector2 {
    switch (dest.*) {
        .top_output => |i| return topOutputPos(top_mod.output_cnt, i),
        .mod_input => |info| {
            const child = top_mod.body.custom.children.get(info.child_key).?;
            const child_mod = modules.get(child.mod_key).?;
            return inputPos(child_mod, child.pos, info.input);
        },
    }
}

fn logicColor(value: bool) Color {
    return if (value) colors.logic_on else colors.logic_off;
}
