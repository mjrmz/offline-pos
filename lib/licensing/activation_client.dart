// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'signature_verifier.dart';
import 'license_store.dart';

class ActivationException implements Exception {
  final String message;
  const ActivationException(this.message);
  @override
  String toString() => message;
}

class ActivationClient {
  final Uri endpoint;
  final SignatureVerifier verifier;
  final LicenseStore store;
  final HttpClient Function() clientFactory;
  ActivationClient(this.endpoint, this.verifier, this.store,
      {HttpClient Function()? clientFactory})
      : clientFactory = clientFactory ?? HttpClient.new;

  Future<void> activate(String key, String deviceId) async {
    if (endpoint.scheme != 'https' &&
        !(endpoint.scheme == 'http' &&
            (endpoint.host == 'localhost' || endpoint.host == '127.0.0.1'))) {
      throw const ActivationException('Activation service must use HTTPS.');
    }
    final client = clientFactory();
    try {
      final request = await client
          .postUrl(endpoint.resolve('/v1/activate'))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(
          {'activationKey': key.trim(), 'deviceFingerprint': deviceId}));
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      final body = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        String? code;
        try {
          code = (jsonDecode(body) as Map<String, dynamic>)['code'] as String?;
        } catch (_) {/* Unstructured server error. */}
        if (response.statusCode == 404)
          throw const ActivationException('Activation key not found.');
        if (response.statusCode == 429)
          throw const ActivationException(
              'Too many activation attempts. Try again later.');
        if (response.statusCode == 403) {
          throw ActivationException(switch (code) {
            'revoked' => 'This license has been revoked.',
            'expired' => 'This license has expired.',
            'reactivation_limit' =>
              'Reactivation allowance reached. Contact support.',
            _ => 'This license cannot activate another device.'
          });
        }
        if (response.statusCode == 400)
          throw const ActivationException(
              'Check the activation key and try again.');
        throw const ActivationException(
            'Activation service is temporarily unavailable.');
      }
      final result = await verifier.verify(body, deviceId);
      if (!result.isValid)
        throw const ActivationException(
            'The received license could not be verified.');
      await store.save(body);
    } on ActivationException {
      rethrow;
    } on SocketException {
      throw const ActivationException(
          'Activation service is temporarily unavailable.');
    } on TimeoutException {
      throw const ActivationException(
          'Activation service is temporarily unavailable.');
    } on FormatException {
      throw const ActivationException(
          'The received license could not be verified.');
    } finally {
      client.close(force: true);
    }
  }
}
