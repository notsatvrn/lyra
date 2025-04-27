const std = @import("std");

const smp = @import("smp.zig");

const log = @import("log.zig");
const logger = log.Logger{ .name = "tasks" };

var tid = std.atomic.Value(usize);
pub var state = smp.LocalStorage(State);

// Per-CPU scheduler state.
pub const State = struct {};

// A basic task.
pub const Task = struct {};
