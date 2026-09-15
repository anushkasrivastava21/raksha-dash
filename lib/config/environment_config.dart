class EnvironmentConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://raksha-api-71a6.onrender.com',
  );

  static const String mlEngineUrl = String.fromEnvironment(
    'ML_ENGINE_URL',
    defaultValue: 'https://raksha-sim.onrender.com',
  );

  static const bool useLocalServer = bool.fromEnvironment(
    'USE_LOCAL_SERVER',
    defaultValue: false,
  );

  static const String localServerIp = String.fromEnvironment(
    'LOCAL_SERVER_IP',
    defaultValue: 'http://172.16.46.141:8000',
  );

  static String get resolvedBaseUrl {
    return useLocalServer ? localServerIp : apiBaseUrl;
  }
}

