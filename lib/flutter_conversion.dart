class AppPaths {
  static const String root = '/';
  static const String auth = '/auth';
  static const String forgotPassword = '/auth/forgot';
  static const String verifyEmail = '/auth/verify';
  static const String resetPassword = '/auth/reset';
  static const String dashboard = '/dashboard';
  static const String production = '/production';
  static const String grading = '/grading';
  static const String inventory = '/inventory';
  static const String reports = '/reports';
  static const String profile = '/profile';
  static const String classification = '/classification';
}

class FlutterConversion {
  static final List<String> primaryRoutes = <String>[
    AppPaths.auth,
    AppPaths.dashboard,
    AppPaths.production,
    AppPaths.grading,
    AppPaths.inventory,
    AppPaths.reports,
    AppPaths.profile,
    AppPaths.classification,
  ];

  static const Map<String, String> legacyRedirects = <String, String>{
    AppPaths.root: AppPaths.auth,
    '/quality-control': AppPaths.grading,
    '/collection': AppPaths.production,
    '/sales': AppPaths.inventory,
    '/losses': AppPaths.grading,
    '/notifications': AppPaths.dashboard,
    '/audit': AppPaths.reports,
    '/security': AppPaths.profile,
  };

  static const Set<String> adminOnlyRoutes = <String>{
    AppPaths.inventory,
    AppPaths.reports,
  };

  static String normalize(String? routeName) {
    if (routeName == null || routeName.isEmpty) {
      return AppPaths.root;
    }
    if (routeName.length > 1 && routeName.endsWith('/')) {
      return routeName.substring(0, routeName.length - 1);
    }
    return routeName;
  }
}
