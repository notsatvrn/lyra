const std = @import("std");
const clock = @import("../clock.zig");

const log = @import("../log.zig");
const logger = log.Logger{ .name = "memory/bench" };

const memory = @import("../memory.zig");
const KB = memory.KB;
const GB = memory.GB;
const page_size = memory.page_size;
const unused = memory.unused;
const page_allocator = memory.page_allocator;

pub fn run() void {
    // bench - random alloc and dealloc

    clock.stall(std.time.ns_per_ms * 10);
    benchRandom(250, 10);
    clock.stall(std.time.ns_per_ms * 10);
    benchRandom(225, 100);
    clock.stall(std.time.ns_per_ms * 10);
    benchRandom(150, 1000);
    clock.stall(std.time.ns_per_ms * 10);
    benchRandom(60, 10000);
    clock.stall(std.time.ns_per_ms * 10);
    benchRandom(20, 100000);
    clock.stall(std.time.ns_per_ms * 10);
    benchRandom(5, 1000000);

    // bench - sequential 4K alloc / random dealloc

    comptime var size: usize = 1;
    inline for (0..8) |_| {
        clock.stall(std.time.ns_per_ms * 10);
        benchSeqRand(size);
        size *= 4;
    }
}

// HELPERS

inline fn writeRNGTable(table: []usize) void {
    var rng = std.Random.Xoroshiro128.init(clock.nanoSinceBoot());
    for (0..table.len) |i| table[i] = i;
    std.Random.shuffle(rng.random(), usize, table);
}

inline fn buildRNGTable(size: usize) []usize {
    const table = memory.page_allocator.alloc(usize, size) catch @panic("failed to build RNG table");
    writeRNGTable(table);
    return table;
}

// BENCHMARKS

fn benchRandom(comptime iters: usize, comptime divisor: usize) void {
    logger.debug("bench: random alloc and dealloc (divisor: {})", .{divisor});

    const divisor_f = @as(f64, @floatFromInt(divisor));
    const amt = (unused() * 3) / 4;

    var rng = std.Random.Xoroshiro128.init(clock.nanoSinceBoot());
    var random = rng.random();
    var bytes_total: usize = 0;

    var storage = page_allocator.alloc(memory.Block, divisor) catch @panic("failed to build bench storage");
    var tables = page_allocator.alloc([]usize, iters) catch @panic("failed to build RNG table directory");
    for (0..iters) |i| tables[i] = buildRNGTable(divisor);

    const start = clock.nanoSinceBoot();

    for (0..iters) |_| {
        for (0..iters) |j| {
            const table = tables[j];
            for (0..divisor) |i| {
                var pages: usize = 0;
                while (pages == 0) {
                    const percent = (random.float(f64) * (1.0 / divisor_f));
                    const pages_f = percent * @as(f64, @floatFromInt(amt));
                    pages = @intFromFloat(pages_f);
                }
                bytes_total += pages * page_size;
                storage[i] = memory.allocBlock(pages).?[0..pages];
            }
            for (0..divisor) |i|
                _ = memory.freeBlock(storage[table[i]]);
        }
    }

    const end = clock.nanoSinceBoot();

    const diff: f64 = @floatFromInt(end - start);
    const btf: f64 = @as(f64, @floatFromInt(bytes_total));
    const bps = btf / (diff / std.time.ns_per_s);

    logger.debug("done ({d:.3}GB/s | {d:.3}KB avg size per alloc)", .{ bps / GB, (btf / (iters * iters * divisor)) / KB });

    page_allocator.free(storage);
    for (0..iters) |i| page_allocator.free(tables[i]);
    page_allocator.free(tables);
}

fn benchSeqRand(comptime pages: usize) void {
    const size_seq = (unused() / 2) / pages;
    const outer_iter = pages * 25;

    logger.debug("bench: sequential {}K alloc / random dealloc ({} iters)", .{ pages * (page_size / KB), size_seq * outer_iter });

    var storage = page_allocator.alloc(memory.Ptr, size_seq) catch @panic("failed to build bench storage");
    var tables = page_allocator.alloc([]usize, outer_iter) catch @panic("failed to build RNG table directory");
    for (0..outer_iter) |i| tables[i] = buildRNGTable(size_seq);

    const start = clock.nanoSinceBoot();
    for (0..outer_iter) |j| {
        const table = tables[j];
        for (0..size_seq) |i|
            storage[i] = memory.allocBlock(pages) orelse @panic("failed to allocate page");
        for (0..size_seq) |i|
            _ = memory.freeBlock(storage[table[i]][0..pages]);
    }
    const end = clock.nanoSinceBoot();

    const p = pages * size_seq * outer_iter;
    const s = @as(f64, @floatFromInt(end - start)) / std.time.ns_per_s;
    const bps = (@as(f64, @floatFromInt(p)) / s) * page_size;

    logger.debug("done ({d:.3}GB/s)", .{bps / GB});

    page_allocator.free(storage);
    for (0..outer_iter) |i| page_allocator.free(tables[i]);
    page_allocator.free(tables);
}
