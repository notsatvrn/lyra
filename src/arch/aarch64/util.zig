pub inline fn wfi() void {
    asm volatile ("wfi");
}

pub fn halt() noreturn {
    @branchHint(.cold);
    disableInterrupts();
    while (true) asm volatile ("hlt");
}

pub inline fn disableInterrupts() void {
    asm volatile ("cpsid if");
}

pub inline fn enableInterrupts() void {
    asm volatile ("cpsie if");
}
