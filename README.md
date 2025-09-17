# lyra

Lyra is a UNIX-like hobby kernel for x86-64, written in [Zig](https://ziglang.org/)

## Goals

- Readable and easy to understand codebase
- Modern design with [Limine](https://github.com/limine-bootloader/limine) boot protocol

## Progress

- internals
  - [x] gdt/idt
  - [x] paging
    - [x] read
    - [x] write
  - [ ] system clock
    - [ ] counter
      - [x] invariant TSC
      - [x] HPET
      - [ ] ACPI PM timer
    - [x] hw clock reading
  - [ ] interrupts
    - [x] pic driver
    - [ ] apic driver
  - [ ] smp
    - [x] core id storage
  - [x] pci device tree
- abstractions
  - [ ] tty
    - [x] text mode backend
    - [x] framebuffer backend
    - [ ] ansi escape codes
  - [ ] memory
    - [x] pmm
    - [ ] vmm
  - [ ] process scheduler
    - [x] red-black tree impl
    - [ ] process structures
    - [ ] smp awareness

## Credits

- [Zig](https://ziglang.org/) for being the best programming language 😉
- [AndreaOrru](https://github.com/AndreaOrru) for the [zen](https://github.com/AndreaOrru/zen/tree/reboot) kernel project (on which this project is based)
  - Attribution headers with the license are provided on all files for which this may apply.
- [OSDev.org](https://wiki.osdev.org/) for being a massively helpful resource
- The x86 architecture for making me question my life's choices
