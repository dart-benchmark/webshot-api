import 'package:puppeteer/puppeteer.dart' as pp;

import 'browser.dart' show isAllowedRemoteBrowserEndpoint;

/// Strategy interface for how the `/flex-shot` route obtains the [pp.Browser]
/// instance it renders a page with -- mirrors this project's existing
/// per-concern strategy-interface convention (see notification_sink.dart's
/// NotificationSink) but for browser *acquisition* rather than completion
/// notifications: which Chrome instance actually executes the page load and
/// screenshot, not what happens after the shot is taken.
abstract class BrowserSource {
  Future<pp.Browser> obtain();
}

/// Uses this process's own already-launched local Chrome instance -- the
/// default, and the only option that involves no caller-supplied
/// destination at all.
class LocalBrowserSource implements BrowserSource {
  final pp.Browser localBrowser;
  LocalBrowserSource(this.localBrowser);

  @override
  Future<pp.Browser> obtain() async => localBrowser;
}

/// Attaches to a caller-specified remote Chrome instance instead -- added
/// for operators who run their own browser pool and want a specific pool
/// member addressed directly, retrying briefly in case that instance is
/// still warming up.
class RemoteBrowserSource implements BrowserSource {
  final String wsEndpoint;
  RemoteBrowserSource(this.wsEndpoint);

  @override
  Future<pp.Browser> obtain() async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await pp.puppeteer
            .connect(browserWsEndpoint: wsEndpoint); // SINK: PLANTED-Dart-HR-128
      } catch (e) {
        lastError = e;
        await Future.delayed(Duration(milliseconds: 200));
      }
    }
    throw StateError('could not connect to remote browser: $lastError');
  }
}

/// Same feature, but only ever attaches to a pool member on the operator's
/// own allow-list -- added once the pool endpoint started coming straight
/// off the request instead of a fixed, server-side pool roster.
class VerifiedRemoteBrowserSource implements BrowserSource {
  final String wsEndpoint;
  VerifiedRemoteBrowserSource(this.wsEndpoint);

  @override
  Future<pp.Browser> obtain() async {
    if (!isAllowedRemoteBrowserEndpoint(wsEndpoint)) {
      throw ArgumentError(
          'refusing to connect to an unrecognized pool member');
    }
    return pp.puppeteer
        .connect(browserWsEndpoint: wsEndpoint); // SAFE_SINK: PLANTED-Dart-HR-128-safe
  }
}
