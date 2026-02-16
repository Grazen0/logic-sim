const std = @import("std");
const rl = @import("raylib");
const structs = @import("./structs/structs.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Color = rl.Color;
const SlotMap = structs.SlotMap;

pub const Module = struct {
    pub const LogicGate = struct {
        pub const Kind = enum { @"and", nand, @"or", nor, xor };

        kind: Kind,
        input_cnt: usize,
    };

    pub const Inner = union(enum) {
        logic_gate: LogicGate,
        not_gate,
        custom: CustomModule.Key,
    };

    pos: Vector2,
    v: Inner,
};

pub const CustomModule = struct {
    const Self = @This();

    pub const Key = SlotMap(Self).Key;
    pub const InputKey = SlotMap(Input).Key;
    pub const OutputKey = SlotMap(Output).Key;
    pub const ChildKey = SlotMap(Module).Key;
    pub const WireKey = SlotMap(Wire).Key;

    pub const ChildInputKeys = struct {
        pub const I = union(enum) {
            logic_gate: usize,
            not_gate,
            custom: InputKey,
        };

        child_key: ChildKey,
        input: I,

        pub fn equals(self: @This(), other: @This()) bool {
            return self.child_key.equals(other.child_key) and switch (self.input) {
                .logic_gate => |i| switch (other.input) {
                    .logic_gate => |j| i == j,
                    else => false,
                },
                .not_gate => other.input == .not_gate,
                .custom => |k1| switch (other.input) {
                    .custom => |k2| k1.equals(k2),
                    else => false,
                },
            };
        }
    };

    pub const ChildOutputKeys = struct {
        pub const O = union(enum) {
            logic_gate,
            not_gate,
            custom: OutputKey,
        };

        child_key: ChildKey,
        output: O,

        pub fn equals(self: @This(), other: @This()) bool {
            return self.child_key.equals(other.child_key) and switch (self.output) {
                .custom => |k1| switch (other.output) {
                    .custom => |k2| k1.equals(k2),
                    else => false,
                },
                .logic_gate => other.output == .logic_gate,
                .not_gate => other.output == .not_gate,
            };
        }
    };

    pub const WireSrc = union(enum) {
        top_input: InputKey,
        child_output: ChildOutputKeys,

        pub fn equals(self: *const @This(), other: *const @This()) bool {
            return switch (self.*) {
                .top_input => |k1| switch (other.*) {
                    .top_input => |k2| k1.equals(k2),
                    else => false,
                },
                .child_output => |k1| switch (other.*) {
                    .child_output => |k2| k1.equals(k2),
                    else => false,
                },
            };
        }
    };

    pub const WireDest = union(enum) {
        top_output: OutputKey,
        child_input: ChildInputKeys,

        pub fn equals(self: *const @This(), other: *const @This()) bool {
            return switch (self.*) {
                .top_output => |k1| switch (other.*) {
                    .top_output => |k2| k1.equals(k2),
                    else => false,
                },
                .child_input => |k1| switch (other.*) {
                    .child_input => |k2| k1.equals(k2),
                    else => false,
                },
            };
        }
    };

    pub const Wire = struct {
        from: WireSrc,
        points: []Vector2,
        to: WireDest,

        pub fn init(gpa: Allocator, from: WireSrc, to: WireDest, points: []Vector2) !@This() {
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
        pos: f32,

        fn deinit(self: *@This(), gpa: Allocator) void {
            if (self.name) |name|
                gpa.free(name);

            self.* = undefined;
        }
    };

    pub const Output = struct {
        name: ?[:0]u8,
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
    children: SlotMap(Module),
    wires: SlotMap(Wire),

    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.name);

        var input_iter = self.inputs.iterator();
        while (input_iter.nextValue()) |input|
            input.deinit(gpa);

        var output_iter = self.outputs.iterator();
        while (output_iter.nextValue()) |output|
            output.deinit(gpa);

        self.children.deinit(gpa);

        var wire_iter = self.wires.iterator();
        while (wire_iter.nextValue()) |wire|
            wire.deinit(gpa);

        self.wires.deinit(gpa);

        self.* = undefined;
    }

    pub fn addWire(self: *@This(), gpa: Allocator, wire: Wire) !WireKey {
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

    pub fn dependsOn(modules: *const SlotMap(Self), mod_key: Key, search_key: Key) bool {
        if (mod_key.equals(search_key))
            return true;

        const mod = modules.get(mod_key).?;

        var iter = mod.children.const_iterator();
        while (iter.nextValue()) |child| {
            if (child.v == .custom and Self.dependsOn(modules, child.v.custom, search_key))
                return true;
        }

        return false;
    }
};
