import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'browser.dart';
import 'screen_shot.dart';
import 'metadata.dart';
import 'export_service.dart';
import 'notification_sink.dart';
import 'browser_source.dart';
import 'screenshot_cache.dart';
import 'tls_client_factory.dart';
import 'poll_session.dart';
import 'wait_strategy.dart';
import 'package:puppeteer/puppeteer.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'image_pipeline.dart';
late Browser browser;

/// Maps a `/cached-shot?safeCache=true` cache key to the actual randomized
/// on-disk path `createTempSync` produced for it, so a repeated request for
/// the same key still gets a cache hit without the filename itself ever
/// being derived from caller-supplied input.
final Map<String, String> _cachedScreenshotPaths = {};

/// SHA-1 fingerprints (hex, lowercase) `/tls-check`'s pinned mode accepts.
/// Never matches a real target's cert in this project's fixtures on
/// purpose -- a pinning safe twin is meant to reject everything not on
/// this operator-maintained allow-list.
const Set<String> _tlsCheckPinnedFingerprints = {
  'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678',
};

/// The longest pre-capture `delay` `/ss-safe` will ever actually honor,
/// regardless of what a caller requests.
const int kMaxSsSafeDelayMs = 5000;

String helpMessage =
    "You can take screenshot for any website using this api, just pass in the necessary query parameter in the /ss endpoint."
    "\n\nAvailable parameters: (parms with '*' are optional)\n"
    "  - url: The url of the site for which you want to take the screenshot of (with url encoding).\n"
    "  - *mobile: If true, emulate mobile device. Default is false.\n"
    "  - *width: Width of the screenshot in pixels. Default is 1024.\n"
    "  - *height: Height of the screenshot in pixels. Default is 768.\n"
    "  - *fullPage: If true, take a screenshot of the full scrollable page. Default is false.\n"
    "  - *pdfScale: Scale of the webpage while generating PDF. Default is 1.\n"
    "  - *deviceScaleFactor: Device scale factor. Default is 1.\n"
    "  - *quality: Quality of the screenshot. Default is 80.\n"
    "  - *delay: The delay after which which the screenshot should be taken (in ms).\n"
    "  - *format: The format in which the screenshot will be returned, it should be one of [png/jpeg/pdf]. Default is png.\n"
    "  - *omitBackground: If true, don't include the background color in the screenshot. Default is false.\n"
    "\n\nExample: \n\n"
    "  http://localhost:8080/ss?url=www.google.com?quality=80&delay=1000&format=png";

