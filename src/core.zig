const std = @import("std");
const rl = @import("raylib");
const structs = @import("./structs/structs.zig");
const globals = @import("./globals.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Color = rl.Color;
const SlotMap = structs.SlotMap;

const assert = std.debug.assert;

pub const Module = union(enum) {
    const Self = @This();

    pub const LogicGate = struct {
        pub const Kind = enum { @"and", nand, @"or", nor, xor };

        kind: Kind,
        input_cnt: usize,
    };

    pub const LogicGateSettings = struct {
        input_cnt: usize,
    };

    pub const Settings = union(enum) {
        logic_gate: LogicGateSettings,
    };

    logic_gate: LogicGate,
    not_gate,
    custom: CustomModule.Key,

    pub fn currentSettings(self: *const Self) ?Settings {
        return switch (self.*) {
            .logic_gate => |*gate| .{ .logic_gate = .{ .input_cnt = gate.input_cnt } },
            .not_gate, .custom => null,
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
    };

    pub const Key = SlotMap(Self).Key;
    pub const InputKey = SlotMap(Input).Key;
    pub const OutputKey = SlotMap(Output).Key;
    pub const WireKey = SlotMap(Wire).Key;

    pub const ChildInput = struct {
        pub const I = union(enum) {
            logic_gate: usize,
            not_gate,
            custom: InputKey,
        };

        child_key: Child.Key,
        input: I,

        pub fn equals(self: @This(), other: @This()) bool {
            if (!self.child_key.equals(other.child_key))
                return false;

            return switch (self.input) {
                .logic_gate => |i| other.input == .logic_gate and other.input.logic_gate == i,
                .not_gate => other.input == .not_gate,
                .custom => |key| other.input == .custom and other.input.custom.equals(key),
            };
        }
    };

    pub const ChildOutput = struct {
        pub const O = union(enum) {
            logic_gate,
            not_gate,
            custom: OutputKey,
        };

        child_key: Child.Key,
        output: O,

        pub fn equals(self: @This(), other: @This()) bool {
            if (!self.child_key.equals(other.child_key))
                return false;

            return switch (self.output) {
                .custom => |key| other.output == .custom and other.output.custom.equals(key),
                .logic_gate => other.output == .logic_gate,
                .not_gate => other.output == .not_gate,
            };
        }
    };

    pub const WireSrc = union(enum) {
        top_input: InputKey,
        child_output: ChildOutput,

        pub fn equals(self: *const @This(), other: *const @This()) bool {
            return switch (self.*) {
                .top_input => |key| other.* == .top_input and other.top_input.equals(key),
                .child_output => |key| other.* == .child_output and other.child_output.equals(key),
            };
        }
    };

    pub const WireDest = union(enum) {
        top_output: OutputKey,
        child_input: ChildInput,

        pub fn equals(self: *const @This(), other: *const @This()) bool {
            return switch (self.*) {
                .top_output => |key| other.* == .top_output and other.top_output.equals(key),
                .child_input => |key| other.* == .child_input and other.child_input.equals(key),
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

    pub const Input = struct {
        name: ?[:0]u8,
        width: usize,
        pos: f32,

        fn deinit(self: *@This(), gpa: Allocator) void {
            if (self.name) |name|
                gpa.free(name);

            self.* = undefined;
        }
    };

    pub const Output = struct {
        name: ?[:0]u8,
        width: usize,
        pos: f32,

        fn deinit(self: *@This(), gpa: Allocator) void {
            if (self.name) |name|
                gpa.free(name);

            self.* = undefined;
        }
    };

    name: [:0]u8,
    color: Color,
    inputs: SlotMap(Input),
    outputs: SlotMap(Output),
    children: SlotMap(Child),
    wires: SlotMap(Wire),

    pub fn deinit(self: *Self, gpa: Allocator) void {
        var input_iter = self.inputs.iterator();
        while (input_iter.nextValue()) |input|
            input.deinit(gpa);

        var output_iter = self.outputs.iterator();
        while (output_iter.nextValue()) |output|
            output.deinit(gpa);

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

    pub fn wireSrcWidth(self: *const Self, src: WireSrc) usize {
        switch (src) {
            .top_input => |input_key| return self.inputs.get(input_key).?.width,
            .child_output => |keys| {
                const child = self.children.get(keys.child_key).?;
                return switch (child.mod) {
                    .logic_gate, .not_gate => return 1,
                    .custom => |mod_key| {
                        const mod = globals.modules.get(mod_key).?;
                        return mod.outputs.get(keys.output.custom).?.width;
                    },
                };
            },
        }
    }

    pub fn wireDestWidth(self: *const Self, dest: WireDest) usize {
        switch (dest) {
            .top_output => |output_key| return self.outputs.get(output_key).?.width,
            .child_input => |keys| {
                const child = self.children.get(keys.child_key).?;
                switch (child.mod) {
                    .logic_gate, .not_gate => return 1,
                    .custom => |mod_key| {
                        const mod = globals.modules.get(mod_key).?;
                        return mod.inputs.get(keys.input.custom).?.width;
                    },
                }
            },
        }
    }

    pub fn wireWidth(self: *const Self, wire: *const Wire) usize {
        const src_width = self.wireSrcWidth(wire.from);
        const dest_width = self.wireDestWidth(wire.to);
        assert(src_width == dest_width);
        return src_width;
    }

    pub fn addWireOrModifyExisting(self: *Self, gpa: Allocator, wire: Wire) !WireKey {
        var iter = self.wires.iterator();
        while (iter.next()) |entry| {
            const other_wire = entry.val;

            if (wire.to.equals(&other_wire.to)) {
                other_wire.deinit(gpa);
                other_wire.* = wire;
                return entry.key;
            }
        }

        return try self.wires.put(gpa, wire);
    }

    pub fn dependsOn(mod_key: Key, search_key: Key) bool {
        if (mod_key.equals(search_key))
            return true;

        const mod = globals.modules.get(mod_key).?;

        var iter = mod.children.const_iterator();
        while (iter.nextValue()) |child| {
            if (child.mod == .custom and Self.dependsOn(child.mod.custom, search_key))
                return true;
        }

        return false;
    }
};
