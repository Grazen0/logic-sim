const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const rg = @import("raygui");
const re = @import("../ray_extra.zig");
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

const wire_thickness = 5;
const port_radius = 12;
const top_port_radius = 20;

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
panel_view: Rectangle,
panel_scroll: Vector2,
panel_width: f32,

pub fn init(gpa: Allocator, ctx: *GameContext, mod_key: Module.Key) !Self {
    return .{
        .ctx = ctx,
        .top = try .fromModule(gpa, &ctx.modules, mod_key),
        .drag = .none,
        .panel_view = .init(0, 0, 0, 0),
        .panel_scroll = .init(0, 0),
        .panel_width = 0,
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

    if (rl.isKeyPressed(globals.escape_key)) {
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

    try self.drawSimulation(mouse);

    const btn_spacing = 5;

    const panel_height = 60;
    const panel_rect: Rectangle = .init(
        0,
        globals.screen_height - panel_height,
        globals.screen_width,
        panel_height,
    );
    const panel_contents: Rectangle = .init(0, 0, self.panel_width, panel_rect.height - 20);
    const panel_base = Vector2
        .init(panel_rect.x, panel_rect.y)
        .add(.init(panel_contents.x, panel_contents.y));

    _ = rg.scrollPanel(panel_rect, null, panel_contents, &self.panel_scroll, &self.panel_view);

    {
        rl.beginScissorMode(
            @intFromFloat(self.panel_view.x),
            @intFromFloat(self.panel_view.y),
            @intFromFloat(self.panel_view.width),
            @intFromFloat(self.panel_view.height),
        );
        defer rl.endScissorMode();

        var iter = self.ctx.modules.iterator();

        const btn_height = panel_contents.height - (2 * btn_spacing);
        var btn_x = panel_base.x + btn_spacing;

        while (iter.next()) |entry| {
            const mod = entry.val;
            const btn_width = 20 + @as(f32, @floatFromInt(rl.measureText(mod.name, globals.font_size)));

            const btn_pos_abs: Vector2 = .init(btn_x, panel_base.y + btn_spacing);

            btn_x += btn_width + (2 * btn_spacing);
            const btn_pos_rel = btn_pos_abs.add(self.panel_scroll);

            re.guiSetEnabled(!Module.dependsOn(&self.ctx.modules, entry.key, self.top.mod_key));
            const pressed = rg.button(.init(btn_pos_rel.x, btn_pos_rel.y, btn_width, btn_height), mod.name);
            rg.enable();

            if (pressed) {
                const child_key = try top_mod.body.custom.children.put(gpa, .{
                    .pos = .init(globals.screen_width / 2, globals.screen_height / 2),
                    .mod_key = entry.key,
                });

                _ = try self.top.body.custom.put(
                    gpa,
                    child_key,
                    try ModuleInstance.fromModule(gpa, &self.ctx.modules, entry.key),
                );
            }
        }

        self.panel_width = btn_x;
    }
}

fn drawSimulation(self: *Self, mouse: Vector2) !void {
    rl.clearBackground(colors.background);

    const top_mod = self.ctx.modules.get(self.top.mod_key).?;

    var wire_iter = top_mod.body.custom.wires.iterator();

    while (wire_iter.nextValue()) |wire| {
        const wire_value = self.top.readWireSrc(wire.from).?;
        const from_pos = getWireSrcPos(&self.ctx.modules, top_mod, &wire.from);
        const to_pos = getWireDestPos(&self.ctx.modules, top_mod, &wire.to);
        rl.drawLineEx(from_pos, to_pos, wire_thickness, logicColor(wire_value));
    }

    switch (self.drag) {
        .wire_from => |from| {
            const from_value = self.top.readWireSrc(from).?;
            const from_pos = getWireSrcPos(&self.ctx.modules, top_mod, &from);
            rl.drawLineEx(from_pos, mouse, wire_thickness, logicColor(from_value));
        },
        .wire_to => |to| {
            const to_pos = getWireDestPos(&self.ctx.modules, top_mod, &to);
            rl.drawLineEx(mouse, to_pos, wire_thickness, logicColor(false));
        },
        else => {},
    }

    for (0..top_mod.input_cnt) |i| {
        const value = self.top.inputs.items[i];
        const pos = topInputPos(top_mod.input_cnt, i);
        rl.drawCircleV(pos, top_port_radius, logicColor(value));
    }

    for (0..top_mod.output_cnt) |i| {
        const value = self.top.outputs.items[i];
        const pos = topOutputPos(top_mod.output_cnt, i);
        rl.drawCircleV(pos, top_port_radius, logicColor(value));
    }

    var child_iter = top_mod.body.custom.children.iterator();

    while (child_iter.next()) |entry| {
        const child = entry.val;
        const mod = self.ctx.modules.get(child.mod_key).?;

        const size: Vector2 = moduleSize(mod);
        rl.drawRectangleV(child.pos, size, mod.color);

        for (0..mod.input_cnt) |i|
            rl.drawCircleV(modInputPos(mod, child.pos, i), port_radius, colors.port);

        for (0..mod.output_cnt) |i|
            rl.drawCircleV(modOutputPos(mod, child.pos, i), port_radius, colors.port);

        const font = try rl.getFontDefault();

        re.drawTextAligned(
            font,
            mod.name,
            child.pos.add(size.divide(.init(2, 2))),
            globals.font_size,
            globals.font_spacing,
            colors.text,
            .center,
            .center,
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

        if (mouse.distance(input_pos) <= top_port_radius)
            return .{ .top_input = input };
    }

    for (0..top_mod.output_cnt) |output| {
        const output_pos = topOutputPos(top_mod.output_cnt, output);

        if (mouse.distance(output_pos) <= top_port_radius)
            return .{ .top_output = output };
    }

    var iter = top_mod.body.custom.children.iterator();

    while (iter.next()) |entry| {
        const child = entry.val;
        const child_mod = self.ctx.modules.get(child.mod_key).?;

        for (0..child_mod.input_cnt) |input| {
            const input_pos = modInputPos(child_mod, child.pos, input);

            if (mouse.distance(input_pos) <= port_radius)
                return .{ .mod_input = .{ .child_key = entry.key, .input = input } };
        }

        for (0..child_mod.output_cnt) |output| {
            const output_pos = modOutputPos(child_mod, child.pos, output);

            if (mouse.distance(output_pos) <= port_radius)
                return .{ .mod_output = .{ .child_key = entry.key, .output = output } };
        }

        const child_size = moduleSize(child_mod);
        const rect: Rectangle = .init(child.pos.x, child.pos.y, child_size.x, child_size.y);

        if (math.checkVec2RectCollision(mouse, rect))
            return .{ .module = entry.key };
    }

    return .none;
}

fn modInputPos(module: *const Module, base_pos: Vector2, idx: usize) Vector2 {
    const mod_size = moduleSize(module);
    return .init(
        base_pos.x,
        base_pos.y - port_radius + math.interpolate(module.input_cnt, idx, mod_size.y + (2 * port_radius)),
    );
}

fn modOutputPos(module: *const Module, base_pos: Vector2, idx: usize) Vector2 {
    const mod_size = moduleSize(module);
    return .init(
        base_pos.x + mod_size.x,
        base_pos.y - port_radius + math.interpolate(module.output_cnt, idx, mod_size.y + (2 * port_radius)),
    );
}

fn topInputPos(input_cnt: usize, input: usize) Vector2 {
    return .init(
        2 * top_port_radius,
        math.interpolate(input_cnt, input, globals.screen_height),
    );
}

fn topOutputPos(output_cnt: usize, input: usize) Vector2 {
    return .init(
        globals.screen_width - (2 * top_port_radius),
        math.interpolate(output_cnt, input, globals.screen_height),
    );
}

fn getWireSrcPos(modules: *const SlotMap(Module), top_mod: *const Module, src: *const Module.WireSrc) Vector2 {
    switch (src.*) {
        .top_input => |i| return topInputPos(top_mod.input_cnt, i),
        .mod_output => |*key| {
            const child = top_mod.body.custom.children.get(key.child_key).?;
            const child_mod = modules.get(child.mod_key).?;
            return modOutputPos(child_mod, child.pos, key.output);
        },
    }
}

fn getWireDestPos(modules: *const SlotMap(Module), top_mod: *const Module, dest: *const Module.WireDest) Vector2 {
    switch (dest.*) {
        .top_output => |i| return topOutputPos(top_mod.output_cnt, i),
        .mod_input => |info| {
            const child = top_mod.body.custom.children.get(info.child_key).?;
            const child_mod = modules.get(child.mod_key).?;
            return modInputPos(child_mod, child.pos, info.input);
        },
    }
}

fn logicColor(value: bool) Color {
    return if (value) colors.logic_on else colors.logic_off;
}

fn moduleSize(module: *const Module) Vector2 {
    const ports: f32 = @floatFromInt(@max(module.input_cnt, module.output_cnt));
    const width_extra = 20 * std.math.log2(ports + 1);
    return .init(60 + width_extra, (ports * (2 * port_radius)) + ((ports + 1) * 4));
}
