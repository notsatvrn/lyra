ENTRY(_start)

SECTIONS
{
	. = 2M;

	.text : ALIGN(4K)
	{
		*(.multiboot)
		*(.text)
	}

	.rodata : ALIGN(4K)
	{
		*(.rodata)
	}

	.data : ALIGN(4K)
	{
		*(.data)
	}

	.bss : ALIGN(4K)
	{
    . += 0x10000;
    stack_top = .;

		*(COMMON)
		*(.bss)
	}
}
