/// Strategy interface for how a route waits before actually capturing a
/// screenshot -- mirrors this project's existing per-concern strategy
/// pattern (`BrowserSource` for browser acquisition, `NotificationSink` for
/// completion delivery) but for the pre-capture wait step. Used by
/// `/strategy-shot`.
abstract class WaitStrategy {
  Future<void> waitBeforeCapture(int requestedMs);
}

/// Waits for exactly the caller-requested duration, with no bound -- the
/// project's original wait behavior, from before a maximum was ever
/// considered.
class UnboundedWaitStrategy implements WaitStrategy {
  @override
  Future<void> waitBeforeCapture(int requestedMs) async {
    await Future.delayed(
        Duration(milliseconds: requestedMs)); // SINK: PLANTED-Dart-HR-293
  }
}

/// The longest wait [BoundedWaitStrategy] will ever actually honor,
/// regardless of what a caller requests.
const int kMaxStrategyWaitMs = 4000;

/// Same wait step, but clamps the caller-requested duration to
/// [kMaxStrategyWaitMs] first -- added once `waitMode` started being read
/// directly off the incoming request instead of a fixed operator default.
class BoundedWaitStrategy implements WaitStrategy {
  @override
  Future<void> waitBeforeCapture(int requestedMs) async {
    final clampedMs = requestedMs.clamp(0, kMaxStrategyWaitMs);
    await Future.delayed(Duration(
        milliseconds: clampedMs)); // SAFE_SINK: PLANTED-Dart-HR-293-safe
  }
}
