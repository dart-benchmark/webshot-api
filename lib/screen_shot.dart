import 'dart:typed_data';
import 'package:puppeteer/puppeteer.dart' as pp;

Future<Uint8List?> takeScreenShot(
  pp.Page page,
  String url, {
  String? format,
  bool? isMoble,
  bool? fullPage,
  bool? omitBackground,
  num? pdfScale,
  num? deviceScaleFactor,
  int? delay,
  int? width,
  int? height,
  int? maxTimeOut,
  int? quality = 84,
}) async {
  int defaultWidth;
  int defaultHeight;
  bool hasTouch;

  format ??= "jpg";
  quality ??= 84;
  fullPage ??= false;
  isMoble ??= false;
  omitBackground ??= false;
  delay ??= 0;
  pdfScale ??= 1;
  deviceScaleFactor ??= 1;
  maxTimeOut ??= 30000; // 30 seconds

  if (isMoble) {
    await page.setUserAgent(
        'Mozilla/5.0 (Linux; Android 8.0; Pixel 2 Build/OPD3.170816.012) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/96.0.4664.110 Mobile Safari/537.36 Dart-Webshot-API/1.0.0');
    defaultWidth = 411;
    defaultHeight = 731;
    hasTouch = true;
  } else {
    await page.setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/84.0.4147.105 Safari/537.36 Dart-Webshot-API/1.0.0');
    defaultWidth = 1280;
    defaultHeight = 960;
    hasTouch = false;
  }
  width ??= defaultWidth;
  height ??= defaultHeight;
  await page.setViewport(pp.DeviceViewport(
      width: width,
      height: height,
      hasTouch: hasTouch,
      isMobile: isMoble,
      deviceScaleFactor: deviceScaleFactor));
  await page.goto(url);
  // await autoScrol(page);
  // await page.waitForNavigation(
  //     wait: pp.Until.networkIdle, timeout: Duration(milliseconds: maxTimeOut));
  Uint8List? rawImage;
  await Future.delayed(Duration(milliseconds: delay)); // SINK: PLANTED-Dart-HR-290
  if (["png", "jpeg"].contains(format)) {
    final _format =
        format == "png" ? pp.ScreenshotFormat.png : pp.ScreenshotFormat.jpeg;
    rawImage = await page.screenshot(
        omitBackground: omitBackground,
        quality: quality,
        fullPage: fullPage,
        format: _format);
  } else {
    rawImage = await page.pdf(
        format: pp.PaperFormat.a4,
        printBackground: !omitBackground,
        landscape: false,
        scale: pdfScale);
  }
  await page.close();
  return rawImage;
}

// Thanks to elestio/ws-screenshot
// https://github.com/elestio/ws-screenshot/blob/master/API/shared.js#L239
Future<void> autoScrol(pp.Page page) async {
  int totalHeight = 0;
  do {
    await page.evaluate('window.scrollBy(0, 200)');
    await Future.delayed(Duration(milliseconds: 100));
    totalHeight += 200;
  } while (await page.evaluate('window.scrollY') >=
      totalHeight); // scroll down to bottom
}

/// Same lazy-load scroll-to-bottom helper as [autoScrol], but the wait
/// between scroll steps is caller-controlled instead of a fixed 100ms --
/// added for targets that lazy-load content on a scroll-triggered timer
/// slower than the original fixed step could reliably catch. Used by
/// `/scroll-shot`.
Future<void> autoScrolWithDelay(pp.Page page, int scrollDelayMs) async {
  int totalHeight = 0;
  do {
    await page.evaluate('window.scrollBy(0, 200)');
    await Future.delayed(
        Duration(milliseconds: scrollDelayMs)); // SINK: PLANTED-Dart-HR-291
    totalHeight += 200;
  } while (await page.evaluate('window.scrollY') >=
      totalHeight); // scroll down to bottom
}

/// The longest per-scroll-step wait [autoScrolWithClampedDelay] will ever
/// actually honor, regardless of what a caller requests.
const int kMaxScrollDelayMs = 1000;

/// Same feature as [autoScrolWithDelay], but clamps the caller-requested
/// per-step wait to [kMaxScrollDelayMs] first -- the safe counterpart
/// reachable via `/scroll-shot`'s `safeScroll` flag.
Future<void> autoScrolWithClampedDelay(pp.Page page, int scrollDelayMs) async {
  final clampedDelayMs = scrollDelayMs.clamp(0, kMaxScrollDelayMs);
  int totalHeight = 0;
  do {
    await page.evaluate('window.scrollBy(0, 200)');
    await Future.delayed(Duration(
        milliseconds: clampedDelayMs)); // SAFE_SINK: PLANTED-Dart-HR-291-safe
    totalHeight += 200;
  } while (await page.evaluate('window.scrollY') >=
      totalHeight); // scroll down to bottom
}

/// Attempts to navigate `page` to `url`, retrying up to `maxRetries` times
/// with a `backoffMs` wait between attempts if navigation throws -- for
/// targets that are slow to come up (a cold-starting backend, a redirect
/// chain still settling, ...) where puppeteer's own per-attempt navigation
/// timeout isn't enough on its own. Both the retry count and the backoff
/// are fully caller-controlled. Used by `/retry-shot`.
Future<void> gotoWithRetry(
    pp.Page page, String url, int maxRetries, int backoffMs) async {
  for (var attempt = 0; attempt < maxRetries; attempt++) {
    try {
      await page.goto(url);
      return;
    } catch (_) {
      await Future.delayed(
          Duration(milliseconds: backoffMs)); // SINK: PLANTED-Dart-HR-294
    }
  }
  await page.goto(url);
}

/// The most retry attempts, and the longest per-attempt backoff,
/// [gotoWithClampedRetry] will ever actually honor, regardless of what a
/// caller requests.
const int kMaxRetryAttempts = 5;
const int kMaxRetryBackoffMs = 2000;

/// Same feature as [gotoWithRetry], but clamps both the attempt count and
/// the per-attempt backoff to a hard-coded ceiling first -- the safe
/// counterpart reachable via `/retry-shot`'s `safeRetry` flag.
Future<void> gotoWithClampedRetry(
    pp.Page page, String url, int maxRetries, int backoffMs) async {
  final clampedRetries = maxRetries.clamp(0, kMaxRetryAttempts);
  final clampedBackoffMs = backoffMs.clamp(0, kMaxRetryBackoffMs);
  for (var attempt = 0; attempt < clampedRetries; attempt++) {
    try {
      await page.goto(url);
      return;
    } catch (_) {
      await Future.delayed(Duration(
          milliseconds:
              clampedBackoffMs)); // SAFE_SINK: PLANTED-Dart-HR-294-safe
    }
  }
  await page.goto(url);
}
