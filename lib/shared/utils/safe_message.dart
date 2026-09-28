String safeMessage(Object error) {
  if (error is StateError) return error.message;
  if (error is ArgumentError) return '${error.message}';
  return 'Operation failed. Please try again.';
}
