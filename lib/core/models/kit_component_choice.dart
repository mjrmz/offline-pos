class KitComponentChoice {
  final String? batchId;
  final List<String> serialIds;
  const KitComponentChoice({this.batchId, this.serialIds = const []});

  Map<String, Object?> toJson() => {
    'batchId': batchId,
    'serialIds': serialIds,
  };

  factory KitComponentChoice.fromJson(Map<String, dynamic> json) =>
      KitComponentChoice(
        batchId: json['batchId'] as String?,
        serialIds: (json['serialIds'] as List? ?? const []).cast<String>(),
      );
}
