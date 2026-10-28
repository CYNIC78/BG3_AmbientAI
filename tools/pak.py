import struct, json, os, sys

def lz4_block_decompress(src):
    out = bytearray(); i = 0; n = len(src)
    while i < n:
        token = src[i]; i += 1
        litlen = token >> 4
        if litlen == 15:
            while True:
                b = src[i]; i += 1; litlen += b
                if b != 255: break
        out += src[i:i+litlen]; i += litlen
        if i >= n: break
        offset = src[i] | (src[i+1] << 8); i += 2
        if offset == 0: break
        matchlen = token & 0x0F
        if matchlen == 15:
            while True:
                b = src[i]; i += 1; matchlen += b
                if b != 255: break
        matchlen += 4
        start = len(out) - offset
        for k in range(matchlen):
            out.append(out[start + k])
    return bytes(out)

def lz4_block_compress_literal(data):
    """Valid LZ4 block using literals only (fine for tiny payloads like the file list)."""
    n = len(data)
    out = bytearray()
    if n == 0:
        return bytes(out)
    if n < 15:
        out.append(n << 4)
    else:
        out.append(0xF0)
        rem = n - 15
        while rem >= 255:
            out.append(255); rem -= 255
        out.append(rem)
    out += data
    return bytes(out)

def read_pak(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'LSPK', 'not a pak'
    version = struct.unpack_from('<I', d, 4)[0]
    fl_off, fl_size = struct.unpack_from('<QI', d, 8)
    flags = d[20]
    priority = d[21]
    md5 = d[22:38]
    num_parts = struct.unpack_from('<H', d, 38)[0]
    pkg = d[fl_off:fl_off + fl_size]
    ncomp, clen = struct.unpack_from('<II', pkg, 0)
    raw = lz4_block_decompress(pkg[8:8 + clen])
    files = []
    for i in range(len(raw) // 272):
        rec = raw[i*272:(i+1)*272]
        name = rec[:256].split(b'\x00')[0].decode('utf-8')
        off = struct.unpack_from('<I', rec, 256)[0]
        offhi = struct.unpack_from('<I', rec, 260)[0]
        size = struct.unpack_from('<I', rec, 264)[0]
        size2 = struct.unpack_from('<I', rec, 268)[0]
        files.append(dict(name=name, offset=off + (offhi << 32), size=size, size2=size2,
                          data=d[off:off+size], pad=d[0:0]))
    # padding trailing each file
    files.sort(key=lambda f: f['offset'])
    for i, f in enumerate(files):
        nxt = files[i+1]['offset'] if i + 1 < len(files) else fl_off
        end = f['offset'] + f['size']
        f['pad'] = nxt - end
    return dict(version=version, flags=flags, priority=priority, md5=md5,
                num_parts=num_parts, files=files, raw_list=raw)

def write_pak(path, files, version=18, flags=0, priority=0, md5=b'\x00'*16, num_parts=1):
    body = bytearray(b'\x00' * 40)
    recs = []
    for f in files:
        off = len(body)
        body += f['data']
        body += b'\x00' * f.get('pad', 32)
        rec = bytearray(272)
        nm = f['name'].encode('utf-8')
        rec[:len(nm)] = nm
        struct.pack_into('<I', rec, 256, off)
        struct.pack_into('<I', rec, 260, 0)
        struct.pack_into('<I', rec, 264, len(f['data']))
        struct.pack_into('<I', rec, 268, 0)
        recs.append(bytes(rec))
    raw = b''.join(recs)
    comp = lz4_block_compress_literal(raw)
    fl_off = len(body)
    pkg = struct.pack('<II', len(recs), len(comp)) + comp
    body += pkg
    hdr = bytearray(40)
    hdr[0:4] = b'LSPK'
    struct.pack_into('<I', hdr, 4, version)
    struct.pack_into('<Q', hdr, 8, fl_off)
    struct.pack_into('<I', hdr, 16, len(pkg))
    hdr[20] = flags
    hdr[21] = priority
    hdr[22:38] = md5
    struct.pack_into('<H', hdr, 38, num_parts)
    body[0:40] = hdr
    open(path, 'wb').write(bytes(body))
    return len(body)
