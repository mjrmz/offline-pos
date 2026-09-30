// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:convert';
import 'package:cryptography/cryptography.dart';

enum LicenseStatus {
  valid,
  missing,
  malformed,
  invalidSignature,
  deviceMismatch,
  expired
}

class LicenseVerificationResult {
  final LicenseStatus status;
  final Map<String, dynamic>? payload;
  const LicenseVerificationResult(this.status, [this.payload]);
  bool get isValid => status == LicenseStatus.valid;
  bool get isBirReady {
    if (!isValid) return false;
    final expires = payload?['expiresAt'] as String?;
    if (expires != null &&
        !DateTime.now().toUtc().isBefore(DateTime.parse(expires).toUtc())) {
      return false;
    }
    return payload?['edition'] == 'bir_ready' ||
        (payload?['features'] as List?)?.contains('bir_ready') == true;
  }
}

/// UTF-8 JSON with these eight fields in this exact order and no whitespace.
String canonicalLicensePayload(Map<String, dynamic> p) {
  const keys = [
    'licenseId',
    'customerId',
    'edition',
    'deviceId',
    'features',
    'issuedAt',
    'expiresAt',
    'nonce'
  ];
  if (p.length != keys.length || !p.keys.toSet().containsAll(keys))
    throw const FormatException('Unexpected license fields');
  for (final key in [
    'licenseId',
    'customerId',
    'edition',
    'deviceId',
    'issuedAt',
    'nonce'
  ]) {
    if (p[key] is! String || (p[key] as String).isEmpty)
      throw const FormatException('Invalid license field');
  }
  if (p['expiresAt'] != null && p['expiresAt'] is! String)
    throw const FormatException('Invalid expiration');
  if (p['features'] is! List ||
      (p['features'] as List).any((e) => e is! String))
    throw const FormatException('Invalid features');
  return jsonEncode(<String, dynamic>{for (final key in keys) key: p[key]});
}

class SignatureVerifier {
  static const embeddedPublicKeyBase64 =
      String.fromEnvironment('LICENSE_PUBLIC_KEY_BASE64');
  final List<int> publicKey;
  SignatureVerifier({List<int>? publicKey})
      : publicKey = publicKey ??
            (embeddedPublicKeyBase64.isEmpty
                ? const []
                : base64Decode(embeddedPublicKeyBase64));

  Future<LicenseVerificationResult> verify(String blob, String deviceId,
      {DateTime? now}) async {
    try {
      final envelope = jsonDecode(blob);
      if (envelope is! Map<String, dynamic> ||
          envelope.length != 2 ||
          envelope['payload'] is! Map<String, dynamic> ||
          envelope['signatureBase64'] is! String) {
        return const LicenseVerificationResult(LicenseStatus.malformed);
      }
      final payload = envelope['payload'] as Map<String, dynamic>;
      final canonical = canonicalLicensePayload(payload);
      final signature = base64Decode(envelope['signatureBase64'] as String);
      if (signature.length != 64 || publicKey.length != 32)
        return const LicenseVerificationResult(LicenseStatus.invalidSignature);
      final valid = await Ed25519().verify(utf8.encode(canonical),
          signature: Signature(signature,
              publicKey:
                  SimplePublicKey(publicKey, type: KeyPairType.ed25519)));
      if (!valid)
        return const LicenseVerificationResult(LicenseStatus.invalidSignature);
      final issued = DateTime.parse(payload['issuedAt'] as String).toUtc();
      final expiry = payload['expiresAt'] == null
          ? null
          : DateTime.parse(payload['expiresAt'] as String).toUtc();
      final current = (now ?? DateTime.now()).toUtc();
      if (issued.isAfter(current.add(const Duration(minutes: 5))) ||
          (expiry != null && !expiry.isAfter(issued))) {
        return const LicenseVerificationResult(LicenseStatus.malformed);
      }
      if (payload['deviceId'] != deviceId)
        return const LicenseVerificationResult(LicenseStatus.deviceMismatch);
      if (expiry != null && !current.isBefore(expiry))
        return const LicenseVerificationResult(LicenseStatus.expired);
      return LicenseVerificationResult(LicenseStatus.valid, payload);
    } catch (_) {
      return const LicenseVerificationResult(LicenseStatus.malformed);
    }
  }
}
