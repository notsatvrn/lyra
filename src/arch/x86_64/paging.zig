const builtin = @import("builtin");
const std = @import("std");

const io = @import("io.zig");
const util = @import("util.zig");

const log = @import("../../log.zig");
const logger = log.Logger{ .name = "x86-64/paging" };

// PAGING

pub const PageEntry = packed struct(u64) {};

var kcr3: u64 = undefined; // kernel page table
//var pml5: bool = false;

pub inline fn saveTable() void {
    kcr3 = io.getRegister(u64, "cr3");
}
