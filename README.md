# lyra

Lyra is a UNIX-like hobby kernel for x86-64 UEFI systems, written in [Zig](https://ziglang.org/)

## Goals

- Readable and easy to understand codebase
- Modern design with [Limine](https://github.com/limine-bootloader/limine) boot protocol

## Progress

- internals
  - [x] gdt/idt
  - [x] paging
    - [x] read
    - [x] write
  - [x] clock
    - [x] counter
      - [x] tsc
      - [x] hpet
    - [x] real-time clock
  - [ ] interrupts
    - [x] pic driver
    - [ ] i/o apic driver
    - [ ] local apic driver
  - [ ] pci
    - [x] device detection
    - [ ] device access
- abstractions
  - [ ] tty
    - [x] basic rendering
    - [ ] ansi escape codes
    - [ ] custom font sizes
  - [x] memory
    - [x] pmm
    - [x] vmm
  - [x] csprng
    - [x] per-cpu generators
    - [x] entropy pool
  - [ ] process scheduler
    - [ ] process structures

## Credits

- [Zig](https://ziglang.org/) for being the best programming language 😉
- [AndreaOrru](https://github.com/AndreaOrru) for the [zen](https://github.com/AndreaOrru/zen/tree/reboot) kernel project (on which this project is based)
  - Attribution headers with the license are provided on all files for which this may apply.
- [OSDev.org](https://wiki.osdev.org/) for being a massively helpful resource
- The x86 architecture for making me question my life's choices
