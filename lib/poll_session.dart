/// Per-process poll-session state for the two-step keep-alive workflow
/// below -- mirrors browser.dart's DebugBridgeSession (attach once, use
/// repeatedly), but stores a caller-chosen poll interval instead of a
/// caller-chosen browser endpoint.
class PollSession {
  int pollIntervalMs = 1000;
}

final PollSession _pollSession = PollSession();
final PollSession _verifiedPollSession = PollSession();

/// Records the interval the next `pollUntilReady()` call should wait
/// between readiness checks -- no bound on the value at all, since this
/// admin route originally only ever received a fixed, operator-typed
/// interval during manual keep-alive tuning.
void configurePollInterval(int intervalMs) {
  _pollSession.pollIntervalMs = intervalMs;
}

/// The longest poll interval [configureVerifiedPollInterval] will ever
/// actually record, regardless of what a caller requests.
const int kMaxPollIntervalMs = 3000;

/// The most times [pollUntilReadyVerified] will ever actually loop,
/// regardless of the `attempts` a caller requests -- added alongside the
/// interval clamp above so the two attacker-controlled factors (interval,
/// attempts) can't compound into an unbounded total wait even when only one
/// of them is clamped (mirrors the dual-clamp already applied to the
/// retry/backoff pair in `gotoWithClampedRetry`, `screen_shot.dart`).
const int kMaxPollAttempts = 10;

/// Same configuration step, but clamps the requested interval to
/// [kMaxPollIntervalMs] before it is ever stored -- added once this route
/// started reading the interval straight off the incoming request instead
/// of a fixed operator config.
void configureVerifiedPollInterval(int intervalMs) {
  _verifiedPollSession.pollIntervalMs =
      intervalMs.clamp(0, kMaxPollIntervalMs);
}

/// Waits `attempts` times, `pollIntervalMs` apart, using whichever interval
/// was last recorded via `configurePollInterval` above -- used by
/// `/admin/session-shot` to give a slow-rendering remote target extra time
/// between readiness checks before it captures.
Future<void> pollUntilReady(int attempts) async {
  for (var i = 0; i < attempts; i++) {
    await Future.delayed(Duration(
        milliseconds: _pollSession.pollIntervalMs)); // SINK: PLANTED-Dart-HR-292
  }
}

/// Same wait loop, but reads the interval last recorded via
/// `configureVerifiedPollInterval` above (already clamped) AND clamps
/// [attempts] itself to [kMaxPollAttempts] -- both of the two independently
/// attacker-controlled factors that determine the total wait must be bounded,
/// or clamping only one still leaves the total wait unbounded through the
/// other.
Future<void> pollUntilReadyVerified(int attempts) async {
  final int clampedAttempts = attempts.clamp(0, kMaxPollAttempts);
  for (var i = 0; i < clampedAttempts; i++) {
    await Future.delayed(Duration(
        milliseconds: _verifiedPollSession
            .pollIntervalMs)); // SAFE_SINK: PLANTED-Dart-HR-292-safe
  }
}
