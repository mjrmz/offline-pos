import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:modern_offline_pos/licensing/license_api_configuration.dart';
import 'package:modern_offline_pos/licensing/signature_verifier.dart';
import 'package:modern_offline_pos/core/services/release_smoke_data_root.dart';
import 'dart:io';
import 'package:path/path.dart' as p;

void main() {
  test('public verification key must be valid base64 with 32 bytes', () {
    expect(SignatureVerifier.isValidPublicKeyBase64(''), isFalse);
    expect(SignatureVerifier.isValidPublicKeyBase64('not-base64'), isFalse);
    expect(SignatureVerifier.isValidPublicKeyBase64(
        base64Encode(List<int>.filled(31, 7))), isFalse);
    expect(SignatureVerifier.isValidPublicKeyBase64(
        base64Encode(List<int>.filled(32, 7))), isTrue);
  });

  test('release API origin requires HTTPS and never falls back to localhost', () {
    expect(LicenseApiConfiguration.isUsable('', release: true), isFalse);
    expect(LicenseApiConfiguration.isUsable('http://localhost:3000',
        release: true), isFalse);
    expect(LicenseApiConfiguration.isUsable('https://127.0.0.1',
        release: true), isFalse);
    expect(LicenseApiConfiguration.isUsable('https://license.example.com',
        release: true), isTrue);
    expect(LicenseApiConfiguration.isUsable('http://localhost:3000',
        release: false), isTrue);
  });

  test('internal smoke data path rejects empty, relative, and root paths', () {
    expect(() => ReleaseSmokeDataRoot.validate(null), throwsStateError);
    expect(() => ReleaseSmokeDataRoot.validate('relative'), throwsStateError);
    expect(() => ReleaseSmokeDataRoot.validate(p.rootPrefix(Directory.systemTemp.path)),
        throwsStateError);
    expect(ReleaseSmokeDataRoot.validate(Directory.systemTemp.path).path,
        p.normalize(Directory.systemTemp.path));
  });
}
