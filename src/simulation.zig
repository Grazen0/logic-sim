const std = @import("std");
const Module = @import("./Module.zig");
const structs = @import("./structs/structs.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SlotMap = structs.SlotMap;
const SecondaryMap = structs.SecondaryMap;
const Deque = structs.Deque;

pub const ModuleInstance = struct {
    const Self = @This();

    mod_key: Module.Key,
    inputs: ArrayList(bool),
    outputs: ArrayList(bool),
    body: ModuleInstanceBody,

    pub fn fromModule(gpa: Allocator, modules: *const SlotMap(Module), mod_key: Module.Key) !Self {
        const mod = modules.get(mod_key) orelse return error.ModuleNotFound;

        var out: Self = .{
            .mod_key = mod_key,
            .inputs = .empty,
            .outputs = .empty,
            .body = switch (mod.body) {
                .primitive => .primitive,
                .custom => .{ .custom = .empty },
            },
        };

        try out.inputs.appendNTimes(gpa, false, mod.input_cnt);
        try out.outputs.appendNTimes(gpa, false, mod.output_cnt);

        switch (mod.body) {
            .primitive => {},
            .custom => |*mod_body| {
                var iter = mod_body.children.iterator();

                while (iter.next()) |entry| {
                    const child_inst = try Self.fromModule(gpa, modules, entry.val.mod_key);
                    _ = try out.body.custom.put(gpa, entry.key, child_inst);

                    for (0..child_inst.outputs.items.len) |output| {
                        out.propagateLogic(gpa, modules, .{
                            .mod_output = .{
                                .child_key = entry.key,
                                .output = output,
                            },
                        }) catch |err| switch (err) {
                            error.InstanceNotFound => {}, // allowed to happen at this stage
                            else => return err,
                        };
                    }
                }
            },
        }

        for (0..mod.input_cnt) |i|
            try out.propagateLogic(gpa, modules, .{ .top_input = i });

        return out;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.inputs.deinit(gpa);
        self.outputs.deinit(gpa);
        self.body.deinit(gpa);
        self.* = undefined;
    }

    pub fn propagateLogic(self: *ModuleInstance, gpa: Allocator, modules: *const SlotMap(Module), start: Module.WireSrc) !void {
        const self_mod = modules.get(self.mod_key) orelse return error.ModuleNotFound;

        switch (self_mod.body) {
            .primitive => |func| func(&self.inputs, &self.outputs),
            .custom => |mod_body| {
                var queue: Deque(Module.WireSrc) = .empty;
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

    fn readChildInput(self: *const Self, key: Module.InputKey) ?bool {
        const child = self.body.custom.get(key.child_key) orelse return null;
        return child.inputs.items[key.input];
    }

    fn writeChildInput(self: *const Self, key: Module.InputKey, value: bool) error{ChildNotFound}!void {
        const child = self.body.custom.get(key.child_key) orelse return error.ChildNotFound;
        child.inputs.items[key.input] = value;
    }

    fn readChildOutput(self: *const Self, key: Module.OutputKey) ?bool {
        const child = self.body.custom.get(key.child_key) orelse return null;
        return child.outputs.items[key.output];
    }

    pub fn readWireSrc(self: *const Self, src: Module.WireSrc) ?bool {
        return switch (src) {
            .top_input => |i| self.inputs.items[i],
            .mod_output => |key| self.readChildOutput(key),
        };
    }

    pub fn readWireDest(self: *const Self, dest: Module.WireDest) ?bool {
        return switch (dest) {
            .top_output => |i| self.outputs.items[i],
            .mod_input => |key| self.readChildInput(key),
        };
    }

    pub fn writeWireDest(self: *const Self, dest: Module.WireDest, value: bool) !void {
        switch (dest) {
            .top_output => |i| self.outputs.items[i] = value,
            .mod_input => |key| try self.writeChildInput(key, value),
        }
    }
};

const ModuleInstanceBody = union(enum) {
    const Self = @This();

    primitive,
    custom: SecondaryMap(Module.ChildKey, ModuleInstance),

    pub fn deinit(self: *Self, gpa: Allocator) void {
        switch (self.*) {
            .primitive => {},
            .custom => |*children| {
                var iter = children.iterator();

                while (iter.nextValue()) |child|
                    child.deinit(gpa);

                children.deinit(gpa);
            },
        }

        self.* = undefined;
    }
};
