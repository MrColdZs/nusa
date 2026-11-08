import CoreGraphics

/// Usap dua jari di notch. Satu usapan cuma ngasih satu perintah, walau jarinya masih lanjut gerak.
struct SwipeDetector {
    enum Action: Equatable { case next, previous }

    private var total: CGFloat = 0
    private var fired = false
    private let threshold: CGFloat = 45

    /// `dx` dan `dy` arah jari: negatif berarti ke kiri.
    mutating func feed(began: Bool, ended: Bool, dx: CGFloat, dy: CGFloat) -> Action? {
        if began {
            total = 0
            fired = false
        }
        if ended {
            total = 0
            return nil
        }
        guard !fired, abs(dx) >= abs(dy) else { return nil }
        total += dx
        guard abs(total) >= threshold else { return nil }
        fired = true
        return total < 0 ? .next : .previous
    }
}
