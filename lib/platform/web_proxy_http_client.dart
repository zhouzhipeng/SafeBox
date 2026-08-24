import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

/// Raised when a Web build expects SafeBox's same-origin cloud proxy but the
/// current server does not provide it.
final class WebProxyUnavailableException implements Exception {
  const WebProxyUnavailableException();

  @override
  String toString() => 'SafeBox Web same-origin proxy is unavailable';
}

/// Web builds cannot read GitHub Release or Gitee attachment redirects
/// directly because those download hosts do not grant browser CORS access.
/// Route provider traffic through the restricted same-origin endpoint served
/// by `serve_safebox_web.py`. Non-Web builds keep their native HTTP client.
http.Client configureRemoteHttpClient(http.Client client) {
  if (!kIsWeb) return client;
  const configuredPath = String.fromEnvironment(
    'SBOX_WEB_PROXY_PATH',
    defaultValue: '/_safebox/proxy',
  );
  if (configuredPath.isEmpty) return client;
  final endpoint = Uri.base.resolve(configuredPath);
  return SafeBoxWebProxyClient(client, proxyEndpoint: endpoint);
}

/// Rewrites one provider request to SafeBox's same-origin proxy while
/// preserving its method, headers, length, body stream, and abort signal.
final class SafeBoxWebProxyClient extends http.BaseClient {
  SafeBoxWebProxyClient(this._inner, {required Uri proxyEndpoint})
    : _proxyEndpoint = _validateProxyEndpoint(proxyEndpoint);

  static const String markerHeader = 'x-safebox-proxy';

  final http.Client _inner;
  final Uri _proxyEndpoint;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest original) async {
    final body = original.finalize();
    final proxyUri = _proxyEndpoint.replace(
      queryParameters: <String, String>{'url': original.url.toString()},
    );
    final http.StreamedRequest request;
    if (original case http.Abortable(:final abortTrigger?)) {
      request = http.AbortableStreamedRequest(
        original.method,
        proxyUri,
        abortTrigger: abortTrigger,
      );
    } else {
      request = http.StreamedRequest(original.method, proxyUri);
    }
    request
      ..contentLength = original.contentLength
      ..followRedirects = false
      ..headers.addAll(original.headers)
      ..maxRedirects = 0
      ..persistentConnection = original.persistentConnection;
    body.listen(
      request.sink.add,
      onError: request.sink.addError,
      onDone: request.sink.close,
      cancelOnError: true,
    );

    final response = await _inner.send(request);
    if (response.headers[markerHeader] != '1') {
      await response.stream.listen((_) {}).cancel();
      throw const WebProxyUnavailableException();
    }
    return response;
  }

  @override
  void close() => _inner.close();

  static Uri _validateProxyEndpoint(Uri value) {
    if (!value.isAbsolute ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        value.hasQuery ||
        value.hasFragment ||
        (value.scheme != 'http' && value.scheme != 'https')) {
      throw ArgumentError.value(value, 'proxyEndpoint');
    }
    return value;
  }
}
