#!/usr/bin/env python3
"""
Extract the HDTV Mate IT930x bridge firmware (symbol 'brFirmware_codes')
from the vendor Android app.  Python port of cxd28xx
utils/extract_firmware_hdtvmate.c so it runs on macOS (no <elf.h>).

Usage:  extract_fw.py <app.apk | liba3_phy_sony.so> [out=dvb-usb-hdtvmate.fw]
Accepts the APK directly (looks for lib/arm64-v8a/liba3_phy_sony.so inside).
"""
import struct, sys, zipfile, io

SYM = b"brFirmware_codes"


def load(path):
    if zipfile.is_zipfile(path):
        z = zipfile.ZipFile(path)
        names = [n for n in z.namelist() if n.endswith("liba3_phy_sony.so")]
        if not names:
            sys.exit("APK has no liba3_phy_sony.so; is this the HDTV Mate app? "
                     "(If it's a split APK/XAPK, unzip and pass the arm64 config APK.)")
        names.sort(key=lambda n: "arm64-v8a" not in n)
        print(f"using {names[0]} from APK")
        return z.read(names[0])
    return open(path, "rb").read()


def extract(elf):
    if elf[:4] != b"\x7fELF":
        sys.exit("not an ELF file")
    if elf[4] != 2:
        sys.exit("32-bit .so -- use the arm64-v8a copy of liba3_phy_sony.so")
    (e_phoff, e_shoff) = struct.unpack_from("<QQ", elf, 0x20)
    (e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from("<HHHHH", elf, 0x36)

    shdrs = [struct.unpack_from("<IIQQQQIIQQ", elf, e_shoff + i * e_shentsize) for i in range(e_shnum)]
    shstr_off = shdrs[e_shstrndx][4]

    def secname(sh):
        o = shstr_off + sh[0]
        return elf[o:elf.index(b"\0", o)]

    symtab = next((s for s in shdrs if s[1] == 2 and secname(s) == b".symtab"), None)
    dynsym = next((s for s in shdrs if s[1] == 11 and secname(s) == b".dynsym"), None)
    sh = symtab or dynsym
    if not sh:
        sys.exit("no symbol table")
    strtab_off = shdrs[sh[6]][4]
    n = sh[5] // sh[9]
    for i in range(n):
        st_name, st_info, st_other, st_shndx, st_value, st_size = struct.unpack_from("<IBBHQQ", elf, sh[4] + i * 24)
        o = strtab_off + st_name
        if elf[o:elf.index(b"\0", o)] != SYM:
            continue
        for p in range(e_phnum):
            p_type, p_flags, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_align = \
                struct.unpack_from("<IIQQQQQQ", elf, e_phoff + p * e_phentsize)
            if p_type == 1 and p_vaddr <= st_value and st_value + st_size <= p_vaddr + p_memsz:
                off = st_value - p_vaddr
                if off + st_size > p_filesz:
                    sys.exit("symbol is in BSS (no data) -- wrong library?")
                return elf[p_offset + off:p_offset + off + st_size]
        sys.exit("could not map symbol address")
    sys.exit("symbol brFirmware_codes not found")


def check(fw):
    i = blocks = 0
    while i < len(fw):
        if fw[i] != 0x03 or i + 7 > len(fw):
            return False, blocks
        seg = fw[i + 3]
        plen = 4 + seg * 3
        blen = sum(fw[i + 6 + j * 3] for j in range(seg))
        i += plen + blen
        blocks += 1
    return i == len(fw), blocks


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = sys.argv[2] if len(sys.argv) > 2 else "dvb-usb-hdtvmate.fw"
    fw = extract(load(sys.argv[1]))
    ok, blocks = check(fw)
    open(out, "wb").write(fw)
    print(f"wrote {out}: {len(fw)} bytes, {blocks} blocks, format {'OK' if ok else 'UNEXPECTED'}")
