const Self = @This();

const std = @import("std");
const rl = @import("raylib");
const structs = @import("./structs/structs.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Vector2 = rl.Vector2;
const Color = rl.Color;
const SlotMap = structs.SlotMap;

pub const Key = SlotMap(Self).Key;
pub const ChildKey = SlotMap(Child).Key;
pub const WireKey = SlotMap(Wire).Key;

pub const InputKey = struct {
    child_key: ChildKey,
    input: usize,

    pub fn equals(self: @This(), other: @This()) bool {
        return self.child_key.equals(other.child_key) and self.input == other.input;
    }
};

pub const OutputKey = struct {
    child_key: ChildKey,
    output: usize,

    pub fn equals(self: @This(), other: @This()) bool {
        return self.child_key.equals(other.child_key) and self.output == other.output;
    }
};

pub const WireSrc = union(enum) {
    top_input: usize,
    mod_output: OutputKey,

    pub fn equals(self: *const @This(), other: *const @This()) bool {
        return switch (self.*) {
            .top_input => |i| switch (other.*) {
                .top_input => |j| i == j,
                else => false,
            },
            .mod_output => |key_1| switch (other.*) {
                .mod_output => |key_2| key_1.equals(key_2),
                else => false,
            },
        };
    }
};

pub const WireDest = union(enum) {
    top_output: usize,
    mod_input: InputKey,

    pub fn equals(self: *const @This(), other: *const @This()) bool {
        return switch (self.*) {
            .top_output => |i| switch (other.*) {
                .top_output => |j| i == j,
                else => false,
            },
            .mod_input => |key_1| switch (other.*) {
                .mod_input => |key_2| key_1.equals(key_2),
                else => false,
            },
        };
    }
};

pub const Wire = struct {
    from: WireSrc,
    points: ArrayList(Vector2),
    to: WireDest,

    pub fn init(from: WireSrc, to: WireDest, points: ArrayList(Vector2)) @This() {
        return .{ .from = from, .to = to, .points = points };
    }

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        self.points.deinit(gpa);
    }
};

name: [:0]u8,
input_cnt: usize,
output_cnt: usize,
color: Color,
body: Body,

pub fn deinit(self: *Self, gpa: Allocator) void {
    gpa.free(self.name);
    self.body.deinit(gpa);
    self.* = undefined;
}

pub fn dependsOn(modules: *const SlotMap(Self), mod_key: Key, search_key: Key) bool {
    if (mod_key.equals(search_key))
        return true;

    const mod = modules.get(mod_key).?;

    switch (mod.body) {
        .primitive => {},
        .custom => |*body| {
            var iter = body.children.iterator();

            while (iter.nextValue()) |child| {
                if (Self.dependsOn(modules, child.mod_key, search_key))
                    return true;
            }
        },
    }

    return false;
}

pub const Body = union(enum) {
    const BooleanFunc = fn (input: *const ArrayList(bool), output: *ArrayList(bool)) void;

    primitive: *const BooleanFunc,
    custom: CustomBody,

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        switch (self.*) {
            .primitive => {},
            .custom => |*body| body.deinit(gpa),
        }

        self.* = undefined;
    }
};

pub const Child = struct {
    pos: Vector2,
    mod_key: Key,
};

pub const CustomBody = struct {
    children: SlotMap(Child),
    wires: SlotMap(Wire),

    pub fn deinit(self: *@This(), gpa: Allocator) void {
        var wire_iter = self.wires.iterator();
        while (wire_iter.nextValue()) |wire|
            wire.deinit(gpa);

        self.children.deinit(gpa);
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
};
