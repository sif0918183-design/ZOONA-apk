import sys
import struct

def check_so(filepath):
    with open(filepath, 'rb') as f:
        data = f.read()
    if data[:4] != b'\x7fELF':
        return "Not ELF"
    ei_class = data[4] # 1=32bit, 2=64bit
    ei_data = data[5]  # 1=little endian, 2=big endian
    is_64 = (ei_class == 2)
    is_le = (ei_data == 1)
    endian = '<' if is_le else '>'

    if is_64:
        # ELF64 header
        # e_phoff offset 32 (8 bytes)
        # e_phentsize offset 54 (2 bytes)
        # e_phnum offset 56 (2 bytes)
        e_phoff = struct.unpack(endian + 'Q', data[32:40])[0]
        e_phentsize = struct.unpack(endian + 'H', data[54:56])[0]
        e_phnum = struct.unpack(endian + 'H', data[56:58])[0]

        load_alignments = []
        for i in range(e_phnum):
            ph_start = e_phoff + i * e_phentsize
            p_type = struct.unpack(endian + 'I', data[ph_start:ph_start+4])[0]
            if p_type == 1: # PT_LOAD
                p_offset = struct.unpack(endian + 'Q', data[ph_start+8:ph_start+16])[0]
                p_vaddr = struct.unpack(endian + 'Q', data[ph_start+16:ph_start+24])[0]
                p_align = struct.unpack(endian + 'Q', data[ph_start+48:ph_start+56])[0]
                load_alignments.append((p_offset, p_vaddr, p_align))
        return load_alignments
    else:
        # ELF32 header
        e_phoff = struct.unpack(endian + 'I', data[28:32])[0]
        e_phentsize = struct.unpack(endian + 'H', data[42:44])[0]
        e_phnum = struct.unpack(endian + 'H', data[44:46])[0]

        load_alignments = []
        for i in range(e_phnum):
            ph_start = e_phoff + i * e_phentsize
            p_type = struct.unpack(endian + 'I', data[ph_start:ph_start+4])[0]
            if p_type == 1: # PT_LOAD
                p_offset = struct.unpack(endian + 'I', data[ph_start+4:ph_start+8])[0]
                p_vaddr = struct.unpack(endian + 'I', data[ph_start+8:ph_start+12])[0]
                p_align = struct.unpack(endian + 'I', data[ph_start+28:ph_start+32])[0]
                load_alignments.append((p_offset, p_vaddr, p_align))
        return load_alignments

if __name__ == '__main__':
    print(check_so(sys.argv[1]))
