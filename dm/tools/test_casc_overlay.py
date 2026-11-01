"""Real overlay transactions on tiny owned TVFS archives; no game resources."""
import hashlib
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

import casc_overlay as overlay


def key(data, archive, offset):
    header = int.from_bytes(data[4:8], "big") if data[:4] == b"BLTE" else len(data)
    return hashlib.md5(data[:header]).digest()[:9] + bytes((0, archive)) + offset.to_bytes(5, "big")


def encoded(data):
    block = b"Z" + zlib.compress(data)
    return b"BLTE" + struct.pack(">I", 36) + b"\x0f\0\0\x01" + struct.pack(">II", len(block), len(data)) + hashlib.md5(block).digest() + block


def tvfs(records, folder=True, spec=b"n\0", spec_offsets=None):
    # Independent single-span fixture layout, with one-byte CFT offsets.
    assert len(records) * 25 <= 255
    paths, cft, files = bytearray(), bytearray(), bytearray()
    for index, (name, ekey, encoded_size, size, virtual_size) in enumerate(records):
        paths += bytes((len(name),)) + name + b"\xff" + struct.pack(">I", index * 10)
        reference = spec_offsets[index] if spec_offsets is not None else 0
        cft += ekey + struct.pack(">I", encoded_size) + bytes((reference,)) + struct.pack(">I", size)
        files += b"\x01" + struct.pack(">II", 0, virtual_size) + bytes((index * 25,))
    if folder:
        paths = b"\x04data\0\xff" + struct.pack(">I", 0x80000000 | (len(paths) + 4)) + paths
    head = bytearray(46)
    head[:8] = b"TVFS\x01\x2e\x10\x10"
    struct.pack_into(">I", head, 8, 0x0a)
    est = 46 + len(paths)
    struct.pack_into(">6I", head, 12, 46, len(paths), est + len(spec) + len(cft), len(files), est + len(spec), len(cft))
    struct.pack_into(">HII", head, 36, 2, est, len(spec))
    return head + paths + spec + cft + files


class CascOverlayTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        (self.source / "data").mkdir(parents=True)
        content = b"owned shared backing bytes"
        blob = bytearray(content)
        self.original_key = key(content, 1, 0)
        self.vfs = tvfs([(b"a.txt", self.original_key, len(content), len(content), 3),
                         (b"b.txt", self.original_key, len(content), len(content), len(content))],
                        spec=b"z\0n\0b:64K*=n\0", spec_offsets=[2, 2])
        packed_vfs = encoded(self.vfs)
        vfs_key = key(packed_vfs, 1, len(blob)); blob += packed_vfs
        root = tvfs([(b"data", vfs_key, len(packed_vfs), len(self.vfs), len(self.vfs))], folder=False, spec=b"b:256K*=z\0")
        packed_root = encoded(root)
        root_key = key(packed_root, 1, len(blob)); blob += packed_root
        self.original_blob = bytes(blob)
        (self.source / "data/00-00000001.data").write_bytes(blob)
        lines = []
        for name, data, packed, ekey in [("vfs-1", self.vfs, packed_vfs, vfs_key), ("vfs-root", root, packed_root, root_key), ("vfs-2", root, packed_root, root_key)]:
            lines += [f"{name} = {hashlib.md5(data).hexdigest()} {ekey.hex()}\n", f"{name}-size = {len(data)} {len(packed)}\n"]
        (self.source / "data/.build.config").write_text("".join(lines))
        # A stale extraction aid must not select resources for the actual TVFS.
        (self.source / "data/build_manifest.psv").write_text("# deliberately obsolete, no current file keys\n")

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, replacements=None, prebuilt=None):
        output = self.root / "output"
        overlay.make_overlay(self.source, output, replacements or {}, prebuilt=prebuilt, link_source=False)
        self.assertEqual((self.source / "data/00-00000001.data").read_bytes(), self.original_blob)
        return output, overlay.load_vfs1(output)

    def root_span_size(self, output):
        _, cfg = overlay.config_values(output / "data/.build.config")
        ekey = bytes.fromhex(cfg["vfs-root"].split()[1])
        size = int(cfg["vfs-root-size"].split()[1])
        root = overlay.read_data_file(output / "data", ekey, size)
        vfs_off = struct.unpack_from(">I", root, 20)[0]
        return struct.unpack_from(">I", root, vfs_off + 5)[0]

    def test_actual_path_distinguishes_files_sharing_an_encoding_key(self):
        paths = overlay.tvfs_path_offsets(self.vfs)
        cft, size = struct.unpack_from(">II", self.vfs, 28)
        self.assertEqual(overlay.cft_position(self.vfs, cft, cft + size, paths, "data/a.txt"), cft)
        self.assertEqual(overlay.cft_position(self.vfs, cft, cft + size, paths, "DATA/B.TXT"), cft + 25)

    def test_encoding_specs_are_byte_offsets_not_string_ordinals(self):
        vfs = tvfs([(b"a.txt", self.original_key, 3, 3, 3)] * 3,
                   spec=b"z\0n\0b:64K*=n\0", spec_offsets=[0, 2, 4])
        cft = struct.unpack_from(">I", vfs, 28)[0]
        self.assertEqual([overlay.encoding_spec(vfs, cft + i * 25) for i in range(3)],
                         ["z", "n", "b:64K*=n"])

    def test_invalid_encoding_spec_offset_is_rejected(self):
        for reference in [1, 3, 255]:
            with self.subTest(reference=reference):
                vfs = tvfs([(b"a.txt", self.original_key, 3, 3, 3)],
                           spec=b"z\0n\0b:64K*=n\0", spec_offsets=[reference])
                with self.assertRaises(SystemExit):
                    overlay.encoding_spec(vfs, struct.unpack_from(">I", vfs, 28)[0])

    def test_standalone_pack_preserves_the_selected_raw_encoding(self):
        content = b"owned raw pack contents"
        replacement = self.root / "replacement"; replacement.write_bytes(content)
        output = self.root / "pack"
        overlay.write_pack(self.source, output, {"data/a.txt": replacement}, (0, 9))
        self.assertEqual((output / "00-00000009.data").read_bytes(), content)

    def test_whole_replacement_updates_virtual_read_limit_and_preserves_other_alias(self):
        content = b"a substantially longer owned replacement"
        replacement = self.root / "replacement"; replacement.write_bytes(content)
        output, vfs = self.build({"data/a.txt": replacement})
        vfs_off, _, cft, _ = struct.unpack_from(">4I", vfs, 20)
        self.assertEqual(struct.unpack_from(">I", vfs, vfs_off + 5)[0], len(content))
        self.assertEqual(struct.unpack_from(">I", vfs, cft + 21)[0], len(content))
        self.assertEqual(vfs[cft + 25:cft + 41], self.original_key)
        encoded = struct.unpack_from(">I", vfs, cft + 16)[0]
        ekey = bytes(vfs[cft:cft + 16]); start = int.from_bytes(ekey[11:16], "big")
        raw = (output / "data" / f"{ekey[9]:02d}-{ekey[10]:08d}.data").read_bytes()
        self.assertEqual(raw[start:start + encoded], content)
        self.assertEqual(self.root_span_size(output), len(vfs))

    def test_prebuilt_replacement_also_updates_virtual_span_size(self):
        content = b"owned prebuilt replacement contents"
        ekey = key(content, 9, 0)
        (self.source / "data/00-00000009.data").write_bytes(content)
        _, vfs = self.build(prebuilt={"data/a.txt": (ekey, len(content), len(content))})
        vfs_off, _, cft, _ = struct.unpack_from(">4I", vfs, 20)
        self.assertEqual(struct.unpack_from(">I", vfs, vfs_off + 5)[0], len(content))
        self.assertEqual(vfs[cft:cft + 16], ekey)

    def test_addition_updates_root_virtual_length_when_vfs_grows(self):
        content = self.root / "new"; content.write_bytes(b"owned new path")
        output, vfs = self.build({"+data/cnew/item.txt": content})
        self.assertGreater(len(vfs), len(self.vfs))
        self.assertEqual(self.root_span_size(output), len(vfs))
        paths = overlay.tvfs_path_offsets(vfs)
        cft, size = struct.unpack_from(">II", vfs, 28)
        self.assertGreaterEqual(overlay.cft_position(vfs, cft, cft + size, paths, "data/cnew/item.txt"), cft)

    def test_multispan_file_is_rejected(self):
        vfs = bytearray(self.vfs); off = struct.unpack_from(">I", vfs, 20)[0]; vfs[off] = 2
        cft, size = struct.unpack_from(">II", vfs, 28)
        with self.assertRaises(SystemExit):
            overlay.cft_position(vfs, cft, cft + size, overlay.tvfs_path_offsets(vfs), "data/a.txt")

    def test_out_of_bounds_container_pointer_is_rejected(self):
        vfs = bytearray(self.vfs); off = struct.unpack_from(">I", vfs, 20)[0]; vfs[off + 9] = 255
        cft, size = struct.unpack_from(">II", vfs, 28)
        with self.assertRaises(SystemExit):
            overlay.cft_position(vfs, cft, cft + size, overlay.tvfs_path_offsets(vfs), "data/a.txt")

    def test_ambiguous_case_normalization_does_not_choose_one_file(self):
        vfs = tvfs([(b"a.txt", self.original_key, 3, 3, 3), (b"A.TXT", self.original_key, 3, 3, 3)])
        cft, size = struct.unpack_from(">II", vfs, 28)
        with self.assertRaises(SystemExit):
            overlay.cft_position(vfs, cft, cft + size, overlay.tvfs_path_offsets(vfs), "data/a.txt")


if __name__ == "__main__":
    unittest.main()
