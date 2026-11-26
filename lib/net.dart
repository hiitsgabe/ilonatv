import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the content sources take in place of [getJson] and [postJson], so tests
/// can hand them canned answers. The real functions also accept a `timeout`,
/// which is optional, so they fit.
typedef Fetch = Future<Map<String, dynamic>> Function(
  Uri uri, {
  Map<String, String> headers,
});
typedef Post = Future<Map<String, dynamic>> Function(
  Uri uri,
  Map<String, dynamic> body, {
  Map<String, String> headers,
});

/// [getText] in the same way: a page that is not JSON.
typedef GetText = Future<String> Function(
  Uri uri, {
  Map<String, String> headers,
});

/// A response outside 200-299. [body] is the text the service sent with it.
class HttpStatusException implements Exception {
  final int status;
  final String body;
  const HttpStatusException(this.status, this.body);

  @override
  String toString() => 'HttpStatusException($status)';
}

/// How long one request may take before its caller stops waiting.
const kRequestTimeout = Duration(seconds: 15);

final _client = HttpClient()
  ..connectionTimeout = const Duration(seconds: 10)
  ..maxConnectionsPerHost = 4
  ..userAgent = 'IlonaTv/0.2';

/// An object comes back as is, an array as `{'items': array}`. Anything else
/// is a [FormatException].
Future<Map<String, dynamic>> getJson(
  Uri uri, {
  Map<String, String> headers = const {},
  Duration timeout = kRequestTimeout,
}) async => _object(await _send('GET', uri, headers: headers).timeout(timeout));

Future<Map<String, dynamic>> postJson(
  Uri uri,
  Map<String, dynamic> body, {
  Map<String, String> headers = const {},
  Duration timeout = kRequestTimeout,
}) async => _object(
  await _send('POST', uri, headers: headers, json: body).timeout(timeout),
);

/// The body as UTF-8 text, malformed bytes kept as U+FFFD.
Future<String> getText(
  Uri uri, {
  Map<String, String> headers = const {},
  Duration timeout = kRequestTimeout,
}) async => utf8.decode(
  await _send('GET', uri, headers: headers).timeout(timeout),
  allowMalformed: true,
);

Future<Uint8List> getBytes(Uri uri, {Duration timeout = kRequestTimeout}) =>
    _send('GET', uri).timeout(timeout);

// ponytail: the callers' .timeout() only stops waiting. A request that timed
// out keeps its socket until the server answers or closes it; abort() the
// request if hung sockets ever pile up.
Future<Uint8List> _send(
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  Map<String, dynamic>? json,
}) async {
  // Before the request is opened: a body that cannot be encoded must not leave
  // a request open behind it.
  final data = json == null ? null : utf8.encode(jsonEncode(json));
  final request = await _client.openUrl(method, uri);
  headers.forEach(request.headers.set);
  if (data != null) {
    // With a Content-Length: some servers and proxies refuse chunked bodies.
    request.headers.contentType = ContentType(
      'application',
      'json',
      charset: 'utf-8',
    );
    request.contentLength = data.length;
    request.add(data);
  }
  final response = await request.close();
  // Drain it before looking at the status, so the connection is always freed.
  // toBytes() copies into a buffer of exactly the body's size. takeBytes()
  // would return a view of the builder's growth buffer, 2.6 to 3.4 times as big
  // (measured), and the images kept in memory would carry that slack around.
  final body = (await response.fold(
    BytesBuilder(),
    (b, chunk) => b..add(chunk),
  )).toBytes();
  if (response.statusCode < 200 || response.statusCode > 299) {
    throw HttpStatusException(
      response.statusCode,
      utf8.decode(body, allowMalformed: true),
    );
  }
  return body;
}

Map<String, dynamic> _object(List<int> bytes) {
  final json = jsonDecode(utf8.decode(bytes));
  if (json is Map<String, dynamic>) return json;
  if (json is List) return {'items': json};
  throw const FormatException('expected a JSON object or array');
}
