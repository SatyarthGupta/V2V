import Foundation

/// Where AI playback was cut off by a barge-in: sent as `conversation.item.truncate` (D-004).
nonisolated struct PlaybackCut: Equatable, Sendable {
    let itemID: String
    let playedMs: Int
}

/// Tracks scheduled vs. played AI audio, so a barge-in can report exactly how much of
/// the current item the user heard (docs/LLD.md §4.3).
///
/// Buffers play in FIFO order. The head of the queue is the buffer playing right now.
/// Items play one after another, so a single running counter for the most recent item is enough.
/// It survives the queue briefly running empty while deltas are still streaming in.
nonisolated struct PlaybackClock: Sendable {
    let sampleRate: Double

    private var pending: [(itemID: String, frames: Int)] = []
    private var playedItemID: String?
    private var playedFrames = 0

    init(sampleRate: Double = 24_000) {
        self.sampleRate = sampleRate
    }

    /// True when nothing is scheduled or playing.
    var isDrained: Bool { pending.isEmpty }

    /// Item of the buffer currently playing, if any.
    var currentItemID: String? { pending.first?.itemID }

    mutating func scheduled(itemID: String, frames: Int) {
        pending.append((itemID, frames))
    }

    /// Call from the player's `.dataPlayedBack` completion for the oldest buffer.
    mutating func completedOldestBuffer() {
        guard !pending.isEmpty else { return }
        let finished = pending.removeFirst()
        if finished.itemID != playedItemID {
            playedItemID = finished.itemID
            playedFrames = 0
        }
        playedFrames += finished.frames
    }

    /// The cut point for the item playing now, given how far into the head buffer playback got.
    /// Returns `nil` if nothing is playing, so there's nothing to truncate.
    func cut(framesIntoCurrentBuffer: Int) -> PlaybackCut? {
        guard let head = pending.first else { return nil }
        let intoHead = min(max(framesIntoCurrentBuffer, 0), head.frames)
        let alreadyPlayed = head.itemID == playedItemID ? playedFrames : 0
        let frames = alreadyPlayed + intoHead
        return PlaybackCut(itemID: head.itemID, playedMs: Int((Double(frames) * 1000 / sampleRate).rounded()))
    }

    /// Call after flushing the player (barge-in, route loss, interruption).
    mutating func reset() {
        pending.removeAll()
        playedItemID = nil
        playedFrames = 0
    }
}
