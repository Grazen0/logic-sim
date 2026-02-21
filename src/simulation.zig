const std = @import("std");
const core = @import("./core.zig");
const structs = @import("./structs/structs.zig");
const globals = @import("./globals.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SlotMap = structs.SlotMap;
const SecondaryMap = structs.SecondaryMap;
const Deque = structs.Deque;
const Module = core.Module;
const CustomModule = core.CustomModule;
const WireSrc = CustomModule.WireSrc;
const WireDest = CustomModule.WireDest;

fn andOp(a: bool, b: bool) bool {
    return a and b;
}

fn nandOp(a: bool, b: bool) bool {
    return !(a and b);
}

fn orOp(a: bool, b: bool) bool {
    return a or b;
}

fn norOp(a: bool, b: bool) bool {
    return !(a or b);
}

fn xorOp(a: bool, b: bool) bool {
    return a ^ b;
}

pub const ModuleInstance = union(enum) {
    const Self = @This();

    logic_gate: struct {
        kind: Module.LogicGate.Kind,
        inputs: ArrayList(bool),
        output: bool,

        pub fn update(self: *@This()) void {
            const op: *const fn (bool, bool) bool = switch (self.kind) {
                .@"and" => andOp,
                .nand => nandOp,
                .@"or" => orOp,
                .nor => norOp,
                .xor => xorOp,
            };

            self.output = self.inputs.items[0];

            for (self.inputs.items[1..]) |b|
                self.output = op(self.output, b);
        }
    },
    not_gate: struct {
        in: bool,
        out: bool,

        pub fn update(self: *@This()) void {
            self.out = !self.in;
        }
    },
    custom: CustomModuleInstance,

    pub fn fromModule(gpa: Allocator, module_v: *const Module) error{OutOfMemory}!Self {
        var inst: ModuleInstance = switch (module_v.*) {
            .logic_gate => |gate| blk: {
                var inst: ModuleInstance = .{
                    .logic_gate = .{
                        .kind = gate.kind,
                        .inputs = .empty,
                        .output = undefined,
                    },
                };

                try inst.logic_gate.inputs.appendNTimes(gpa, false, gate.input_cnt);
                break :blk inst;
            },
            .not_gate => .{
                .not_gate = .{
                    .in = false,
                    .out = undefined,
                },
            },
            .custom => |mod_key| .{
                .custom = try .fromModuleNoUpdate(gpa, mod_key),
            },
        };

        try inst.update(gpa);
        return inst;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .logic_gate => |*gate| gate.inputs.deinit(gpa),
            .not_gate => {},
            .custom => |*custom| custom.deinit(gpa),
        }
    }

    pub fn update(self: *Self, gpa: Allocator) !void {
        switch (self.*) {
            .logic_gate => |*gate| gate.update(),
            .not_gate => |*gate| gate.update(),
            .custom => |*custom| try custom.update(gpa),
        }
    }

    pub fn writeInputUpdate(self: *Self, gpa: Allocator, input_key: CustomModule.ChildInput.I, value: bool) ![]CustomModule.ChildOutput.O {
        var affected_outputs: ArrayList(CustomModule.ChildOutput.O) = .empty;

        switch (self.*) {
            .logic_gate => |*gate_inst| {
                gate_inst.inputs.items[input_key.logic_gate] = value;

                const prev_output = gate_inst.output;
                gate_inst.update();

                if (gate_inst.output != prev_output)
                    try affected_outputs.append(gpa, .logic_gate);
            },
            .not_gate => |*gate_inst| {
                if (gate_inst.in != value) {
                    gate_inst.in = value;
                    gate_inst.out = !value;

                    try affected_outputs.append(gpa, .not_gate);
                }
            },
            .custom => |*custom_inst| {
                _ = custom_inst.inputs.putAssumeCapacity(input_key.custom, value);

                var prev_outputs = try custom_inst.outputs.clone(gpa);
                defer prev_outputs.deinit(gpa);

                try custom_inst.updateFromSrcs(gpa, &.{.{ .top_input = input_key.custom }});

                var output_iter = prev_outputs.const_iterator();
                while (output_iter.next()) |entry| {
                    const output_key = entry.key;
                    const prev_output = entry.val.*;
                    const new_output = custom_inst.outputs.get(output_key).?.*;

                    if (prev_output != new_output)
                        try affected_outputs.append(gpa, .{ .custom = output_key });
                }
            },
        }

        return affected_outputs.toOwnedSlice(gpa);
    }
};

