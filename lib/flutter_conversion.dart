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
  static const String accounts = '/accounts';
  static const String classification = '/classification';
  static const String sales = '/sales';
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
    AppPaths.accounts,
    AppPaths.classification,
    AppPaths.sales,
  ];

  static const Map<String, String> legacyRedirects = <String, String>{
    AppPaths.root: AppPaths.auth,
    '/quality-control': AppPaths.production,
    AppPaths.grading: AppPaths.production,
    '/collection': AppPaths.production,
    '/losses': AppPaths.production,
    '/notifications': AppPaths.dashboard,
    '/audit': AppPaths.reports,
    '/security': AppPaths.profile,
  };

  static const Set<String> adminOnlyRoutes = <String>{
    AppPaths.inventory,
    AppPaths.reports,
    AppPaths.accounts,
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
