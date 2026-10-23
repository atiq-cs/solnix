#!/usr/bin/env python3
# aa64c-observers.py <gate> : console observers for the nvme-down question. No behaviour change.
import re, sys
G = sys.argv[1] + '/usr/src/uts/'

def edit(path, fn):
    s = open(G + path).read(); t = fn(s)
    assert t != s, path; open(G + path, 'w').write(t)

# 1. nvme: every log-only ('!') message goes to the console as well.
def nvme(s):
    n = s.count('"!'); assert n == 86, n
    return s.replace('"!', '"')
edit('common/io/nvme/nvme.c', nvme)

# 2. dboot: carry the raw ACPI IORT to the kernel on the its@ node.
def dboot(s):
    a = '\t\t(void) prop_reg2(fdt, gic.its, 0x20000);\n'
    assert s.count(a) == 1
    b = a + ('\t\t{\n'
        '\t\t\t/*\n'
        '\t\t\t * NOTE: diagnostic.  Copy the raw ACPI IORT here so the\n'
        '\t\t\t * kernel can print it at console speed (gicv3_its attach).\n'
        '\t\t\t * Capped at 4 KiB so the synth FDT (9069 of 16384 bytes on\n'
        '\t\t\t * c6g.metal) cannot overflow.\n'
        '\t\t\t */\n'
        '\t\t\tconst ACPI_TABLE_HEADER *iort =\n'
        '\t\t\t    synth_find_table(ACPI_SIG_IORT);\n'
        '\t\t\tif (iort != NULL) {\n'
        '\t\t\t\tUINT32 ilen;\n'
        '\t\t\t\tmemcpy(&ilen, &iort->Length, sizeof (ilen));\n'
        '\t\t\t\tif (ilen > 4096)\n'
        '\t\t\t\t\tilen = 4096;\n'
        '\t\t\t\t(void) fdt_property(fdt, "solnix,acpi-iort",\n'
        '\t\t\t\t    iort, (int)ilen);\n'
        '\t\t\t}\n'
        '\t\t}\n')
    return s.replace(a, b, 1)
edit('armv8/dboot/dboot_synth_fdt.c', dboot)

# 3. gicv3_its: attach summary to the console, then the IORT bytes.
def its(s):
    a = '\t    "!GICv3 ITS: Devbits=%u'
    assert s.count(a) == 1
    s = s.replace(a, '\t    "?GICv3 ITS: Devbits=%u', 1)
    s = s.replace('#include <sys/cmn_err.h>\n', '#include <sys/cmn_err.h>\n#include <sys/systm.h>\n', 1)
    a = '\tddi_report_dev(dip);\n\treturn (DDI_SUCCESS);\n\nfail_tables:'
    assert s.count(a) == 1
    b = ('\t{\n'
        '\t\t/* NOTE: diagnostic.  Print the IORT that dboot copied. */\n'
        '\t\tuchar_t *iort;\n'
        '\t\tuint_t niort, o, i;\n'
        '\t\tchar line[3 * 32 + 1];\n'
        '\n'
        '\t\tif (ddi_prop_lookup_byte_array(DDI_DEV_T_ANY, dip,\n'
        '\t\t    DDI_PROP_DONTPASS, "solnix,acpi-iort", &iort, &niort) ==\n'
        '\t\t    DDI_PROP_SUCCESS) {\n'
        '\t\t\tfor (o = 0; o < niort; o += 32) {\n'
        '\t\t\t\tchar *p = line;\n'
        '\t\t\t\tline[0] = \'\\0\';\n'
        '\t\t\t\tfor (i = o; i < niort && i < o + 32; i++) {\n'
        '\t\t\t\t\t(void) snprintf(p, 4, " %02x", iort[i]);\n'
        '\t\t\t\t\tp += 3;\n'
        '\t\t\t\t}\n'
        '\t\t\t\tcmn_err(CE_CONT, "?[IORT] %04x:%s\\n", o, line);\n'
        '\t\t\t}\n'
        '\t\t\tddi_prop_free(iort);\n'
        '\t\t} else {\n'
        '\t\t\tcmn_err(CE_CONT, "?[IORT] none\\n");\n'
        '\t\t}\n'
        '\t}\n' + a)
    return s.replace(a, b, 1)
edit('armv8/io/gicv3_its.c', its)
# 4. nvme: say which interrupt type the admin queue got (observer).
def nvme2(s):
    a = ('\t/*\n\t * Initialize the failure status we should use if we mark the controller\n'
         '\t * dead. Do this ahead of issuing any commands.\n\t */\n')
    assert s.count(a) == 1
    b = ('\tdev_err(nvme->n_dip, CE_CONT, "?admin intr type 0x%x of 0x%x, "\n'
         '\t    "%d vector(s)\\n", nvme->n_intr_type, nvme->n_intr_types,\n'
         '\t    nvme->n_intr_cnt);\n\n' + a)
    return s.replace(a, b, 1)
edit('common/io/nvme/nvme.c', nvme2)

# 5. gicv3_its: report each translation it programs for a non-bridge device.
def its2(s):
    a = '\tpriv->ip_msi_addr = sc->its_doorbell_pa;\n\tpriv->ip_msi_data = eventid;\n'
    assert s.count(a) == 1
    b = a + ('\tif (strcmp(ddi_driver_name(rdip), "pcieb") != 0)\n'
        '\t\tdev_err(sc->its_dip, CE_CONT, "?MAPTI %s%d devid 0x%x "\n'
        '\t\t    "event %u lpi %u cpu %d doorbell 0x%" PRIx64 "\\n",\n'
        '\t\t    ddi_driver_name(rdip), ddi_get_instance(rdip), devid,\n'
        '\t\t    eventid, lpi, target_cpu, sc->its_doorbell_pa);\n')
    return s.replace(a, b, 1)
edit('armv8/io/gicv3_its.c', its2)
print('OBSERVERS_OK')