pub const CustomModuleInstance = struct {
    const Self = @This();

    mod_key: CustomModule.Key,
    inputs: SecondaryMap(CustomModule.InputKey, bool),
    outputs: SecondaryMap(CustomModule.OutputKey, bool),
    children: SecondaryMap(CustomModule.Child.Key, ModuleInstance),

    pub fn fromModuleNoUpdate(gpa: Allocator, mod_key: CustomModule.Key) !Self {
        const mod = globals.modules.get(mod_key).?;

        var out: Self = .{
            .mod_key = mod_key,
            .inputs = .empty,
            .outputs = .empty,
            .children = .empty,
        };

        var input_iter = mod.inputs.const_iterator();
        while (input_iter.nextKey()) |input_key|
            _ = try out.inputs.put(gpa, input_key, false);

        var output_iter = mod.outputs.const_iterator();
        while (output_iter.nextKey()) |output_key|
            _ = try out.outputs.put(gpa, output_key, false);

        var children_iter = mod.children.const_iterator();
        while (children_iter.next()) |entry| {
            const child_inst: ModuleInstance = try .fromModule(gpa, &entry.val.mod);
            _ = try out.children.put(gpa, entry.key, child_inst);

            var wire_iter = mod.wires.const_iterator();
            while (wire_iter.nextValue()) |wire| {
                if (wire.to == .child_input and wire.to.child_input.child_key.equals(entry.key))
                    try out.updateFromSrcs(gpa, &.{wire.from});
            }
        }

        return out;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);

        var children_iter = self.children.iterator();
        while (children_iter.nextValue()) |child|
            child.deinit(gpa);

        self.children.deinit(gpa);

        self.* = undefined;
    }

    pub fn updateFromSrcs(self: *Self, gpa: Allocator, srcs: []const WireSrc) error{OutOfMemory}!void {
        const self_mod = globals.modules.get(self.mod_key).?;

        var queue: Deque(WireSrc) = .empty;
        defer queue.deinit(gpa);

        for (srcs) |src|
            try queue.pushBack(gpa, src);

        while (queue.popFront()) |src| {
            // orelse can occur while instantiating a new child on a module
            // instance that is currently in the middle of initializing.
            const src_value = self.readWireSrc(src) orelse false;

            var wires_iter = self_mod.wires.const_iterator();
            while (wires_iter.nextValue()) |wire| {
                if (!wire.from.equals(&src))
                    continue;

                switch (wire.to) {
                    .top_output => |key| _ = self.outputs.putAssumeCapacity(key, src_value),
                    .child_input => |to| {
                        const child_inst = self.children.get(to.child_key).?;
                        const affected = try child_inst.writeInputUpdate(gpa, to.input, src_value);
                        defer gpa.free(affected);

                        for (affected) |affected_output| {
                            try queue.pushBack(gpa, .{
                                .child_output = .{
                                    .child_key = to.child_key,
                                    .output = affected_output,
                                },
                            });
                        }
                    },
                }
            }
        }
    }

    pub fn update(self: *Self, gpa: Allocator) !void {
        var srcs = try gpa.alloc(WireSrc, self.inputs.size);
        defer gpa.free(srcs);

        var input_iter = self.inputs.const_iterator();
        var i: usize = 0;
        while (input_iter.nextKey()) |input_key| : (i += 1)
            srcs[i] = .{ .top_input = input_key };

        try self.updateFromSrcs(gpa, srcs);
    }

    fn writeChildInput(self: *const Self, gpa: Allocator, key: CustomModule.ChildInput, value: bool) ![]CustomModule.ChildOutput.O {
        const child = self.children.get(key.child_key).?;
        return try child.writeInputUpdate(gpa, key.input, value);
    }

    fn readChildOutput(self: *const Self, key: CustomModule.ChildOutput) ?bool {
        const child = self.children.get(key.child_key) orelse return null;

        return switch (child.*) {
            .logic_gate => child.logic_gate.output,
            .not_gate => child.not_gate.out,
            .custom => child.custom.outputs.get(key.output.custom).?.*,
        };
    }

    pub fn readWireSrc(self: *const Self, src: WireSrc) ?bool {
        return switch (src) {
            .top_input => |input_key| self.inputs.get(input_key).?.*,
            .child_output => |keys| self.readChildOutput(keys),
        };
    }

    pub fn writeWireDestUpdate(self: *Self, gpa: Allocator, dest: WireDest, value: bool) !void {
        switch (dest) {
            .top_output => |key| _ = self.outputs.putAssumeCapacity(key, value),
            .child_input => |key| {
                const affected = try self.writeChildInput(gpa, key, value);
                defer gpa.free(affected);

                var starts = try gpa.alloc(WireSrc, affected.len);
                defer gpa.free(starts);

                for (0.., affected) |i, output| {
                    starts[i] = .{
                        .child_output = .{
                            .child_key = key.child_key,
                            .output = output,
                        },
                    };
                }

                try self.updateFromSrcs(gpa, starts);
            },
        }
    }
};
