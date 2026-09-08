# solnix K1 boot script (compiled to boot.scr with mkimage -T script)
setenv kernel_addr_r 0x02000000
setenv fdt_addr_r    0x08000000
echo "solnix: loading unix-k1.Image + k1.dtb from bootfs..."
load mmc 0:1 ${kernel_addr_r} unix-k1.Image
load mmc 0:1 ${fdt_addr_r} k1.dtb
echo "solnix: booti ${kernel_addr_r} - ${fdt_addr_r}"
booti ${kernel_addr_r} - ${fdt_addr_r}
