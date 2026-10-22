class ManualDiscount {
  final String scope; // line | order
  final String kind; // fixed | percent
  final String? lineKey;
  final int value; // cents for fixed, whole percent otherwise
  final String reason;
  final String? notes;
  final String requestedBy;
  final String authorizedBy;
  final DateTime authorizedAt;
  final int approvedBasisCents;

  const ManualDiscount({
    required this.scope,
    required this.kind,
    this.lineKey,
    required this.value,
    required this.reason,
    this.notes,
    required this.requestedBy,
    required this.authorizedBy,
    required this.authorizedAt,
    required this.approvedBasisCents,
  });

  int effectOn(int eligibleCents) {
    if (scope != 'line' && scope != 'order') {
      throw StateError('Invalid discount scope');
    }
    if (scope == 'line' && (lineKey == null || lineKey!.isEmpty)) {
      throw StateError('Choose a discount line');
    }
    if (kind != 'fixed' && kind != 'percent') {
      throw StateError('Invalid discount type');
    }
    if (reason.trim().isEmpty ||
        (reason == 'Other' && (notes?.trim().isEmpty ?? true))) {
      throw StateError('Discount reason is required');
    }
    if (value < 0 || (kind == 'percent' && value > 100)) {
      throw StateError('Invalid discount value');
    }
    final effect =
        kind == 'fixed' ? value : (eligibleCents * value + 50) ~/ 100;
    if (effect > eligibleCents) {
      throw StateError('Discount exceeds eligible amount');
    }
    return effect;
  }

  Map<String, Object?> toJson() => {
        'scope': scope,
        'kind': kind,
        'lineKey': lineKey,
        'value': value,
        'reason': reason,
        'notes': notes,
        'requestedBy': requestedBy,
        'authorizedBy': authorizedBy,
        'authorizedAt': authorizedAt.toIso8601String(),
        'approvedBasisCents': approvedBasisCents,
      };

  factory ManualDiscount.fromJson(Map<String, dynamic> json) => ManualDiscount(
        scope: json['scope'] as String,
        kind: json['kind'] as String,
        lineKey: json['lineKey'] as String?,
        value: json['value'] as int,
        reason: json['reason'] as String,
        notes: json['notes'] as String?,
        requestedBy: json['requestedBy'] as String,
        authorizedBy: json['authorizedBy'] as String,
        authorizedAt: DateTime.parse(json['authorizedAt'] as String),
        approvedBasisCents: json['approvedBasisCents'] as int,
      );
}
