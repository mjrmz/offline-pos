import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/licensing/activation_client.dart';
import 'package:modern_offline_pos/licensing/license_store.dart';
import 'package:modern_offline_pos/licensing/signature_verifier.dart';

void main() {
  test(
      'activation stores only verified response; errors and offline failure preserve empty store',
      () async {
    final temp = await Directory.systemTemp.createTemp('activation-test-');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      await server.close(force: true);
      await temp.delete(recursive: true);
    });
    final pair = await Ed25519().newKeyPair();
    final pub = await pair.extractPublicKey();
    final store = LicenseStore(fileOverride: File('${temp.path}/license.json'));
    final client = ActivationClient(
        Uri.parse('http://127.0.0.1:${server.port}'),
        SignatureVerifier(publicKey: pub.bytes),
        store);
    var responseCode = 200;
    var tamper = false;
    server.listen((request) async {
      expect(request.uri.path, '/v1/activate');
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      expect(body['deviceFingerprint'], 'device-a');
      final payload = <String, dynamic>{
        'licenseId': 'id',
        'customerId': 'customer',
        'edition': 'non_bir',
        'deviceId': 'device-a',
        'features': <String>[],
        'issuedAt': '2026-01-01T00:00:00.000Z',
        'expiresAt': null,
        'nonce': 'nonce'
      };
      final signature = await Ed25519()
          .sign(utf8.encode(canonicalLicensePayload(payload)), keyPair: pair);
      if (tamper) payload['edition'] = 'changed';
      request.response.statusCode = responseCode;
      request.response.write(responseCode == 200
          ? jsonEncode({
              'payload': payload,
              'signatureBase64': base64Encode(signature.bytes)
            })
          : jsonEncode({'code': 'device_limit'}));
      await request.response.close();
    });
    tamper = true;
    await expectLater(client.activate('AAAAA-BBBBB-CCCCC-DDDDD', 'device-a'),
        throwsA(isA<ActivationException>()));
    expect(await store.load(), isNull);
    tamper = false;
    responseCode = 403;
    await expectLater(client.activate('AAAAA-BBBBB-CCCCC-DDDDD', 'device-a'),
        throwsA(isA<ActivationException>()));
    expect(await store.load(), isNull);
    responseCode = 429;
    await expectLater(client.activate('AAAAA-BBBBB-CCCCC-DDDDD', 'device-a'),
        throwsA(isA<ActivationException>()));
    responseCode = 200;
    await client.activate('AAAAA-BBBBB-CCCCC-DDDDD', 'device-a');
    expect(
        (await SignatureVerifier(publicKey: pub.bytes)
                .verify((await store.load())!, 'device-a'))
            .isValid,
        true);
    await server.close(force: true);
    await expectLater(client.activate('AAAAA-BBBBB-CCCCC-DDDDD', 'device-a'),
        throwsA(isA<ActivationException>()));
    expect(await store.load(), isNotNull);
  });
}
