// lib/licensing/signature_verifier.dart
//
// Verifies a signed license locally against the app's embedded public key.
// The private key never ships with the app — see docs/LICENSING.md.
// No network access required — this is what makes offline operation possible
// after activation.

import 'dart:convert';
import 'package:cryptography/cryptography.dart';

class LicensePayload {
  final String licenseId;
  final String customerId;
  final String edition; // 'non_bir' | 'bir_ready'
  final String deviceId;
  final List<String> features;
  final DateTime issuedAt;
  final DateTime? expiresAt;

  LicensePayload({
    required this.licenseId,
    required this.customerId,
    required this.edition,
    required this.deviceId,
    required this.features,
    required this.issuedAt,
    this.expiresAt,
  });

  factory LicensePayload.fromJson(Map<String, dynamic> json) {
    return LicensePayload(
      licenseId: json['licenseId'] as String,
      customerId: json['customerId'] as String,
      edition: json['edition'] as String,
      deviceId: json['deviceId'] as String,
      features: List<String>.from(json['features'] as List),
      issuedAt: DateTime.parse(json['issuedAt'] as String),
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
    );
  }

  bool get isBirReady => edition == 'bir_ready';

  bool isExpired() =>
      expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

class LicenseVerificationResult {
  final bool isValid;
  final LicensePayload? payload;
  final String? error;

  LicenseVerificationResult.valid(this.payload)
      : isValid = true,
        error = null;

  LicenseVerificationResult.invalid(this.error)
      : isValid = false,
        payload = null;
}

class SignatureVerifier {
  // Embedded at build time — the app's public key, matching the private
  // key held only by the License API server. Replace with the real key.
  static const String _embeddedPublicKeyBase64 =
      'REPLACE_WITH_REAL_ED25519_PUBLIC_KEY_BASE64';

  final Ed25519 _algorithm = Ed25519();

  /// Verifies a stored license blob of the form:
  /// { "payload": {...}, "signatureBase64": "..." }
  /// against the embedded public key, and checks device binding + expiry.
  Future<LicenseVerificationResult> verify(
    String licenseJson,
    String currentDeviceId,
  ) async {
    try {
      final decoded = jsonDecode(licenseJson) as Map<String, dynamic>;
      final payloadJson = decoded['payload'] as Map<String, dynamic>;
      final signatureBase64 = decoded['signatureBase64'] as String;

      final payloadBytes = utf8.encode(jsonEncode(payloadJson));
      final signatureBytes = base64Decode(signatureBase64);
      final publicKeyBytes = base64Decode(_embeddedPublicKeyBase64);

      final publicKey =
          SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519);

      final isSignatureValid = await _algorithm.verify(
        payloadBytes,
        signature: Signature(signatureBytes, publicKey: publicKey),
      );

      if (!isSignatureValid) {
        return LicenseVerificationResult.invalid('Invalid signature');
      }

      final payload = LicensePayload.fromJson(payloadJson);

      if (payload.deviceId != currentDeviceId) {
        return LicenseVerificationResult.invalid(
          'Device mismatch — this license is bound to a different device',
        );
      }

      if (payload.isExpired()) {
        return LicenseVerificationResult.invalid('License expired');
      }

      return LicenseVerificationResult.valid(payload);
    } catch (e) {
      return LicenseVerificationResult.invalid('Malformed license: $e');
    }
  }
}
