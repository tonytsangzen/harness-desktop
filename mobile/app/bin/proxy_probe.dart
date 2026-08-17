import 'dart:convert';
import 'dart:io';

import '../lib/core/relay_client.dart';
import '../lib/core/web_proxy.dart';

Future<void> main() async {
  final hostId = '8621742451123';
  final pair = await HttpClient().postUrl(Uri.parse('http://127.0.0.1:8080/relay/v1/pair'));
  pair.headers.contentType = ContentType.json;
  pair.write(jsonEncode({'deviceId': hostId, 'pin': '123456'}));
  final pr = await pair.close();
  final pj = jsonDecode(await pr.transform(utf8.decoder).join()) as Map<String, dynamic>;
  final token = pj['sessionToken'] as String?;
  if (token == null) throw StateError('pair failed: $pj');

  final client = RelayClient(relayBase: 'http://127.0.0.1:8080', sessionToken: token);
  await client.connect();
  final proxy = WebProxy(client);
  await proxy.start();
  final port = proxy.port;
  print('PROXY PORT: $port');

  // Plain plugin script (like the WebView loads).
  final req = await HttpClient().getUrl(Uri.parse(
      'http://127.0.0.1:$port/plugins/@deepseek-ai/dsh-client-ui-jobs/client.js?rev=a31e2a9cfc0c'));
  final resp = await req.close();
  final ct = resp.headers.value('content-type');
  final status = resp.statusCode;
  await resp.drain<void>();
  print('PLUGIN status=$status content-type=$ct');
  if (ct != null && ct.contains('javascript')) {
    print('RESULT: PASS');
  } else {
    print('RESULT: FAIL');
  }
  await proxy.close();
  exit(0);
}