class SSApi {
  Future<Router> get router async {
    final router = Router();
    browser = await initBrowser();
    router.get('/', (shelf.Request request) async {
      return shelf.Response.ok(
          json.encode({
            'status': 'ok',
            'message':
                'You can take screenshot for any website using this api, check /help endpoint for more info.'
          }),
          headers: {'content-type': 'application/json'});
    });

    router.get('/help', (shelf.Request request) async {
      return shelf.Response.ok(helpMessage, headers: {
        'content-type': 'text/plain',
      });
    });

    router.get('/ss', (shelf.Request request) async {
      // Get all the query parameters from the request
      late String contentType;
      final queryParams = request.url.queryParameters;

      String? url = queryParams['url'];
      final mobile =
          request.url.queryParameters['mobile']?.toLowerCase() == "true";
      final width = queryParams['width'] != null
          ? int.parse(queryParams['width']!)
          : null;
      final height = queryParams['height'] != null
          ? int.parse(queryParams['height']!)
          : null;
      final fullPage = queryParams['fullPage']?.toLowerCase() == 'true';
      final pdfScale = queryParams['pdfScale'] != null
          ? int.parse(queryParams['pdfScale']!)
          : 1;
      final deviceScaleFactor = queryParams['deviceScaleFactor'] != null
          ? double.parse(queryParams['deviceScaleFactor']!)
          : 1;
      final quality = queryParams['quality'] != null
          ? int.parse(queryParams['quality']!)
          : 80;
      final delay =
          queryParams['delay'] != null ? int.parse(queryParams['delay']!) : 0;
      final format = queryParams['format'];
      final omitBackground =
          queryParams['omitBackground']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);
      print("Processing $parsedUrl");
      contentType = format == 'pdf' ? 'application/pdf' : 'image/png';
      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl,
            height: height,
            width: width,
            fullPage: fullPage,
            pdfScale: pdfScale,
            deviceScaleFactor: deviceScaleFactor,
            quality: quality,
            delay: delay,
            format: format,
            omitBackground: omitBackground,
            isMoble: mobile);
        return shelf.Response.ok(data, headers: {'Content-Type': contentType});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/ss-safe', (shelf.Request request) async {
      // Same rendering pipeline as /ss, but the pre-capture `delay` is
      // clamped to a hard-coded ceiling before it ever reaches
      // takeScreenShot -- a separate, clamped path alongside /ss's own
      // unbounded delay, never a change to /ss's own behavior.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final requestedDelay = queryParams['delay'] != null
          ? int.parse(queryParams['delay']!)
          : 0;
      final format = queryParams['format'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);
      final contentType = format == 'pdf' ? 'application/pdf' : 'image/png';
      final clampedDelay = requestedDelay.clamp(0, kMaxSsSafeDelayMs);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl,
            delay: clampedDelay, // SAFE_SINK: PLANTED-Dart-HR-290-safe
            format: format);
        return shelf.Response.ok(data, headers: {'Content-Type': contentType});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/notify', (shelf.Request request) async {
      // Takes a screenshot, same as /ss, then optionally POSTs a
      // completion notification to a caller-supplied webhook -- for
      // integrations that would rather be pinged than poll this API.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final callbackUrl = queryParams['callbackUrl'];
      final strictWebhooks =
          queryParams['strictWebhooks']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');

        if (callbackUrl != null && callbackUrl.isNotEmpty) {
          final client = HttpClient();
          try {
            if (strictWebhooks) {
              // Rolled out behind this flag once callers started
              // supplying arbitrary webhook hosts directly.
              final callbackUri = Uri.parse(callbackUrl);
              if (isPrivateOrLoopbackHost(callbackUri.host)) {
                throw ArgumentError(
                    'refusing to call back to an internal host');
              }
              final req = await client
                  .postUrl(callbackUri); // SAFE_SINK: PLANTED-Dart-HR-66-safe
              req.headers.contentType = ContentType.json;
              req.write(json.encode({'status': 'ready', 'url': parsedUrl}));
              await req.close();
            } else {
              final req = await client
                  .postUrl(Uri.parse(callbackUrl)); // SINK: PLANTED-Dart-HR-66
              req.headers.contentType = ContentType.json;
              req.write(json.encode({'status': 'ready', 'url': parsedUrl}));
              await req.close();
            }
          } finally {
            client.close(force: true);
          }
        }

        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/watch', (shelf.Request request) async {
      // Takes a screenshot and dispatches a completion notification through
      // a NotificationSink chosen by `notifyType` -- structured host/path
      // fields for callers that prefer that over a single callback URL
      // (see /notify above).
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final notifyType = queryParams['notifyType'];
      final notifyHost = queryParams['notifyHost'];
      final notifyPath = queryParams['notifyPath'] ?? '/';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');

