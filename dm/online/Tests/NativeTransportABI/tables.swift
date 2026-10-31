import Foundation
@_silgen_name("dm_test_tables_load") func fixture(_ mode: Int32)

@main struct TableCaptureABITest {
    static func main() throws {
        let usage = try CharacterStatUsage(itemIDs: [0, 1], playerIDs: [1])
        fixture(0)
        let first = try NativeItemStatCostCapture.load(edition: 3, usage: usage)
        let descriptors = try first.snapshot.descriptors(for: usage)
        precondition(descriptors.count == 2 && descriptors[0].byte34 == 10 && descriptors[1].byte38 == 13)
        precondition(descriptors[1].flags == 3 && descriptors[1].name == Data("own_synthetic_stat".utf8))
        try first.validateCurrent()
        fixture(5)
        do { try first.validateCurrent(); preconditionFailure("Old generation accepted") } catch {}
        let unchanged = try first.snapshot.descriptors(for: usage)
        precondition(unchanged == descriptors)
        let changed = try NativeItemStatCostCapture.load(edition: 3, usage: usage)
        precondition(changed.generation != first.generation)
        let changedDescriptors = try changed.snapshot.descriptors(for: usage)
        precondition(changedDescriptors[0].byte34 == 11)
        for mode: Int32 in [1, 2, 3, 4] {
            fixture(mode)
            do {
                _ = try NativeItemStatCostCapture.load(edition: 3, usage: usage)
                preconditionFailure("Invalid/incomplete native snapshot accepted")
            } catch {}
        }
        print("native C/Swift table ABI: copied rows/names, strict UTF8, stale generations and incomplete linker rejection passed")
    }
}
