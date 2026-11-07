import Foundation

/// Sentinel pages make a swipe past either end land on the opposite end.
enum LoopingPages {
    static func indices(count: Int) -> Range<Int> { 0..<(count > 1 ? count + 2 : max(count, 0)) }
    static func logical(_ slot: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return (slot - 1 + count) % count
    }
    static func settled(_ slot: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        if slot == 0 { return count }
        if slot == count + 1 { return 1 }
        return slot
    }
}
