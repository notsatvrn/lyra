pub inline fn counter() u64 {
    var time: u64 = 0;
    asm volatile (
        \\cntpct_el0
        : [time] "=r" (time),
    );

    return time;
}

pub inline fn counterSpeed() u64 {
    var freq: u64 = 0;
    asm volatile (
        \\cntfrq_el0
        : [freq] "=r" (freq),
    );

    return freq;
}

pub inline fn readSystemClock() u64 {
    return 0;
}
