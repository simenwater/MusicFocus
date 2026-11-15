#if DEBUG && MUSICFOCUS_HOMR
  import Foundation

  /// The decoder sees clefs, beams and adjacent measures on the system. Timing edits
  /// still require two matching readings and can only affect nominated measures.
  enum ScoreRecognitionContextReview {
    typealias Note = ScoreRecognizedNote
    typealias Sequence = ScoreRecognitionTimeline.Result
    typealias Observation = ScoreRecognitionMeasureReview.Observation
    private struct Pitch: Hashable {
      var staff: Int
      var midi: Int
    }
    private struct Event: Hashable {
      var pitch: Pitch
      var start: Int
      var duration: Int
      var voice: String?
      init(_ n: Note) {
        pitch = Pitch(staff: n.staff, midi: n.midi)
        start = Int((n.beat * 100_000).rounded())
        duration = Int((n.duration * 100_000).rounded())
        voice = n.voice
      }
    }
    private static func notes(_ sequence: Sequence) -> [[Note]] {
      let grouped = Dictionary(grouping: sequence.notes, by: \.measure)
      return sequence.bars.map { bar in
        (grouped[bar.measure] ?? []).map { source in
          var n = source
          n.beat -= bar.start
          return n
        }
      }
    }
    private static func equal(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }
    static func suspicious(_ ns: [Note], length: Double, neighbors: [Double]) -> Bool {
      guard ns.count >= 3, !neighbors.isEmpty, !ns.contains(where: { $0.decoration != nil }) else {
        return false
      }
      let fast = ns.contains { $0.duration <= 0.5 }
      if fast && !neighbors.contains(where: { equal($0, length) }) { return true }
      // Independently moving voices with a last sustained note ending early.
      // A real rest can trigger inspection, but cannot justify an edit on its own.
      let voices = Dictionary(grouping: ns, by: \.voice)
      if voices.count >= 3
        && voices.values.contains(where: { lane in
          guard let last = lane.max(by: { $0.beat + $0.duration < $1.beat + $1.duration }) else {
            return false
          }
          return lane.count >= 2 && last.duration >= 1 && last.beat + last.duration <= length - 0.25
        })
      {
        return true
      }
      // A large backwards jump in the printed attack columns contradicts the
      // decoded order. Use a median column for chords to limit attention noise.
      let columns = Dictionary(grouping: ns, by: { Int(($0.beat * 100_000).rounded()) }).sorted {
        $0.key < $1.key
      }.map { item in
        let x = item.value.map(\.point.x).sorted()
        return x[x.count / 2]
      }
      return fast && zip(columns, columns.dropFirst()).contains { $0 > $1 + 12 }
    }
    private static func signature(_ ns: [Note]) -> [Event: Int] {
      ns.reduce(into: [:]) { $0[Event($1), default: 0] += 1 }
    }
    private static func revised(_ primary: [Note], _ alternate: [Note]) -> [Note]? {
      guard primary.count == alternate.count, !alternate.contains(where: { $0.decoration != nil })
      else { return nil }
      let pitch: (Note) -> Pitch = { Pitch(staff: $0.staff, midi: $0.midi) }
      let candidates = Dictionary(grouping: alternate, by: pitch)
      let groups = Dictionary(grouping: primary.indices, by: { pitch(primary[$0]) })
      // Pair repeated instances in musical order. At a unison chord, retain
      // independent voices in deterministic order before transferring timing.
      func ordered(_ a: Note, _ b: Note) -> Bool {
        if !equal(a.beat, b.beat) { return a.beat < b.beat }
        if a.voice != b.voice { return (a.voice ?? "") < (b.voice ?? "") }
        return a.duration < b.duration
      }
      var result = primary
      for (key, indices) in groups {
        guard let ns = candidates[key], ns.count == indices.count else { return nil }
        for (i, n) in zip(
          indices.sorted { ordered(primary[$0], primary[$1]) }, ns.sorted(by: ordered))
        {
          guard abs(primary[i].point.x - n.point.x) < 32 else { return nil }
          let alters = !equal(primary[i].beat, n.beat) || !equal(primary[i].duration, n.duration)
          if alters, primary[i].slur != "_", primary[i].slur != nil, primary[i].slur != n.slur {
            return nil
          }
          result[i].beat = n.beat
          result[i].duration = n.duration
          result[i].voice = n.voice
        }
      }
      return result
    }
    private struct Proposal {
      var notes: [Note]
      var length: Double
      var optical: Bool
    }
    /// A repeated short note is blocked by another voice on the same staff.
    /// The independent longer voice, empty space in the bar, original rests,
    /// and a contextual reading must all support the earlier entry.
    private static func releasedVoice(
      _ ns: [Note], tokens: ArraySlice<ScoreRecognitionSymbol>,
      length: Double, neighbors: [Double]
    ) -> Proposal? {
      guard ns.count >= 3, !tokens.contains(where: { $0.rhythm.hasPrefix("rest_") || $0.isGrace }),
        !ns.contains(where: { $0.decoration != nil }),
        let end = ns.map(\.beat).max(), end > 0, neighbors.contains(where: { equal($0, end) })
      else { return nil }
      let late = ns.indices.filter { equal(ns[$0].beat, end) }
      guard late.count == 1, let j = late.first else { return nil }
      let n = ns[j]
      let d = n.duration
      guard equal(2 * d, end), equal(end + d, length),
        ns.contains(where: {
          equal($0.beat, 0) && equal($0.duration, end) && $0.staff == n.staff && $0.voice == n.voice
        }),
        let first = ns.first(where: {
          equal($0.beat, 0) && equal($0.duration, d) && $0.staff == n.staff && $0.midi == n.midi
            && $0.voice != nil && $0.voice != n.voice
        }),
        n.point.x > first.point.x + 8,
        ns.enumerated().allSatisfy({
          $0.offset == j || $0.element.beat + $0.element.duration <= end + 0.0001
        })
      else { return nil }
      var proposed = ns
      proposed[j].beat = d
      proposed[j].voice = first.voice
      return Proposal(notes: proposed, length: end, optical: false)
    }

    /// Read a continuous beamed pattern passed between hands. The rests on
    /// each staff must independently account for all the time played by the other.
    private static func sharedRun(
      _ ns: [Note], tokens: ArraySlice<ScoreRecognitionSymbol>, length: Double,
      beamCount: (ScoreRecognitionSymbol) -> Int?
    ) -> Proposal? {
      guard ns.count >= 8, let short = ns.first?.duration,
        equal(short, 0.125) || equal(short, 0.25),
        ns.allSatisfy({ equal($0.duration, short) && $0.decoration == nil }),
        equal(Double(ns.count) * 2 * short, length),
        Set(ns.compactMap(\.voice)).count == 2, Set(ns.map(\.staff)).count == 2,
        !tokens.contains(where: { $0.rhythm == "chord" || $0.isGrace })
      else { return nil }
      let timed = tokens.filter { $0.duration > 0 }
      let lanes = Dictionary(grouping: timed, by: \.position)
      guard lanes.count == 2,
        lanes.values.allSatisfy({ lane in
          let rests = lane.filter { $0.rhythm.hasPrefix("rest_") }.map(\.duration).reduce(0, +)
          return rests > 0
            && equal(rests + 2 * short * Double(lane.filter { $0.midi != nil }.count), length)
        })
      else { return nil }
      let order = ns.indices.sorted { ns[$0].point.x < ns[$1].point.x }
      let gaps = zip(order.dropFirst(), order).map { ns[$0].point.x - ns[$1].point.x }
      guard let minimum = gaps.min(), let maximum = gaps.max(), minimum > 2, maximum < 2.8 * minimum
      else { return nil }
      let expected = equal(short, 0.125) ? 2 : 1
      var votes = 0
      var other = 0
      var hands = Set<String>()
      for symbol in timed where symbol.midi != nil {
        if let beams = beamCount(symbol) {
          if beams == expected {
            votes += 1
            hands.insert(symbol.position)
          } else {
            other += 1
          }
        }
      }
      guard votes >= 3, hands.count == 2, votes >= 3 * max(1, other) else { return nil }
      var updated = ns
      for (col, j) in order.enumerated() {
        updated[j].beat = Double(col) * 2 * short
        updated[j].duration = 2 * short
      }
      return Proposal(notes: updated, length: length, optical: true)
    }
    private static func timedMatch(_ a: [Note], _ b: [Note]) -> Bool {
      func signature(_ ns: [Note]) -> [Event: Int] {
        ns.reduce(into: [:]) { accum, n in
          var e = Event(n)
          e.voice = nil
          accum[e, default: 0] += 1
        }
      }
      return signature(a) == signature(b)
    }
    static func run(
      _ primary: Sequence, protected: Set<Int>, symbols: [ScoreRecognitionSymbol],
      beamCount: (ScoreRecognitionSymbol) -> Int?, read: (Bool) throws -> Sequence,
      observe: (Observation) -> Void
    ) throws -> Sequence {
      let bars = primary.bars
      guard bars.count >= 2 else { return primary }
      let original = notes(primary)
      func adjacent(_ i: Int) -> [Double] {
        bars.indices.filter { $0 != i && abs(i - $0) <= 2 }.map { bars[$0].duration }
      }
      let spans = ScoreRecognitionMeasureReview.spans(symbols)
      guard spans.count == bars.count else { return primary }
      var structural: [Int: Proposal] = [:]
      var marked: [Int] = []
      for i in bars.indices where !protected.contains(bars[i].measure) {
        let tokens = symbols[spans[i]]
        let ns = original[i]
        let length = bars[i].duration
        let proposal =
          releasedVoice(ns, tokens: tokens, length: length, neighbors: adjacent(i))
          ?? sharedRun(ns, tokens: tokens, length: length, beamCount: beamCount)
        if let proposal { structural[i] = proposal }
        if proposal != nil || suspicious(ns, length: length, neighbors: adjacent(i)) {
          marked.append(i)
        }
      }
      guard !marked.isEmpty else { return primary }
      let start = ProcessInfo.processInfo.systemUptime
      var count = 0
      var changes = Set<Int>()
      defer {
        for (index, i) in marked.enumerated() {
          // Decoding cost belongs to the system once, even if several bars share it.
          observe(
            .init(
              measure: bars[i].measure, reads: index == 0 ? count : 0,
              change: changes.contains(i) ? "context-rhythm" : "none",
              seconds: index == 0 ? ProcessInfo.processInfo.systemUptime - start : 0))
        }
      }
      func decode(_ smaller: Bool) throws -> Sequence? {
        try Task.checkCancellation()
        count += 1
        do { return try read(smaller) } catch is CancellationError {
          throw CancellationError()
        } catch { return nil }
      }
      guard let first = try decode(false), first.bars.count == bars.count else { return primary }
      let a = notes(first)
      var proposals: [Int: [Note]] = [:]
      for i in marked {
        let len = first.bars[i].duration
        guard adjacent(i).contains(where: { equal($0, len) }),
          signature(original[i]) != signature(a[i]),
          let update = revised(original[i], a[i])
        else { continue }
        proposals[i] = update
      }
      guard !proposals.isEmpty || !structural.isEmpty, let second = try decode(true),
        second.bars.count == bars.count
      else { return primary }
      let b = notes(second)
      var output = primary
      var clock = 0.0
      output.notes = []
      for i in bars.indices {
        var ns = original[i]
        var len = bars[i].duration
        if let update = proposals[i], equal(first.bars[i].duration, second.bars[i].duration),
          signature(a[i]) == signature(b[i]), revised(original[i], b[i]) != nil
        {
          ns = update
          len = first.bars[i].duration
          changes.insert(i)
        }
        if !changes.contains(i), let different = structural[i],
          revised(original[i], a[i]) != nil, revised(original[i], b[i]) != nil,
          different.optical || timedMatch(different.notes, a[i])
            || timedMatch(different.notes, b[i])
        {
          ns = different.notes
          len = different.length
          changes.insert(i)
        }
        output.bars[i].start = clock
        output.bars[i].duration = len
        for var n in ns {
          n.beat += clock
          output.notes.append(n)
        }
        clock += len
      }
      output.duration = clock
      return changes.isEmpty ? primary : output
    }
  }

#endif
