import struct
import unittest
from pathlib import Path

from net_level_fields import check_cut, load_fields


class FieldValidationTests(unittest.TestCase):
    def fixture(self):
        original = bytearray(64)
        struct.pack_into('<I', original, 4, 0x39402108)
        row = 'DM_LEVEL_FIELD(0x4, 0x39402108, 8, 8, OBJECT_GET)'
        return original, row

    def test_valid_instruction_and_exact_single_service(self):
        original, row = self.fixture()
        fields = load_fields(row, original)
        check_cut(fields, 4, original[4:8], struct.pack('<I', 0xd4001441), 0xa2)

    def test_mutated_manifests_are_rejected(self):
        original, row = self.fixture()
        mutations = [
            row + '\n' + row,
            row.replace('0x4,', '0x5,'),
            row.replace('0x4,', '0x40,'),
            row.replace('0x39402108', '0x39402109'),
            row.replace(', 8, 8,', ', 9, 8,'),
            row.replace(', 8, 8,', ', 8, 9,'),
            row.replace('OBJECT_GET', 'OBJECT_SET'),
            row.replace('OBJECT_GET', 'DESTINATION'),
            row.replace('OBJECT_GET', 'ALLOCATE'),
            row.replace('OBJECT_GET', 'UNKNOWN'),
            row.replace(', 8, 8,', ', 8, 18,'),
            row.replace(', 8, 8,', ', 8, 29,'),
            '',
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                load_fields(mutation, original)

    def test_changed_image_is_rejected(self):
        original, row = self.fixture()
        original[4] ^= 1
        with self.assertRaises(ValueError):
            load_fields(row, original)

    def test_extra_bytes_sites_and_wrong_service_are_rejected(self):
        original, row = self.fixture()
        fields = load_fields(row, original)
        svc = struct.pack('<I', 0xd4001441)
        for site, old, new in [(8, original[4:8], svc), (4, b'\0' * 4, svc),
                               (4, original[4:8], svc + b'\0' * 4),
                               (4, original[4:8], struct.pack('<I', 0xd4001461))]:
            with self.subTest(site=site, new=new), self.assertRaises(ValueError):
                check_cut(fields, site, old, new, 0xa2)

    def test_full_manifest_semantics(self):
        text = (Path(__file__).parent.parent / 'host/dm_net_level_sites.inc').read_text()
        rows = [line for line in text.splitlines() if line.startswith('DM_LEVEL_FIELD(')]
        original = bytearray(0x1b63370)
        for row in rows:
            parts = row.removeprefix('DM_LEVEL_FIELD(').removesuffix(')').split(', ')
            struct.pack_into('<I', original, int(parts[0], 16), int(parts[1], 16))
        self.assertEqual(len(load_fields(text, original)), len(rows))


if __name__ == '__main__':
    unittest.main()
