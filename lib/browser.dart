import 'package:puppeteer/puppeteer.dart' as pp;

Future<pp.Browser> initBrowser() async {
  final browser = await pp.puppeteer.launch(ignoreHttpsErrors: true, args: [
    "--mute-audio",
    "--no-sandbox",
    '--hide-scrollbars',
    "--disable-breakpad",
    "--disable-extensions",
    "--disable-dev-shm-usage",
    "--metrics-recording-only",
    '--force-color-profile=srgb',
    '--font-render-hinting=none',
    "--disable-renderer-backgrounding",
    "--disable-ipc-flooding-protection",
    "--disable-background-timer-throttling",
    "--disable-backgrounding-occluded-windows",
    "--disable-component-extensions-with-background-pages",
    "--disable-features=TranslateUI,BlinkGenPropertyTrees",
    "--enable-features=NetworkService,NetworkServiceInProcess",
  ]);
  browser.ignoreHttpsErrors;
  return browser;
}

// ---------------------------------------------------------------------------
// Remote-browser connection support.
//
// Some deployments run their headless Chrome instances in a separate, shared
// "browser farm" process (or a third-party browser-as-a-service endpoint)
// instead of launching a fresh local instance per request -- puppeteer
// supports this natively via `connect`, which attaches to the same
// DevTools-protocol control channel `launch` uses, just against an
// already-running instance instead of one this process just spawned.
// ---------------------------------------------------------------------------

/// Connects to an already-running remote Chrome instance over its
/// DevTools-protocol WebSocket endpoint, instead of launching a local one.
/// Used by the `/farm-shot` route for deployments that keep a warm pool of
/// browser instances behind a load balancer rather than paying the launch
/// cost per request.
Future<pp.Browser> connectToRemoteBrowser(String wsEndpoint) async {
  return pp.puppeteer.connect(browserWsEndpoint: wsEndpoint); // SINK: PLANTED-Dart-HR-126
}

/// The operator's own recognized remote-browser destinations -- endpoints
/// this process is actually meant to attach to, as opposed to whatever a
/// caller happens to name. Shared by every planted safe twin in this file
/// that connects to a caller-addressable remote browser.
final Set<String> _allowedRemoteBrowserEndpoints = {
  'ws://browser-farm.internal:9222/devtools/browser/pool-a',
  'ws://browser-farm.internal:9223/devtools/browser/pool-b',
  'http://browser-farm.internal:9222',
};

/// True if the given browser endpoint (either a WebSocket endpoint or an
/// http CDP endpoint) is one of the operator's own recognized destinations.
bool isAllowedRemoteBrowserEndpoint(String endpoint) {
  return _allowedRemoteBrowserEndpoints.contains(endpoint);
}

/// Same feature, but only ever dials a browser-farm endpoint that is on the
/// operator's own allow-list -- added once the farm target started being
/// read directly off the incoming request instead of a server-side
/// deployment config.
Future<pp.Browser> connectToVerifiedRemoteBrowser(String wsEndpoint) async {
  if (!isAllowedRemoteBrowserEndpoint(wsEndpoint)) {
    throw ArgumentError(
        'refusing to connect to an unrecognized browser-farm endpoint');
  }
  return pp.puppeteer.connect(browserWsEndpoint: wsEndpoint); // SAFE_SINK: PLANTED-Dart-HR-126-safe
}

/// A request-scoped description of which remote browser instance to attach
/// to for this call -- lets callers that manage their own browser pool
/// (e.g. a batch worker dispatching many `/pool-shot` calls against the
/// same warm instance) address it directly by either its WebSocket or its
/// CDP-HTTP endpoint, instead of this API launching a fresh local one.
class RemoteBrowserRequest {
  final String? wsEndpoint;
  final String? cdpUrl;
  RemoteBrowserRequest({this.wsEndpoint, this.cdpUrl});
}

Future<pp.Browser> connectFromRequest(RemoteBrowserRequest request) async {
  return pp.puppeteer.connect(
    browserWsEndpoint: request.wsEndpoint,
    browserUrl: request.cdpUrl,
  ); // SINK: PLANTED-Dart-HR-127
}

/// Same feature, gated behind an allow-list check on whichever endpoint form
/// the caller supplied -- introduced once the pool address started coming
/// from request-supplied fields instead of a fixed operator config.
Future<pp.Browser> connectVerifiedFromRequest(
    RemoteBrowserRequest request) async {
  final endpoint = request.wsEndpoint ?? request.cdpUrl;
  if (endpoint == null || !isAllowedRemoteBrowserEndpoint(endpoint)) {
    throw ArgumentError(
        'refusing to connect to an unrecognized browser pool endpoint');
  }
  return pp.puppeteer.connect(
    browserWsEndpoint: request.wsEndpoint,
    browserUrl: request.cdpUrl,
  ); // SAFE_SINK: PLANTED-Dart-HR-127-safe
}

/// Holds the CDP HTTP endpoint of a remote Chrome instance an operator has
/// "attached" to via `/admin/attach-debugger`, for a later
/// `/admin/debug-shot` call to connect to and render through -- a two-step
/// admin workflow so a debugging session doesn't have to re-supply its
/// target on every screenshot request.
class DebugBridgeSession {
  String? cdpUrl;
}

final DebugBridgeSession _debugSession = DebugBridgeSession();
final DebugBridgeSession _verifiedDebugSession = DebugBridgeSession();

/// Records the CDP endpoint for the next `ensureDebugBrowser()` call to
/// attach to -- no check on the value at all, since this admin route
/// originally only ever received a fixed, operator-typed host:port during
/// manual troubleshooting.
void attachDebugSession(String host, String port) {
  var url = 'http://';
  url += host;
  url += ':';
  url += port;
  _debugSession.cdpUrl = url;
}

/// The operator's own recognized debug hosts, as `host:port` pairs.
final Set<String> _allowedDebugHostPorts = {
  'browser-farm.internal:9222',
  'browser-farm.internal:9223',
};

/// Same attach step, but only records the endpoint if it matches one of the
/// operator's own known debug hosts -- added once this route started being
/// reachable with a host/port pair read straight from the request instead
/// of typed in by an operator at a trusted terminal.
void attachVerifiedDebugSession(String host, String port) {
  final hostPort = '$host:$port';
  if (!_allowedDebugHostPorts.contains(hostPort)) {
    throw ArgumentError('refusing to attach to an unrecognized debug host');
  }
  _verifiedDebugSession.cdpUrl = 'http://$hostPort';
}

/// Connects to whichever CDP endpoint was last attached via
/// `attachDebugSession` above.
Future<pp.Page> ensureDebugBrowser() async {
  final cdpUrl = _debugSession.cdpUrl;
  if (cdpUrl == null) {
    throw StateError('no debug session attached -- call attach-debugger first');
  }
  final remoteBrowser = await pp.puppeteer.connect(browserUrl: cdpUrl); // SINK: PLANTED-Dart-HR-129
  return remoteBrowser.newPage();
}

/// Same feature, for a session that can only ever have been attached via
/// `attachVerifiedDebugSession` above.
Future<pp.Page> ensureVerifiedDebugBrowser() async {
  final cdpUrl = _verifiedDebugSession.cdpUrl;
  if (cdpUrl == null) {
    throw StateError(
        'no verified debug session attached -- call attach-debugger-verified first');
  }
  final remoteBrowser = await pp.puppeteer.connect(browserUrl: cdpUrl); // SAFE_SINK: PLANTED-Dart-HR-129-safe
  return remoteBrowser.newPage();
}
