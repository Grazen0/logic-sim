const std = @import("std");
const math = @import("./math.zig");
const rl = @import("raylib");
const structs = @import("./structs/structs.zig");
const globals = @import("./globals.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Color = rl.Color;
const Rectangle = rl.Rectangle;
const SlotMap = structs.SlotMap;

const assert = std.debug.assert;

pub const Module = union(enum) {
    const Self = @This();

    pub const LogicGate = struct {
        pub const Kind = enum { @"and", nand, @"or", nor, xor };

        kind: Kind,
        input_cnt: usize,
        single_wire: bool,

        pub fn init(kind: Kind) @This() {
            return .{
                .kind = kind,
                .input_cnt = 2,
                .single_wire = false,
            };
        }
    };

    pub const LogicGateSettings = struct {
        input_cnt: usize,
        input_cnt_edit: bool,
        single_wire: bool,
    };

    pub const SplitSettings = struct {
        input_width: usize,
        input_width_edit: bool,
        output_from: usize,
        output_from_edit: bool,
        output_to: usize,
        output_to_edit: bool,
    };

    pub const Split = struct {
        input_width: usize,
        output_from: usize,
        output_to: usize,

        pub fn init(input_width: usize, output_from: usize, output_to: usize) @This() {
            return .{
                .input_width = input_width,
                .output_from = output_from,
                .output_to = output_to,
            };
        }

        pub fn outputWidth(self: @This()) usize {
            return self.output_to - self.output_from + 1;
        }

        pub fn allocFmtRange(self: @This(), gpa: Allocator) ![:0]u8 {
            return std.fmt.allocPrintSentinel(gpa, "{d}:{d}", .{ self.output_to, self.output_from }, 0);
        }
    };

    pub const JoinSettings = struct {
        pub const Input = struct {
            width: usize,
            edit: bool,
        };

        inputs: ArrayList(Input),
        panel_scroll: Vector2,
        panel_view: Rectangle,
    };

    pub const Join = struct {
        inputs: []usize,

        pub fn init(gpa: Allocator, inputs: []const usize) !@This() {
            return .{
                .inputs = try gpa.dupe(usize, inputs),
            };
        }

        pub fn clone(self: @This(), gpa: Allocator) !@This() {
            return try .init(gpa, self.inputs);
        }

        pub fn outputWidth(self: @This()) usize {
            return math.sum(usize, self.inputs);
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.inputs);
            self.* = undefined;
        }
    };

    pub const Clock = struct {
        freq: f32,

        pub fn init(freq: f32) @This() {
            return .{ .freq = freq };
        }

        pub fn allocFmtFreq(self: @This(), gpa: Allocator) ![:0]u8 {
            return std.fmt.allocPrintSentinel(gpa, "{d} Hz", .{self.freq}, 0);
        }
    };

    pub const ClockSettings = struct {
        freq: f32,
        freq_text: [32:0]u8,
        freq_edit: bool,
    };

    pub const Display = struct {
        pub const Mode = enum { hex, dec };

        input_width: usize,
        mode: Mode,

        pub fn init(input_width: usize, mode: Mode) @This() {
            return .{ .input_width = input_width, .mode = mode };
        }

        pub fn digitCount(self: @This()) usize {
            return switch (self.mode) {
                .dec => @intFromFloat(@ceil(@as(f32, @floatFromInt(self.input_width)) * std.math.log10(@as(f32, 2)))),
                .hex => (self.input_width + 3) / 4,
            };
        }
    };

    pub const DisplaySettings = struct {
        input_width: usize,
        input_width_edit: bool,
        mode_num: i32,
        mode_edit: bool,
    };

    pub const Settings = union(enum) {
        logic_gate: LogicGateSettings,
        split: SplitSettings,
        join: JoinSettings,
        clock: ClockSettings,
        display: DisplaySettings,

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            switch (self.*) {
                .join => |*join| join.inputs.deinit(gpa),
                else => {},
            }

            self.* = undefined;
        }
    };

    logic_gate: LogicGate,
    not_gate,
    split: Split,
    join: Join,
    clock: Clock,
    display: Display,
    custom: CustomModule.Key,

    pub fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .join => |*join| join.deinit(gpa),
            else => {},
        }
        self.* = undefined;
    }

    pub fn getInputTooltip(self: *const Self, input: CustomModule.InputRef) ?[:0]const u8 {
        switch (self.*) {
            .custom => |mod_key| {
                const mod = globals.modules.getPtr(mod_key).?;
                return mod.inputs.get(input.custom).?.name;
            },
            else => return null,
        }
    }

    pub fn getOutputTooltip(self: *const Self, output: CustomModule.OutputRef) ?[:0]const u8 {
        switch (self.*) {
            .custom => |mod_key| {
                const mod = globals.modules.getPtr(mod_key).?;
                return mod.outputs.get(output.custom).?.name;
            },
            else => return null,
        }
    }

    pub fn hasSettings(self: Self) bool {
        return switch (self) {
            .logic_gate => true,
            .not_gate => false,
            .split => true,
            .join => true,
            .display => true,
            .clock => true,
            .custom => false,
        };
    }

    pub fn currentSettings(self: Self, gpa: Allocator) !Settings {
        return switch (self) {
            .logic_gate => |*gate| .{
                .logic_gate = .{
                    .input_cnt = gate.input_cnt,
                    .input_cnt_edit = false,
                    .single_wire = gate.single_wire,
                },
            },
            .not_gate => unreachable,
            .split => |split| .{
                .split = .{
                    .input_width = split.input_width,
                    .input_width_edit = false,
                    .output_from = split.output_from,
                    .output_from_edit = false,
                    .output_to = split.output_to,
                    .output_to_edit = false,
                },
            },
            .join => |join| blk: {
                var inputs: ArrayList(JoinSettings.Input) = try .initCapacity(gpa, join.inputs.len);

                for (join.inputs) |width|
                    inputs.appendAssumeCapacity(.{ .width = width, .edit = false });

                break :blk .{
                    .join = .{
                        .inputs = inputs,
                        .panel_scroll = .init(0, 0),
                        .panel_view = .init(0, 0, 0, 0),
                    },
                };
            },
            .display => |display| .{
                .display = .{
                    .input_width = display.input_width,
                    .input_width_edit = false,
                    .mode_num = @intFromEnum(display.mode),
                    .mode_edit = false,
                },
            },
            .clock => |clock| blk: {
                var freq_text: [32:0]u8 = .{0} ** 32;
                _ = std.fmt.bufPrintZ(&freq_text, "{d}", .{clock.freq}) catch unreachable;

                break :blk .{
                    .clock = .{
                        .freq = clock.freq,
                        .freq_text = freq_text,
                        .freq_edit = false,
                    },
                };
            },
            .custom => unreachable,
        };
    }
};

