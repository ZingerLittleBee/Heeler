/// The part of a poll loop's timeout that has run, counting no gap between
/// polls as more than `maxGap`.
///
/// A loaded CI runner can stall the main actor for longer than a whole
/// timeout, and the work a test waits on often needs the main actor too, as
/// image staging does, so it cannot finish during the stall either. A
/// wall-clock deadline runs out in the stall, and the loop gives up moments
/// before that work lands. Charging each gap at most `maxGap` keeps a stall
/// from spending the timeout on its own; a condition that never holds still
/// runs the budget out, after at least `timeout`.
struct PollBudget {
    private let timeout: Duration
    private let maxGap: Duration
    private var spent = Duration.zero
    private var lastPoll = ContinuousClock.now

    init(_ timeout: Duration, maxGap: Duration = .seconds(1)) {
        self.timeout = timeout
        self.maxGap = maxGap
    }

    var hasTimeLeft: Bool { spent < timeout }

    /// Charges the time since the previous charge, or since the budget
    /// started, up to `maxGap`.
    mutating func charge() {
        let now = ContinuousClock.now
        spent += min(lastPoll.duration(to: now), maxGap)
        lastPoll = now
    }
}