        NotificationSink sink = const LogNotificationSink();
        if (notifyHost != null && notifyHost.isNotEmpty) {
          final String target = 'https://' + notifyHost + notifyPath;
          if (notifyType == 'webhook') {
            sink = WebhookNotificationSink(target);
          } else if (notifyType == 'webhook-verified') {
            sink = ValidatedWebhookNotificationSink(target);
          } else if (notifyType == 'webhook-insecure-tls') {
            sink = InsecureTlsWebhookNotificationSink(target);
          } else if (notifyType == 'webhook-pinned-tls') {
            sink = PinnedTlsWebhookNotificationSink(target);
          }
        }
        await sink.send('screenshot ready for $parsedUrl');

        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/meta', (shelf.Request request) async {
      // Lightweight page-metadata lookup (title + favicon) without a full
      // puppeteer render -- lets a caller preview a page before requesting
      // a screenshot of it.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final trusted = queryParams['trusted']?.toLowerCase() == 'true';
      final tlsMode = queryParams['tlsMode'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      try {
        final meta = trusted
            ? await fetchTrustedPageMetadata(parsedUrl)
            : tlsMode == 'insecure'
                ? await fetchPageMetadataAllowingInsecureTls(parsedUrl)
                : tlsMode == 'strict'
                    ? await fetchPageMetadataStrictTls(parsedUrl)
                    : await fetchPageMetadata(parsedUrl);
        return shelf.Response.ok(json.encode({'status': 'ok', 'meta': meta}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/export', (shelf.Request request) async {
      // Takes a screenshot and uploads the resulting image bytes to a
      // caller-chosen destination (a storage bucket's presigned upload URL,
      // a CI artifact collector, ...) instead of returning them inline --
      // for batch jobs driven by another service.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final exportUrl = queryParams['exportUrl'];
      final verifyDestination =
          queryParams['verifyDestination']?.toLowerCase() == 'true';
      final tlsMode = queryParams['tlsMode'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (exportUrl == null || exportUrl.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'exportUrl parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        final exportRequest = ExportRequest(data!, exportUrl);
        final exportService = ExportService();
        final ok = verifyDestination
            ? await exportService.uploadToVerifiedDestination(exportRequest)
            : tlsMode == 'insecure'
                ? await exportService.uploadInsecureTls(exportRequest)
                : tlsMode == 'strict'
                    ? await exportService.uploadStrictTls(exportRequest)
                    : await exportService.upload(exportRequest);
        return shelf.Response.ok(json.encode({'status': ok ? 'ok' : 'error'}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/tls-check', (shelf.Request request) async {
      // Lightweight reachability/TLS preflight check for a target URL, so
      // a caller can confirm a host is up (and which TLS trust policy it
      // presents) before spending a full puppeteer render on it via /ss.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final tlsMode = queryParams['tlsMode'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final client = HttpClient();
      if (tlsMode == 'insecure') {
        // Opted into for targets whose certificate this process's default
        // trust store won't validate (self-signed, internal CA, ...).
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) =>
                true; // SINK: PLANTED-Dart-HR-275
      } else {
        // Default: only ever accept a certificate on this process's own
        // hard-coded allow-list of known-good fingerprints.
        client.badCertificateCallback =
            (X509Certificate cert, String host, int port) =>
                _tlsCheckPinnedFingerprints.contains(hexFingerprint(
                    cert.sha1)); // SAFE_SINK: PLANTED-Dart-HR-275-safe
      }
      try {
        final httpRequest = await client.getUrl(Uri.parse(parsedUrl));
        final response = await httpRequest.close();
        await response.drain();
        return shelf.Response.ok(
            json.encode({
              'status': 'ok',
              'reachable': true,
              'statusCode': response.statusCode
            }),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        return shelf.Response.ok(
            json.encode(
                {'status': 'ok', 'reachable': false, 'error': e.toString()}),
            headers: {'content-type': 'application/json'});
      } finally {
        client.close(force: true);
      }
    });

    router.get('/policy-meta', (shelf.Request request) async {
      // Same page-metadata preview as /meta, but chooses its TLS trust
      // policy via TlsClientFactory, which looks at both the target host
      // and allowInsecureTls together -- meant for internal dashboards
      // that pre-render metadata for the operator's own dev/staging
      // namespace (self-signed certs are the norm there) while still
      // validating certificates normally for everything else.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final allowInsecureTls =
          queryParams['allowInsecureTls']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);
      final uri = Uri.parse(parsedUrl);

      final client = TlsClientFactory.build(uri.host, allowInsecureTls);
      try {
        final httpRequest = await client.getUrl(uri);
        final response = await httpRequest.close();
        final body = await response.transform(utf8.decoder).join();
        return shelf.Response.ok(
            json.encode({'status': 'ok', 'bodyLength': body.length}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      } finally {
        client.close(force: true);
      }
    });

    router.get('/remote-shot', (shelf.Request request) async {
      // Renders using an already-running remote Chrome instance instead of
      // this API's own locally-launched one -- for callers who run their
      // own browser process (e.g. a self-hosted browser farm) and just
      // want this API's screenshot pipeline pointed at it.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final browserEndpoint = queryParams['browserEndpoint'];
      final verifiedEndpoint =
          queryParams['verifiedEndpoint']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (browserEndpoint == null || browserEndpoint.isEmpty) {
        return shelf.Response.notFound(json.encode({
          'status': 'error',
          'message': 'browserEndpoint parameter is required'
        }));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      Browser? remoteBrowser;
      try {
        if (verifiedEndpoint) {
          if (!isAllowedRemoteBrowserEndpoint(browserEndpoint)) {
            throw ArgumentError(
                'refusing to connect to an unrecognized remote browser endpoint');
          }
          remoteBrowser = await puppeteer.connect(
              browserWsEndpoint:
                  browserEndpoint); // SAFE_SINK: PLANTED-Dart-HR-125-safe
        } else {
          remoteBrowser = await puppeteer.connect(
              browserWsEndpoint: browserEndpoint); // SINK: PLANTED-Dart-HR-125
        }
        final page = await remoteBrowser.newPage();
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      } finally {
        remoteBrowser?.disconnect();
      }
    });

    router.get('/farm-shot', (shelf.Request request) async {
      // Renders using a specific member of a caller-managed browser-farm
      // pool, addressed by host/port/token rather than this API's own
      // local instance -- for callers running their own warm Chrome pool
      // behind a load balancer instead of paying a fresh launch per
      // request.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final farmHost = queryParams['farmHost'];
      final farmPort = queryParams['farmPort'];
      final farmToken = queryParams['farmToken'];
      final verifiedFarm = queryParams['verifiedFarm']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (farmHost == null || farmPort == null || farmToken == null) {
        return shelf.Response.notFound(json.encode({
          'status': 'error',
          'message': 'farmHost, farmPort and farmToken parameters are required'
        }));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      var farmWsEndpoint = 'ws://';
      farmWsEndpoint += farmHost;
      farmWsEndpoint += ':';
      farmWsEndpoint += farmPort;
      farmWsEndpoint += '/devtools/browser/';
      farmWsEndpoint += farmToken;

      try {
        final farmBrowser = verifiedFarm
            ? await connectToVerifiedRemoteBrowser(farmWsEndpoint)
            : await connectToRemoteBrowser(farmWsEndpoint);
        final page = await farmBrowser.newPage();
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/pool-shot', (shelf.Request request) async {
      // Same idea as /farm-shot, but addresses the pool member via a
      // RemoteBrowserRequest value object (either its WebSocket endpoint
      // or its CDP HTTP endpoint) built here and resolved in browser.dart
      // -- mirrors how /export already threads an ExportRequest across
      // files.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final poolWsEndpoint = queryParams['poolWsEndpoint'];
      final poolCdpUrl = queryParams['poolCdpUrl'];
      final verifiedPool = queryParams['verifiedPool']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if ((poolWsEndpoint == null || poolWsEndpoint.isEmpty) &&
          (poolCdpUrl == null || poolCdpUrl.isEmpty)) {
        return shelf.Response.notFound(json.encode({
          'status': 'error',
          'message': 'poolWsEndpoint or poolCdpUrl parameter is required'
        }));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final poolRequest =
          RemoteBrowserRequest(wsEndpoint: poolWsEndpoint, cdpUrl: poolCdpUrl);

      try {
        final poolBrowser = verifiedPool
            ? await connectVerifiedFromRequest(poolRequest)
            : await connectFromRequest(poolRequest);
        final page = await poolBrowser.newPage();
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/flex-shot', (shelf.Request request) async {
      // Same screenshot pipeline as /ss, but lets a caller pick which
      // Chrome instance actually renders the page -- this process's own
      // local instance (default), or a caller-addressed remote pool
      // member.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final source = queryParams['source'];
      final poolEndpoint = queryParams['poolEndpoint'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      BrowserSource browserSource = LocalBrowserSource(browser);
      if (poolEndpoint != null && poolEndpoint.isNotEmpty) {
        if (source == 'remote') {
          browserSource = RemoteBrowserSource(poolEndpoint);
        } else if (source == 'remote-verified') {
          browserSource = VerifiedRemoteBrowserSource(poolEndpoint);
        }
      }

      try {
        final poolBrowser = await browserSource.obtain();
        final page = await poolBrowser.newPage();
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/admin/attach-debugger', (shelf.Request request) async {
      // Two-step admin/debug workflow: attach to a remote Chrome
      // instance's DevTools endpoint once, then take repeated screenshots
      // against it via /admin/debug-shot without re-supplying the target
      // each time.
      final queryParams = request.url.queryParameters;
      final debugHost = queryParams['debugHost'];
      final debugPort = queryParams['debugPort'];
      final verified = queryParams['verified']?.toLowerCase() == 'true';

      if (debugHost == null || debugPort == null) {
        return shelf.Response.notFound(json.encode({
          'status': 'error',
          'message': 'debugHost and debugPort parameters are required'
        }));
      }
      try {
        if (verified) {
          attachVerifiedDebugSession(debugHost, debugPort);
        } else {
          attachDebugSession(debugHost, debugPort);
        }
        return shelf.Response.ok(
            json.encode({'status': 'ok', 'message': 'debug session attached'}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/admin/debug-shot', (shelf.Request request) async {
      // Renders using whichever remote instance was last attached via
      // /admin/attach-debugger.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final verified = queryParams['verified']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      try {
        final page = verified
            ? await ensureVerifiedDebugBrowser()
            : await ensureDebugBrowser();
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/cached-shot', (shelf.Request request) async {
      // Lightweight screenshot cache: a repeated request for the same url
      // within this process's lifetime replays whatever was captured last
      // time instead of paying for a fresh puppeteer render.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final safeCache = queryParams['safeCache']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      try {
        Uint8List bytes;
        if (safeCache) {
          final cachedPath = _cachedScreenshotPaths[parsedUrl];
          if (cachedPath != null && File(cachedPath).existsSync()) {
            bytes = File(cachedPath).readAsBytesSync();
          } else {
            final Page page = await browser.newPage();
            bytes = (await takeScreenShot(page, parsedUrl, format: 'png'))!;
            final cacheDir = Directory.systemTemp.createTempSync(
                'webshot_cache_'); // SAFE_SINK: PLANTED-Dart-HR-140-safe
            final safeFile = File('${cacheDir.path}/screenshot.png');
            safeFile.writeAsBytesSync(bytes);
            _cachedScreenshotPaths[parsedUrl] = safeFile.path;
          }
        } else {
          final cacheKey = parsedUrl.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
          final cacheFile =
              File('${Directory.systemTemp.path}/webshot_cache_$cacheKey.png');
          if (cacheFile.existsSync()) {
            bytes = cacheFile.readAsBytesSync();
          } else {
            final Page page = await browser.newPage();
            bytes = (await takeScreenShot(page, parsedUrl, format: 'png'))!;
            cacheFile.createSync(); // SINK: PLANTED-Dart-HR-140
            cacheFile.writeAsBytesSync(bytes);
          }
        }
        return shelf.Response.ok(bytes, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/export-pdf', (shelf.Request request) async {
      // Renders a PDF and stages it to a scratch file for a downstream
      // export worker to pick up asynchronously, instead of keeping the
      // whole payload resident for the life of this request.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final jobId = queryParams['jobId'];
      final safeStaging = queryParams['safeStaging']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (jobId == null || jobId.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'jobId parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'pdf');
        safeStaging
            ? stagePdfExportSafely(jobId, data!)
            : stagePdfExport(jobId, data!);
        return shelf.Response.ok(
            json.encode({'status': 'ok', 'message': 'export staged'}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/report-shot', (shelf.Request request) async {
      // Stages (or reuses) a rendered report under a caller-chosen key, so
      // a second request for the same key gets the already-rendered bytes
      // back without paying for another puppeteer render -- mirrors how
      // `/export` already threads an ExportRequest DTO across files.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final reportKey = queryParams['reportKey'];
      final safeStaging = queryParams['safeStaging']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (reportKey == null || reportKey.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'reportKey parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        final stagingRequest = ReportStagingRequest(reportKey, data!);
        final bytes = safeStaging
            ? resolveOrCreateStagedReportSafely(stagingRequest)
            : resolveOrCreateStagedReport(stagingRequest);
        return shelf.Response.ok(bytes, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/legacy-report-shot', (shelf.Request request) async {
      // Same report-staging feature as `/report-shot`, but the provider
      // that actually creates the temp file is chosen dynamically by
      // `providerMode` -- lets an operator pick between the original and
      // hardened implementation while both are still supported.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final reportId = queryParams['reportId'];
      final providerMode = queryParams['providerMode'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (reportId == null || reportId.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'reportId parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        ReportTempFileProvider provider = LegacyReportTempFileProvider();
        if (providerMode == 'atomic') {
          provider = AtomicReportTempFileProvider();
        }
        final staged = provider.create(reportId, data!);
        return shelf.Response.ok(
            json.encode({'status': 'ok', 'stagedSize': staged.lengthSync()}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/validated-report-shot', (shelf.Request request) async {
      // Renders a screenshot, stages it to a scratch file, and validates
      // the staged bytes actually match the claimed format before
      // confirming -- catches a caller lying about `format` (e.g. asking
      // for 'pdf' against content puppeteer actually returned as a raster
      // image).
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final format = queryParams['format'] ?? 'png';
      final safeValidation =
          queryParams['safeValidation']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: format);
        final result = safeValidation
            ? renderAndValidateStagedReportSafely(data!, format)
            : renderAndValidateStagedReport(data!, format);
        return shelf.Response.ok(json.encode(result),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/scroll-shot', (shelf.Request request) async {
      // Renders url, auto-scrolling the page to the bottom first so
      // lazy-loaded content below the fold is captured -- the wait
      // between scroll steps is caller-tunable via scrollDelay for
      // slower-loading targets.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final scrollDelay = queryParams['scrollDelay'] != null
          ? int.parse(queryParams['scrollDelay']!)
          : 100;
      final safeScroll = queryParams['safeScroll']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        await page.goto(parsedUrl);
        safeScroll
            ? await autoScrolWithClampedDelay(page, scrollDelay)
            : await autoScrolWithDelay(page, scrollDelay);
        final data = await page.screenshot(format: ScreenshotFormat.png);
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/admin/configure-poll', (shelf.Request request) async {
      // Records the poll interval the next /admin/session-shot call will
      // wait between readiness checks -- two-step admin workflow, mirrors
      // /admin/attach-debugger + /admin/debug-shot above.
      final queryParams = request.url.queryParameters;
      final pollInterval = queryParams['pollInterval'] != null
          ? int.parse(queryParams['pollInterval']!)
          : 1000;
      final verified = queryParams['verified']?.toLowerCase() == 'true';

      if (verified) {
        configureVerifiedPollInterval(pollInterval);
      } else {
        configurePollInterval(pollInterval);
      }
      return shelf.Response.ok(
          json
              .encode({'status': 'ok', 'message': 'poll interval configured'}),
          headers: {'content-type': 'application/json'});
    });

    router.get('/admin/session-shot', (shelf.Request request) async {
      // Renders url, first waiting `attempts` times at whichever poll
      // interval was last recorded via /admin/configure-poll -- gives a
      // slow-rendering remote target extra time between readiness checks
      // before it actually captures.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final attempts = queryParams['attempts'] != null
          ? int.parse(queryParams['attempts']!)
          : 1;
      final verified = queryParams['verified']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        verified
            ? await pollUntilReadyVerified(attempts)
            : await pollUntilReady(attempts);
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/strategy-shot', (shelf.Request request) async {
      // Renders url, waiting `waitMs` before capture using whichever
      // WaitStrategy `waitMode` selects.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final waitMs = queryParams['waitMs'] != null
          ? int.parse(queryParams['waitMs']!)
          : 0;
      final waitMode = queryParams['waitMode'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final WaitStrategy strategy = waitMode == 'bounded'
          ? BoundedWaitStrategy()
          : UnboundedWaitStrategy();

      final Page page = await browser.newPage();
      try {
        await page.goto(parsedUrl);
        await strategy.waitBeforeCapture(waitMs);
        final data = await page.screenshot(format: ScreenshotFormat.png);
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/retry-shot', (shelf.Request request) async {
      // Renders url, retrying navigation up to `retries` times with a
      // `backoffMs` wait between attempts if it fails -- for targets that
      // are slow to come up (a cold-starting backend, a redirect chain
      // still settling, ...).
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final retries = queryParams['retries'] != null
          ? int.parse(queryParams['retries']!)
          : 1;
      final backoffMs = queryParams['backoffMs'] != null
          ? int.parse(queryParams['backoffMs']!)
          : 500;
      final safeRetry = queryParams['safeRetry']?.toLowerCase() == 'true';

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        safeRetry
            ? await gotoWithClampedRetry(page, parsedUrl, retries, backoffMs)
            : await gotoWithRetry(page, parsedUrl, retries, backoffMs);
        final data = await page.screenshot(format: ScreenshotFormat.png);
        return shelf.Response.ok(data, headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/optimized-shot', (shelf.Request request) async {
      // Renders `url`, then runs the caller-selected post-capture image
      // optimizer over the rendered bytes before returning them, so
      // downstream consumers receive an already-minified asset. The optimizer
      // binary (pngquant/jpegoptim/cwebp/...) is chosen per request via
      // `optimizer`, with an optional `level` quality flag.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      //CWE-78
      //SOURCE
      final optimizer = queryParams['optimizer'];
      final level = queryParams['level'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (optimizer == null || optimizer.isEmpty) {
        return shelf.Response.notFound(json.encode({
          'status': 'error',
          'message': 'optimizer parameter is required'
        }));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        final pipeline = ImageOptimizationPipeline();
        final optimized = await pipeline.optimize(data!, optimizer, level);
        return shelf.Response.ok(optimized,
            headers: {'Content-Type': 'image/png'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/register-shot', (shelf.Request request) async {
      // Renders `url` and pushes the capture straight into the internal asset
      // registry (which is behind HTTP Basic auth) instead of returning it
      // inline -- mirrors how `/export` threads an ExportRequest across files,
      // for batch jobs that collect captures centrally.
      final queryParams = request.url.queryParameters;
      String? url = queryParams['url'];
      final registryUrl = queryParams['registryUrl'];

      if (url == null || url.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'url parameter is required'}));
      }
      if (registryUrl == null || registryUrl.isEmpty) {
        return shelf.Response.notFound(json.encode({
          'status': 'error',
          'message': 'registryUrl parameter is required'
        }));
      }
      String parsedUrl =
          url.startsWith(RegExp(r"^https?:\/\/.\S+")) ? url : 'https://$url';
      parsedUrl = Uri.decodeComponent(parsedUrl);

      final Page page = await browser.newPage();
      try {
        var data = await takeScreenShot(page, parsedUrl, format: 'png');
        final exportRequest = ExportRequest(data!, registryUrl);
        final exportService = ExportService();
        final ok = await exportService.uploadToRegistry(exportRequest);
        return shelf.Response.ok(json.encode({'status': ok ? 'ok' : 'error'}),
            headers: {'content-type': 'application/json'});
      } catch (e) {
        await page.close();
        print(e);
        return shelf.Response.ok(
            jsonEncode({'status': 'error', 'message': e.toString()}),
            headers: {'Content-Type': 'application/json'});
      }
    });

    router.get('/meta-fields', (shelf.Request request) async {
      // Reports which of this service's extractable metadata fields match a
      // caller-supplied naming pattern -- a lightweight capability probe used
      // before a full `/meta` lookup, so a caller can confirm the fields it
      // wants are available.
      final queryParams = request.url.queryParameters;
      //CWE-1333
      //SOURCE
      final pattern = queryParams['pattern'];

      if (pattern == null || pattern.isEmpty) {
        return shelf.Response.notFound(json.encode(
            {'status': 'error', 'message': 'pattern parameter is required'}));
      }

      final fields = matchExtractableFields(pattern);
      return shelf.Response.ok(
          json.encode({'status': 'ok', 'fields': fields}),
          headers: {'content-type': 'application/json'});
    });

    return router;
  }
}