pub const CustomModule = struct {
    const Self = @This();

    pub const Child = struct {
        pub const Key = SlotMap(@This()).Key;

        pos: Vector2,
        mod: Module,

        pub fn init(pos: Vector2, mod: Module) @This() {
            return .{ .pos = pos, .mod = mod };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            self.mod.deinit(gpa);
            self.* = undefined;
        }
    };

    pub const Key = SlotMap(Self).Key;
    pub const PortKey = SlotMap(Port).Key;
    pub const WireKey = SlotMap(Wire).Key;

    pub const InputRef = union(enum) {
        logic_gate: ?usize,
        not_gate,
        split,
        join: usize,
        display,
        custom: PortKey,
    };

    pub const ChildInputRef = struct {
        child_key: Child.Key,
        input: InputRef,

        pub fn equals(self: @This(), other: @This()) bool {
            if (!self.child_key.equals(other.child_key))
                return false;

            return switch (self.input) {
                .logic_gate => |i| other.input == .logic_gate and other.input.logic_gate == i,
                .not_gate => other.input == .not_gate,
                .split => other.input == .split,
                .join => |i| other.input == .join and other.input.join == i,
                .display => other.input == .display,
                .custom => |key| other.input == .custom and other.input.custom.equals(key),
            };
        }
    };

    pub const OutputRef = union(enum) {
        logic_gate,
        not_gate,
        split,
        join,
        clock,
        custom: PortKey,
    };

    pub const ChildOutputRef = struct {
        child_key: Child.Key,
        output: OutputRef,

        pub fn equals(self: @This(), other: @This()) bool {
            if (!self.child_key.equals(other.child_key))
                return false;

            return switch (self.output) {
                .logic_gate => other.output == .logic_gate,
                .not_gate => other.output == .not_gate,
                .split => other.output == .split,
                .join => other.output == .join,
                .clock => other.output == .clock,
                .custom => |key| other.output == .custom and other.output.custom.equals(key),
            };
        }
    };

    pub const WireSrc = union(enum) {
        top_input: PortKey,
        child_output: ChildOutputRef,

        pub fn equals(self: @This(), other: @This()) bool {
            return switch (self) {
                .top_input => |key| other == .top_input and other.top_input.equals(key),
                .child_output => |key| other == .child_output and other.child_output.equals(key),
            };
        }
    };

    pub const WireDest = union(enum) {
        top_output: PortKey,
        child_input: ChildInputRef,

        pub fn equals(self: @This(), other: @This()) bool {
            return switch (self) {
                .top_output => |key| other == .top_output and other.top_output.equals(key),
                .child_input => |key| other == .child_input and other.child_input.equals(key),
            };
        }
    };

    pub const Wire = struct {
        from: WireSrc,
        points: []Vector2,
        to: WireDest,

        pub fn init(gpa: Allocator, from: WireSrc, to: WireDest, points: []const Vector2) !@This() {
            return .{
                .from = from,
                .to = to,
                .points = try gpa.dupe(Vector2, points),
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.points);
        }
    };

    pub const Port = struct {
        name: ?[:0]u8,
        width: usize,
        order: usize,

        pub fn init(width: usize, order: usize) @This() {
            return .{
                .name = null,
                .width = width,
                .order = order,
            };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            if (self.name) |name|
                gpa.free(name);

            self.* = undefined;
        }

        pub fn clone(self: @This(), gpa: Allocator) !@This() {
            return .{
                .name = if (self.name) |name| try gpa.dupeZ(u8, name) else null,
                .width = self.width,
                .order = self.order,
            };
        }
    };

    name: [:0]u8,
    color: Color,
    inputs: SlotMap(Port),
    outputs: SlotMap(Port),
    children: SlotMap(Child),
    wires: SlotMap(Wire),

    pub fn deinit(self: *Self, gpa: Allocator) void {
        var input_iter = self.inputs.iterator();
        while (input_iter.nextValue()) |input|
            input.deinit(gpa);

        var output_iter = self.outputs.iterator();
        while (output_iter.nextValue()) |output|
            output.deinit(gpa);

        var children_iter = self.children.iterator();
        while (children_iter.nextValue()) |child|
            child.deinit(gpa);

        var wire_iter = self.wires.iterator();
        while (wire_iter.nextValue()) |wire|
            wire.deinit(gpa);

        gpa.free(self.name);
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.children.deinit(gpa);
        self.wires.deinit(gpa);

        self.* = undefined;
    }

    pub fn wireSrcWidth(self: Self, src: WireSrc) usize {
        switch (src) {
            .top_input => |input_key| return self.inputs.get(input_key).?.width,
            .child_output => |ref| {
                const child = self.children.get(ref.child_key).?;
                return switch (child.mod) {
                    .logic_gate, .not_gate, .clock => 1,
                    .split => |split| split.outputWidth(),
                    .join => |join| join.outputWidth(),
                    .display => unreachable,
                    .custom => |mod_key| blk: {
                        const mod = globals.modules.get(mod_key).?;
                        break :blk mod.outputs.get(ref.output.custom).?.width;
                    },
                };
            },
        }
    }

    pub fn wireDestWidth(self: Self, dest: WireDest) usize {
        switch (dest) {
            .top_output => |output_key| return self.outputs.get(output_key).?.width,
            .child_input => |ref| {
                const child = self.children.get(ref.child_key).?;
                return switch (child.mod) {
                    .logic_gate => |gate| if (gate.single_wire) gate.input_cnt else 1,
                    .not_gate => 1,
                    .split => |split| split.input_width,
                    .join => |join| join.inputs[ref.input.join],
                    .clock => unreachable,
                    .display => |display| display.input_width,
                    .custom => |mod_key| blk: {
                        const mod = globals.modules.get(mod_key).?;
                        break :blk mod.inputs.get(ref.input.custom).?.width;
                    },
                };
            },
        }
    }

    pub fn addWireOrModifyExisting(self: *Self, gpa: Allocator, wire: Wire) !WireKey {
        var iter = self.wires.iterator();
        while (iter.next()) |entry| {
            const other_wire = entry.val;

            if (wire.to.equals(other_wire.to)) {
                other_wire.deinit(gpa);
                other_wire.* = wire;
                return entry.key;
            }
        }

        return try self.wires.put(gpa, wire);
    }

    pub fn isWireSrcValid(self: Self, src: WireSrc) bool {
        switch (src) {
            .top_input => |input_key| return self.inputs.hasKey(input_key),
            .child_output => |ref| {
                const child = self.children.get(ref.child_key) orelse return false;

                return switch (child.mod) {
                    .logic_gate => ref.output == .logic_gate,
                    .not_gate => ref.output == .not_gate,
                    .split => ref.output == .split,
                    .join => ref.output == .join,
                    .display => false,
                    .clock => ref.output == .clock,
                    .custom => |mod_key| blk: {
                        const mod = globals.modules.get(mod_key).?;
                        break :blk mod.outputs.hasKey(ref.output.custom);
                    },
                };
            },
        }
    }

    pub fn isWireDestValid(self: Self, dest: WireDest) bool {
        switch (dest) {
            .top_output => |output_key| return self.outputs.hasKey(output_key),
            .child_input => |ref| {
                const child = self.children.get(ref.child_key) orelse return false;

                return switch (child.mod) {
                    .logic_gate => |gate| if (gate.single_wire) ref.input.logic_gate == null else ref.input.logic_gate.? < gate.input_cnt,
                    .not_gate => ref.input == .not_gate,
                    .split => ref.input == .split,
                    .join => |join| ref.input.join < join.inputs.len,
                    .display => ref.input == .display,
                    .clock => false,
                    .custom => |mod_key| blk: {
                        const mod = globals.modules.get(mod_key).?;
                        break :blk mod.inputs.hasKey(ref.input.custom);
                    },
                };
            },
        }
        return true;
    }

    pub fn isWireValid(self: Self, wire: Wire) bool {
        return self.isWireSrcValid(wire.from) and self.isWireDestValid(wire.to) and self.wireSrcWidth(wire.from) == self.wireDestWidth(wire.to);
    }

    pub fn pruneInvalidWires(self: *Self, gpa: Allocator) void {
        var iter = self.wires.constIterator();

        while (iter.next()) |entry| {
            if (!self.isWireValid(entry.val.*)) {
                var removed = self.wires.remove(entry.key).?;
                defer removed.deinit(gpa);
            }
        }
    }

    pub fn removeChildNoAffectWires(self: *Self, gpa: Allocator, child_key: Child.Key) void {
        var removed = self.children.remove(child_key).?;
        defer removed.deinit(gpa);
    }

    pub fn dependsOn(mod_key: Key, search_key: Key) bool {
        if (mod_key.equals(search_key))
            return true;

        const mod = globals.modules.get(mod_key).?;

        var iter = mod.children.constIterator();
        while (iter.nextValue()) |child| {
            if (child.mod == .custom and Self.dependsOn(child.mod.custom, search_key))
                return true;
        }

        return false;
    }
};
