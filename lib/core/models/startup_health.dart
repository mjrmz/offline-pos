class StartupHealth {
  final bool databaseReady;
  final String databaseStatus;
  const StartupHealth.ready()
      : databaseReady = true,
        databaseStatus = 'healthy';
  const StartupHealth.unavailable(String reason)
      : databaseReady = false,
        databaseStatus = reason;

  bool get canUseRegister => databaseReady;
}
