"""Check scoped field adapters against the displaced ARM64 instructions."""
import re
import struct


_ROW = re.compile(
    r'DM_LEVEL_FIELD\((0x[0-9a-f]+), (0x[0-9a-f]+), (\d+), (\d+), ([A-Z_]+)\)'
)
_BYTE = {
    'ROOM_LEVEL': (0x39400000, 5),
    'CREATE_LEVEL': (0x39400000, 16),
    'OBJECT_GET': (0x39400000, 8),
    'OBJECT_SET': (0x39000000, 8),
    'DESTINATION': (0x39400000, 0x1ba),
}
_SPECIAL = {
    'ALLOCATE': (0x4a5b38, 0x52800f01, 19, 1),
    'INITIALIZE': (0x4a5b50, 0xf900381f, 0, 0),
    'RELEASE': (0x1b6336c, 0xd000b568, 1, 8),
}


def load_fields(text, original):
    fields = {}
    previous = -1
    for line in text.splitlines():
        if not line.strip() or line.startswith('/*'):
            continue
        match = _ROW.fullmatch(line)
        if not match:
            raise ValueError('Invalid field manifest row')
        site, word, base, value = (int(match[i], 16 if i < 3 else 10) for i in range(1, 5))
        kind = match[5]
        if site <= previous or site % 4 or site + 4 > len(original):
            raise ValueError('Field sites must be unique, sorted, aligned and in the original image')
        previous = site
        if value in (18, 29, 30, 31) or not 0 <= base <= 30 or not 0 <= value <= 30:
            raise ValueError('Unsupported field register')
        if struct.unpack_from('<I', original, site)[0] != word:
            raise ValueError('Field original instruction does not match the pinned image')
        if kind in _BYTE:
            opcode, offset = _BYTE[kind]
            expected = opcode | (offset << 10) | (base << 5) | value
            if word != expected:
                raise ValueError('Field register, offset or instruction kind mismatch')
            if kind == 'CREATE_LEVEL' and (site, base, value) != (0x460468, 29, 8):
                raise ValueError('Unexpected object constructor field site')
        elif _SPECIAL.get(kind) != (site, word, base, value):
            raise ValueError('Unexpected allocator instruction or field kind')
        fields[site] = word
    if not fields:
        raise ValueError('Empty field manifest')
    return fields


def check_cut(fields, site, old_bytes, new_bytes, service):
    """An allowed site replaces exactly one instruction with this service."""
    if site not in fields or old_bytes != struct.pack('<I', fields[site]):
        raise ValueError('Field cut is absent from the validated manifest')
    if new_bytes != struct.pack('<I', 0xd4000001 | (service << 5)):
        raise ValueError('Field cut must be exactly the registered service instruction')
