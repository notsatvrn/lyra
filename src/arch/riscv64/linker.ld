OUTPUT_FORMAT(elf64-littleriscv)

ENTRY(_start)

PHDRS
{
  requests PT_LOAD;
  text     PT_LOAD;
  rodata   PT_LOAD;
  data     PT_LOAD;
}

SECTIONS
{
  . = 0xffffffff80000000;

  .requests : {
    KEEP(*(.requests_start))
    KEEP(*(.requests))
    KEEP(*(.requests_end))
  } :requests

  . = ALIGN(4K);

  .text : {
    *(.text .text.*)
  } :text

  . = ALIGN(4K);

  .rodata : {
    *(.rodata .rodata.*)
  } :rodata

  . = ALIGN(4K);

  .data : {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } :data

  .bss : {
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
  } :data

  /DISCARD/ : {
    *(.eh_frame*)
    *(.note .note.*)
  }
}
