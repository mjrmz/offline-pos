import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/licensing/license_store.dart';
import 'package:modern_offline_pos/licensing/signature_verifier.dart';

void main() {
  test('accepts canonical payload signed by Node License API fixture',
      () async {
    // Test-only Ed25519 seed: 32 bytes of 0x01; never a production key.
    final publicKey =
        base64Decode('iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=');
    final payload = <String, dynamic>{
      'licenseId': 'license-1',
      'customerId': 'customer-1',
      'edition': 'non_bir',
      'deviceId': 'device-a',
      'features': <String>[],
      'issuedAt': '2026-01-01T00:00:00.000Z',
      'expiresAt': null,
      'nonce': 'nonce-1'
    };
    final blob = jsonEncode({
      'payload': payload,
      'signatureBase64':
          'GSPvLnMYGS1PkM63Odk+nv+Cqk4u7xWcRuaDcmS35GiDBycXAWKkeH/qfRvcgyE8X4E8R+OrwASvjQfVJCL3Cg=='
    });
    expect(
        (await SignatureVerifier(publicKey: publicKey).verify(blob, 'device-a'))
            .isValid,
        true);
  });
  test(
      'signed local license verifies offline; tamper, wrong key, device and expiry fail',
      () async {
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPair();
    final pub = await pair.extractPublicKey();
    final verifier = SignatureVerifier(publicKey: pub.bytes);
    final payload = <String, dynamic>{
      'licenseId': 'license-1',
      'customerId': 'customer-1',
      'edition': 'non_bir',
      'deviceId': 'device-a',
      'features': <String>[],
      'issuedAt': '2026-01-01T00:00:00.000Z',
      'expiresAt': null,
      'nonce': 'nonce-1'
    };
    Future<String> signed() async => jsonEncode({
          'payload': payload,
          'signatureBase64': base64Encode((await algorithm.sign(
                  utf8.encode(canonicalLicensePayload(payload)),
                  keyPair: pair))
              .bytes)
        });
    final blob = await signed();
    final temp = await Directory.systemTemp.createTemp('license-test-');
    addTearDown(() => temp.delete(recursive: true));
    final store = LicenseStore(fileOverride: File('${temp.path}/license.json'));
    await store.save(blob);
    await store.save(blob);
    expect((await verifier.verify((await store.load())!, 'device-a')).status,
        LicenseStatus.valid);
    expect((await verifier.verify(blob, 'device-b')).status,
        LicenseStatus.deviceMismatch);
    expect(
        (await SignatureVerifier(publicKey: List.filled(32, 0))
                .verify(blob, 'device-a'))
            .status,
        LicenseStatus.invalidSignature);
    expect(
        (await verifier.verify(
                blob.replaceFirst('non_bir', 'altered'), 'device-a'))
            .status,
        LicenseStatus.invalidSignature);
    expect(
        (await verifier.verify(
                blob.replaceFirst('nonce-1', 'nonce-2'), 'device-a'))
            .status,
        LicenseStatus.invalidSignature);
    expect((await verifier.verify('{bad', 'device-a')).status,
        LicenseStatus.malformed);
    expect(
        (await verifier.verify(
                blob.replaceFirst(
                    '"signatureBase64":"', '"signatureBase64":"x'),
                'device-a'))
            .isValid,
        false);
    payload['expiresAt'] = '2026-02-01T00:00:00.000Z';
    expect(
        (await verifier.verify(await signed(), 'device-a',
                now: DateTime.utc(2026, 3)))
            .status,
        LicenseStatus.expired);
  });
}
