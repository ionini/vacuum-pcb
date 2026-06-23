//
//  TestDSL.swift
//  Vacuum PCB
//
//  A tiny line-oriented DSL for board test suites, ported from the bench-side
//  "Vacuum Tester" app so the *same* scripts can be replayed against the
//  software simulation. One statement per line:
//
//      test <name>                       — start a new test; lines below are its steps
//      set     out<N> <0|1>              — drive one mapped input port
//      wait    <N>ms | <N>s              — fixed delay (in *simulated* time)
//      waitfor ch<N> <0|1> timeout <dur> — block until a mapped probe reaches a level, else fail
//      assert  ch<N> <0|1>              — fail the test if a mapped probe isn't at the level
//      # ...                             — comment; blank lines are ignored
//
//  On hardware `out<N>` / `ch<N>` are physical pins. Here they're *logical*
//  pins the user maps onto the board's named input ports / probes (see
//  `SimTestModel`). The grammar is intentionally flat — no variables, loops, or
//  expressions — and is kept byte-compatible with the bench DSL, except the
//  pin index is no longer capped at 8: any non-negative index is accepted and
//  validity ("is this pin mapped?") is checked at run time so larger boards work.
//

import Foundation

/// One executable step. Levels are `true` = 1 / high, `false` = 0 / low.
enum TestStep: Equatable {
    case set(output: Int, on: Bool)
    case wait(seconds: Double)
    case waitFor(channel: Int, level: Bool, timeout: Double)
    case assert(channel: Int, level: Bool)

    /// Human-readable form shown in the results list.
    var label: String {
        switch self {
        case let .set(o, on):              "set out\(o) = \(on ? 1 : 0)"
        case let .wait(s):                 "wait \(Self.dur(s))"
        case let .waitFor(c, lvl, t):      "waitfor ch\(c) == \(lvl ? 1 : 0) (timeout \(Self.dur(t)))"
        case let .assert(c, lvl):          "assert ch\(c) == \(lvl ? 1 : 0)"
        }
    }

    static func dur(_ s: Double) -> String {
        s < 1 ? "\(Int((s * 1000).rounded()))ms" : "\(String(format: "%g", s))s"
    }
}

/// A named sequence of steps.
struct TestCase: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var steps: [TestStep]
}

/// A parse problem tied to a source line (1-based).
struct ParseIssue: Identifiable, Equatable {
    let id = UUID()
    let line: Int
    let message: String
}

/// Result of parsing a script: the runnable tests plus any line-numbered errors.
struct ParsedScript {
    var tests: [TestCase]
    var issues: [ParseIssue]
    var isValid: Bool { issues.isEmpty }
    var stepCount: Int { tests.reduce(0) { $0 + $1.steps.count } }

    /// Logical output pins (`out<N>`) referenced anywhere in the script, sorted.
    /// Used to render only the mapping rows a script actually needs.
    var referencedOutputs: [Int] {
        var seen = Set<Int>()
        for t in tests { for s in t.steps { if case let .set(o, _) = s { seen.insert(o) } } }
        return seen.sorted()
    }

    /// Logical input pins (`ch<N>`) referenced anywhere in the script, sorted.
    var referencedChannels: [Int] {
        var seen = Set<Int>()
        for t in tests {
            for s in t.steps {
                switch s {
                case let .assert(c, _):    seen.insert(c)
                case let .waitFor(c, _, _): seen.insert(c)
                default:                    break
                }
            }
        }
        return seen.sorted()
    }
}

enum TestParser {
    static func parse(_ source: String) -> ParsedScript {
        var tests: [TestCase] = []
        var issues: [ParseIssue] = []
        var current: TestCase?

        // Nested funcs capture the locals above by reference.
        func flush() {
            if let c = current { tests.append(c); current = nil }
        }
        func ensureCurrent() {
            if current == nil { current = TestCase(name: "Test \(tests.count + 1)", steps: []) }
        }
        func append(_ step: TestStep) {
            ensureCurrent()
            current?.steps.append(step)
        }

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            let lineNo = i + 1

            // Strip trailing comment, then trim.
            var text = String(raw)
            if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            let verb = tokens[0].lowercased()

            switch verb {
            case "test":
                flush()
                let name = trimmed.dropFirst(tokens[0].count).trimmingCharacters(in: .whitespaces)
                current = TestCase(name: name.isEmpty ? "Test \(tests.count + 1)" : name, steps: [])

            case "set":
                guard tokens.count == 3, let out = outputIndex(tokens[1]) else {
                    issues.append(.init(line: lineNo, message: "usage: set out<N> <0|1>")); break
                }
                guard let lvl = level(tokens[2]) else {
                    issues.append(.init(line: lineNo, message: "level must be 0 or 1")); break
                }
                append(.set(output: out, on: lvl))

            case "wait":
                guard tokens.count == 2, let secs = duration(tokens[1]) else {
                    issues.append(.init(line: lineNo, message: "usage: wait <N>ms | <N>s")); break
                }
                append(.wait(seconds: secs))

            case "waitfor":
                guard tokens.count == 5, tokens[3].lowercased() == "timeout",
                      let ch = channelIndex(tokens[1]), let lvl = level(tokens[2]),
                      let secs = duration(tokens[4]) else {
                    issues.append(.init(line: lineNo, message: "usage: waitfor ch<N> <0|1> timeout <dur>")); break
                }
                append(.waitFor(channel: ch, level: lvl, timeout: secs))

            case "assert":
                guard tokens.count == 3, let ch = channelIndex(tokens[1]) else {
                    issues.append(.init(line: lineNo, message: "usage: assert ch<N> <0|1>")); break
                }
                guard let lvl = level(tokens[2]) else {
                    issues.append(.init(line: lineNo, message: "level must be 0 or 1")); break
                }
                append(.assert(channel: ch, level: lvl))

            default:
                issues.append(.init(line: lineNo, message: "unknown command '\(tokens[0])'"))
            }
        }
        flush()
        return ParsedScript(tests: tests, issues: issues)
    }

    // MARK: - Token helpers

    /// `out<N>` where N is any non-negative output index. The mapping onto a
    /// named board input is resolved (and validated) at run time.
    private static func outputIndex(_ s: String) -> Int? {
        guard s.lowercased().hasPrefix("out"), let n = Int(s.dropFirst(3)), n >= 0 else { return nil }
        return n
    }

    /// `ch<N>` where N is any non-negative channel index.
    private static func channelIndex(_ s: String) -> Int? {
        guard s.lowercased().hasPrefix("ch"), let n = Int(s.dropFirst(2)), n >= 0 else { return nil }
        return n
    }

    /// 0/1 plus a few friendly synonyms.
    private static func level(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "1", "high", "on", "true": return true
        case "0", "low", "off", "false": return false
        default: return nil
        }
    }

    /// `200ms`, `1.5s`, or a bare number (seconds). Returns seconds.
    private static func duration(_ s: String) -> Double? {
        let t = s.lowercased()
        if t.hasSuffix("ms"), let v = Double(t.dropLast(2)), v >= 0 { return v / 1000 }
        if t.hasSuffix("s"), let v = Double(t.dropLast(1)), v >= 0 { return v }
        if let v = Double(t), v >= 0 { return v }
        return nil
    }
}
