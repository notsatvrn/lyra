# lyra

Lyra is a 64-bit UNIX-like hobby kernel for learning operating system development in [Zig](https://ziglang.org/)

## Goals

- Readable and easy to understand codebase
- Multi-architecture support (x86, RISC-V, ARM)
- Modern design with [Limine](https://github.com/limine-bootloader/limine) boot protocol
- Best-effort support for all post-2008 CPUs

## Progress

- generic
  - [x] tty
    - [x] text mode impl
    - [x] framebuffer impl
  - [ ] memory
    - [x] pmm
    - [ ] vmm
  - [ ] process scheduler
    - [x] red-black tree impl
    - [ ] process structures
    - [ ] smp awareness
- x86-64
  - [x] gdt/idt
  - [ ] paging
    - [x] read
    - [ ] write
  - [x] system clock
    - [x] counter
    - [x] hw clock reading
  - [ ] interrupts
    - [x] basic handlers
    - [ ] lapic driver
    - [ ] deferred work
  - [ ] smp
    - [x] core id storage
  - [x] pci device tree
- aarch64
  - [ ] paging
  - [ ] system clock
    - [x] counter
    - [ ] hw clock reading
  - [ ] interrupts
  - [ ] smp

## Credits

- [Zig](https://ziglang.org/) for being the best programming language 😉
- [AndreaOrru](https://github.com/AndreaOrru) for the [zen](https://github.com/AndreaOrru/zen/tree/reboot) kernel project (on which this project is based)
  - Attribution headers with the license are provided on all files for which this may apply.
- [OSDev.org](https://wiki.osdev.org/) for being a massively helpful resource
- The x86 architecture for making me question my life's choices
