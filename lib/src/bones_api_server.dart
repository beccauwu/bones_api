import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async_extension/async_extension.dart';
import 'package:bones_api/bones_api.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// An API HTTP Server
class APIServer {
  static const String VERSION = '1.0.0';

  /// The API root of this server.
  final APIRoot apiRoot;

  /// The bind address of this server.
  final String address;

  /// The listen port of this server.
  final int port;

  /// The name of this server.
  ///
  /// This is used for the `server` header.
  final String name;

  /// The version of this server.
  ///
  /// This is used for the `server` header.
  final String version;

  APIServer(this.apiRoot, String address, this.port,
      {this.name = 'APIServer', this.version = VERSION})
      : address = _normalizeAddress(address);

  static String _normalizeAddress(String address) {
    address = address.trim();

    if (address.isEmpty || address == '*' || address == '0') {
      return '0.0.0.0';
    }

    if (address == 'local' || address == '1') {
      return 'localhost';
    }

    return address;
  }

  /// The `server` header value.
  String get serverName => '$name/$version';

  /// The local URL of this server.
  String get url {
    return 'http://$address:$port/';
  }

  bool _started = false;

  /// Returns `true` if this servers is started.
  bool get isStarted => _started;

  late HttpServer _httpServer;

  /// Starts this server.
  Future<bool> start() async {
    if (_started) return true;
    _started = true;

    _httpServer = await shelf_io.serve(_process, address, port);
    _httpServer.autoCompress = true;

    return true;
  }

  bool _closed = false;

  /// Returns `true` if this server is closed.type
  ///
  /// A closed server can't processe new requests.
  bool get isClosed => _closed;

  /// Stops/closes this server.
  void stop() {
    if (!_started || _closed) return;
    _closed = true;
    _httpServer.close();
  }

  FutureOr<Response> _process(Request request) {
    var apiRequest = toAPIRequest(request);
    var apiResponse = apiRoot.call(apiRequest);
    return apiResponse
        .resolveMapped((res) => _processAPIResponse(request, res));
  }

  /// Convers a [request] to an [APIRequest].
  APIRequest toAPIRequest(Request request) {
    var method = parseAPIRequestMethod(request.method)!;

    var headers = Map.fromEntries(request.headersAll.entries.map((e) {
      var vals = e.value;
      return MapEntry(e.key, vals.length == 1 ? vals[0] : vals);
    }));

    var requestedUri = request.requestedUri;

    var path = requestedUri.path;
    var parameters =
        Map.fromEntries(requestedUri.queryParametersAll.entries.map((e) {
      var vals = e.value;
      return MapEntry(e.key, vals.length == 1 ? vals[0] : vals);
    }));

    var req =
        APIRequest(method, path, parameters: parameters, headers: headers);

    return req;
  }

  Response _processAPIResponse(Request request, APIResponse apiResponse) {
    var headers = <String, Object>{};

    for (var e in apiResponse.headers.entries) {
      var value = e.value;
      if (value != null) {
        headers[e.key] = value;
      }
    }

    headers['server'] ??= serverName;

    var payload = resolveBody(apiResponse.payload);

    Response response;
    switch (apiResponse.status) {
      case APIResponseStatus.OK:
        {
          response = Response.ok(payload, headers: headers);
          break;
        }
      case APIResponseStatus.NOT_FOUND:
        {
          response = Response.notFound(payload, headers: headers);
          break;
        }
      case APIResponseStatus.UNAUTHORIZED:
        {
          response = Response.forbidden(payload, headers: headers);
          break;
        }
      case APIResponseStatus.ERROR:
        {
          var error = resolveBody(apiResponse.error);
          response =
              Response.internalServerError(body: error, headers: headers);
          break;
        }
      default:
        {
          response = Response.notFound(
              'NOT FOUND[${request.method}]: ${request.url}',
              headers: headers);
          break;
        }
    }

    return response;
  }

  /// Resolves a [payload] to a HTTP body.
  static Object? resolveBody(dynamic payload) {
    if (payload == null) return null;
    if (payload is String) return payload;
    if (payload is List<int>) return payload;
    if (payload is Stream<List<int>>) return payload;

    if (payload is DateTime) {
      return payload.toString();
    }

    try {
      var s = json.encode(payload);
      return s;
    } catch (e) {
      var s = payload.toString();
      return s;
    }
  }

  @override
  String toString() {
    return 'APIServer{ apiRoot: $apiRoot, address: $address, port: $port, started: $isStarted, closed: $isClosed }';
  }
}
