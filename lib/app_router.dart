import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_config.dart';
import 'app_state.dart';
import 'auth_api.dart';
import 'csv_download.dart';
import 'iot_egg_reading.dart';
import 'flutter_conversion.dart';
import 'live_cam_mjpeg.dart';

String _homeRoute(AppState appState) {
  return appState.isSales ? AppPaths.sales : AppPaths.dashboard;
}

class AppRouter {
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static final Set<String> _protectedRoutes = <String>{
    AppPaths.dashboard,
    AppPaths.production,
    AppPaths.grading,
    AppPaths.inventory,
    AppPaths.reports,
    AppPaths.profile,
    AppPaths.accounts,
    AppPaths.sales,
  };

  static Route<dynamic> onGenerateRoute(
    RouteSettings settings,
    AppState appState,
  ) {
    final String path = FlutterConversion.normalize(settings.name);
    final String? redirectTarget = FlutterConversion.legacyRedirects[path];

    if (redirectTarget != null) {
      return _page(settings, RedirectScreen(from: path, to: redirectTarget));
    }

    if (path == AppPaths.auth) {
      return _page(settings, AuthScreen(appState: appState));
    }
    if (path == AppPaths.forgotPassword) {
      return _page(settings, ForgotPasswordScreen(appState: appState));
    }
    if (path == AppPaths.verifyEmail) {
      final Object? args = settings.arguments;
      String? email;
      String? password;
      String? verificationCode;
      if (args is String) {
        email = args;
      } else if (args is Map) {
        email = args['email'] as String?;
        password = args['password'] as String?;
        verificationCode = args['verificationCode'] as String?;
      }
      return _page(
        settings,
        VerifyEmailScreen(
          appState: appState,
          email: email,
          password: password,
          verificationCode: verificationCode,
        ),
      );
    }
    if (path == AppPaths.resetPassword) {
      return _page(settings, ResetPasswordScreen(appState: appState));
    }

    if (!_protectedRoutes.contains(path)) {
      return _page(
        settings,
        NotFoundScreen(appState: appState, requestedPath: path),
      );
    }

    if (!appState.isAuthenticated) {
      return _page(settings, AuthRequiredScreen(requestedPath: path));
    }

    // Seller desk: only sales routes (plus profile).
    if (appState.isSales &&
        path != AppPaths.sales &&
        path != AppPaths.profile &&
        path != AppPaths.reports) {
      return _page(
        settings,
        RedirectScreen(from: path, to: AppPaths.sales),
      );
    }

    // Egg Sales desk is seller-only; admin uses dashboard sales widgets.
    if (path == AppPaths.sales && !appState.isSales) {
      return _page(
        settings,
        AccessDeniedScreen(appState: appState, requestedPath: path),
      );
    }

    // Worker floor: production/QC/dashboard/profile only.
    if (appState.isWorker &&
        (path == AppPaths.sales ||
            path == AppPaths.accounts ||
            path == AppPaths.inventory ||
            path == AppPaths.reports)) {
      return _page(
        settings,
        AccessDeniedScreen(appState: appState, requestedPath: path),
      );
    }

    if (path == AppPaths.reports &&
        !appState.isAdmin &&
        !appState.isSales) {
      return _page(
        settings,
        AccessDeniedScreen(appState: appState, requestedPath: path),
      );
    }

    // Accounts + inventory: sole admin Gmail only.
    if (FlutterConversion.adminOnlyRoutes.contains(path) && !appState.isAdmin) {
      return _page(
        settings,
        AccessDeniedScreen(appState: appState, requestedPath: path),
      );
    }

    switch (path) {
      case AppPaths.dashboard:
        return _page(settings, DashboardScreen(appState: appState));
      case AppPaths.production:
        return _page(settings, ProductionScreen(appState: appState));
      case AppPaths.grading:
        return _page(settings, GradingScreen(appState: appState));
      case AppPaths.inventory:
        return _page(settings, InventoryScreen(appState: appState));
      case AppPaths.reports:
        return _page(settings, ReportsScreen(appState: appState));
      case AppPaths.profile:
        return _page(settings, ProfileScreen(appState: appState));
      case AppPaths.accounts:
        return _page(settings, AccountScreen(appState: appState));
      case AppPaths.sales:
        return _page(settings, EggSalesScreen(appState: appState));
      default:
        return _page(
          settings,
          NotFoundScreen(appState: appState, requestedPath: path),
        );
    }
  }

  static MaterialPageRoute<void> _page(RouteSettings settings, Widget child) {
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (BuildContext context) => child,
    );
  }
}

class RedirectScreen extends StatefulWidget {
  const RedirectScreen({super.key, required this.from, required this.to});

  final String from;
  final String to;

  @override
  State<RedirectScreen> createState() => _RedirectScreenState();
}

class _RedirectScreenState extends State<RedirectScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).pushReplacementNamed(widget.to);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _StatusScaffold(
      title: 'Redirecting',
      message: 'Legacy route ${widget.from} now points to ${widget.to}.',
      actionLabel: 'Go now',
      onPressed: () => Navigator.of(context).pushReplacementNamed(widget.to),
    );
  }
}

class AuthRequiredScreen extends StatefulWidget {
  const AuthRequiredScreen({super.key, required this.requestedPath});

  final String requestedPath;

  @override
  State<AuthRequiredScreen> createState() => _AuthRequiredScreenState();
}

class _AuthRequiredScreenState extends State<AuthRequiredScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).pushReplacementNamed(AppPaths.auth);
    });
  }

  @override
  Widget build(BuildContext context) {
    return _StatusScaffold(
      title: 'Authentication Required',
      message: 'Sign in to open ${widget.requestedPath}.',
      actionLabel: 'Open sign in',
      onPressed: () =>
          Navigator.of(context).pushReplacementNamed(AppPaths.auth),
    );
  }
}

class AccessDeniedScreen extends StatelessWidget {
  const AccessDeniedScreen({
    super.key,
    required this.appState,
    required this.requestedPath,
  });

  final AppState appState;
  final String requestedPath;

  @override
  Widget build(BuildContext context) {
    return _StatusScaffold(
      title: 'Admin Access Only',
      message:
          '$requestedPath is restricted to admin users. Current role: ${appState.role?.name ?? 'guest'}.',
      actionLabel: 'Back to dashboard',
      onPressed: () =>
          Navigator.of(context).pushReplacementNamed(AppPaths.dashboard),
    );
  }
}

class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({
    super.key,
    required this.appState,
    required this.requestedPath,
  });

  final AppState appState;
  final String requestedPath;

  @override
  Widget build(BuildContext context) {
    return EggScaffold(
      appState: appState,
      title: 'Page Not Found',
      selectedRoute: requestedPath,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'The requested route is not defined in the Flutter scaffold.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 12),
          Text('Requested route: $requestedPath'),
          const SizedBox(height: 24),
          const Text(
            'Try one of these routes:',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: FlutterConversion.primaryRoutes
                .map(
                  (String route) => ActionChip(
                    label: Text(route),
                    onPressed: () =>
                        Navigator.of(context).pushReplacementNamed(route),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

String _extractAuthToken(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.contains('token=')) {
    try {
      final String? fromQuery = Uri.parse(trimmed).queryParameters['token'];
      if (fromQuery != null && fromQuery.isNotEmpty) {
        return fromQuery;
      }
    } catch (_) {
      // Fall through and use the raw text.
    }
  }
  return trimmed;
}

String _digitsOnly(String raw) => raw.replaceAll(RegExp(r'\D'), '');

class _OtpCodeField extends StatelessWidget {
  const _OtpCodeField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (BuildContext context, TextEditingValue value, _) {
        final String digits = _digitsOnly(value.text);
        return Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Row(
              children: List<Widget>.generate(6, (int index) {
                final bool filled = index < digits.length;
                final bool active = index == digits.length && enabled;
                return Expanded(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: 58,
                    margin: EdgeInsets.only(right: index == 5 ? 0 : 8),
                    decoration: BoxDecoration(
                      color: _AuthPalette.fieldBackground,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: active
                            ? _AuthPalette.primary
                            : filled
                            ? const Color(0x66EFB73E)
                            : _AuthPalette.border,
                        width: active ? 2 : 1,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      filled ? digits[index] : '',
                      style: const TextStyle(
                        color: _AuthPalette.foreground,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                );
              }),
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0.02,
                child: TextField(
                  controller: controller,
                  enabled: enabled,
                  autofocus: true,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(color: Colors.transparent),
                  cursorColor: Colors.transparent,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  onSubmitted: (_) => onSubmitted(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const String _rememberEmailKey = 'auth.remember_email';
  static const Color _orange = Color(0xFFE8B423);
  static const Color _ink = Color(0xFFF7F3EA);
  static const Color _muted = Color(0xFFC8BBA8);
  static const Color _line = Color(0x33FFFFFF);

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _workerSignUp = false;
  bool _obscurePassword = true;
  bool _rememberMe = false;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRememberedEmail();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadRememberedEmail() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? email = prefs.getString(_rememberEmailKey);
    if (!mounted || email == null || email.isEmpty) {
      return;
    }
    setState(() {
      _rememberMe = true;
      _emailController.text = email;
    });
  }

  Future<void> _persistRememberedEmail(String email) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (_rememberMe) {
      await prefs.setString(_rememberEmailKey, email);
    } else {
      await prefs.remove(_rememberEmailKey);
    }
  }

  void _openVerifyEmail({
    required String email,
    required String password,
    String? verificationCode,
    String? message,
  }) {
    if (message != null && message.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
    Navigator.of(context).pushNamed(
      AppPaths.verifyEmail,
      arguments: <String, String>{
        'email': email,
        'password': password,
        if (verificationCode != null && verificationCode.isNotEmpty)
          'verificationCode': verificationCode,
      },
    );
  }

  Future<void> _submit() async {
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }

    final String email = _emailController.text.trim();
    final String password = _passwordController.text;

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (_workerSignUp) {
        final String name = _nameController.text.trim();
        if (name.isEmpty) {
          setState(() => _error = 'Name is required');
          return;
        }
        final String? passwordError = _validateNewPassword(password);
        if (passwordError != null) {
          setState(() => _error = passwordError);
          return;
        }
        final AuthMailResult result = await widget.appState.signup(
          name: name,
          email: email,
          password: password,
          role: 'worker',
        );
        if (!mounted) {
          return;
        }
        if (widget.appState.isAuthenticated) {
          Navigator.of(context).pushReplacementNamed(_homeRoute(widget.appState));
          return;
        }
        // Codes are emailed to the real Gmail — always open verify after signup.
        _openVerifyEmail(
          email: email,
          password: password,
          message:
              'We sent a verification code to $email. Check your Gmail inbox (and Spam).',
        );
        if (result.message.isNotEmpty && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message)),
          );
        }
        return;
      }
      await widget.appState.login(email: email, password: password);
      await _persistRememberedEmail(email);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacementNamed(_homeRoute(widget.appState));
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.isUnverified || error.code == 'email_delivery_failed') {
        _openVerifyEmail(
          email: email,
          password: password,
          message: error.code == 'email_delivery_failed'
              ? 'Account saved. Fix farm email settings, then tap Resend to get your Gmail code.'
              : 'Check $email for the 6-digit code.',
        );
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Wrong email or password.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  String? _validateNewPassword(String password) {
    if (password.length < 8) {
      return 'Minimum 8 characters';
    }
    if (!RegExp(r'[A-Za-z]').hasMatch(password)) {
      return 'Include a letter';
    }
    if (!RegExp(r'\d').hasMatch(password)) {
      return 'Include a number';
    }
    return null;
  }

  String? _validateEmail(String? value) {
    final String trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return 'Email is required';
    }
    final String normalized = trimmed.toLowerCase();
    if (normalized.contains(' ') ||
        normalized.split('@').length != 2 ||
        !(normalized.endsWith('@gmail.com') ||
            normalized.endsWith('@googlemail.com'))) {
      return 'Use a real Gmail account (@gmail.com)';
    }
    if (normalized.endsWith('.local') ||
        normalized.contains('@eggsystem.local')) {
      return 'Local emails are not allowed';
    }
    return null;
  }

  InputDecoration _fieldDecoration({
    required String hintText,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: _line),
    );
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: Color(0xFFB7AA9A), fontSize: 15),
      prefixIcon: Icon(icon, color: const Color(0xFFB7AA9A), size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFF3A322B),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: _orange, width: 1.4),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFEF4444)),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.4),
      ),
    );
  }

  Widget _fieldLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: _ink,
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A120C),
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Image.asset(
            'assets/egg-factory-bg.jpg',
            fit: BoxFit.cover,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0xCC3A2A12),
                  Color(0xB31A120C),
                  Color(0xE6140E0A),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: 420,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      ClipOval(
                        child: Image.asset(
                          'assets/egg-logo.png',
                          width: 72,
                          height: 72,
                          fit: BoxFit.cover,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'SMARTSORT',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Color(0xFFE8B84A),
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.6,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Row(
                        children: <Widget>[
                          Expanded(
                            child: Divider(
                              color: Color(0xFFE8B84A),
                              thickness: 1.2,
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              'EGG SIZING, SORTING & INVENTORY SYSTEM',
                              style: TextStyle(
                                color: Color(0xFFE8B84A),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Divider(
                              color: Color(0xFFE8B84A),
                              thickness: 1.2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xD9241C16),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: const Color(0x33FFFFFF)),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 28,
                              offset: Offset(0, 12),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(24, 28, 24, 22),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                    Text(
                      _workerSignUp ? 'Create worker account' : 'Welcome Back!',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _ink,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                    ),
                    if (!_workerSignUp) ...<Widget>[
                      const SizedBox(height: 8),
                      const Text(
                        'Log in to continue to SMARTSORT',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _muted,
                          fontSize: 15,
                          height: 1.3,
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                    if (_workerSignUp) ...<Widget>[
                      _fieldLabel('Full name'),
                      TextFormField(
                        controller: _nameController,
                        textInputAction: TextInputAction.next,
                        cursorColor: _orange,
                        style: const TextStyle(color: Colors.white, fontSize: 15),
                        decoration: _fieldDecoration(
                          hintText: 'Enter your name',
                          icon: Icons.person_outline,
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                    _fieldLabel('Email'),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      cursorColor: _orange,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      validator: _validateEmail,
                      decoration: _fieldDecoration(
                        hintText: 'Enter your email',
                        icon: Icons.mail_outline_rounded,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _fieldLabel('Password'),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      cursorColor: _orange,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      onFieldSubmitted: (_) => _submit(),
                      validator: (String? value) {
                        if ((value ?? '').isEmpty) {
                          return 'Password is required';
                        }
                        return null;
                      },
                      decoration: _fieldDecoration(
                        hintText: 'Enter your password',
                        icon: Icons.lock_outline_rounded,
                        suffixIcon: IconButton(
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            color: const Color(0xFFB7AA9A),
                            size: 20,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!_workerSignUp)
                    Row(
                      children: <Widget>[
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: Checkbox(
                            value: _rememberMe,
                            onChanged: (bool? value) {
                              setState(() => _rememberMe = value ?? false);
                            },
                            activeColor: _orange,
                            side: const BorderSide(color: Color(0xFFB7AA9A)),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Remember me',
                          style: TextStyle(color: _muted, fontSize: 14),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(
                            context,
                          ).pushNamed(AppPaths.forgotPassword),
                          style: TextButton.styleFrom(
                            foregroundColor: _orange,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                          ),
                          child: const Text(
                            'Forgot Password?',
                            style: TextStyle(
                              color: _orange,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFFDC2626),
                          height: 1.35,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: _orange,
                        foregroundColor: const Color(0xFF2A2118),
                        disabledBackgroundColor: _orange.withValues(alpha: 0.55),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      child: _submitting
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Color(0xFF2A2118),
                              ),
                            )
                          : Text(_workerSignUp ? 'Sign up' : 'Log In'),
                    ),
                    const SizedBox(height: 28),
                    Wrap(
                      alignment: WrapAlignment.center,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(
                          _workerSignUp
                              ? 'Already have an account? '
                              : "Don't have an account? ",
                          style: const TextStyle(color: _muted, fontSize: 14),
                        ),
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              _workerSignUp = !_workerSignUp;
                              _error = null;
                            });
                          },
                          child: Text(
                            _workerSignUp ? 'Sign in' : 'Sign up',
                            style: const TextStyle(
                              color: _orange,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  bool _submitting = false;
  String? _message;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _message = null;
    });
    try {
      final String message = await widget.appState.forgotPassword(
        _emailController.text.trim(),
      );
      if (!mounted) {
        return;
      }
      setState(() => _message = message);
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Unable to reach the authentication server.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFormScaffold(
      title: 'Reset password',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Enter your email. If an account exists, we will send a single-use link that expires in one hour.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _AuthPalette.mutedForeground, height: 1.45),
            ),
            const SizedBox(height: 18),
            _AuthTextField(
              controller: _emailController,
              hintText: 'Email',
              prefixIcon: Icons.mail_outline_rounded,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              validator: (String? value) {
                final String trimmed = value?.trim() ?? '';
                if (trimmed.isEmpty || !trimmed.contains('@')) {
                  return 'Enter a valid email';
                }
                return null;
              },
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFED6A5A)),
              ),
            ],
            if (_message != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _AuthPalette.foreground, height: 1.4),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _AuthPalette.primary,
                foregroundColor: _AuthPalette.primaryForeground,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(_submitting ? 'Sending…' : 'Send reset link'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pushNamed(AppPaths.resetPassword),
              child: const Text(
                'Already have a reset token?',
                style: TextStyle(color: _AuthPalette.mutedForeground),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Back to sign in',
                style: TextStyle(color: _AuthPalette.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({
    super.key,
    required this.appState,
    this.email,
    this.password,
    this.verificationCode,
  });

  final AppState appState;
  final String? email;
  final String? password;
  final String? verificationCode;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final TextEditingController _tokenController = TextEditingController();
  bool _submitting = false;
  bool _verified = false;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final String token = _digitsOnly(_tokenController.text);
    if (token.length != 6) {
      setState(() => _error = 'Enter all 6 digits from your email.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _message = null;
    });
    try {
      final String message = await widget.appState.verifyEmail(token);
      if (!mounted) {
        return;
      }
      setState(() {
        _verified = true;
        _message = message;
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Unable to reach the authentication server.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _resend() async {
    final String email = widget.email?.trim() ?? '';
    if (email.isEmpty) {
      setState(() => _error = 'Return to sign up and enter your email to resend.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final AuthMailResult result = await widget.appState.resendVerification(
        email,
        password: widget.password,
      );
      if (!mounted) {
        return;
      }
      _tokenController.clear();
      setState(() {
        _message = result.emailSent || result.message.isNotEmpty
            ? 'A new code was sent to $email. Check Gmail (and Spam).'
            : 'A new code was sent to $email.';
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Unable to reach the authentication server.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _confirmGmailLink() async {
    final String email = widget.email?.trim() ?? '';
    final String password = widget.password ?? '';
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error =
            'Return to sign up, then open the Gmail verification link and try again.';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _message = null;
    });
    try {
      await widget.appState.confirmFirebaseEmail(
        email: email,
        password: password,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushReplacementNamed(_homeRoute(widget.appState));
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Unable to reach the authentication server.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFormScaffold(
      title: 'Verify email',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0x33271C15),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _AuthPalette.glassBorder),
            ),
            child: Column(
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: const Color(0x33EFB73E),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0x66EFB73E)),
                  ),
                  child: Icon(
                    _verified ? Icons.verified_rounded : Icons.mark_email_unread_outlined,
                    color: _AuthPalette.primary,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _verified
                      ? 'Email confirmed'
                      : 'Enter the 6-digit code',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _AuthPalette.foreground,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _verified
                      ? 'Your account is verified. You can sign in and start using Egg System.'
                      : widget.email == null
                      ? 'Open your Gmail for the Egg System message. Enter the 6-digit code, or open the verification link then tap Continue below.'
                      : 'We emailed ${widget.email}. Enter the 6-digit code from Gmail, or open the verification link in that message then tap “I opened the Gmail link”.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _AuthPalette.mutedForeground,
                    height: 1.45,
                    fontSize: 13.5,
                  ),
                ),
              ],
            ),
          ),
          if (!_verified) ...<Widget>[
            const SizedBox(height: 22),
            _OtpCodeField(
              controller: _tokenController,
              enabled: !_submitting,
              onSubmitted: _verify,
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFED6A5A), height: 1.35),
            ),
          ],
          if (_message != null) ...<Widget>[
            const SizedBox(height: 14),
            Text(
              _message!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _AuthPalette.foreground, height: 1.4),
            ),
          ],
          const SizedBox(height: 22),
          if (_verified)
            FilledButton(
              onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil(
                AppPaths.auth,
                (Route<dynamic> route) => false,
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _AuthPalette.primary,
                foregroundColor: _AuthPalette.primaryForeground,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('Continue to sign in'),
            )
          else ...<Widget>[
            FilledButton(
              onPressed: _submitting ? null : _verify,
              style: FilledButton.styleFrom(
                backgroundColor: _AuthPalette.primary,
                foregroundColor: _AuthPalette.primaryForeground,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(_submitting ? 'Verifying…' : 'Verify code'),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: _submitting ? null : _resend,
              child: const Text(
                'Resend code to Gmail',
                style: TextStyle(color: _AuthPalette.mutedForeground),
              ),
            ),
            TextButton(
              onPressed: _submitting ? null : _confirmGmailLink,
              child: const Text(
                'I opened the Gmail link',
                style: TextStyle(color: _AuthPalette.primary),
              ),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pushNamedAndRemoveUntil(AppPaths.auth, (Route<dynamic> route) => false),
            child: const Text(
              'Back to sign in',
              style: TextStyle(color: _AuthPalette.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _tokenController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;
  String? _message;
  String? _error;

  @override
  void initState() {
    super.initState();
    final String? queryToken = Uri.base.queryParameters['token'];
    if (queryToken != null && queryToken.isNotEmpty) {
      _tokenController.text = queryToken;
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _message = null;
    });
    try {
      final String message = await widget.appState.resetPassword(
        token: _extractAuthToken(_tokenController.text),
        password: _passwordController.text,
      );
      if (!mounted) {
        return;
      }
      setState(() => _message = message);
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Unable to reach the authentication server.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _AuthFormScaffold(
      title: 'New password',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'Paste the reset token from your email. It expires in one hour and can be used once.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _AuthPalette.mutedForeground, height: 1.45),
            ),
            const SizedBox(height: 18),
            _AuthTextField(
              controller: _tokenController,
              hintText: 'Reset token',
              prefixIcon: Icons.key_outlined,
              textInputAction: TextInputAction.next,
              validator: (String? value) {
                if ((value ?? '').trim().isEmpty) {
                  return 'Token is required';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            _AuthTextField(
              controller: _passwordController,
              hintText: 'New password (8+ chars, letter and number)',
              prefixIcon: Icons.lock_outline_rounded,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: _AuthPalette.mutedForeground,
                ),
              ),
              validator: (String? value) {
                final String password = value ?? '';
                if (password.length < 8) {
                  return 'Minimum 8 characters';
                }
                if (!RegExp(r'[A-Za-z]').hasMatch(password) ||
                    !RegExp(r'\d').hasMatch(password)) {
                  return 'Include a letter and a number';
                }
                return null;
              },
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFED6A5A)),
              ),
            ],
            if (_message != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                _message!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: _AuthPalette.foreground, height: 1.4),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: _AuthPalette.primary,
                foregroundColor: _AuthPalette.primaryForeground,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(_submitting ? 'Updating…' : 'Update password'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                context,
              ).pushNamedAndRemoveUntil(AppPaths.auth, (Route<dynamic> route) => false),
              child: const Text(
                'Back to sign in',
                style: TextStyle(color: _AuthPalette.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuthFormScaffold extends StatelessWidget {
  const _AuthFormScaffold({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final EdgeInsets viewInsets = MediaQuery.viewInsetsOf(context);
    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ColoredBox(
              color: const Color(0xFF140F0C),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    _AuthPalette.overlayTop,
                    _AuthPalette.overlayBottom,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  20,
                  24,
                  20,
                  24 + viewInsets.bottom,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Container(
                        decoration: BoxDecoration(
                          color: _AuthPalette.glassBackground,
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: _AuthPalette.glassBorder),
                        ),
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: <Widget>[
                            Text(
                              title.toUpperCase(),
                              style: const TextStyle(
                                color: _AuthPalette.foreground,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.6,
                              ),
                            ),
                            const SizedBox(height: 18),
                            child,
                          ],
                        ),
                      ),
                    ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthTextField extends StatelessWidget {
  const _AuthTextField({
    required this.controller,
    required this.hintText,
    required this.prefixIcon,
    this.validator,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.suffixIcon,
    this.onFieldSubmitted,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String hintText;
  final IconData prefixIcon;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final Widget? suffixIcon;
  final ValueChanged<String>? onFieldSubmitted;
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      obscureText: obscureText,
      inputFormatters: inputFormatters,
      cursorColor: _AuthPalette.primary,
      style: const TextStyle(color: _AuthPalette.foreground),
      onFieldSubmitted: onFieldSubmitted,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: _AuthPalette.mutedForeground),
        prefixIcon: Icon(prefixIcon, color: _AuthPalette.mutedForeground),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: _AuthPalette.fieldBackground,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 18,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _AuthPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _AuthPalette.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFED6A5A)),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFED6A5A), width: 1.5),
        ),
      ),
    );
  }
}

class _AuthPalette {
  static const Color foreground = Color(0xFFF6F1E7);
  static const Color mutedForeground = Color(0xFFB4A79A);
  static const Color primary = Color(0xFFEFB73E);
  static const Color primaryForeground = Color(0xFF271C15);
  static const Color border = Color(0xFF4B3C31);
  static const Color fieldBackground = Color(0xAA3C322C);
  static const Color tabBackground = Color(0x663D342D);
  static const Color glassBackground = Color(0xF22F2721);
  static const Color glassBorder = Color(0x26F6F1E7);
  static const Color overlayTop = Color(0xB81D140F);
  static const Color overlayBottom = Color(0xD1261B14);
}

// ── Shared palette, data classes, and helper function ─────────────────────
// Declared here so they are available to all screens and scaffold widgets
// that follow below.

String _formatDashboardDate() {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final DateTime now = DateTime.now();
  return '${months[now.month - 1]} ${now.day}, ${now.year}';
}

class _DashboardPalette {
  static const Color foreground = _AuthPalette.foreground;
  static const Color mutedForeground = _AuthPalette.mutedForeground;
  static const Color primary = _AuthPalette.primary;
  static const Color primaryForeground = _AuthPalette.primaryForeground;
  static const Color border = _AuthPalette.border;
  static const Color tabBackground = _AuthPalette.tabBackground;
  static const Color glassBackground = _AuthPalette.glassBackground;
  static const Color glassBorder = _AuthPalette.glassBorder;
  static const Color overlayTop = Color(0xCC18110D);
  static const Color overlayBottom = Color(0xE5221813);
  static const Color success = Color(0xFF3DBA6A);
  static const Color warning = Color(0xFFE8AA34);
  static const Color danger = Color(0xFFE1645A);
}

class _NavItem {
  const _NavItem({
    required this.label,
    required this.route,
    required this.icon,
  });
  final String label;
  final String route;
  final IconData icon;
}

class _DashboardStat {
  const _DashboardStat({
    required this.label,
    required this.value,
    required this.unit,
    required this.icon,
    required this.accent,
    required this.route,
    this.onTap,
    this.selected = false,
  });
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color accent;
  final String route;
  final VoidCallback? onTap;
  final bool selected;
}

class _QuickLinkItem {
  const _QuickLinkItem({
    required this.label,
    required this.route,
    required this.icon,
  });
  final String label;
  final String route;
  final IconData icon;
}

class _SeriesPoint {
  const _SeriesPoint(this.label, this.value);
  final String label;
  final double value;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppState);
  }

  @override
  void didUpdateWidget(DashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) {
      oldWidget.appState.removeListener(_onAppState);
      widget.appState.addListener(_onAppState);
    }
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppState);
    super.dispose();
  }

  void _onAppState() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppState appState = widget.appState;
    final DemoUser? user = appState.currentUser;
    if (user == null || !appState.isAuthenticated) {
      return AuthRequiredScreen(requestedPath: AppPaths.dashboard);
    }
    final bool isWorker = !appState.isAdmin;

    // ── Worker stat cards — driven by live AppState data ──────────────────
    final List<_DashboardStat> stats = isWorker
        ? <_DashboardStat>[
            _DashboardStat(
              label: 'Today\'s Collection',
              value: (appState.workerTodayCollection > 0
                      ? appState.workerTodayCollection
                      : appState.todayProductionTotal)
                  .toString(),
              unit: 'Eggs Collected',
              icon: Icons.trending_up_rounded,
              accent: _DashboardPalette.success,
              route: AppPaths.production,
            ),
            _DashboardStat(
              label: 'Grading Progress',
              value:
                  '${appState.liveGoodEggs > 0 ? ((appState.liveGoodEggs / (appState.liveGoodEggs + appState.liveCrackedEggs).clamp(1, 999999)) * 100).toStringAsFixed(0) : '0'}%',
              unit: 'Good Quality',
              icon: Icons.fact_check_outlined,
              accent: _DashboardPalette.primary,
              route: AppPaths.grading,
            ),
            _DashboardStat(
              label: 'Damaged / Rejected',
              value: appState.workerDamagedCount.toString(),
              unit: 'Eggs Today',
              icon: Icons.warning_amber_rounded,
              accent: _DashboardPalette.warning,
              route: AppPaths.grading,
            ),
          ]
        : <_DashboardStat>[
            _DashboardStat(
              label: 'Current Inventory',
              value: appState.totalInventoryUnits.toString(),
              unit: 'Eggs in Stock',
              icon: Icons.inventory_2_outlined,
              accent: _DashboardPalette.foreground,
              route: AppPaths.inventory,
            ),
            _DashboardStat(
              label: 'Today\'s Sales',
              value: appState.todaySalesEggCount > 0
                  ? '₱${appState.todaySalesRevenue.toStringAsFixed(0)}'
                  : '₱0',
              unit: appState.todaySalesEggCount > 0
                  ? '${appState.todaySalesEggCount} eggs sold'
                  : 'Eggs Sold',
              icon: Icons.payments_outlined,
              accent: _DashboardPalette.primary,
              route: AppPaths.inventory,
            ),
            _DashboardStat(
              label: 'Damaged / Rejected',
              value: '${appState.liveCrackedEggs}',
              unit: 'Eggs Today',
              icon: Icons.warning_amber_rounded,
              accent: _DashboardPalette.warning,
              route: AppPaths.grading,
            ),
          ];

    // ── Worker quick links — four essential actions ────────────────────────
    final List<_QuickLinkItem> quickLinks = isWorker
        ? <_QuickLinkItem>[
            const _QuickLinkItem(
              label: 'Production',
              route: AppPaths.production,
              icon: Icons.egg_alt_outlined,
            ),
            const _QuickLinkItem(
              label: 'Quality Control',
              route: AppPaths.grading,
              icon: Icons.shield_outlined,
            ),
            const _QuickLinkItem(
              label: 'Profile',
              route: AppPaths.profile,
              icon: Icons.verified_user_outlined,
            ),
          ]
        : const <_QuickLinkItem>[
            _QuickLinkItem(
              label: 'Production',
              route: AppPaths.production,
              icon: Icons.egg_alt_outlined,
            ),
            _QuickLinkItem(
              label: 'Quality Control',
              route: AppPaths.grading,
              icon: Icons.shield_outlined,
            ),
            _QuickLinkItem(
              label: 'Inventory',
              route: AppPaths.inventory,
              icon: Icons.inventory_2_outlined,
            ),
            _QuickLinkItem(
              label: 'Reports',
              route: AppPaths.reports,
              icon: Icons.assessment_outlined,
            ),
          ];

    Widget zoneLine = Text(
      'Zone: ${user.assignedZone}',
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: _DashboardPalette.mutedForeground,
        letterSpacing: 0.4,
      ),
    );

    return EggScaffold(
      appState: appState,
      title: 'Dashboard',
      selectedRoute: AppPaths.dashboard,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool split = constraints.maxWidth >= 1040;
          final Widget links = _QuickLinkGrid(items: quickLinks);
          final Widget inspect = _LiveInspectionLedger(appState: appState);
          final Widget analytics = _EggAnalyticsBoard(appState: appState);
          if (!isWorker) {
            return _AdminDashboardBody(
              appState: appState,
              links: links,
              inspect: inspect,
              zoneLine: zoneLine,
            );
          }
          final Widget kpis = _DashboardStatGrid(stats: stats);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _DashboardHeading('Overview'),
              kpis,
              const SizedBox(height: 16),
              analytics,
              const SizedBox(height: 16),
              const _DashboardHeading('Modules'),
              links,
              const SizedBox(height: 16),
              if (split)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(flex: 7, child: inspect),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 5,
                      child: _WorkerNotificationCard(appState: appState),
                    ),
                  ],
                )
              else ...<Widget>[
                inspect,
                const SizedBox(height: 16),
                _WorkerNotificationCard(appState: appState),
              ],
              const SizedBox(height: 10),
              zoneLine,
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: _LiveCameraStream(
                  appState: appState,
                  pollSnapshots: true,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AdminDashboardBody extends StatefulWidget {
  const _AdminDashboardBody({
    required this.appState,
    required this.links,
    required this.inspect,
    required this.zoneLine,
  });

  final AppState appState;
  final Widget links;
  final Widget inspect;
  final Widget zoneLine;

  @override
  State<_AdminDashboardBody> createState() => _AdminDashboardBodyState();
}

class _AdminDashboardBodyState extends State<_AdminDashboardBody> {
  final GlobalKey _productionOverviewKey = GlobalKey();

  void _showProductionOverview() {
    final BuildContext? target = _productionOverviewKey.currentContext;
    if (target == null) {
      return;
    }
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      alignment: 0.05,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppState appState = widget.appState;
    final List<_DashboardStat> stats = <_DashboardStat>[
      _DashboardStat(
        label: 'Today\'s Egg Production',
        value: _productionBetween(
          appState,
          _dashboardDay(DateTime.now()),
          _dashboardDay(DateTime.now()),
        ).toString(),
        unit: 'Eggs logged today',
        icon: Icons.trending_up_rounded,
        accent: _DashboardPalette.success,
        route: AppPaths.production,
        onTap: _showProductionOverview,
      ),
      _DashboardStat(
        label: 'Current Inventory',
        value: appState.totalInventoryUnits.toString(),
        unit: 'Eggs in Stock',
        icon: Icons.inventory_2_outlined,
        accent: _DashboardPalette.foreground,
        route: AppPaths.inventory,
      ),
      _DashboardStat(
        label: 'Today\'s Sales',
        value: appState.todaySalesEggCount > 0
            ? '₱${appState.todaySalesRevenue.toStringAsFixed(0)}'
            : '₱0',
        unit: appState.todaySalesEggCount > 0
            ? '${appState.todaySalesEggCount} eggs sold'
            : 'Eggs Sold',
        icon: Icons.payments_outlined,
        accent: _DashboardPalette.primary,
        route: AppPaths.inventory,
      ),
      _DashboardStat(
        label: 'Damaged / Rejected',
        value: '${appState.liveCrackedEggs}',
        unit: 'Eggs Today',
        icon: Icons.warning_amber_rounded,
        accent: _DashboardPalette.warning,
        route: AppPaths.grading,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _DashboardHeading('Analytics'),
        _DashboardStatGrid(stats: stats),
        const SizedBox(height: 16),
        const _DashboardHeading('Modules'),
        widget.links,
        const SizedBox(height: 16),
        KeyedSubtree(
          key: _productionOverviewKey,
          child: _WeeklyProductionOverview(appState: appState),
        ),
        const SizedBox(height: 16),
        _InventoryStatusCard(appState: appState),
        const SizedBox(height: 16),
        widget.inspect,
        const SizedBox(height: 10),
        widget.zoneLine,
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: _LiveCameraStream(
            appState: appState,
            // Cloudflare cancels long /stream MJPEG; poll /live.jpg instead.
            pollSnapshots: true,
          ),
        ),
      ],
    );
  }
}

class ProductionScreen extends StatefulWidget {
  const ProductionScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<ProductionScreen> createState() => _ProductionScreenState();
}

class _ProductionScreenState extends State<ProductionScreen> {
  static const List<String> _timeSlots = <String>[
    'Morning',
    'Afternoon',
    'Evening',
  ];
  static const List<String> _sources = <String>[
    'Coop A',
    'Coop B',
    'Coop C',
    'Coop D',
    'Cage 1',
    'Cage 2',
  ];
  static const int _maxCount = 50000;
  static const int _maxSourceLength = 50;

  final TextEditingController _customSourceController = TextEditingController();
  final TextEditingController _countController = TextEditingController();

  late List<_ProductionEntry> _records;
  late DateTime _selectedDate;
  String _selectedTimeSlot = _timeSlots.first;
  String _selectedSource = _sources.first;
  bool _showForm = false;
  Map<String, String> _errors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _records = widget.appState.productionRecords
        .map(
          (ProductionRecord record) => _ProductionEntry.fromRecord(
            record.id.isEmpty
                ? 'seed-${record.date}-${record.source}'
                : record.id,
            record,
          ),
        )
        .toList();
    _selectedDate = _records.isEmpty
        ? DateTime.now()
        : _parseIsoDate(_records.first.date);
  }

  @override
  void dispose() {
    _customSourceController.dispose();
    _countController.dispose();
    super.dispose();
  }

  String get _activeDateString {
    if (_records.isEmpty) {
      return _toIsoDate(DateTime.now());
    }
    final List<String> dates =
        _records.map((record) => record.date).toSet().toList()..sort();
    return dates.last;
  }

  int get _todayTotal => _records
      .where((record) => record.date == _activeDateString)
      .fold<int>(0, (int sum, _ProductionEntry record) => sum + record.count);

  int get _todayEntries =>
      _records.where((record) => record.date == _activeDateString).length;

  int get _allTimeTotal => _records.fold<int>(
    0,
    (int sum, _ProductionEntry record) => sum + record.count,
  );

  int get _uniqueSources =>
      _records.map((record) => record.source).toSet().length;

  List<MapEntry<String, _DailyTotal>> get _dailyTotals {
    final Map<String, _DailyTotal> grouped = <String, _DailyTotal>{};
    for (final _ProductionEntry record in _records) {
      final _DailyTotal current =
          grouped[record.date] ?? const _DailyTotal(total: 0, records: 0);
      grouped[record.date] = _DailyTotal(
        total: current.total + record.count,
        records: current.records + 1,
      );
    }
    final List<MapEntry<String, _DailyTotal>> entries = grouped.entries.toList()
      ..sort(
        (MapEntry<String, _DailyTotal> a, MapEntry<String, _DailyTotal> b) =>
            b.key.compareTo(a.key),
      );
    return entries;
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.dark(
              primary: _DashboardPalette.primary,
              onPrimary: _DashboardPalette.primaryForeground,
              surface: Color(0xFF2A211C),
              onSurface: _DashboardPalette.foreground,
            ),
            dialogTheme: const DialogThemeData(
              backgroundColor: Color(0xFF2A211C),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        _selectedDate = picked;
        _errors.remove('date');
      });
    }
  }

  void _toggleForm() {
    setState(() {
      _showForm = !_showForm;
      if (!_showForm) {
        _errors = <String, String>{};
      }
    });
  }

  void _addRecord() {
    final Map<String, String> errors = <String, String>{};
    final int? count = int.tryParse(_countController.text.trim());
    final String source = _selectedSource == '__custom'
        ? _customSourceController.text.trim()
        : _selectedSource;

    if (count == null || count <= 0) {
      errors['count'] = 'Enter a valid egg count';
    } else if (count > _maxCount) {
      errors['count'] = 'Max $_maxCount per entry';
    }

    if (source.isEmpty) {
      errors['source'] = 'Select or enter a source';
    } else if (source.length > _maxSourceLength) {
      errors['source'] = 'Max $_maxSourceLength characters';
    }

    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    final _ProductionEntry newRecord = _ProductionEntry(
      id: 'manual-${DateTime.now().microsecondsSinceEpoch}',
      date: _toIsoDate(_selectedDate),
      timeSlot: _selectedTimeSlot,
      source: source,
      count: count!,
      method: 'Manual',
    );

    setState(() {
      _records = <_ProductionEntry>[newRecord, ..._records];
      _countController.clear();
      _customSourceController.clear();
      _selectedSource = _sources.first;
      _selectedTimeSlot = _timeSlots.first;
      _showForm = false;
      _errors = <String, String>{};
    });
    _persistProduction();
  }

  void _deleteRecord(String id) {
    setState(() {
      _records = _records
          .where((_ProductionEntry record) => record.id != id)
          .toList();
    });
    _persistProduction();
  }

  void _persistProduction() {
    widget.appState.replaceProductionRecords(
      _records
          .map(
            (_ProductionEntry record) => ProductionRecord(
              id: record.id,
              date: record.date,
              timeSlot: record.timeSlot,
              source: record.source,
              count: record.count,
              method: record.method,
            ),
          )
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width < 760;
    final List<_ProductionStat> stats = <_ProductionStat>[
      _ProductionStat(
        icon: Icons.egg_alt_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Today\'s Total',
        value: _todayTotal.toString(),
        suffix: 'eggs',
      ),
      _ProductionStat(
        icon: Icons.schedule_outlined,
        iconColor: _DashboardPalette.success,
        label: 'Today\'s Entries',
        value: _todayEntries.toString(),
        suffix: 'records',
      ),
      _ProductionStat(
        icon: Icons.trending_up_rounded,
        iconColor: _DashboardPalette.warning,
        label: 'All-Time Total',
        value: _allTimeTotal.toString(),
        suffix: 'eggs',
      ),
      _ProductionStat(
        icon: Icons.home_work_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Active Sources',
        value: _uniqueSources.toString(),
        suffix: 'coops/cages',
      ),
    ];

    return EggScaffold(
      appState: widget.appState,
      title: 'Production',
      selectedRoute: AppPaths.production,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _DashboardPalette.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.egg_alt_outlined,
                  color: _DashboardPalette.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'EGG PRODUCTION',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'IoT-enhanced egg counting and collection tracking',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _DashboardPalette.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (!narrow)
                FilledButton.icon(
                  onPressed: _toggleForm,
                  style: FilledButton.styleFrom(
                    backgroundColor: _DashboardPalette.primary,
                    foregroundColor: _DashboardPalette.primaryForeground,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: Icon(
                    _showForm ? Icons.close_rounded : Icons.add_rounded,
                  ),
                  label: Text(_showForm ? 'Close Entry' : 'Manual Entry'),
                ),
            ],
          ),
          if (narrow) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _toggleForm,
                style: FilledButton.styleFrom(
                  backgroundColor: _DashboardPalette.primary,
                  foregroundColor: _DashboardPalette.primaryForeground,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: Icon(_showForm ? Icons.close_rounded : Icons.add_rounded),
                label: Text(_showForm ? 'Close Entry' : 'Manual Entry'),
              ),
            ),
          ],
          const SizedBox(height: 20),
          _ProductionStatGrid(stats: stats),
          if (_showForm) ...<Widget>[
            const SizedBox(height: 20),
            _GlassSection(
              title: 'Manual Production Entry',
              titleIcon: Icons.edit_note_rounded,
              child: _ProductionForm(
                selectedDate: _selectedDate,
                selectedTimeSlot: _selectedTimeSlot,
                selectedSource: _selectedSource,
                customSourceController: _customSourceController,
                countController: _countController,
                errors: _errors,
                timeSlots: _timeSlots,
                sources: _sources,
                onPickDate: _pickDate,
                onTimeSlotChanged: (String? value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _selectedTimeSlot = value;
                  });
                },
                onSourceChanged: (String? value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _selectedSource = value;
                    _errors.remove('source');
                  });
                },
                onCancel: _toggleForm,
                onSubmit: _addRecord,
              ),
            ),
          ],
          const SizedBox(height: 20),
          _GlassSection(
            title: 'Daily Totals',
            titleIcon: Icons.bar_chart_rounded,
            child: _ProductionDailyTotals(
              activeDateString: _activeDateString,
              dailyTotals: _dailyTotals,
            ),
          ),
          const SizedBox(height: 20),
          _GlassSection(
            title: 'Collection Records',
            child: _ProductionRecordsTable(
              records: _records,
              onDelete: _deleteRecord,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductionForm extends StatelessWidget {
  const _ProductionForm({
    required this.selectedDate,
    required this.selectedTimeSlot,
    required this.selectedSource,
    required this.customSourceController,
    required this.countController,
    required this.errors,
    required this.timeSlots,
    required this.sources,
    required this.onPickDate,
    required this.onTimeSlotChanged,
    required this.onSourceChanged,
    required this.onCancel,
    required this.onSubmit,
  });

  final DateTime selectedDate;
  final String selectedTimeSlot;
  final String selectedSource;
  final TextEditingController customSourceController;
  final TextEditingController countController;
  final Map<String, String> errors;
  final List<String> timeSlots;
  final List<String> sources;
  final VoidCallback onPickDate;
  final ValueChanged<String?> onTimeSlotChanged;
  final ValueChanged<String?> onSourceChanged;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 1040;
        final bool medium = constraints.maxWidth >= 640;
        final double width = wide
            ? (constraints.maxWidth - 36) / 4
            : medium
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;

        return Column(
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Collection Date',
                    errorText: errors['date'],
                    child: _PickerButton(
                      text: _formatLongDate(selectedDate),
                      icon: Icons.calendar_month_outlined,
                      onPressed: onPickDate,
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Time of Collection',
                    child: _DropdownShell(
                      value: selectedTimeSlot,
                      items: timeSlots,
                      onChanged: onTimeSlotChanged,
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Source (Coop/Cage)',
                    errorText: errors['source'],
                    child: Column(
                      children: <Widget>[
                        _DropdownShell(
                          value: selectedSource,
                          items: <String>[...sources, '__custom'],
                          labels: <String, String>{
                            '__custom': 'Other (custom)',
                          },
                          onChanged: onSourceChanged,
                        ),
                        if (selectedSource == '__custom') ...<Widget>[
                          const SizedBox(height: 10),
                          _ProductionTextField(
                            controller: customSourceController,
                            hintText: 'Enter source name',
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Egg Count',
                    errorText: errors['count'],
                    child: _ProductionTextField(
                      controller: countController,
                      hintText: 'e.g. 320',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: onCancel,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(color: _DashboardPalette.mutedForeground),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: onSubmit,
                  style: FilledButton.styleFrom(
                    backgroundColor: _DashboardPalette.primary,
                    foregroundColor: _DashboardPalette.primaryForeground,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Record Production'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ProductionDailyTotals extends StatelessWidget {
  const _ProductionDailyTotals({
    required this.activeDateString,
    required this.dailyTotals,
  });

  final String activeDateString;
  final List<MapEntry<String, _DailyTotal>> dailyTotals;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: dailyTotals
          .map(
            (MapEntry<String, _DailyTotal> entry) => _DailyTotalCard(
              date: entry.key,
              dailyTotal: entry.value,
              activeDateString: activeDateString,
            ),
          )
          .toList(),
    );
  }
}

class _DailyTotalCard extends StatelessWidget {
  const _DailyTotalCard({
    required this.date,
    required this.dailyTotal,
    required this.activeDateString,
  });

  final String date;
  final _DailyTotal dailyTotal;
  final String activeDateString;

  @override
  Widget build(BuildContext context) {
    final bool active = date == activeDateString;
    return Container(
      width: 240,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: active
            ? _DashboardPalette.primary.withValues(alpha: 0.08)
            : _DashboardPalette.tabBackground,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: active
              ? _DashboardPalette.primary.withValues(alpha: 0.28)
              : _DashboardPalette.glassBorder,
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  active ? 'Today' : date,
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  dailyTotal.total.toString(),
                  style: const TextStyle(
                    color: _DashboardPalette.foreground,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${dailyTotal.records} entries',
                style: const TextStyle(
                  color: _DashboardPalette.mutedForeground,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 6),
              if (active)
                const Text(
                  'LIVE',
                  style: TextStyle(
                    color: _DashboardPalette.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProductionRecordsTable extends StatelessWidget {
  const _ProductionRecordsTable({
    required this.records,
    required this.onDelete,
  });

  final List<_ProductionEntry> records;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            'No production records yet',
            style: TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Theme(
        data: Theme.of(
          context,
        ).copyWith(dividerColor: _DashboardPalette.glassBorder),
        child: DataTable(
          horizontalMargin: 10,
          columnSpacing: 28,
          headingTextStyle: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontWeight: FontWeight.w600,
          ),
          dataTextStyle: const TextStyle(color: _DashboardPalette.foreground),
          columns: const <DataColumn>[
            DataColumn(label: Text('Date')),
            DataColumn(label: Text('Time')),
            DataColumn(label: Text('Source')),
            DataColumn(numeric: true, label: Text('Count')),
            DataColumn(label: Text('Method')),
            DataColumn(label: Text('')),
          ],
          rows: records
              .map(
                (_ProductionEntry record) => DataRow(
                  cells: <DataCell>[
                    DataCell(Text(record.date)),
                    DataCell(_TimeChip(timeSlot: record.timeSlot)),
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const Icon(
                            Icons.home_work_outlined,
                            size: 15,
                            color: _DashboardPalette.mutedForeground,
                          ),
                          const SizedBox(width: 6),
                          Text(record.source),
                        ],
                      ),
                    ),
                    DataCell(Text(record.count.toString())),
                    DataCell(_MethodChip(method: record.method)),
                    DataCell(
                      IconButton(
                        onPressed: () => onDelete(record.id),
                        icon: const Icon(Icons.delete_outline_rounded),
                        color: _DashboardPalette.mutedForeground,
                        tooltip: 'Delete',
                      ),
                    ),
                  ],
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _ProductionStatGrid extends StatelessWidget {
  const _ProductionStatGrid({required this.stats});

  final List<_ProductionStat> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool large = constraints.maxWidth >= 1080;
        final bool medium = constraints.maxWidth >= 680;
        final double width = large
            ? (constraints.maxWidth - 36) / 4
            : medium
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: stats
              .map(
                (_ProductionStat stat) => SizedBox(
                  width: width,
                  child: _ProductionStatCard(stat: stat),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _ProductionStatCard extends StatelessWidget {
  const _ProductionStatCard({required this.stat});

  final _ProductionStat stat;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _DashboardPalette.glassBackground,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _DashboardPalette.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(stat.icon, color: stat.iconColor, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  stat.label,
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          RichText(
            text: TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: stat.value,
                  style: const TextStyle(
                    color: _DashboardPalette.foreground,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: ' ${stat.suffix}',
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductionField extends StatelessWidget {
  const _ProductionField({
    required this.label,
    required this.child,
    this.errorText,
  });

  final String label;
  final Widget child;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        child,
        if (errorText != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            errorText!,
            style: const TextStyle(
              color: _DashboardPalette.danger,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

class _PickerButton extends StatelessWidget {
  const _PickerButton({
    required this.text,
    required this.icon,
    required this.onPressed,
  });

  final String text;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: _DashboardPalette.foreground,
        side: const BorderSide(color: _DashboardPalette.border),
        backgroundColor: _DashboardPalette.tabBackground,
        minimumSize: const Size.fromHeight(52),
        alignment: Alignment.centerLeft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      icon: Icon(icon, color: _DashboardPalette.mutedForeground),
      label: Align(alignment: Alignment.centerLeft, child: Text(text)),
    );
  }
}

class _DropdownShell extends StatelessWidget {
  const _DropdownShell({
    required this.value,
    required this.items,
    required this.onChanged,
    this.labels = const <String, String>{},
  });

  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  final Map<String, String> labels;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey<String>(value),
      initialValue: value,
      onChanged: onChanged,
      dropdownColor: const Color(0xFF2D241E),
      iconEnabledColor: _DashboardPalette.mutedForeground,
      decoration: InputDecoration(
        filled: true,
        fillColor: _DashboardPalette.tabBackground,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _DashboardPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _DashboardPalette.primary),
        ),
      ),
      style: const TextStyle(color: _DashboardPalette.foreground),
      items: items
          .map(
            (String item) => DropdownMenuItem<String>(
              value: item,
              child: Text(labels[item] ?? item),
            ),
          )
          .toList(),
    );
  }
}

class _ProductionTextField extends StatelessWidget {
  const _ProductionTextField({
    required this.controller,
    required this.hintText,
    this.keyboardType,
    this.obscureText = false,
    this.suffixIcon,
  });

  final TextEditingController controller;
  final String hintText;
  final TextInputType? keyboardType;
  final bool obscureText;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      obscureText: obscureText,
      style: const TextStyle(color: _DashboardPalette.foreground),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: _DashboardPalette.mutedForeground),
        filled: true,
        fillColor: _DashboardPalette.tabBackground,
        suffixIcon: suffixIcon,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _DashboardPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: _DashboardPalette.primary),
        ),
      ),
    );
  }
}

class _TimeChip extends StatelessWidget {
  const _TimeChip({required this.timeSlot});

  final String timeSlot;

  @override
  Widget build(BuildContext context) {
    final Color color = switch (timeSlot) {
      'Morning' => _DashboardPalette.warning,
      'Afternoon' => _DashboardPalette.primary,
      _ => _DashboardPalette.foreground,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        timeSlot,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({required this.method});

  final String method;

  @override
  Widget build(BuildContext context) {
    final bool isIot = method == 'IoT Sensor';
    final Color color = isIot
        ? _DashboardPalette.success
        : _DashboardPalette.mutedForeground;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        method,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _formatLongDate(DateTime date) {
  const List<String> months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${months[date.month - 1]} ${date.day}, ${date.year}';
}

DateTime _parseIsoDate(String value) {
  return DateTime.parse(value);
}

String _toIsoDate(DateTime date) {
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

class _ProductionEntry {
  const _ProductionEntry({
    required this.id,
    required this.date,
    required this.timeSlot,
    required this.source,
    required this.count,
    required this.method,
  });

  factory _ProductionEntry.fromRecord(String id, ProductionRecord record) {
    return _ProductionEntry(
      id: id,
      date: record.date,
      timeSlot: record.timeSlot,
      source: record.source,
      count: record.count,
      method: record.method,
    );
  }

  final String id;
  final String date;
  final String timeSlot;
  final String source;
  final int count;
  final String method;
}

class _DailyTotal {
  const _DailyTotal({required this.total, required this.records});

  final int total;
  final int records;
}

class _ProductionStat {
  const _ProductionStat({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.suffix,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String suffix;
}

class GradingScreen extends StatefulWidget {
  const GradingScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<GradingScreen> createState() => _GradingScreenState();
}

class _GradingScreenState extends State<GradingScreen> {
  static const List<String> _sizes = <String>[
    'Small',
    'Medium',
    'Large',
    'Extra Large',
  ];
  static const List<String> _qualities = <String>[
    'Good',
    'Cracked',
    'Rejected',
  ];
  static const int _maxQuantity = 50000;
  static const int _maxNameLength = 50;

  final TextEditingController _quantityController = TextEditingController();
  final TextEditingController _gradedByController = TextEditingController();

  late List<_GradingEntry> _records;
  String _selectedSize = 'Medium';
  String _selectedQuality = 'Good';
  bool _showForm = false;
  Map<String, String> _errors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _records = widget.appState.gradingRecords
        .map(
          (GradingRecord record) => _GradingEntry(
            id: record.id,
            date: record.date,
            time: record.time,
            batchId: record.batchId,
            size: record.size,
            quality: record.quality,
            quantity: record.quantity,
            gradedBy: record.gradedBy,
          ),
        )
        .toList();
    _gradedByController.text = widget.appState.currentUser?.name ?? '';
  }

  @override
  void dispose() {
    _quantityController.dispose();
    _gradedByController.dispose();
    super.dispose();
  }

  String get _activeDateString {
    if (_records.isEmpty) {
      return _toIsoDate(DateTime.now());
    }
    final List<String> dates =
        _records.map((record) => record.date).toSet().toList()..sort();
    return dates.last;
  }

  List<_GradingEntry> get _todayRecords => _records
      .where((_GradingEntry record) => record.date == _activeDateString)
      .toList();

  int get _collectedToday => widget.appState.todayProductionTotal;

  int get _todayGraded => _todayRecords.fold<int>(
    0,
    (int sum, _GradingEntry record) => sum + record.quantity,
  );

  int get _remaining => _collectedToday - _todayGraded;

  int get _sellable => _todayRecords
      .where((record) => record.quality == 'Good')
      .fold<int>(0, (int sum, _GradingEntry record) => sum + record.quantity);

  int get _nonSellable => _todayGraded - _sellable;

  int get _batchCount =>
      _todayRecords.map((record) => record.batchId).toSet().length;

  String get _nextBatch {
    final String datePortion = _activeDateString
        .replaceAll('-', '')
        .substring(4);
    final String sequence = (_batchCount + 1).toString().padLeft(2, '0');
    return 'B-$datePortion-$sequence';
  }

  double get _gradedRatio {
    if (_collectedToday <= 0) {
      return 0;
    }
    return (_todayGraded / _collectedToday).clamp(0, 1).toDouble();
  }

  Map<String, int> _breakdownByQuality() {
    return <String, int>{
      for (final String quality in _qualities)
        quality: _todayRecords
            .where((record) => record.quality == quality)
            .fold<int>(
              0,
              (int sum, _GradingEntry record) => sum + record.quantity,
            ),
    };
  }

  Map<String, int> _breakdownBySize() {
    return <String, int>{
      for (final String size in _sizes)
        size: _todayRecords
            .where((record) => record.size == size)
            .fold<int>(
              0,
              (int sum, _GradingEntry record) => sum + record.quantity,
            ),
    };
  }

  void _toggleForm() {
    setState(() {
      _showForm = !_showForm;
      if (!_showForm) {
        _errors = <String, String>{};
      }
    });
  }

  void _submitGrading() {
    final Map<String, String> errors = <String, String>{};
    final int? quantity = int.tryParse(_quantityController.text.trim());
    final String gradedBy = _gradedByController.text.trim();

    if (quantity == null || quantity <= 0) {
      errors['quantity'] = 'Enter a valid quantity';
    } else if (quantity > _maxQuantity) {
      errors['quantity'] = 'Max $_maxQuantity';
    }

    if (gradedBy.isEmpty) {
      errors['gradedBy'] = 'Enter grader name';
    } else if (gradedBy.length > _maxNameLength) {
      errors['gradedBy'] = 'Max $_maxNameLength characters';
    }

    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    final DateTime now = DateTime.now();
    final _GradingEntry newRecord = _GradingEntry(
      id: 'grade-${now.microsecondsSinceEpoch}',
      date: _activeDateString,
      time:
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
      batchId: _nextBatch,
      size: _selectedSize,
      quality: _selectedQuality,
      quantity: quantity!,
      gradedBy: gradedBy,
    );

    setState(() {
      _records = <_GradingEntry>[newRecord, ..._records];
      _quantityController.clear();
      _showForm = false;
      _errors = <String, String>{};
    });
    _persistGrading();
  }

  void _deleteRecord(String id) {
    setState(() {
      _records = _records
          .where((_GradingEntry record) => record.id != id)
          .toList();
    });
    _persistGrading();
  }

  void _persistGrading() {
    widget.appState.replaceGradingRecords(
      _records
          .map(
            (_GradingEntry record) => GradingRecord(
              id: record.id,
              date: record.date,
              time: record.time,
              batchId: record.batchId,
              size: record.size,
              quality: record.quality,
              quantity: record.quantity,
              gradedBy: record.gradedBy,
            ),
          )
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isWorker = !widget.appState.isAdmin;
    final bool narrow = MediaQuery.sizeOf(context).width < 760;
    final Map<String, int> qualityBreakdown = _breakdownByQuality();
    final Map<String, int> sizeBreakdown = _breakdownBySize();
    final List<_ProductionStat> stats = <_ProductionStat>[
      _ProductionStat(
        icon: Icons.egg_alt_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Graded Today',
        value: _todayGraded.toString(),
        suffix: 'eggs',
      ),
      _ProductionStat(
        icon: Icons.check_circle_outline_rounded,
        iconColor: _DashboardPalette.success,
        label: 'Sellable',
        value: _sellable.toString(),
        suffix: 'good',
      ),
      _ProductionStat(
        icon: Icons.cancel_outlined,
        iconColor: _DashboardPalette.warning,
        label: 'Non-Sellable',
        value: _nonSellable.toString(),
        suffix: 'cracked',
      ),
      _ProductionStat(
        icon: Icons.bar_chart_rounded,
        iconColor: _DashboardPalette.primary,
        label: 'Batches Today',
        value: _batchCount.toString(),
        suffix: 'batches',
      ),
    ];

    return EggScaffold(
      appState: widget.appState,
      title: 'Grading',
      selectedRoute: AppPaths.grading,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _DashboardPalette.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.assignment_outlined,
                  color: _DashboardPalette.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'QUALITY CONTROL',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Grade eggs and track damaged or rejected units',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _DashboardPalette.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (!narrow)
                FilledButton.icon(
                  onPressed: _toggleForm,
                  style: FilledButton.styleFrom(
                    backgroundColor: _DashboardPalette.primary,
                    foregroundColor: _DashboardPalette.primaryForeground,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: Icon(
                    _showForm ? Icons.close_rounded : Icons.add_rounded,
                  ),
                  label: const Text('Grade Eggs'),
                ),
            ],
          ),
          if (narrow) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _toggleForm,
                style: FilledButton.styleFrom(
                  backgroundColor: _DashboardPalette.primary,
                  foregroundColor: _DashboardPalette.primaryForeground,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: Icon(_showForm ? Icons.close_rounded : Icons.add_rounded),
                label: const Text('Grade Eggs'),
              ),
            ),
          ],
          const SizedBox(height: 18),
          _GradingValidationBar(
            collectedToday: _collectedToday,
            todayGraded: _todayGraded,
            remaining: _remaining,
            gradedRatio: _gradedRatio,
          ),
          const SizedBox(height: 18),
          _ProductionStatGrid(stats: stats),
          if (!isWorker) ...<Widget>[
            const SizedBox(height: 18),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool medium = constraints.maxWidth >= 860;
                final double width = medium
                    ? (constraints.maxWidth - 16) / 2
                    : constraints.maxWidth;

                return Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: <Widget>[
                    SizedBox(
                      width: width,
                      child: _GlassSection(
                        title: 'Quality Breakdown',
                        child: _GradingBreakdownPanel(
                          totalLabel: _todayGraded > 0
                              ? '${((_sellable / _todayGraded) * 100).round()}%'
                              : '--',
                          totalValue: _todayGraded > 0
                              ? (_sellable / _todayGraded).clamp(0, 1)
                              : 0,
                          centerColor: _DashboardPalette.success,
                          breakdown: qualityBreakdown,
                          colorForKey: _gradingQualityColor,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _GlassSection(
                        title: 'Size Breakdown',
                        child: _GradingBreakdownPanel(
                          totalLabel: _todayGraded.toString(),
                          totalValue: _todayGraded > 0 ? 1 : 0,
                          centerColor: _DashboardPalette.foreground,
                          breakdown: sizeBreakdown,
                          colorForKey: _gradingSizeColor,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
          if (_showForm) ...<Widget>[
            const SizedBox(height: 18),
            _GlassSection(
              title: 'Grade Eggs',
              child: _GradingForm(
                nextBatch: _nextBatch,
                remaining: _remaining,
                sizes: _sizes,
                qualities: _qualities,
                selectedSize: _selectedSize,
                selectedQuality: _selectedQuality,
                quantityController: _quantityController,
                gradedByController: _gradedByController,
                errors: _errors,
                onSizeSelected: (String size) {
                  setState(() => _selectedSize = size);
                },
                onQualitySelected: (String quality) {
                  setState(() => _selectedQuality = quality);
                },
                onCancel: _toggleForm,
                onSubmit: _submitGrading,
              ),
            ),
          ],
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Grading Records',
            child: _GradingRecordsTable(
              records: _records,
              onDelete: _deleteRecord,
            ),
          ),
        ],
      ),
    );
  }
}

class _GradingValidationBar extends StatelessWidget {
  const _GradingValidationBar({
    required this.collectedToday,
    required this.todayGraded,
    required this.remaining,
    required this.gradedRatio,
  });

  final int collectedToday;
  final int todayGraded;
  final int remaining;
  final double gradedRatio;

  @override
  Widget build(BuildContext context) {
    final bool complete = remaining == 0;
    final bool over = remaining < 0;
    final Color accent = over
        ? _DashboardPalette.danger
        : complete
        ? _DashboardPalette.success
        : _DashboardPalette.primary;

    return _GlassSection(
      title: 'Grading Validation',
      titleIcon: Icons.verified_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$collectedToday collected today - $todayGraded graded (${(gradedRatio * 100).toStringAsFixed(1)}%)'
            '${remaining > 0
                ? ' - $remaining remaining'
                : complete
                ? ' - All graded'
                : ' - Over-graded by ${remaining.abs()}'}',
            style: const TextStyle(
              color: _DashboardPalette.mutedForeground,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: gradedRatio,
              minHeight: 10,
              color: accent,
              backgroundColor: _DashboardPalette.border,
            ),
          ),
        ],
      ),
    );
  }
}

class _GradingBreakdownPanel extends StatelessWidget {
  const _GradingBreakdownPanel({
    required this.totalLabel,
    required this.totalValue,
    required this.centerColor,
    required this.breakdown,
    required this.colorForKey,
  });

  final String totalLabel;
  final double totalValue;
  final Color centerColor;
  final Map<String, int> breakdown;
  final Color Function(String key) colorForKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        _CircularScore(
          value: totalValue,
          label: totalLabel,
          color: centerColor,
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            children: breakdown.entries
                .map(
                  (MapEntry<String, int> entry) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _LegendRow(
                      label: entry.key,
                      value: entry.value.toString(),
                      color: colorForKey(entry.key),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

class _GradingForm extends StatelessWidget {
  const _GradingForm({
    required this.nextBatch,
    required this.remaining,
    required this.sizes,
    required this.qualities,
    required this.selectedSize,
    required this.selectedQuality,
    required this.quantityController,
    required this.gradedByController,
    required this.errors,
    required this.onSizeSelected,
    required this.onQualitySelected,
    required this.onCancel,
    required this.onSubmit,
  });

  final String nextBatch;
  final int remaining;
  final List<String> sizes;
  final List<String> qualities;
  final String selectedSize;
  final String selectedQuality;
  final TextEditingController quantityController;
  final TextEditingController gradedByController;
  final Map<String, String> errors;
  final ValueChanged<String> onSizeSelected;
  final ValueChanged<String> onQualitySelected;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        RichText(
          text: TextSpan(
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
            children: <InlineSpan>[
              const TextSpan(text: 'Batch: '),
              TextSpan(
                text: nextBatch,
                style: const TextStyle(
                  color: _DashboardPalette.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              TextSpan(
                text: remaining > 0
                    ? ' - $remaining remaining to grade'
                    : ' - All collected eggs graded',
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Size',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: _DashboardPalette.mutedForeground,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: sizes
              .map(
                (String size) => _GradingChoiceButton(
                  label: size,
                  selected: selectedSize == size,
                  onTap: () => onSizeSelected(size),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 16),
        Text(
          'Quality',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: _DashboardPalette.mutedForeground,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: qualities
              .map(
                (String quality) => _GradingChoiceButton(
                  label: quality,
                  selected: selectedQuality == quality,
                  onTap: () => onQualitySelected(quality),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 18),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool medium = constraints.maxWidth >= 700;
            final double width = medium
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Quantity',
                    errorText: errors['quantity'],
                    child: _ProductionTextField(
                      controller: quantityController,
                      hintText: 'e.g. 200',
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Graded By',
                    errorText: errors['gradedBy'],
                    child: _ProductionTextField(
                      controller: gradedByController,
                      hintText: 'e.g. Staff A',
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            TextButton(
              onPressed: onCancel,
              child: const Text(
                'Cancel',
                style: TextStyle(color: _DashboardPalette.mutedForeground),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: onSubmit,
              style: FilledButton.styleFrom(
                backgroundColor: _DashboardPalette.primary,
                foregroundColor: _DashboardPalette.primaryForeground,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text('Record Grading'),
            ),
          ],
        ),
      ],
    );
  }
}

class _GradingChoiceButton extends StatelessWidget {
  const _GradingChoiceButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? _DashboardPalette.primary.withValues(alpha: 0.12)
              : _DashboardPalette.tabBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.mutedForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _GradingRecordsTable extends StatelessWidget {
  const _GradingRecordsTable({required this.records, required this.onDelete});

  final List<_GradingEntry> records;
  final ValueChanged<String> onDelete;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text(
            'No grading records yet',
            style: TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        horizontalMargin: 10,
        columnSpacing: 24,
        headingTextStyle: const TextStyle(
          color: _DashboardPalette.mutedForeground,
          fontWeight: FontWeight.w600,
        ),
        dataTextStyle: const TextStyle(color: _DashboardPalette.foreground),
        columns: const <DataColumn>[
          DataColumn(label: Text('Date')),
          DataColumn(label: Text('Batch')),
          DataColumn(label: Text('Size')),
          DataColumn(label: Text('Quality')),
          DataColumn(numeric: true, label: Text('Qty')),
          DataColumn(label: Text('Grader')),
          DataColumn(label: Text('')),
        ],
        rows: records
            .map(
              (_GradingEntry record) => DataRow(
                cells: <DataCell>[
                  DataCell(Text('${record.date} ${record.time}')),
                  DataCell(
                    Text(
                      record.batchId,
                      style: const TextStyle(
                        color: _DashboardPalette.primary,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  DataCell(_GradingSizeChip(size: record.size)),
                  DataCell(_GradingQualityChip(quality: record.quality)),
                  DataCell(Text(record.quantity.toString())),
                  DataCell(Text(record.gradedBy)),
                  DataCell(
                    IconButton(
                      onPressed: () => onDelete(record.id),
                      icon: const Icon(Icons.delete_outline_rounded),
                      color: _DashboardPalette.mutedForeground,
                    ),
                  ),
                ],
              ),
            )
            .toList(),
      ),
    );
  }
}

class _GradingSizeChip extends StatelessWidget {
  const _GradingSizeChip({required this.size});

  final String size;

  @override
  Widget build(BuildContext context) {
    final Color color = _gradingSizeColor(size);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        size,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GradingQualityChip extends StatelessWidget {
  const _GradingQualityChip({required this.quality});

  final String quality;

  @override
  Widget build(BuildContext context) {
    final Color color = _gradingQualityColor(quality);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        quality,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

Color _gradingQualityColor(String quality) {
  switch (quality) {
    case 'Good':
      return _DashboardPalette.success;
    case 'Cracked':
      return _DashboardPalette.warning;
    case 'Rejected':
      return _DashboardPalette.danger;
    default:
      return _DashboardPalette.mutedForeground;
  }
}

Color _gradingSizeColor(String size) {
  switch (size) {
    case 'Small':
      return const Color(0xFF9B5DE5);
    case 'Medium':
      return const Color(0xFF4DA3FF);
    case 'Large':
      return _DashboardPalette.primary;
    case 'Extra Large':
      return const Color(0xFFFF7F50);
    default:
      return _DashboardPalette.mutedForeground;
  }
}

class _GradingEntry {
  const _GradingEntry({
    required this.id,
    required this.date,
    required this.time,
    required this.batchId,
    required this.size,
    required this.quality,
    required this.quantity,
    required this.gradedBy,
  });

  final String id;
  final String date;
  final String time;
  final String batchId;
  final String size;
  final String quality;
  final int quantity;
  final String gradedBy;
}

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  final TextEditingController _todayTraysController = TextEditingController();

  late List<InventoryItem> _items;
  late List<InventoryZone> _zones;
  late List<InventoryMovement> _movements;
  String _zoneFilter = 'all';

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppState);
    _reloadFromAppState();
    if (widget.appState.hasTodayTrayStock) {
      _todayTraysController.text = '${widget.appState.todayTrayStockSet}';
    } else if (widget.appState.availableTrays > 0) {
      _todayTraysController.text = '${widget.appState.availableTrays}';
    }
  }

  void _onAppState() {
    if (!mounted) {
      return;
    }
    setState(_reloadFromAppState);
  }

  void _reloadFromAppState() {
    _items = List<InventoryItem>.from(widget.appState.inventoryItems);
    _zones = List<InventoryZone>.from(widget.appState.inventoryZones);
    _movements = List<InventoryMovement>.from(
      widget.appState.inventoryMovements,
    );
  }

  void _saveTodayTrays() {
    final int? trays = int.tryParse(_todayTraysController.text.trim());
    if (trays == null || trays < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter how many trays are available today.')),
      );
      return;
    }
    widget.appState.setTodayTrayStock(trays);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Saved $trays tray(s) for today (${trays * 30} eggs). Sellers will see this stock.',
        ),
      ),
    );
  }

  Future<void> _deleteTodayTrays() async {
    final bool hasStock = widget.appState.availableTrays > 0 ||
        widget.appState.availableSellableEggs > 0 ||
        widget.appState.hasTodayTrayStock;
    if (!hasStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tray stock to delete.')),
      );
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF241C16),
          title: const Text(
            'Delete today\'s trays permanently?',
            style: TextStyle(color: _DashboardPalette.foreground),
          ),
          content: Text(
            'This hard-deletes today\'s tray stock '
            '(${widget.appState.availableTrays} trays / '
            '${widget.appState.availableSellableEggs} eggs) from the app and farm database. '
            'Sellers will see 0 available.',
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    widget.appState.deleteTodayTrayStock();
    _todayTraysController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Today\'s trays permanently deleted.')),
    );
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppState);
    _todayTraysController.dispose();
    super.dispose();
  }

  List<InventoryItem> get _visibleItems {
    if (_zoneFilter == 'all') {
      return _items;
    }
    return _items
        .where((InventoryItem item) => item.zoneId == _zoneFilter)
        .toList();
  }

  List<InventoryMovement> get _visibleMovements {
    if (_zoneFilter == 'all') {
      return _movements;
    }
    final Set<String> itemIds = _visibleItems
        .map((InventoryItem item) => item.id)
        .toSet();
    return _movements
        .where(
          (InventoryMovement movement) => itemIds.contains(movement.itemId),
        )
        .toList();
  }

  int get _totalStockUnits => _visibleItems.fold<int>(
    0,
    (int sum, InventoryItem item) => sum + item.quantity,
  );

  int get _lowStockCount => _visibleItems
      .where(
        (InventoryItem item) =>
            item.minThreshold > 0 && item.quantity <= item.minThreshold,
      )
      .length;

  int get _capacityPercentage {
    final int used = _totalStockUnits;
    final int max = _visibleItems.fold<int>(
      0,
      (int sum, InventoryItem item) => sum + item.maxCapacity,
    );
    if (max == 0) {
      return 0;
    }
    return ((used / max) * 100).round();
  }

  InventoryItem? _itemById(String itemId) {
    for (final InventoryItem item in _items) {
      if (item.id == itemId) {
        return item;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final List<_ProductionStat> stats = <_ProductionStat>[
      _ProductionStat(
        icon: Icons.inventory_2_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Total Stock',
        value: _totalStockUnits.toString(),
        suffix: 'units',
      ),
      _ProductionStat(
        icon: Icons.warning_amber_rounded,
        iconColor: _DashboardPalette.warning,
        label: 'Low Stock Items',
        value: _lowStockCount.toString(),
        suffix: 'items',
      ),
      _ProductionStat(
        icon: Icons.speed_outlined,
        iconColor: _DashboardPalette.success,
        label: 'Capacity Used',
        value: _capacityPercentage.toString(),
        suffix: '%',
      ),
    ];

    return EggScaffold(
      appState: widget.appState,
      title: 'Inventory',
      selectedRoute: AppPaths.inventory,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _DashboardPalette.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.inventory_2_outlined,
                  color: _DashboardPalette.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'LIVE INVENTORY',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Track stock and recent inventory movements',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _DashboardPalette.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _ProductionStatGrid(stats: stats),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Trays available for sale today',
            titleIcon: Icons.egg_alt_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Enter how many trays the seller can sell today. '
                  '1 tray = 30 eggs. This updates inventory and shows on the seller screen.',
                  style: TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool stacked = constraints.maxWidth < 560;
                    final Widget field = TextField(
                      controller: _todayTraysController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(
                        color: _DashboardPalette.foreground,
                      ),
                      cursorColor: _DashboardPalette.primary,
                      decoration: InputDecoration(
                        labelText: 'Trays for today',
                        labelStyle: const TextStyle(
                          color: _DashboardPalette.mutedForeground,
                        ),
                        hintText: 'e.g. 10',
                        hintStyle: const TextStyle(color: Color(0xFFB7AA9A)),
                        filled: true,
                        fillColor: const Color(0xFF3A322B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF4A4038)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFF4A4038)),
                        ),
                      ),
                    );
                    final Widget saveButton = FilledButton.icon(
                      onPressed: _saveTodayTrays,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Save for sellers'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _DashboardPalette.primary,
                        foregroundColor: const Color(0xFF2A2118),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    );
                    final Widget deleteButton = OutlinedButton.icon(
                      onPressed: _deleteTodayTrays,
                      icon: const Icon(Icons.delete_outline_rounded),
                      label: const Text('Delete trays'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFDC2626),
                        side: const BorderSide(color: Color(0xFFDC2626)),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    );
                    if (stacked) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          field,
                          const SizedBox(height: 12),
                          saveButton,
                          const SizedBox(height: 10),
                          deleteButton,
                        ],
                      );
                    }
                    return Row(
                      children: <Widget>[
                        Expanded(child: field),
                        const SizedBox(width: 12),
                        saveButton,
                        const SizedBox(width: 10),
                        deleteButton,
                      ],
                    );
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  widget.appState.hasTodayTrayStock
                      ? 'Today: ${widget.appState.todayTrayStockSet} trays set · '
                          '${widget.appState.availableTrays} trays left · '
                          '${widget.appState.availableSellableEggs} eggs left'
                      : 'No trays set for today yet. '
                          'Current stock: ${widget.appState.availableTrays} trays · '
                          '${widget.appState.availableSellableEggs} sellable eggs.',
                  style: const TextStyle(
                    color: _DashboardPalette.foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Stock on hand',
            titleIcon: Icons.inventory_2_outlined,
            child: _items.isEmpty
                ? const Text(
                    'No inventory items.',
                    style: TextStyle(color: _DashboardPalette.mutedForeground),
                  )
                : Column(
                    children: <Widget>[
                      for (final InventoryItem item in _visibleItems)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF241C16),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFF4A4038),
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        item.name,
                                        style: const TextStyle(
                                          color: _DashboardPalette.foreground,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${item.sku} · ${item.category}',
                                        style: const TextStyle(
                                          color:
                                              _DashboardPalette.mutedForeground,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  '${item.quantity} ${item.unit}',
                                  style: const TextStyle(
                                    color: _DashboardPalette.primary,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Zone Scope',
            titleIcon: Icons.location_on_outlined,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                _InventoryFilterChip(
                  label: 'All Zones',
                  selected: _zoneFilter == 'all',
                  onTap: () => setState(() => _zoneFilter = 'all'),
                ),
                ..._zones.map(
                  (InventoryZone zone) => _InventoryFilterChip(
                    label: zone.name,
                    selected: _zoneFilter == zone.id,
                    onTap: () => setState(() => _zoneFilter = zone.id),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Recent Movements',
            titleIcon: Icons.history_rounded,
            child: _InventoryMovementsTable(
              movements: _visibleMovements,
              itemById: _itemById,
            ),
          ),
        ],
      ),
    );
  }
}

class _InventoryFilterChip extends StatelessWidget {
  const _InventoryFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? _DashboardPalette.primary.withValues(alpha: 0.14)
              : _DashboardPalette.tabBackground,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.mutedForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _InventoryMovementsTable extends StatelessWidget {
  const _InventoryMovementsTable({
    required this.movements,
    required this.itemById,
  });

  final List<InventoryMovement> movements;
  final InventoryItem? Function(String itemId) itemById;

  @override
  Widget build(BuildContext context) {
    if (movements.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Text(
            'No inventory movements recorded yet',
            style: TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        horizontalMargin: 10,
        columnSpacing: 20,
        headingTextStyle: const TextStyle(
          color: _DashboardPalette.mutedForeground,
          fontWeight: FontWeight.w600,
        ),
        dataTextStyle: const TextStyle(color: _DashboardPalette.foreground),
        columns: const <DataColumn>[
          DataColumn(label: Text('When')),
          DataColumn(label: Text('Item')),
          DataColumn(label: Text('Type')),
          DataColumn(label: Text('Source')),
          DataColumn(numeric: true, label: Text('Delta')),
          DataColumn(numeric: true, label: Text('After')),
          DataColumn(label: Text('Note')),
        ],
        rows: movements.map((InventoryMovement movement) {
          final InventoryItem? item = itemById(movement.itemId);
          final bool incoming = movement.quantityDelta > 0;
          return DataRow(
            cells: <DataCell>[
              DataCell(Text(movement.timestamp)),
              DataCell(Text(item?.name ?? movement.itemId)),
              DataCell(
                _InventoryPill(
                  label: _movementTypeLabel(movement.movementType),
                  color: _movementTypeColor(movement.movementType),
                ),
              ),
              DataCell(
                _InventoryPill(
                  label: movement.source == 'iot_device'
                      ? 'IoT Device'
                      : 'User',
                  color: movement.source == 'iot_device'
                      ? _DashboardPalette.primary
                      : _DashboardPalette.mutedForeground,
                ),
              ),
              DataCell(
                Text(
                  '${incoming ? '+' : '-'}${movement.quantityDelta.abs()}',
                  style: TextStyle(
                    color: incoming
                        ? _DashboardPalette.success
                        : _DashboardPalette.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              DataCell(Text(movement.quantityAfter.toString())),
              DataCell(
                SizedBox(width: 220, child: Text(movement.note ?? '--')),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

class _InventoryPill extends StatelessWidget {
  const _InventoryPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _movementTypeLabel(String movementType) {
  switch (movementType) {
    case 'stock_in':
      return 'Stock In';
    case 'stock_out':
      return 'Stock Out';
    case 'release':
      return 'Release';
    case 'refill':
      return 'Refill';
    default:
      return movementType;
  }
}

Color _movementTypeColor(String movementType) {
  switch (movementType) {
    case 'stock_in':
    case 'refill':
      return _DashboardPalette.success;
    case 'stock_out':
      return _DashboardPalette.warning;
    case 'release':
      return _DashboardPalette.primary;
    default:
      return _DashboardPalette.mutedForeground;
  }
}

enum _ReportPeriod { daily, weekly, monthly }

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  _ReportPeriod _selectedPeriod = _ReportPeriod.weekly;
  String? _expandedModule;
  String? _lastExportFileName;

  String get _periodLabel {
    final DateTime now = DateTime.now();
    String mon(int m) {
      const List<String> names = <String>[
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return names[m - 1];
    }

    switch (_selectedPeriod) {
      case _ReportPeriod.daily:
        return '${mon(now.month)} ${now.day}, ${now.year}';
      case _ReportPeriod.weekly:
        final DateTime start = now.subtract(const Duration(days: 6));
        return '${mon(start.month)} ${start.day} - ${mon(now.month)} ${now.day}, ${now.year}';
      case _ReportPeriod.monthly:
        return '${mon(now.month)} ${now.year}';
    }
  }

  String get _periodName {
    switch (_selectedPeriod) {
      case _ReportPeriod.daily:
        return 'daily';
      case _ReportPeriod.weekly:
        return 'weekly';
      case _ReportPeriod.monthly:
        return 'monthly';
    }
  }

  List<ReportTrendPoint> get _trendPoints {
    final List<ReportTrendPoint> points = widget.appState.reportTrendPoints;
    switch (_selectedPeriod) {
      case _ReportPeriod.daily:
        return points.isEmpty
            ? <ReportTrendPoint>[]
            : <ReportTrendPoint>[points.last];
      case _ReportPeriod.weekly:
        return points;
      case _ReportPeriod.monthly:
        return points;
    }
  }

  bool get _sellerMode => widget.appState.isSales;

  DateTime get _periodStart {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    switch (_selectedPeriod) {
      case _ReportPeriod.daily:
        return today;
      case _ReportPeriod.weekly:
        return today.subtract(const Duration(days: 6));
      case _ReportPeriod.monthly:
        return DateTime(now.year, now.month, 1);
    }
  }

  List<EggSale> get _salesInPeriod {
    final DateTime start = _periodStart;
    return widget.appState.eggSales.where((EggSale sale) {
      final DateTime? parsed = DateTime.tryParse(sale.createdAt);
      if (parsed == null) {
        return false;
      }
      final DateTime local = parsed.toLocal();
      final DateTime day = DateTime(local.year, local.month, local.day);
      return !day.isBefore(start);
    }).toList();
  }

  String _csvEscape(String value) {
    final String safe = value.replaceAll('"', '""');
    if (safe.contains(',') || safe.contains('"') || safe.contains('\n')) {
      return '"$safe"';
    }
    return safe;
  }

  String get _exportPreview {
    if (_sellerMode) {
      final List<String> lines = <String>[
        'Date,Time,SoldBy,Size,Quantity,EggCount,UnitPrice,Total,Buyer,Seller',
        ..._salesInPeriod.map((EggSale sale) {
          final DateTime? parsed = DateTime.tryParse(sale.createdAt)?.toLocal();
          final String date = parsed == null
              ? ''
              : '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
          final String time = parsed == null
              ? ''
              : '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
          return <String>[
            date,
            time,
            sale.perTray ? 'tray' : 'piece',
            _csvEscape(sale.size),
            '${sale.quantity}',
            '${sale.eggCount}',
            sale.unitPrice.toStringAsFixed(2),
            sale.total.toStringAsFixed(2),
            _csvEscape(sale.buyer),
            _csvEscape(
              sale.sellerName.isNotEmpty ? sale.sellerName : sale.sellerEmail,
            ),
          ].join(',');
        }),
      ];
      return lines.join('\n');
    }
    final List<ReportTrendPoint> rows = _trendPoints;
    final List<String> csvLines = <String>[
      'Date,Production,Sales,Losses,Graded,Collected',
      ...rows.map(
        (ReportTrendPoint row) =>
            '${row.label},${row.production},${row.sales},'
            '${row.losses},${row.graded},${row.collected}',
      ),
    ];
    return csvLines.join('\n');
  }

  void _exportCsv() {
    final DateTime now = DateTime.now();
    final String stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final String fileName = _sellerMode
        ? 'egg-sales-report-$_periodName-$stamp.csv'
        : 'egg-report-$_periodName-$stamp.csv';
    final String csv = _exportPreview;
    final bool empty = _sellerMode
        ? _salesInPeriod.isEmpty
        : _trendPoints.isEmpty;
    setState(() => _lastExportFileName = fileName);
    if (!empty) {
      downloadTextFile(fileName, '$csv\n');
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          empty
              ? (_sellerMode
                  ? 'No sales in this period yet — record a sale first.'
                  : 'No rows to export yet — log production or wait for live eggs.')
              : 'Downloaded $fileName'
                  '${_sellerMode ? ' (${_salesInPeriod.length} sale(s))' : ' (${_trendPoints.length} day(s))'}.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<_ProductionStat> stats = <_ProductionStat>[
      _ProductionStat(
        icon: Icons.egg_alt_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Production',
        value: _trendPoints
            .fold<int>(
              0,
              (int sum, ReportTrendPoint point) => sum + point.production,
            )
            .toString(),
        suffix: 'eggs',
      ),
      _ProductionStat(
        icon: Icons.point_of_sale_outlined,
        iconColor: _DashboardPalette.success,
        label: 'Sales',
        value: _trendPoints
            .fold<int>(
              0,
              (int sum, ReportTrendPoint point) => sum + point.sales,
            )
            .toString(),
        suffix: 'sold',
      ),
      _ProductionStat(
        icon: Icons.fact_check_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Graded',
        value: _trendPoints
            .fold<int>(
              0,
              (int sum, ReportTrendPoint point) => sum + point.graded,
            )
            .toString(),
        suffix: 'graded',
      ),
      _ProductionStat(
        icon: Icons.warning_amber_rounded,
        iconColor: _DashboardPalette.warning,
        label: 'Losses',
        value: _trendPoints
            .fold<int>(
              0,
              (int sum, ReportTrendPoint point) => sum + point.losses,
            )
            .toString(),
        suffix: 'units',
      ),
    ];

    return EggScaffold(
      appState: widget.appState,
      title: 'Reports',
      selectedRoute: AppPaths.reports,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _DashboardPalette.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.insert_chart_outlined,
                  color: _DashboardPalette.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'REPORTS & SUMMARIES',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _sellerMode
                          ? 'Generate and download daily, weekly, or monthly sales reports'
                          : 'Exportable daily, weekly, and monthly admin summaries',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _DashboardPalette.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: _exportCsv,
                style: FilledButton.styleFrom(
                  backgroundColor: _DashboardPalette.primary,
                  foregroundColor: _DashboardPalette.primaryForeground,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 16,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.download_rounded),
                label: Text(_sellerMode ? 'Generate / Download' : 'Export CSV'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Reporting Period',
            titleIcon: Icons.calendar_month_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _ReportsPeriodChip(
                      label: 'Daily',
                      selected: _selectedPeriod == _ReportPeriod.daily,
                      onTap: () {
                        setState(() => _selectedPeriod = _ReportPeriod.daily);
                      },
                    ),
                    _ReportsPeriodChip(
                      label: 'Weekly',
                      selected: _selectedPeriod == _ReportPeriod.weekly,
                      onTap: () {
                        setState(() => _selectedPeriod = _ReportPeriod.weekly);
                      },
                    ),
                    _ReportsPeriodChip(
                      label: 'Monthly',
                      selected: _selectedPeriod == _ReportPeriod.monthly,
                      onTap: () {
                        setState(() => _selectedPeriod = _ReportPeriod.monthly);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  _periodLabel,
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _ProductionStatGrid(stats: stats),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Overview Trend',
            titleIcon: Icons.show_chart_rounded,
            child: _ReportsTrendChart(points: _trendPoints),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Module Summaries',
            titleIcon: Icons.dashboard_customize_outlined,
            child: _ReportsModuleGrid(
              modules: widget.appState.reportModuleSummaries,
              expandedModule: _expandedModule,
              onToggle: (String module) {
                setState(() {
                  _expandedModule = _expandedModule == module ? null : module;
                });
              },
            ),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool medium = constraints.maxWidth >= 920;
              final double width = medium
                  ? (constraints.maxWidth - 16) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: <Widget>[
                  SizedBox(
                    width: width,
                    child: _GlassSection(
                      title: 'Monthly Breakdown by Week',
                      titleIcon: Icons.bar_chart_rounded,
                      child: _ReportsBreakdownChart(
                        rows: widget.appState.reportWeeklyBreakdown,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _GlassSection(
                      title: 'Export Preview',
                      titleIcon: Icons.description_outlined,
                      child: _ReportsExportPreview(
                        fileName: _lastExportFileName ??
                            (_sellerMode
                                ? 'egg-sales-report-$_periodName.csv'
                                : 'egg-report-$_periodName.csv'),
                        csvPreview: _exportPreview,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Key Insights',
            titleIcon: Icons.lightbulb_outline_rounded,
            child: _ReportsInsightsGrid(
              insights: widget.appState.reportInsights,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportsPeriodChip extends StatelessWidget {
  const _ReportsPeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? _DashboardPalette.primary.withValues(alpha: 0.14)
              : _DashboardPalette.tabBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.mutedForeground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _ReportsTrendChart extends StatelessWidget {
  const _ReportsTrendChart({required this.points});

  final List<ReportTrendPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const SizedBox.shrink();
    }

    final int maxValue = points
        .map(
          (ReportTrendPoint point) => <int>[
            point.production,
            point.sales,
            point.losses,
          ].reduce((int a, int b) => a > b ? a : b),
        )
        .reduce((int a, int b) => a > b ? a : b);

    return SizedBox(
      height: 280,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: points
            .map(
              (ReportTrendPoint point) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        point.label,
                        style: const TextStyle(
                          color: _DashboardPalette.mutedForeground,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              _MiniBar(
                                heightFactor: point.production / maxValue,
                                color: _DashboardPalette.primary,
                              ),
                              const SizedBox(width: 6),
                              _MiniBar(
                                heightFactor: point.sales / maxValue,
                                color: _DashboardPalette.success,
                              ),
                              const SizedBox(width: 6),
                              _MiniBar(
                                heightFactor: point.losses / maxValue,
                                color: _DashboardPalette.danger,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'P ${point.production}',
                        style: const TextStyle(
                          color: _DashboardPalette.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'S ${point.sales}',
                        style: const TextStyle(
                          color: _DashboardPalette.success,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'L ${point.losses}',
                        style: const TextStyle(
                          color: _DashboardPalette.danger,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ReportsModuleGrid extends StatelessWidget {
  const _ReportsModuleGrid({
    required this.modules,
    required this.expandedModule,
    required this.onToggle,
  });

  final List<ReportModuleSummary> modules;
  final String? expandedModule;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool large = constraints.maxWidth >= 1120;
        final bool medium = constraints.maxWidth >= 720;
        final double width = large
            ? (constraints.maxWidth - 36) / 4
            : medium
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: modules
              .map(
                (ReportModuleSummary module) => SizedBox(
                  width: width,
                  child: _ReportsModuleCard(
                    module: module,
                    expanded: expandedModule == module.module,
                    onTap: () => onToggle(module.module),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _ReportsModuleCard extends StatelessWidget {
  const _ReportsModuleCard({
    required this.module,
    required this.expanded,
    required this.onTap,
  });

  final ReportModuleSummary module;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Ink(
        decoration: BoxDecoration(
          color: _DashboardPalette.tabBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _DashboardPalette.glassBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: module.color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(module.icon, color: module.color, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      module.module,
                      style: const TextStyle(
                        color: _DashboardPalette.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: _DashboardPalette.mutedForeground,
                  ),
                ],
              ),
              if (expanded) ...<Widget>[
                const SizedBox(height: 16),
                ...module.metrics.map(
                  (ReportMetric metric) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            metric.label,
                            style: const TextStyle(
                              color: _DashboardPalette.mutedForeground,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          metric.value,
                          style: const TextStyle(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (metric.change != 0) ...<Widget>[
                          const SizedBox(width: 10),
                          _ReportsChangeChip(change: metric.change),
                        ],
                      ],
                    ),
                  ),
                ),
              ] else ...<Widget>[
                const SizedBox(height: 14),
                Text(
                  '${module.metrics.first.value} ${module.metrics.first.label}',
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportsChangeChip extends StatelessWidget {
  const _ReportsChangeChip({required this.change});

  final double change;

  @override
  Widget build(BuildContext context) {
    final bool positive = change > 0;
    final Color color = positive
        ? _DashboardPalette.success
        : _DashboardPalette.danger;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            positive ? Icons.trending_up_rounded : Icons.trending_down_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '${change.abs()}%',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportsBreakdownChart extends StatelessWidget {
  const _ReportsBreakdownChart({required this.rows});

  final List<ReportBreakdownRow> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }

    final int maxValue = rows
        .map(
          (ReportBreakdownRow row) => <int>[
            row.production,
            row.sales,
            row.losses,
          ].reduce((int a, int b) => a > b ? a : b),
        )
        .reduce((int a, int b) => a > b ? a : b);

    return Column(
      children: rows
          .map(
            (ReportBreakdownRow row) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    row.label,
                    style: const TextStyle(
                      color: _DashboardPalette.foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _ReportsBreakdownBar(
                    label: 'Production',
                    value: row.production,
                    maxValue: maxValue,
                    color: _DashboardPalette.primary,
                  ),
                  const SizedBox(height: 6),
                  _ReportsBreakdownBar(
                    label: 'Sales',
                    value: row.sales,
                    maxValue: maxValue,
                    color: _DashboardPalette.success,
                  ),
                  const SizedBox(height: 6),
                  _ReportsBreakdownBar(
                    label: 'Losses',
                    value: row.losses,
                    maxValue: maxValue,
                    color: _DashboardPalette.danger,
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class _ReportsBreakdownBar extends StatelessWidget {
  const _ReportsBreakdownBar({
    required this.label,
    required this.value,
    required this.maxValue,
    required this.color,
  });

  final String label;
  final int value;
  final int maxValue;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double progress = maxValue == 0 ? 0 : value / maxValue;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: const TextStyle(
              color: _DashboardPalette.mutedForeground,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.clamp(0, 1).toDouble(),
              minHeight: 10,
              color: color,
              backgroundColor: _DashboardPalette.border,
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 54,
          child: Text(
            value.toString(),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: _DashboardPalette.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _ReportsExportPreview extends StatelessWidget {
  const _ReportsExportPreview({
    required this.fileName,
    required this.csvPreview,
  });

  final String fileName;
  final String csvPreview;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          fileName,
          style: const TextStyle(
            color: _DashboardPalette.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Local preview generated from the active reporting period.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: _DashboardPalette.mutedForeground,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _DashboardPalette.tabBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _DashboardPalette.glassBorder),
          ),
          child: SelectableText(
            csvPreview,
            style: const TextStyle(
              color: _DashboardPalette.foreground,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _ReportsInsightsGrid extends StatelessWidget {
  const _ReportsInsightsGrid({required this.insights});

  final List<InsightNote> insights;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool medium = constraints.maxWidth >= 760;
        final double width = medium
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: insights.asMap().entries.map((
            MapEntry<int, InsightNote> entry,
          ) {
            final bool positive = entry.key < 2;
            return SizedBox(
              width: width,
              child: _ReportsInsightTile(note: entry.value, positive: positive),
            );
          }).toList(),
        );
      },
    );
  }
}

class _ReportsInsightTile extends StatelessWidget {
  const _ReportsInsightTile({required this.note, required this.positive});

  final InsightNote note;
  final bool positive;

  @override
  Widget build(BuildContext context) {
    final Color color = positive
        ? _DashboardPalette.success
        : _DashboardPalette.warning;
    final IconData icon = positive
        ? Icons.trending_up_rounded
        : Icons.warning_amber_rounded;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  note.title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            note.description,
            style: const TextStyle(
              color: _DashboardPalette.mutedForeground,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class EggSalesScreen extends StatefulWidget {
  const EggSalesScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<EggSalesScreen> createState() => _EggSalesScreenState();
}

class _EggSalesScreenState extends State<EggSalesScreen> {
  static const int _eggsPerTray = 30;
  static const List<String> _sizes = <String>[
    'Small',
    'Medium',
    'Large',
    'Extra Large',
  ];
  static const List<int> _quickAmounts = <int>[1, 2, 5, 10];

  bool _perTray = true;
  String _size = 'Extra Large';
  int _quantity = 1;
  String? _error;
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _buyerController = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppState);
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppState);
    _priceController.dispose();
    _buyerController.dispose();
    super.dispose();
  }

  void _onAppState() {
    if (mounted) {
      setState(() {});
    }
  }

  double? get _unitPrice {
    final String raw = _priceController.text.trim().replaceAll(',', '');
    if (raw.isEmpty) {
      return null;
    }
    return double.tryParse(raw);
  }

  double get _lineTotal {
    final double? price = _unitPrice;
    if (price == null || price < 0) {
      return 0;
    }
    return price * _quantity;
  }

  int get _eggCount => _perTray ? _quantity * _eggsPerTray : _quantity;

  void _recordSale() {
    final double? price = _unitPrice;
    if (_quantity < 1) {
      setState(() => _error = 'Enter how many ${_perTray ? 'trays' : 'pieces'}.');
      return;
    }
    if (price == null || price <= 0) {
      setState(() => _error = 'Enter the price.');
      return;
    }
    final int needEggs = _eggCount;
    final int needTrays = _perTray ? _quantity : 0;
    if (needTrays > widget.appState.availableTrays) {
      setState(() {
        _error =
            'Only ${widget.appState.availableTrays} tray(s) left in inventory. Ask admin to add trays for today.';
      });
      return;
    }
    if (needEggs > widget.appState.availableSellableEggs) {
      setState(() {
        _error =
            'Only ${widget.appState.availableSellableEggs} egg(s) left in inventory. Ask admin to add trays for today.';
      });
      return;
    }
    final DemoUser? user = widget.appState.currentUser;
    widget.appState.addEggSale(
      EggSale(
        id: 'sale-${DateTime.now().microsecondsSinceEpoch}',
        createdAt: DateTime.now().toUtc().toIso8601String(),
        soldBy: _perTray ? 'tray' : 'piece',
        size: _size,
        quantity: _quantity,
        unitPrice: price,
        buyer: _buyerController.text.trim(),
        payment: '',
        sellerName: user?.name ?? '',
        sellerEmail: user?.email ?? '',
      ),
    );
    _priceController.clear();
    _buyerController.clear();
    setState(() {
      _quantity = 1;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final DateTime today = _dashboardDay(DateTime.now());
    final List<EggSale> todaySales = widget.appState.eggSales.where((EggSale sale) {
      final DateTime? parsed = DateTime.tryParse(sale.createdAt);
      return parsed != null && _dashboardDay(parsed) == today;
    }).toList();
    final int eggsSold = todaySales.fold<int>(0, (int sum, EggSale sale) => sum + sale.eggCount);
    final int trays = todaySales.fold<int>(
      0,
      (int sum, EggSale sale) => sum + (sale.perTray ? sale.quantity : 0),
    );
    final int pieces = todaySales.fold<int>(
      0,
      (int sum, EggSale sale) => sum + (sale.perTray ? 0 : sale.quantity),
    );
    final double revenue = todaySales.fold<double>(0, (double sum, EggSale sale) => sum + sale.total);

    return EggScaffold(
      appState: widget.appState,
      title: 'Egg Monitoring System',
      selectedRoute: AppPaths.sales,
      useLoginBackground: true,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF2A2118),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x66EFB73E)),
                ),
                child: const Icon(Icons.shopping_cart_outlined, color: Color(0xFFEFB73E)),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'EGG SALES',
                      style: TextStyle(
                        color: _DashboardPalette.foreground,
                        fontWeight: FontWeight.w800,
                        fontSize: 22,
                        letterSpacing: 0.6,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Record eggs sold per piece or per tray (1 tray = 30 eggs)',
                      style: TextStyle(color: _DashboardPalette.mutedForeground),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _GlassSection(
            title: 'Inventory for sale',
            titleIcon: Icons.inventory_2_outlined,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final int columns = constraints.maxWidth >= 700 ? 3 : 1;
                final double width =
                    (constraints.maxWidth - 12 * (columns - 1)) / columns;
                final int availableTrays = widget.appState.availableTrays;
                final int availableEggs = widget.appState.availableSellableEggs;
                final List<Widget> stockCards = <Widget>[
                  _SalesMetric(
                    icon: Icons.inventory_2_outlined,
                    label: 'Trays available',
                    value: '$availableTrays',
                    accent: availableTrays > 0
                        ? _DashboardPalette.primary
                        : _DashboardPalette.warning,
                  ),
                  _SalesMetric(
                    icon: Icons.egg_alt_outlined,
                    label: 'Eggs available',
                    value: '$availableEggs',
                    accent: availableEggs > 0
                        ? _DashboardPalette.success
                        : _DashboardPalette.warning,
                  ),
                  _SalesMetric(
                    icon: Icons.today_outlined,
                    label: 'Admin set today',
                    value: widget.appState.hasTodayTrayStock
                        ? '${widget.appState.todayTrayStockSet} trays'
                        : 'Not set',
                  ),
                ];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      availableTrays > 0 || availableEggs > 0
                          ? 'Stock from admin Inventory. Sales reduce these numbers automatically.'
                          : 'No stock yet. Ask the admin to open Inventory and enter trays for today.',
                      style: const TextStyle(
                        color: _DashboardPalette.mutedForeground,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: stockCards
                          .map(
                            (Widget card) =>
                                SizedBox(width: width, child: card),
                          )
                          .toList(),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final int columns = constraints.maxWidth >= 900
                  ? 4
                  : constraints.maxWidth >= 560
                  ? 2
                  : 1;
              final double width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
              final List<Widget> cards = <Widget>[
                _SalesMetric(icon: Icons.egg_alt_outlined, label: 'Eggs sold today', value: '$eggsSold'),
                _SalesMetric(icon: Icons.inventory_2_outlined, label: 'Trays sold today', value: '$trays'),
                _SalesMetric(icon: Icons.egg_outlined, label: 'Loose pieces today', value: '$pieces'),
                _SalesMetric(
                  icon: Icons.payments_outlined,
                  label: 'Revenue today',
                  value: _peso(revenue),
                  accent: _DashboardPalette.success,
                ),
              ];
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: cards
                    .map((Widget card) => SizedBox(width: width, child: card))
                    .toList(),
              );
            },
          ),
          const SizedBox(height: 16),
          _GlassSection(
            title: 'New sale',
            titleIcon: Icons.point_of_sale_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Sold by',
                  style: TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool stacked = constraints.maxWidth < 640;
                    final Widget tray = _SaleModeCard(
                      icon: Icons.inventory_2_outlined,
                      title: 'Per Tray',
                      subtitle: '30 eggs each',
                      selected: _perTray,
                      onTap: () => setState(() => _perTray = true),
                    );
                    final Widget piece = _SaleModeCard(
                      icon: Icons.egg_alt_outlined,
                      title: 'Per Piece',
                      subtitle: 'Loose eggs',
                      selected: !_perTray,
                      onTap: () => setState(() => _perTray = false),
                    );
                    if (stacked) {
                      return Column(
                        children: <Widget>[tray, const SizedBox(height: 10), piece],
                      );
                    }
                    return Row(
                      children: <Widget>[
                        Expanded(child: tray),
                        const SizedBox(width: 12),
                        Expanded(child: piece),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                const Text(
                  'Egg size',
                  style: TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _sizes
                      .map(
                        (String size) => _SaleChoiceChip(
                          label: size,
                          selected: _size == size,
                          onTap: () => setState(() => _size = size),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool stacked = constraints.maxWidth < 720;
                    final Widget amount = _SalesField(
                      label: _perTray ? 'How many trays?' : 'How many pieces?',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              _QtyButton(
                                icon: Icons.remove,
                                onTap: _quantity > 1
                                    ? () => setState(() => _quantity -= 1)
                                    : null,
                              ),
                              Expanded(
                                child: Text(
                                  '$_quantity',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: _DashboardPalette.foreground,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              _QtyButton(
                                icon: Icons.add,
                                onTap: () => setState(() => _quantity += 1),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            children: _quickAmounts
                                .map(
                                  (int amount) => _SaleChoiceChip(
                                    label: '$amount',
                                    selected: _quantity == amount,
                                    onTap: () => setState(() => _quantity = amount),
                                  ),
                                )
                                .toList(),
                          ),
                        ],
                      ),
                    );
                    final Widget price = _SalesField(
                      label: _perTray ? 'Price per tray (₱)' : 'Price per piece (₱)',
                      child: TextField(
                        controller: _priceController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(color: _DashboardPalette.foreground),
                        cursorColor: _DashboardPalette.primary,
                        onChanged: (_) => setState(() {}),
                        decoration: _salesInput(_perTray ? 'e.g. 240' : 'e.g. 8'),
                      ),
                    );
                    if (stacked) {
                      return Column(
                        children: <Widget>[amount, const SizedBox(height: 12), price],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(child: amount),
                        const SizedBox(width: 16),
                        Expanded(child: price),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                _SalesField(
                  label: 'Buyer (optional)',
                  child: TextField(
                    controller: _buyerController,
                    style: const TextStyle(color: _DashboardPalette.foreground),
                    cursorColor: _DashboardPalette.primary,
                    decoration: _salesInput("e.g. Aling Nena's Store"),
                  ),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
                ],
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF241C16),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0x66EFB73E)),
                  ),
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      final Widget summary = Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _perTray
                                ? '$_quantity ${_quantity == 1 ? 'tray' : 'trays'} = $_eggCount eggs · $_size'
                                : '$_quantity ${_quantity == 1 ? 'piece' : 'pieces'} · $_size',
                            style: const TextStyle(color: _DashboardPalette.foreground),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _peso(_lineTotal),
                            style: const TextStyle(
                              color: _DashboardPalette.primary,
                              fontWeight: FontWeight.w800,
                              fontSize: 20,
                            ),
                          ),
                        ],
                      );
                      final Widget button = FilledButton.icon(
                        onPressed: _recordSale,
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: const Text('RECORD SALE'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _DashboardPalette.primary,
                          foregroundColor: const Color(0xFF2A2118),
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                      if (constraints.maxWidth < 560) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[summary, const SizedBox(height: 12), button],
                        );
                      }
                      return Row(
                        children: <Widget>[
                          Expanded(child: summary),
                          const SizedBox(width: 12),
                          button,
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _GlassSection(
            title: 'Sales history',
            titleIcon: Icons.history_rounded,
            child: widget.appState.eggSales.isEmpty
                ? const Text(
                    'No sales recorded yet.',
                    style: TextStyle(color: _DashboardPalette.mutedForeground),
                  )
                : Column(
                    children: <Widget>[
                      for (final EggSale sale in widget.appState.eggSales)
                        _SaleHistoryRow(
                          sale: sale,
                          onDelete: () => _confirmDeleteSale(sale),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteSale(EggSale sale) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF241C16),
          title: const Text(
            'Delete sale permanently?',
            style: TextStyle(color: _DashboardPalette.foreground),
          ),
          content: Text(
            'This hard-deletes the ${sale.size} sale '
            '(${sale.perTray ? '${sale.quantity} tray(s)' : '${sale.quantity} piece(s)'}) '
            'from the app and the farm database. Stock will be restored.',
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626),
                foregroundColor: Colors.white,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) {
      return;
    }
    widget.appState.deleteEggSale(sale.id);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Sale permanently deleted.')),
    );
  }
}

String _peso(double value) => '₱${value.toStringAsFixed(2)}';

InputDecoration _salesInput(String hint) {
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFFB7AA9A)),
    filled: true,
    fillColor: const Color(0xFF3A322B),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFF4A4038)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFF4A4038)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFFEFB73E)),
    ),
  );
}

class _SalesMetric extends StatelessWidget {
  const _SalesMetric({
    required this.icon,
    required this.label,
    required this.value,
    this.accent = _DashboardPalette.primary,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1612),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A322B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: accent, size: 20),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(color: _DashboardPalette.mutedForeground, fontSize: 12)),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: _DashboardPalette.foreground,
              fontWeight: FontWeight.w800,
              fontSize: 22,
            ),
          ),
        ],
      ),
    );
  }
}

class _SaleModeCard extends StatelessWidget {
  const _SaleModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF241C16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? _DashboardPalette.primary : const Color(0xFF4A4038),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, color: selected ? _DashboardPalette.primary : _DashboardPalette.mutedForeground),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: selected ? _DashboardPalette.primary : _DashboardPalette.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(subtitle, style: const TextStyle(color: _DashboardPalette.mutedForeground, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SaleChoiceChip extends StatelessWidget {
  const _SaleChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0x332A2118) : const Color(0xFF241C16),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? _DashboardPalette.primary : const Color(0xFF4A4038),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _DashboardPalette.primary : _DashboardPalette.foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _QtyButton extends StatelessWidget {
  const _QtyButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon),
      color: _DashboardPalette.primary,
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xFF3A322B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

class _SalesField extends StatelessWidget {
  const _SalesField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _SaleHistoryRow extends StatelessWidget {
  const _SaleHistoryRow({required this.sale, required this.onDelete});

  final EggSale sale;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final DateTime? parsed = DateTime.tryParse(sale.createdAt)?.toLocal();
    final String when = parsed == null
        ? ''
        : '${_shortMonthDay(parsed)}  ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
    final String amount = sale.perTray
        ? '${sale.quantity} tray · ${sale.eggCount} eggs'
        : '${sale.quantity} piece · ${sale.eggCount} eggs';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF241C16),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A322B)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${sale.size} · ${sale.perTray ? 'Per tray' : 'Per piece'}',
                  style: const TextStyle(
                    color: _DashboardPalette.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    amount,
                    if (sale.payment.trim().isNotEmpty) sale.payment.trim(),
                    if (sale.buyer.isNotEmpty) sale.buyer,
                  ].join(' · '),
                  style: const TextStyle(color: _DashboardPalette.mutedForeground, fontSize: 12),
                ),
                if (when.isNotEmpty)
                  Text(when, style: const TextStyle(color: _DashboardPalette.mutedForeground, fontSize: 12)),
              ],
            ),
          ),
          Text(
            _peso(sale.total),
            style: const TextStyle(
              color: _DashboardPalette.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onDelete,
            tooltip: 'Delete permanently',
            icon: const Icon(Icons.delete_outline_rounded),
            color: const Color(0xFFDC2626),
          ),
        ],
      ),
    );
  }
}

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  bool _obscurePassword = true;
  bool _saving = false;
  bool _loading = true;
  bool _salesAccount = false;
  String _roleFilter = 'all';
  String? _error;
  String? _success;
  String? _listError;
  String? _busyEmail;
  List<DemoUser> _accounts = <DemoUser>[];

  @override
  void initState() {
    super.initState();
    unawaited(_loadAccounts());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    setState(() {
      _loading = true;
      _listError = null;
    });
    try {
      final List<DemoUser> users = await widget.appState.listFarmAccounts();
      if (!mounted) {
        return;
      }
      setState(() {
        _accounts = users;
        _loading = false;
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _listError = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _listError = 'Unable to load accounts from Firebase.';
        _loading = false;
      });
    }
  }

  String? _validatePassword(String? value) {
    final String password = value ?? '';
    if (password.length < 8) {
      return 'Minimum 8 characters';
    }
    if (!RegExp(r'[A-Za-z]').hasMatch(password)) {
      return 'Include a letter';
    }
    if (!RegExp(r'\d').hasMatch(password)) {
      return 'Include a number';
    }
    return null;
  }

  Future<void> _createAccount() async {
    final FormState? form = _formKey.currentState;
    if (form == null || !form.validate()) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      final ({String message, String? verificationCode, bool emailSent})
          created = _salesAccount
              ? await widget.appState.createSalesAccount(
                  name: _nameController.text.trim(),
                  email: _emailController.text.trim(),
                  password: _passwordController.text,
                )
              : await widget.appState.createWorkerAccount(
                  name: _nameController.text.trim(),
                  email: _emailController.text.trim(),
                  password: _passwordController.text,
                );
      if (!mounted) {
        return;
      }
      _nameController.clear();
      _emailController.clear();
      _passwordController.clear();
      _confirmController.clear();
      final String emailed = created.emailSent
          ? ' Verification code sent to their Gmail.'
          : '';
      setState(() => _success = '${created.message}$emailed');
      await _loadAccounts();
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'Unable to create the account.');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _setRole(DemoUser user, String role) async {
    if (user.email.trim().toLowerCase() == kSoleAdminEmail) {
      return;
    }
    setState(() => _busyEmail = user.email);
    try {
      final DemoUser updated = await widget.appState.updateFarmAccount(
        email: user.email,
        role: role,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _accounts = _accounts
            .map((DemoUser row) => row.email == updated.email ? updated : row)
            .toList();
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() => _busyEmail = null);
      }
    }
  }

  Future<void> _setDisabled(DemoUser user, bool disabled) async {
    if (user.email.trim().toLowerCase() == kSoleAdminEmail) {
      return;
    }
    setState(() => _busyEmail = user.email);
    try {
      final DemoUser updated = await widget.appState.updateFarmAccount(
        email: user.email,
        disabled: disabled,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _accounts = _accounts
            .map((DemoUser row) => row.email == updated.email ? updated : row)
            .toList();
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } finally {
      if (mounted) {
        setState(() => _busyEmail = null);
      }
    }
  }

  InputDecoration _decoration(String hint, {Widget? suffixIcon}) {
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xFF4A4038)),
    );
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFFB7AA9A), fontSize: 14),
      filled: true,
      fillColor: const Color(0xFF3A322B),
      suffixIcon: suffixIcon,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: _DashboardPalette.primary, width: 1.4),
      ),
    );
  }

  List<DemoUser> get _filteredAccounts {
    final String query = _searchController.text.trim().toLowerCase();
    return _accounts.where((DemoUser user) {
      if (_roleFilter == 'admin' && user.role != AppRole.admin) {
        return false;
      }
      if (_roleFilter == 'worker' && user.role != AppRole.worker) {
        return false;
      }
      if (_roleFilter == 'sales' && user.role != AppRole.sales) {
        return false;
      }
      if (_roleFilter == 'disabled' && !user.disabled) {
        return false;
      }
      if (query.isEmpty) {
        return true;
      }
      return user.name.toLowerCase().contains(query) ||
          user.email.toLowerCase().contains(query);
    }).toList();
  }

  String _roleLabel(AppRole role) {
    switch (role) {
      case AppRole.admin:
        return 'Admin';
      case AppRole.sales:
        return 'Seller';
      case AppRole.worker:
        return 'Worker';
    }
  }

  Color _roleColor(AppRole role) {
    switch (role) {
      case AppRole.admin:
        return _DashboardPalette.primary;
      case AppRole.sales:
        return _DashboardPalette.warning;
      case AppRole.worker:
        return const Color(0xFF8BB4E8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final int adminCount =
        _accounts.where((DemoUser u) => u.role == AppRole.admin).length;
    final int workerCount =
        _accounts.where((DemoUser u) => u.role == AppRole.worker).length;
    final int sellerCount =
        _accounts.where((DemoUser u) => u.role == AppRole.sales).length;
    final int disabledCount =
        _accounts.where((DemoUser u) => u.disabled).length;
    final List<DemoUser> visible = _filteredAccounts;

    return EggScaffold(
      appState: widget.appState,
      title: 'Account Management',
      selectedRoute: AppPaths.accounts,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'ACCOUNT MANAGEMENT',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.1,
                          ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Create staff, change roles, and disable access',
                      style: TextStyle(
                        color: _DashboardPalette.mutedForeground,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _loadAccounts,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(
                        Icons.refresh_rounded,
                        color: _DashboardPalette.mutedForeground,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _ProductionStatGrid(
            stats: <_ProductionStat>[
              _ProductionStat(
                icon: Icons.groups_outlined,
                iconColor: _DashboardPalette.primary,
                label: 'Total',
                value: '${_accounts.length}',
                suffix: 'accounts',
              ),
              _ProductionStat(
                icon: Icons.engineering_outlined,
                iconColor: const Color(0xFF8BB4E8),
                label: 'Workers',
                value: '$workerCount',
                suffix: 'floor',
              ),
              _ProductionStat(
                icon: Icons.storefront_outlined,
                iconColor: _DashboardPalette.warning,
                label: 'Sellers',
                value: '$sellerCount',
                suffix: 'sales',
              ),
              _ProductionStat(
                icon: Icons.person_off_outlined,
                iconColor: _DashboardPalette.danger,
                label: 'Disabled',
                value: '$disabledCount',
                suffix: 'locked',
              ),
              _ProductionStat(
                icon: Icons.shield_outlined,
                iconColor: _DashboardPalette.primary,
                label: 'Admin',
                value: '$adminCount',
                suffix: 'owner',
              ),
            ],
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool wide = constraints.maxWidth >= 980;
              final double listWidth =
                  wide ? constraints.maxWidth * 0.62 : constraints.maxWidth;
              final double formWidth = wide
                  ? constraints.maxWidth - listWidth - 16
                  : constraints.maxWidth;

              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: <Widget>[
                  SizedBox(
                    width: listWidth,
                    child: _GlassSection(
                      title: 'All accounts',
                      titleIcon: Icons.badge_outlined,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          TextField(
                            controller: _searchController,
                            onChanged: (_) => setState(() {}),
                            style: const TextStyle(
                              color: _DashboardPalette.foreground,
                            ),
                            decoration: _decoration(
                              'Search name or Gmail',
                              suffixIcon: const Icon(
                                Icons.search_rounded,
                                color: Color(0xFFB7AA9A),
                                size: 20,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              for (final MapEntry<String, String> entry
                                  in const <MapEntry<String, String>>[
                                MapEntry<String, String>('all', 'All'),
                                MapEntry<String, String>('admin', 'Admin'),
                                MapEntry<String, String>('worker', 'Worker'),
                                MapEntry<String, String>('sales', 'Seller'),
                                MapEntry<String, String>('disabled', 'Disabled'),
                              ])
                                _AccountFilterChip(
                                  label: entry.value,
                                  selected: _roleFilter == entry.key,
                                  onTap: () => setState(
                                    () => _roleFilter = entry.key,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          if (_listError != null)
                            Text(
                              _listError!,
                              style: const TextStyle(
                                color: _DashboardPalette.danger,
                                height: 1.35,
                              ),
                            )
                          else if (_loading)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 28),
                              child: Center(
                                child: CircularProgressIndicator(strokeWidth: 2.4),
                              ),
                            )
                          else if (visible.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 28),
                              child: Text(
                                'No accounts match this filter.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: _DashboardPalette.mutedForeground,
                                ),
                              ),
                            )
                          else
                            Column(
                              children: <Widget>[
                                for (int i = 0; i < visible.length; i++) ...<Widget>[
                                  _AccountManageRow(
                                    user: visible[i],
                                    roleLabel: _roleLabel(visible[i].role),
                                    roleColor: _roleColor(visible[i].role),
                                    busy: _busyEmail == visible[i].email,
                                    isLast: i == visible.length - 1,
                                    onRoleChanged: (String role) =>
                                        unawaited(_setRole(visible[i], role)),
                                    onDisabledChanged: (bool value) =>
                                        unawaited(
                                      _setDisabled(visible[i], value),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: formWidth,
                    child: Form(
                      key: _formKey,
                      child: _GlassSection(
                        title: 'Add staff',
                        titleIcon: Icons.person_add_alt_1_outlined,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            const Text(
                              'Invite a real Gmail. Worker uses production/QC; Seller uses the sales desk only.',
                              style: TextStyle(
                                color: _DashboardPalette.mutedForeground,
                                height: 1.4,
                                fontSize: 13.5,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: _AccountFilterChip(
                                    label: 'Worker',
                                    selected: !_salesAccount,
                                    expanded: true,
                                    onTap: () =>
                                        setState(() => _salesAccount = false),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: _AccountFilterChip(
                                    label: 'Seller',
                                    selected: _salesAccount,
                                    expanded: true,
                                    onTap: () =>
                                        setState(() => _salesAccount = true),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _nameController,
                              style: const TextStyle(
                                color: _DashboardPalette.foreground,
                              ),
                              decoration: _decoration('Full name'),
                              validator: (String? value) =>
                                  (value ?? '').trim().isEmpty
                                      ? 'Name is required'
                                      : null,
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              style: const TextStyle(
                                color: _DashboardPalette.foreground,
                              ),
                              decoration: _decoration('Gmail address'),
                              validator: (String? value) {
                                final String email =
                                    (value ?? '').trim().toLowerCase();
                                if (!AppState.isRealGmail(email)) {
                                  return 'Use a real @gmail.com address';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _passwordController,
                              obscureText: _obscurePassword,
                              style: const TextStyle(
                                color: _DashboardPalette.foreground,
                              ),
                              decoration: _decoration(
                                'Temporary password',
                                suffixIcon: IconButton(
                                  onPressed: () => setState(
                                    () => _obscurePassword = !_obscurePassword,
                                  ),
                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_outlined
                                        : Icons.visibility_off_outlined,
                                    color: const Color(0xFFB7AA9A),
                                  ),
                                ),
                              ),
                              validator: _validatePassword,
                            ),
                            const SizedBox(height: 10),
                            TextFormField(
                              controller: _confirmController,
                              obscureText: _obscurePassword,
                              style: const TextStyle(
                                color: _DashboardPalette.foreground,
                              ),
                              decoration: _decoration('Confirm password'),
                              validator: (String? value) {
                                if ((value ?? '') != _passwordController.text) {
                                  return 'Passwords do not match';
                                }
                                return null;
                              },
                            ),
                            if (_error != null) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: const TextStyle(
                                  color: _DashboardPalette.danger,
                                  height: 1.35,
                                ),
                              ),
                            ],
                            if (_success != null) ...<Widget>[
                              const SizedBox(height: 12),
                              Text(
                                _success!,
                                style: const TextStyle(
                                  color: _DashboardPalette.success,
                                  height: 1.35,
                                ),
                              ),
                            ],
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _saving ? null : _createAccount,
                              style: FilledButton.styleFrom(
                                backgroundColor: _DashboardPalette.primary,
                                foregroundColor: const Color(0xFF2A2118),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 15),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: _saving
                                  ? const SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                      ),
                                    )
                                  : Text(
                                      _salesAccount
                                          ? 'Create seller'
                                          : 'Create worker',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AccountFilterChip extends StatelessWidget {
  const _AccountFilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.expanded = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: expanded ? double.infinity : null,
        padding: EdgeInsets.symmetric(
          horizontal: expanded ? 12 : 14,
          vertical: 10,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? _DashboardPalette.primary.withValues(alpha: 0.16)
              : const Color(0xFF2A221C),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? _DashboardPalette.primary
                : const Color(0xFF4A4038),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? _DashboardPalette.primary
                : _DashboardPalette.foreground,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _AccountManageRow extends StatelessWidget {
  const _AccountManageRow({
    required this.user,
    required this.roleLabel,
    required this.roleColor,
    required this.busy,
    required this.isLast,
    required this.onRoleChanged,
    required this.onDisabledChanged,
  });

  final DemoUser user;
  final String roleLabel;
  final Color roleColor;
  final bool busy;
  final bool isLast;
  final ValueChanged<String> onRoleChanged;
  final ValueChanged<bool> onDisabledChanged;

  @override
  Widget build(BuildContext context) {
    final bool isSoleAdmin =
        user.email.trim().toLowerCase() == kSoleAdminEmail;
    final String initial = user.name.trim().isNotEmpty
        ? user.name.trim()[0].toUpperCase()
        : (user.email.isNotEmpty ? user.email[0].toUpperCase() : '?');
    final String roleValue =
        user.role == AppRole.sales ? 'sales' : 'worker';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0x334A4038)),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: roleColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: roleColor.withValues(alpha: 0.35)),
            ),
            child: Text(
              initial,
              style: TextStyle(
                color: roleColor,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  user.name.isEmpty ? user.email.split('@').first : user.name,
                  style: TextStyle(
                    color: user.disabled
                        ? _DashboardPalette.mutedForeground
                        : _DashboardPalette.foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    decoration:
                        user.disabled ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  user.email,
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  user.disabled
                      ? 'Disabled'
                      : (user.emailVerified ? 'Verified' : 'Pending verify'),
                  style: TextStyle(
                    color: user.disabled
                        ? _DashboardPalette.danger
                        : (user.emailVerified
                            ? _DashboardPalette.success
                            : _DashboardPalette.warning),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (isSoleAdmin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: roleColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                roleLabel,
                style: TextStyle(
                  color: roleColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            )
          else ...<Widget>[
            DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: roleValue,
                dropdownColor: const Color(0xFF2A221C),
                style: const TextStyle(
                  color: _DashboardPalette.foreground,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(
                    value: 'worker',
                    child: Text('Worker'),
                  ),
                  DropdownMenuItem<String>(
                    value: 'sales',
                    child: Text('Seller'),
                  ),
                ],
                onChanged: (String? value) {
                  if (value != null) {
                    onRoleChanged(value);
                  }
                },
              ),
            ),
            const SizedBox(width: 4),
            Switch.adaptive(
              value: !user.disabled,
              activeThumbColor: _DashboardPalette.success,
              onChanged: (bool enabled) => onDisabledChanged(!enabled),
            ),
          ],
        ],
      ),
    );
  }
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const int _minPasswordLength = 8;

  final TextEditingController _currentPasswordController =
      TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  Map<String, String> _errors = <String, String>{};
  bool _saving = false;
  bool _showCurrentPassword = false;
  bool _showPassword = false;
  bool _showConfirmPassword = false;

  @override
  void dispose() {
    _currentPasswordController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submitPasswordChange() async {
    final Map<String, String> errors = <String, String>{};
    final String current = _currentPasswordController.text;
    final String password = _passwordController.text;
    final String confirm = _confirmPasswordController.text;

    if (current.isEmpty) {
      errors['current'] = 'Current password is required';
    }
    if (password.length < _minPasswordLength) {
      errors['password'] =
          'Password must be at least $_minPasswordLength characters';
    } else if (!RegExp(r'[A-Za-z]').hasMatch(password) ||
        !RegExp(r'\d').hasMatch(password)) {
      errors['password'] = 'Include a letter and a number';
    }
    if (confirm != password) {
      errors['confirm'] = 'Passwords do not match';
    }

    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }

    setState(() {
      _saving = true;
      _errors = <String, String>{};
    });

    try {
      await widget.appState.changePassword(
        currentPassword: current,
        newPassword: password,
      );
      if (!mounted) {
        return;
      }
      _currentPasswordController.clear();
      _passwordController.clear();
      _confirmPasswordController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated')),
      );
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _errors = <String, String>{'current': error.message});
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(
        () => _errors = <String, String>{
          'current': 'Unable to reach the authentication server.',
        },
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _signOut() {
    widget.appState.signOut();
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil(AppPaths.auth, (Route<dynamic> route) => false);
  }

  String _roleTitle() {
    if (widget.appState.isAdmin) {
      return 'Admin';
    }
    if (widget.appState.isSales) {
      return 'Seller';
    }
    return 'Worker';
  }

  @override
  Widget build(BuildContext context) {
    final DemoUser user = widget.appState.currentUser!;
    final String initial = user.name.trim().isNotEmpty
        ? user.name.trim()[0].toUpperCase()
        : (user.email.isNotEmpty ? user.email[0].toUpperCase() : '?');

    return EggScaffold(
      appState: widget.appState,
      title: 'Profile',
      selectedRoute: AppPaths.profile,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'PROFILE',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: _DashboardPalette.foreground,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Your personal information for this farm account',
            style: TextStyle(
              color: _DashboardPalette.mutedForeground,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Personal information',
            titleIcon: Icons.person_outline_rounded,
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _DashboardPalette.primary.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: _DashboardPalette.primary.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: _DashboardPalette.primary,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            user.name.isEmpty
                                ? user.email.split('@').first
                                : user.name,
                            style: const TextStyle(
                              color: _DashboardPalette.foreground,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            user.email,
                            style: const TextStyle(
                              color: _DashboardPalette.mutedForeground,
                              fontSize: 13.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _ProfileBadge(
                                label: _roleTitle(),
                                color: _DashboardPalette.primary,
                              ),
                              _ProfileBadge(
                                label: user.emailVerified
                                    ? 'Verified'
                                    : 'Unverified',
                                color: user.emailVerified
                                    ? _DashboardPalette.success
                                    : _DashboardPalette.warning,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(color: Color(0x334A4038), height: 28),
                _ProfileInfoRow(
                  icon: Icons.badge_outlined,
                  label: 'Full name',
                  value: user.name.isEmpty ? '—' : user.name,
                ),
                _ProfileInfoRow(
                  icon: Icons.mail_outline_rounded,
                  label: 'Gmail',
                  value: user.email,
                ),
                _ProfileInfoRow(
                  icon: Icons.shield_outlined,
                  label: 'Assigned role',
                  value: _roleTitle(),
                  isLast: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Security',
            titleIcon: Icons.lock_outline_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Update the password for your own Gmail login. Other sessions will be signed out.',
                  style: TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    height: 1.45,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 16),
                _ProductionField(
                  label: 'Current password',
                  errorText: _errors['current'],
                  child: _ProductionTextField(
                    controller: _currentPasswordController,
                    hintText: 'Enter current password',
                    obscureText: !_showCurrentPassword,
                    suffixIcon: IconButton(
                      onPressed: () {
                        setState(
                          () => _showCurrentPassword = !_showCurrentPassword,
                        );
                      },
                      icon: Icon(
                        _showCurrentPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: _DashboardPalette.mutedForeground,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool medium = constraints.maxWidth >= 700;
                    final double width = medium
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        SizedBox(
                          width: width,
                          child: _ProductionField(
                            label: 'New password',
                            errorText: _errors['password'],
                            child: _ProductionTextField(
                              controller: _passwordController,
                              hintText: 'At least $_minPasswordLength characters',
                              obscureText: !_showPassword,
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(() => _showPassword = !_showPassword);
                                },
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: _DashboardPalette.mutedForeground,
                                ),
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: width,
                          child: _ProductionField(
                            label: 'Confirm password',
                            errorText: _errors['confirm'],
                            child: _ProductionTextField(
                              controller: _confirmPasswordController,
                              hintText: 'Repeat new password',
                              obscureText: !_showConfirmPassword,
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(
                                    () => _showConfirmPassword =
                                        !_showConfirmPassword,
                                  );
                                },
                                icon: Icon(
                                  _showConfirmPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: _DashboardPalette.mutedForeground,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : _submitPasswordChange,
                  style: FilledButton.styleFrom(
                    backgroundColor: _DashboardPalette.primary,
                    foregroundColor: _DashboardPalette.primaryForeground,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _DashboardPalette.primaryForeground,
                          ),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('Update password'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: _DashboardPalette.danger.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _DashboardPalette.danger.withValues(alpha: 0.28),
              ),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _DashboardPalette.danger.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.logout_rounded,
                    color: _DashboardPalette.danger,
                  ),
                ),
                const SizedBox(width: 14),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Sign out',
                        style: TextStyle(
                          color: _DashboardPalette.foreground,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'End this session on this device.',
                        style: TextStyle(
                          color: _DashboardPalette.mutedForeground,
                          height: 1.35,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _signOut,
                  style: FilledButton.styleFrom(
                    backgroundColor: _DashboardPalette.danger,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text('Logout'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileBadge extends StatelessWidget {
  const _ProfileBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11.5,
        ),
      ),
    );
  }
}

class _ProfileInfoRow extends StatelessWidget {
  const _ProfileInfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : const Border(
                bottom: BorderSide(color: _DashboardPalette.glassBorder),
              ),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: _DashboardPalette.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: _DashboardPalette.mutedForeground),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: _DashboardPalette.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.selectedRoute, required this.appState});

  final String selectedRoute;
  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final List<_NavItem> navItems = appState.isSales
        ? <_NavItem>[
            const _NavItem(
              label: 'Egg Sales',
              route: AppPaths.sales,
              icon: Icons.shopping_cart_outlined,
            ),
            const _NavItem(
              label: 'Reports',
              route: AppPaths.reports,
              icon: Icons.assessment_outlined,
            ),
          ]
        : <_NavItem>[
      const _NavItem(
        label: 'Dashboard',
        route: AppPaths.dashboard,
        icon: Icons.dashboard_outlined,
      ),
      const _NavItem(
        label: 'Production',
        route: AppPaths.production,
        icon: Icons.egg_alt_outlined,
      ),
      const _NavItem(
        label: 'Quality Control',
        route: AppPaths.grading,
        icon: Icons.shield_outlined,
      ),
      if (appState.isAdmin)
        const _NavItem(
          label: 'Inventory',
          route: AppPaths.inventory,
          icon: Icons.inventory_2_outlined,
        ),
      if (appState.isAdmin)
        const _NavItem(
          label: 'Reports',
          route: AppPaths.reports,
          icon: Icons.assessment_outlined,
        ),
    ];

    return Container(
      width: 250,
      color: const Color(0xFF130F0D),
      child: SafeArea(
        right: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(
                      'assets/app-icon.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'EGG SORTING',
                          style: TextStyle(
                            color: _DashboardPalette.primary,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          'IOT SYSTEM',
                          style: TextStyle(
                            color: _DashboardPalette.mutedForeground,
                            fontWeight: FontWeight.w700,
                            fontSize: 10,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
              const Text(
                'MODULES',
                style: TextStyle(
                  color: Color(0xFF8C7E72),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    ...navItems.map(
                      (_NavItem item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _SidebarTile(
                          item: item,
                          selected: item.route == selectedRoute,
                          onTap: () {
                            if (item.route != selectedRoute) {
                              Navigator.of(
                                context,
                              ).pushReplacementNamed(item.route);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _SidebarTile(
                      item: _NavItem(
                        label: 'Notifications',
                        route: 'notifications',
                        icon: appState.workerUnreadCount > 0
                            ? Icons.notifications_active_outlined
                            : Icons.notifications_none_outlined,
                      ),
                      selected: false,
                      onTap: () => _showNotificationPanel(context, appState),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'ACCOUNT',
                      style: TextStyle(
                        color: Color(0xFF8C7E72),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _SidebarTile(
                      item: const _NavItem(
                        label: 'Profile',
                        route: AppPaths.profile,
                        icon: Icons.person_outline,
                      ),
                      selected: selectedRoute == AppPaths.profile,
                      onTap: () {
                        if (selectedRoute != AppPaths.profile) {
                          Navigator.of(
                            context,
                          ).pushReplacementNamed(AppPaths.profile);
                        }
                      },
                    ),
                    if (appState.isAdmin) ...<Widget>[
                      const SizedBox(height: 8),
                      _SidebarTile(
                        item: const _NavItem(
                          label: 'Account Management',
                          route: AppPaths.accounts,
                          icon: Icons.manage_accounts_outlined,
                        ),
                        selected: selectedRoute == AppPaths.accounts,
                        onTap: () {
                          if (selectedRoute != AppPaths.accounts) {
                            Navigator.of(
                              context,
                            ).pushReplacementNamed(AppPaths.accounts);
                          }
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const Text(
                'v1.0 - IoT Egg Monitor',
                style: TextStyle(color: Color(0xFF63564B), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showNotificationPanel(BuildContext context, AppState appState) {
  appState.refreshOperationalNotifications();
  final bool wide = MediaQuery.sizeOf(context).width >= 700;
  final Widget panel = AnimatedBuilder(
    animation: appState,
    builder: (BuildContext context, Widget? child) {
      final List<WorkerNotification> notes = appState.workerNotifications;
      final Widget list = notes.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No notifications yet. Live farm status will appear here.',
                style: TextStyle(color: _DashboardPalette.mutedForeground),
              ),
            )
          : ListView.separated(
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              itemCount: notes.length,
              separatorBuilder: (BuildContext context, int index) =>
                  const SizedBox(height: 8),
              itemBuilder: (BuildContext context, int index) {
                final WorkerNotification note = notes[index];
                return _WorkerNotificationTile(
                  notification: note,
                  onTap: note.read
                      ? null
                      : () => appState.markNotificationRead(note.id),
                );
              },
            );
      final List<Widget> actions = <Widget>[
        if (appState.workerUnreadCount > 0)
          TextButton(
            onPressed: appState.markAllNotificationsRead,
            child: const Text('Mark all read'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ];
      if (wide) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1C1612),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: <Widget>[
              const Expanded(
                child: Text(
                  'Notifications',
                  style: TextStyle(color: _DashboardPalette.foreground),
                ),
              ),
              if (appState.workerUnreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _DashboardPalette.warning.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${appState.workerUnreadCount} new',
                    style: const TextStyle(
                      color: _DashboardPalette.warning,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          content: SizedBox(width: 420, height: 360, child: list),
          actions: actions,
        );
      }
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: _DashboardPalette.mutedForeground.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Notifications',
                      style: TextStyle(
                        color: _DashboardPalette.foreground,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  ...actions,
                ],
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.55,
                ),
                child: list,
              ),
            ],
          ),
        ),
      );
    },
  );

  if (wide) {
    showDialog<void>(context: context, builder: (_) => panel);
  } else {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1612),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => panel,
    );
  }
}

Widget _notificationBellButton(BuildContext context, AppState appState) {
  final int unread = appState.workerUnreadCount;
  return IconButton(
    tooltip: 'Notifications',
    onPressed: () => _showNotificationPanel(context, appState),
    style: IconButton.styleFrom(
      backgroundColor: _DashboardPalette.tabBackground,
    ),
    icon: Badge(
      isLabelVisible: unread > 0,
      label: Text(
        unread > 9 ? '9+' : '$unread',
        style: const TextStyle(fontSize: 9),
      ),
      backgroundColor: _DashboardPalette.warning,
      child: Icon(
        unread > 0
            ? Icons.notifications_active_outlined
            : Icons.notifications_none_outlined,
        color: _DashboardPalette.foreground,
      ),
    ),
  );
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2A211B) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(0xFFEFB73E).withValues(alpha: 0.45)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: 3,
              height: 22,
              decoration: BoxDecoration(
                color: selected ? _DashboardPalette.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              item.icon,
              color: selected
                  ? _DashboardPalette.primary
                  : _DashboardPalette.mutedForeground,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  color: selected
                      ? _DashboardPalette.foreground
                      : _DashboardPalette.mutedForeground,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final bool online = appState.backendReachable;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: online
            ? const Color(0x332E7D4F)
            : const Color(0x33E4A11B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: online
              ? const Color(0x663DBA6A)
              : const Color(0x66E4A11B),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 18,
            color: online
                ? const Color(0xFF3DBA6A)
                : _DashboardPalette.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              online
                  ? (appState.farmSyncPending
                      ? 'Online — saving to the farm database…'
                      : 'Online — farm data is saved on this device and in the database')
                  : 'Offline mode — all entries stay saved on this device and upload when signal returns',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _DashboardPalette.foreground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EggScaffold extends StatefulWidget {
  const EggScaffold({
    super.key,
    required this.appState,
    required this.title,
    required this.selectedRoute,
    required this.body,
    this.useLoginBackground = false,
  });

  final AppState appState;
  final String title;
  final String selectedRoute;
  final Widget body;
  final bool useLoginBackground;

  @override
  State<EggScaffold> createState() => _EggScaffoldState();
}

class _EggScaffoldState extends State<EggScaffold> {
  @override
  void initState() {
    super.initState();
    widget.appState.addListener(_onAppState);
  }

  @override
  void didUpdateWidget(EggScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.appState != widget.appState) {
      oldWidget.appState.removeListener(_onAppState);
      widget.appState.addListener(_onAppState);
    }
  }

  @override
  void dispose() {
    widget.appState.removeListener(_onAppState);
    super.dispose();
  }

  void _onAppState() {
    if (mounted) {
      setState(() {});
    }
  }

  // Mobile bottom-nav — workers and admins (drawer still has full list).
  static const List<_NavItem> _workerBottomItems = <_NavItem>[
    _NavItem(
      label: 'Home',
      route: AppPaths.dashboard,
      icon: Icons.dashboard_outlined,
    ),
    _NavItem(
      label: 'Production',
      route: AppPaths.production,
      icon: Icons.egg_alt_outlined,
    ),
    _NavItem(
      label: 'QC',
      route: AppPaths.grading,
      icon: Icons.fact_check_outlined,
    ),
    _NavItem(
      label: 'Profile',
      route: AppPaths.profile,
      icon: Icons.person_outline,
    ),
  ];

  static const List<_NavItem> _adminBottomItems = <_NavItem>[
    _NavItem(
      label: 'Home',
      route: AppPaths.dashboard,
      icon: Icons.dashboard_outlined,
    ),
    _NavItem(
      label: 'Production',
      route: AppPaths.production,
      icon: Icons.egg_alt_outlined,
    ),
    _NavItem(
      label: 'QC',
      route: AppPaths.grading,
      icon: Icons.fact_check_outlined,
    ),
    _NavItem(
      label: 'Inventory',
      route: AppPaths.inventory,
      icon: Icons.inventory_2_outlined,
    ),
    _NavItem(
      label: 'Reports',
      route: AppPaths.reports,
      icon: Icons.assessment_outlined,
    ),
  ];

  static const List<_NavItem> _salesBottomItems = <_NavItem>[
    _NavItem(
      label: 'Sales',
      route: AppPaths.sales,
      icon: Icons.shopping_cart_outlined,
    ),
    _NavItem(
      label: 'Reports',
      route: AppPaths.reports,
      icon: Icons.assessment_outlined,
    ),
    _NavItem(
      label: 'Profile',
      route: AppPaths.profile,
      icon: Icons.person_outline,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final AppState appState = widget.appState;
    final String selectedRoute = widget.selectedRoute;
    final String title = widget.title;
    final Widget body = widget.body;
    final DemoUser? user = appState.currentUser;
    final String dateLabel = _formatDashboardDate();
    final bool wide = MediaQuery.sizeOf(context).width >= 840;

    final List<_NavItem> navItems = appState.isSales
        ? <_NavItem>[
            const _NavItem(
              label: 'Egg Sales',
              route: AppPaths.sales,
              icon: Icons.shopping_cart_outlined,
            ),
            const _NavItem(
              label: 'Reports',
              route: AppPaths.reports,
              icon: Icons.assessment_outlined,
            ),
            const _NavItem(
              label: 'Profile',
              route: AppPaths.profile,
              icon: Icons.person_outline,
            ),
          ]
        : <_NavItem>[
      const _NavItem(
        label: 'Dashboard',
        route: AppPaths.dashboard,
        icon: Icons.dashboard_outlined,
      ),
      const _NavItem(
        label: 'Production',
        route: AppPaths.production,
        icon: Icons.egg_alt_outlined,
      ),
      const _NavItem(
        label: 'Quality Control',
        route: AppPaths.grading,
        icon: Icons.fact_check_outlined,
      ),
      if (appState.isAdmin)
        const _NavItem(
          label: 'Inventory',
          route: AppPaths.inventory,
          icon: Icons.inventory_2_outlined,
        ),
      if (appState.isAdmin)
        const _NavItem(
          label: 'Reports',
          route: AppPaths.reports,
          icon: Icons.assessment_outlined,
        ),
      const _NavItem(
        label: 'Profile',
        route: AppPaths.profile,
        icon: Icons.person_outline,
      ),
    ];

    Widget header = Row(
      children: <Widget>[
        if (!wide) ...<Widget>[
          Builder(
            builder: (BuildContext context) {
              return IconButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: const Icon(
                  Icons.menu_rounded,
                  color: _DashboardPalette.foreground,
                ),
                style: IconButton.styleFrom(
                  backgroundColor: _DashboardPalette.tabBackground,
                ),
              );
            },
          ),
          const SizedBox(width: 12),
        ] else ...<Widget>[
          const Icon(
            Icons.developer_board,
            color: _DashboardPalette.primary,
            size: 22,
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                (appState.isSales
                    ? 'EGG MONITORING SYSTEM'
                    : (selectedRoute == AppPaths.dashboard && wide)
                    ? 'Farm dashboard'
                    : title.toUpperCase()),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _DashboardPalette.foreground,
                  fontSize: wide ? 18 : 15,
                  fontWeight: FontWeight.w800,
                  letterSpacing: wide ? 1.4 : 0.6,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                dateLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _DashboardPalette.mutedForeground,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _notificationBellButton(context, appState),
      ],
    );

    Widget content = Column(
      children: <Widget>[
        if (wide)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
            child: header,
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: _DashboardPalette.glassBackground,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: _DashboardPalette.glassBorder),
                  ),
                  child: header,
                ),
            ),
          ),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1360),
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  wide ? 24 : 16,
                  14,
                  wide ? 24 : 16,
                  24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (!wide && !appState.backendReachable) ...<Widget>[
                      _ConnectionBanner(appState: appState),
                      const SizedBox(height: 12),
                    ],
                    body,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    final List<_NavItem> bottomItems = appState.isSales
        ? _salesBottomItems
        : (appState.isAdmin ? _adminBottomItems : _workerBottomItems);
    // Phone / narrow tablet: always show bottom nav so modules stay one tap away.
    final bool showBottomNav = !wide;
    final int bottomIndex = showBottomNav
        ? bottomItems
              .indexWhere((item) => item.route == selectedRoute)
              .clamp(0, bottomItems.length - 1)
        : 0;

    return Scaffold(
      backgroundColor: widget.useLoginBackground
          ? const Color(0xFF1A120C)
          : const Color(0xFF100C0A),
      bottomNavigationBar: showBottomNav
          ? Theme(
              data: Theme.of(context).copyWith(
                splashColor: Colors.transparent,
                highlightColor: Colors.transparent,
              ),
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF16110F),
                  border: Border(top: BorderSide(color: Color(0xFF332A24))),
                ),
                child: BottomNavigationBar(
                  currentIndex: bottomIndex,
                  onTap: (int i) {
                    final String route = bottomItems[i].route;
                    if (route != selectedRoute) {
                      Navigator.of(context).pushReplacementNamed(route);
                    }
                  },
                  type: BottomNavigationBarType.fixed,
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  selectedItemColor: _DashboardPalette.primary,
                  unselectedItemColor: _DashboardPalette.mutedForeground,
                  selectedLabelStyle: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedLabelStyle: const TextStyle(fontSize: 10),
                  items: bottomItems
                      .map(
                        (_NavItem item) => BottomNavigationBarItem(
                          icon: _buildNavIcon(
                            item,
                            item.route == selectedRoute,
                            appState,
                          ),
                          label: item.label,
                        ),
                      )
                      .toList(),
                ),
              ),
            )
          : null,
      drawer: wide
          ? null
          : Drawer(
              backgroundColor: const Color(0xFF211914),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: _DashboardPalette.glassBackground,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                color: _DashboardPalette.glassBorder,
                              ),
                            ),
                            child: Row(
                              children: <Widget>[
                                Container(
                                  width: 54,
                                  height: 54,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: Image.asset(
                                    'assets/app-icon.png',
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        user?.name ?? 'Guest',
                                        style: const TextStyle(
                                          color: _DashboardPalette.foreground,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        user?.email ?? 'Not signed in',
                                        style: const TextStyle(
                                          color:
                                              _DashboardPalette.mutedForeground,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'NAVIGATION',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _DashboardPalette.mutedForeground,
                          letterSpacing: 1.6,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView(
                          children: <Widget>[
                            ...navItems.map(
                              (_NavItem item) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _DrawerNavTile(
                                  item: item,
                                  selected: item.route == selectedRoute,
                                  onTap: () {
                                    Navigator.of(context).pop();
                                    if (item.route != selectedRoute) {
                                      Navigator.of(
                                        context,
                                      ).pushReplacementNamed(item.route);
                                    }
                                  },
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _DrawerNavTile(
                                item: _NavItem(
                                  label: 'Notifications',
                                  route: 'notifications',
                                  icon: appState.workerUnreadCount > 0
                                      ? Icons.notifications_active_outlined
                                      : Icons.notifications_none_outlined,
                                ),
                                selected: false,
                                onTap: () {
                                  final NavigatorState rootNav =
                                      Navigator.of(context, rootNavigator: true);
                                  Navigator.of(context).pop();
                                  WidgetsBinding.instance.addPostFrameCallback((_) {
                                    final BuildContext panelContext =
                                        rootNav.context;
                                    if (panelContext.mounted) {
                                      _showNotificationPanel(
                                        panelContext,
                                        appState,
                                      );
                                    }
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          appState.signOut();
                          Navigator.of(context).pushNamedAndRemoveUntil(
                            AppPaths.auth,
                            (Route<dynamic> route) => false,
                          );
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: _DashboardPalette.tabBackground,
                          foregroundColor: _DashboardPalette.foreground,
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        icon: const Icon(Icons.logout),
                        label: const Text('Sign Out'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
      body: Stack(
        children: <Widget>[
          if (widget.useLoginBackground) ...<Widget>[
            const Positioned.fill(
              child: ColoredBox(color: Color(0xFF1A120C)),
            ),
            Positioned.fill(
              child: Image.asset(
                'assets/egg-factory-bg.jpg',
                fit: BoxFit.cover,
              ),
            ),
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0xCC3A2A12),
                      Color(0xB31A120C),
                      Color(0xE6140E0A),
                    ],
                  ),
                ),
              ),
            ),
          ] else ...<Widget>[
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0xFF140F0C),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      _DashboardPalette.overlayTop,
                      _DashboardPalette.overlayBottom,
                    ],
                  ),
                ),
              ),
            ),
          ],
          SafeArea(
            child: wide
                ? Row(
                    children: <Widget>[
                      _Sidebar(
                        selectedRoute: selectedRoute,
                        appState: appState,
                      ),
                      Expanded(child: content),
                    ],
                  )
                : content,
          ),
        ],
      ),
    );
  }

  /// Build a badge-aware icon for the bottom nav bar.
  Widget _buildNavIcon(_NavItem item, bool selected, AppState appState) {
    Widget icon = Icon(item.icon);
    // Badge unread farm alerts on Home.
    if (item.route == AppPaths.dashboard && appState.workerUnreadCount > 0) {
      icon = Badge(
        label: Text(
          appState.workerUnreadCount.toString(),
          style: const TextStyle(fontSize: 9),
        ),
        backgroundColor: _DashboardPalette.warning,
        child: icon,
      );
    }
    return icon;
  }
}

class _StatusScaffold extends StatelessWidget {
  const _StatusScaffold({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const CircularProgressIndicator(),
                const SizedBox(height: 20),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 20),
                FilledButton(onPressed: onPressed, child: Text(actionLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        color: _DashboardPalette.foreground,
        fontWeight: FontWeight.w800,
        letterSpacing: 1,
      ),
    );
  }
}

class _DashboardStatGrid extends StatelessWidget {
  const _DashboardStatGrid({required this.stats});

  final List<_DashboardStat> stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool large = constraints.maxWidth >= 1080;
        final bool medium = constraints.maxWidth >= 700;
        final int columns = !medium
            ? 1
            : (stats.length == 4 && constraints.maxWidth >= 780)
            ? 4
            : large
            ? 4
            : 2;
        final double width = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - 12 * (columns - 1)) / columns;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: stats
              .map(
                (_DashboardStat stat) => SizedBox(
                  width: width,
                  child: _DashboardStatCard(stat: stat),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _DashboardStatCard extends StatelessWidget {
  const _DashboardStatCard({required this.stat});

  final _DashboardStat stat;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1C1613),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: stat.onTap ??
            () => Navigator.of(context).pushReplacementNamed(stat.route),
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: stat.selected ? stat.accent : const Color(0xFF3A302A),
              width: stat.selected ? 1.6 : 1,
            ),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: stat.accent,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      bottomLeft: Radius.circular(16),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: stat.accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Icon(
                                stat.icon,
                                color: stat.accent,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                stat.label,
                                style: const TextStyle(
                                  color: Color(0xFFD4B48A),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          stat.value,
                          style: TextStyle(
                            color: stat.accent,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            height: 1.05,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          stat.unit,
                          style: const TextStyle(
                            color: _DashboardPalette.mutedForeground,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickLinkGrid extends StatelessWidget {
  const _QuickLinkGrid({required this.items});

  final List<_QuickLinkItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool large = constraints.maxWidth >= 960;
        final bool medium = constraints.maxWidth >= 620;
        final double width = large
            ? (constraints.maxWidth - (10 * (items.length - 1))) / items.length
            : medium
            ? (constraints.maxWidth - 10) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: items
              .map(
                (_QuickLinkItem item) => SizedBox(
                  width: width,
                  child: Material(
                    color: const Color(0xFF1C1613),
                    borderRadius: BorderRadius.circular(14),
                    child: InkWell(
                      onTap: () =>
                          Navigator.of(context).pushReplacementNamed(item.route),
                      borderRadius: BorderRadius.circular(14),
                      child: Ink(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF3A302A)),
                        ),
                        child: Column(
                          children: <Widget>[
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: _DashboardPalette.primary
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                item.icon,
                                color: _DashboardPalette.primary,
                                size: 20,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              item.label,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: _DashboardPalette.foreground,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _DashboardHeading extends StatelessWidget {
  const _DashboardHeading(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: const TextStyle(
          color: _DashboardPalette.mutedForeground,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _EggAnalyticsBoard extends StatelessWidget {
  const _EggAnalyticsBoard({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final int good = appState.liveGoodEggs;
    final int cracked = appState.liveCrackedEggs;
    final int inspected = good + cracked;
    final int produced = appState.productionRecords.fold<int>(
      0,
      (int sum, ProductionRecord record) => sum + record.count,
    );
    final bool hasRecords = inspected > 0 ||
        produced > 0 ||
        appState.iotReadings.isNotEmpty ||
        appState.detectionRecords.isNotEmpty;
    if (!hasRecords) {
      return const _GlassSection(
        title: 'Egg analytics',
        child: Text(
          'No egg records yet. Counts, grade mix, and production will appear here after the first egg is inspected or logged.',
          style: TextStyle(
            color: _DashboardPalette.mutedForeground,
            height: 1.4,
          ),
        ),
      );
    }

    final int base = inspected == 0 ? 1 : inspected;
    final int goodPercent = ((good / base) * 100).round();
    final List<IotEggReading> latest = appState.iotReadings.take(4).toList();
    final Map<String, int> byDate = <String, int>{};
    for (final ProductionRecord record in appState.productionRecords) {
      byDate[record.date] = (byDate[record.date] ?? 0) + record.count;
    }
    final List<String> dates = byDate.keys.toList()..sort();
    final List<String> recentDates = dates.length <= 6
        ? dates
        : dates.sublist(dates.length - 6);

    return _GlassSection(
      title: 'Egg analytics',
      titleIcon: Icons.insights_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              _AnalyticsPill(label: 'Inspected', value: '$inspected'),
              _AnalyticsPill(label: 'Good', value: '$goodPercent%'),
              _AnalyticsPill(label: 'Logged production', value: '$produced'),
            ],
          ),
          const SizedBox(height: 14),
          _GradeBar(label: 'Good', count: good, total: base, color: _DashboardPalette.success),
          const SizedBox(height: 8),
          _GradeBar(label: 'Cracked', count: cracked, total: base, color: _DashboardPalette.primary),
          if (recentDates.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            const Text(
              'Production by day',
              style: TextStyle(
                color: _DashboardPalette.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            _SimpleLineChart(
              data: recentDates
                  .map(
                    (String date) => _SeriesPoint(
                      date.length > 5 ? date.substring(5) : date,
                      (byDate[date] ?? 0).toDouble(),
                    ),
                  )
                  .toList(),
            ),
          ],
          if (latest.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            const Text(
              'Latest egg records',
              style: TextStyle(
                color: _DashboardPalette.foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ...latest.map(
              (IotEggReading reading) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${reading.displayGrade} · ${reading.sizeClass.isEmpty ? 'size n/a' : reading.sizeClass} · ${reading.weightGrams.toStringAsFixed(1)} g',
                  style: const TextStyle(color: _DashboardPalette.mutedForeground),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AnalyticsPill extends StatelessWidget {
  const _AnalyticsPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _DashboardPalette.tabBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _DashboardPalette.glassBorder),
      ),
      child: Text(
        '$label  $value',
        style: const TextStyle(
          color: _DashboardPalette.foreground,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _GradeBar extends StatelessWidget {
  const _GradeBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  final String label;
  final int count;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final double share = total == 0 ? 0 : count / total;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
        Expanded(child: _GradientProgressBar(value: share)),
        const SizedBox(width: 10),
        SizedBox(
          width: 64,
          child: Text(
            '$count  ${(share * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: _DashboardPalette.foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

DateTime _dashboardDay(DateTime value) {
  final DateTime local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

String _dashboardIsoDate(DateTime date) {
  final String month = date.month.toString().padLeft(2, '0');
  final String day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

int _productionBetween(AppState appState, DateTime start, DateTime end) {
  final String from = _dashboardIsoDate(start);
  final String to = _dashboardIsoDate(end);
  return appState.productionRecords
      .where(
        (ProductionRecord record) =>
            record.date.compareTo(from) >= 0 && record.date.compareTo(to) <= 0,
      )
      .fold<int>(0, (int sum, ProductionRecord record) => sum + record.count);
}

class _PeriodGradeCounts {
  const _PeriodGradeCounts({
    required this.good,
    required this.cracked,
    required this.produced,
  });

  final int good;
  final int cracked;
  final int produced;

  int get inspected => good + cracked;
}

_PeriodGradeCounts _gradesBetween(
  AppState appState,
  DateTime start,
  DateTime end, {
  required bool useLiveFallback,
}) {
  int good = 0;
  int cracked = 0;
  // 1) Live Egg Records board (camera Clean/Crack) — primary for the week chart.
  for (final DetectionRecord record in appState.detectionRecords) {
    final DateTime? parsed = DateTime.tryParse(record.timestamp);
    if (parsed == null) {
      continue;
    }
    final DateTime day = _dashboardDay(parsed);
    if (day.isBefore(start) || day.isAfter(end)) {
      continue;
    }
    final String cat = record.category.toLowerCase();
    final String lab = record.label.toLowerCase();
    if (cat == 'crackedeggs' ||
        (lab.contains('crack') && !lab.contains('no crack'))) {
      cracked += 1;
    } else {
      good += 1;
    }
  }
  // 2) Firestore IoT readings (if any).
  for (final IotEggReading reading in appState.iotReadings) {
    final DateTime day = _dashboardDay(reading.createdAt);
    if (day.isBefore(start) || day.isAfter(end)) {
      continue;
    }
    final String grade = reading.displayGrade.toLowerCase();
    if (grade.contains('crack')) {
      cracked += 1;
    } else if (grade.contains('good') ||
        grade.contains('dirt') ||
        grade.contains('clean')) {
      good += 1;
    }
  }
  // 3) Live counters as floor for "today" when board/IoT briefly lag.
  if (useLiveFallback) {
    if (appState.liveGoodEggs > good) {
      good = appState.liveGoodEggs;
    }
    if (appState.liveCrackedEggs > cracked) {
      cracked = appState.liveCrackedEggs;
    }
  }
  final int produced = _productionBetween(appState, start, end);
  final int inspected = good + cracked;
  return _PeriodGradeCounts(
    good: good,
    cracked: cracked,
    produced: inspected > produced ? inspected : produced,
  );
}

const List<String> _weekDayLabels = <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

DateTime _weekStart(DateTime day) {
  final DateTime date = _dashboardDay(day);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}

int _eggsOnDay(AppState appState, DateTime day) {
  final DateTime date = _dashboardDay(day);
  final int produced = _productionBetween(appState, date, date);
  int detected = 0;
  for (final DetectionRecord record in appState.detectionRecords) {
    final DateTime? parsed = DateTime.tryParse(record.timestamp);
    if (parsed != null && _dashboardDay(parsed) == date) {
      detected += 1;
    }
  }
  int iot = 0;
  for (final IotEggReading reading in appState.iotReadings) {
    if (_dashboardDay(reading.createdAt) == date) {
      iot += 1;
    }
  }
  int live = 0;
  if (date == _dashboardDay(DateTime.now())) {
    live = appState.liveGoodEggs + appState.liveCrackedEggs;
  }
  int best = produced;
  if (detected > best) {
    best = detected;
  }
  if (iot > best) {
    best = iot;
  }
  if (live > best) {
    best = live;
  }
  return best;
}

class _DayHarvest {
  const _DayHarvest({
    required this.harvested,
    required this.good,
    required this.crack,
    required this.rejected,
  });

  final int harvested;
  final int good;
  final int crack;
  final int rejected;
}

void _countGrade(String raw, int qty, List<int> counts) {
  final String grade = raw.toLowerCase();
  final int amount = qty <= 0 ? 1 : qty;
  if (grade.contains('crack')) {
    counts[1] += amount;
  } else if (grade.contains('good') ||
      grade.contains('clean') ||
      grade.contains('dirt') ||
      grade.contains('reject')) {
    // Dirty/dust is not a system grade — count as Good.
    counts[0] += amount;
  }
}

_DayHarvest _harvestOnDay(AppState appState, DateTime day) {
  final DateTime date = _dashboardDay(day);
  final String iso = _dashboardIsoDate(date);
  final List<List<int>> sources = <List<int>>[];

  final List<int> graded = <int>[0, 0, 0];
  for (final GradingRecord record in appState.gradingRecords) {
    if (record.date != iso) {
      continue;
    }
    _countGrade(record.quality, record.quantity, graded);
  }
  sources.add(graded);

  final List<int> detected = <int>[0, 0, 0];
  for (final DetectionRecord record in appState.detectionRecords) {
    final DateTime? parsed = DateTime.tryParse(record.timestamp);
    if (parsed == null || _dashboardDay(parsed) != date) {
      continue;
    }
    _countGrade('${record.label} ${record.category}', 1, detected);
  }
  sources.add(detected);

  final List<int> iot = <int>[0, 0, 0];
  for (final IotEggReading reading in appState.iotReadings) {
    if (_dashboardDay(reading.createdAt) != date) {
      continue;
    }
    _countGrade(reading.displayGrade, 1, iot);
  }
  sources.add(iot);

  if (date == _dashboardDay(DateTime.now())) {
    sources.add(<int>[
      appState.liveGoodEggs,
      appState.liveCrackedEggs,
      0,
    ]);
  }

  List<int> best = <int>[0, 0, 0];
  int bestTotal = 0;
  for (final List<int> source in sources) {
    // Index 2 was Dirty — fold into Good; Crack only is reject.
    final List<int> folded = <int>[
      source[0] + source[2],
      source[1],
      0,
    ];
    final int total = folded[0] + folded[1];
    if (total > bestTotal) {
      best = folded;
      bestTotal = total;
    }
  }

  final int logged = _eggsOnDay(appState, date);
  return _DayHarvest(
    harvested: logged > bestTotal ? logged : bestTotal,
    good: best[0],
    crack: best[1],
    rejected: 0,
  );
}

String _shortMonthDay(DateTime date) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[date.month - 1]} ${date.day}';
}

class _WeeklyProductionOverview extends StatefulWidget {
  const _WeeklyProductionOverview({required this.appState});

  final AppState appState;

  @override
  State<_WeeklyProductionOverview> createState() =>
      _WeeklyProductionOverviewState();
}

class _WeeklyProductionOverviewState extends State<_WeeklyProductionOverview> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _dashboardDay(DateTime.now()).weekday - DateTime.monday;
  }

  @override
  Widget build(BuildContext context) {
    final AppState appState = widget.appState;
    final DateTime today = _dashboardDay(DateTime.now());
    final DateTime start = _weekStart(today);
    final List<_SeriesPoint> points = List<_SeriesPoint>.generate(7, (int index) {
      final DateTime day = start.add(Duration(days: index));
      return _SeriesPoint(_weekDayLabels[index], _eggsOnDay(appState, day).toDouble());
    });
    final int weekTotal = points.fold<int>(
      0,
      (int sum, _SeriesPoint point) => sum + point.value.round(),
    );
    final DateTime end = start.add(const Duration(days: 6));
    final DateTime selected = start.add(Duration(days: _selectedIndex));
    final _DayHarvest harvest = _harvestOnDay(appState, selected);

    return _GlassSection(
      title: 'Production Overview',
      titleIcon: Icons.show_chart_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'This week · ${_shortMonthDay(start)} – ${_shortMonthDay(end)} · $weekTotal eggs',
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
          ),
          const SizedBox(height: 8),
          _SimpleLineChart(
            data: points,
            selectedIndex: _selectedIndex,
            showAxis: true,
            showPointValues: false,
            callout: _DayHarvestCallout(
              day: _fullWeekDayLabels[selected.weekday - DateTime.monday],
              total: harvest.harvested,
              good: harvest.good,
              cracked: harvest.crack,
            ),
            onSelect: (int index) => setState(() => _selectedIndex = index),
          ),
        ],
      ),
    );
  }
}

class _InventoryStatusCard extends StatefulWidget {
  const _InventoryStatusCard({required this.appState});

  final AppState appState;

  @override
  State<_InventoryStatusCard> createState() => _InventoryStatusCardState();
}

class _InventoryStatusCardState extends State<_InventoryStatusCard> {
  late DateTime _visibleMonth;
  late DateTime _selected;
  bool _showCalendar = false;

  @override
  void initState() {
    super.initState();
    final DateTime today = _dashboardDay(DateTime.now());
    _selected = today;
    _visibleMonth = DateTime(today.year, today.month);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final DateTime today = _dashboardDay(DateTime.now());
    final DateTime selected = _dashboardDay(_selected);
    final int selectedCount = _eggsOnDay(widget.appState, selected);
    final _PeriodGradeCounts grades = _gradesBetween(
      widget.appState,
      selected,
      selected,
      useLiveFallback: selected == today,
    );
    final int daysInMonth = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    final int leading = DateTime(
          _visibleMonth.year,
          _visibleMonth.month,
          1,
        ).weekday -
        DateTime.monday;
    final List<DateTime?> cells = <DateTime?>[
      ...List<DateTime?>.filled(leading, null),
      for (int day = 1; day <= daysInMonth; day++)
        DateTime(_visibleMonth.year, _visibleMonth.month, day),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }

    return _GlassSection(
      title: 'Inventory Status',
      titleIcon: Icons.inventory_2_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '${_weekDayLabels[selected.weekday - DateTime.monday]}, ${_shortMonthDay(selected)}',
            style: const TextStyle(
              color: _DashboardPalette.foreground,
              fontWeight: FontWeight.w800,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              onPressed: () => setState(() => _showCalendar = !_showCalendar),
              tooltip: _showCalendar ? 'Hide calendar' : 'Show calendar',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
              icon: Icon(
                _showCalendar
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                color: _DashboardPalette.primary,
              ),
            ),
          ),
          _InventoryStatusRow(
            label: 'Eggs produced',
            value: '$selectedCount',
            color: _DashboardPalette.success,
          ),
          if (grades.inspected > 0) ...<Widget>[
            const SizedBox(height: 8),
            _InventoryStatusRow(
              label: 'Good',
              value: '${grades.good}',
              color: _DashboardPalette.success,
            ),
            const SizedBox(height: 8),
            _InventoryStatusRow(
              label: 'Cracked',
              value: '${grades.cracked}',
              color: _DashboardPalette.warning,
            ),
          ],
          if (_showCalendar) ...<Widget>[
            const SizedBox(height: 12),
          Row(
            children: <Widget>[
              IconButton(
                onPressed: () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_left_rounded),
                color: _DashboardPalette.foreground,
                tooltip: 'Previous month',
              ),
              Expanded(
                child: Text(
                  '${_shortMonthDay(DateTime(_visibleMonth.year, _visibleMonth.month, 1)).split(' ').first} ${_visibleMonth.year}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: _DashboardPalette.foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right_rounded),
                color: _DashboardPalette.foreground,
                tooltip: 'Next month',
              ),
            ],
          ),
          Row(
            children: _weekDayLabels
                .map(
                  (String label) => Expanded(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _DashboardPalette.mutedForeground,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 6),
          for (int row = 0; row < cells.length ~/ 7; row++)
            Row(
              children: <Widget>[
                for (int column = 0; column < 7; column++)
                  Expanded(
                    child: _DayCell(
                      day: cells[row * 7 + column],
                      selected: cells[row * 7 + column] == selected,
                      today: cells[row * 7 + column] == today,
                      eggs: cells[row * 7 + column] == null
                          ? 0
                          : _eggsOnDay(widget.appState, cells[row * 7 + column]!),
                      onTap: cells[row * 7 + column] == null
                          ? null
                          : () => setState(() => _selected = cells[row * 7 + column]!),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.selected,
    required this.today,
    required this.eggs,
    required this.onTap,
  });

  final DateTime? day;
  final bool selected;
  final bool today;
  final int eggs;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DateTime? date = day;
    if (date == null) {
      return const SizedBox(height: 42);
    }
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: selected
            ? _DashboardPalette.primary
            : today
            ? _DashboardPalette.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 42,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(
                  '${date.day}',
                  style: TextStyle(
                    color: selected
                        ? const Color(0xFF2A2118)
                        : _DashboardPalette.foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                if (eggs > 0)
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFF2A2118)
                          : _DashboardPalette.success,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Live Inspection section ────────────────────────────────────────────────

String _friendlyInspectionStatus(String raw, bool ok) {
  final String low = raw.toLowerCase();
  if (low.contains('permission-denied')) {
    return ok
        ? 'Camera records on farm PC. Cloud Firestore sync needs rules (permission-denied).'
        : 'Firestore permission-denied — farm Live Inspection still works from the PC.';
  }
  if (ok) {
    return raw;
  }
  final String lower = raw.toLowerCase();
  if (lower.contains('waiting for esp32') ||
      lower.contains('farm pc is online') ||
      lower.contains('server running')) {
    return raw;
  }
  if (lower.contains('404')) {
    return 'Farm PC is on port 8000. Waiting for ESP32-CAM heartbeat.';
  }
  if (lower.contains('connection') ||
      lower.contains('timeout') ||
      lower.contains('failed host')) {
    return 'Cannot reach the inspection server on this network.';
  }
  return raw;
}

/// Small live farm-camera picture at the bottom of the admin and worker dashboards.
class _LiveCameraStream extends StatelessWidget {
  const _LiveCameraStream({
    required this.appState,
    this.pollSnapshots = false,
  });

  final AppState appState;

  /// Prefer true on hosted web — Cloudflare/QUIC cancels long /stream MJPEG.
  final bool pollSnapshots;

  @override
  Widget build(BuildContext context) {
    final bool live = appState.liveInspectionConnected;
    // Prefer relative paths on workers.dev so the camera never hits LAN http
    // (mixed-content block). liveInspectionBackendUrl is already same-origin
    // when hosted; keep absolute for native / LAN builds.
    final String base = appState.liveInspectionBackendUrl;
    // Hosted tunnel cannot keep multipart /stream open — poll still JPEGs.
    // Prefer the farm tunnel for snapshots: workers.dev returns 429 when the
    // dashboard polls /live.jpg too often through the Worker proxy.
    final bool usePoll = pollSnapshots || ApiConfig.isHostedHttpsWeb;
    final String camBase = ApiConfig.isHostedHttpsWeb
        ? ApiConfig.farmTunnelUrl
        : base;
    final String streamUrl = usePoll ? '$camBase/live.jpg' : '$camBase/stream';

    return SizedBox(
      width: 280,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFF171210),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF3A302A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.videocam_outlined,
                  size: 14,
                  color: _DashboardPalette.primary,
                ),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'Live Camera',
                    style: TextStyle(
                      color: _DashboardPalette.foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                ),
                Text(
                  live ? 'LIVE' : 'OPEN',
                  style: TextStyle(
                    color: live
                        ? _DashboardPalette.success
                        : _DashboardPalette.warning,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 140,
                width: double.infinity,
                child: ColoredBox(
                  color: const Color(0xFF211A16),
                  child: LiveCamMjpeg(
                    key: ValueKey<String>('$streamUrl|$usePoll'),
                    streamUrl: streamUrl,
                    pollSnapshots: usePoll,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Main live-inspection panel on the dashboard.
/// Shows: system status bar, last quality result, last size classification,
/// and the three egg-count totals — all updating every 2 s from the backend.
class _LiveInspectionLedger extends StatelessWidget {
  const _LiveInspectionLedger({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    // Rebuild on every AppState notify. EggScaffold receives a pre-built body
    // Widget; Flutter skips updating identical body instances, so Live Egg
    // Records otherwise stayed stale until a full page refresh.
    return ListenableBuilder(
      listenable: appState,
      builder: (BuildContext context, Widget? _) {
        final String lab = appState.liveLastLabel.trim();
        final String low = lab.toLowerCase();
        final bool hasResult = appState.liveAwaitingWeight ||
            (lab.isNotEmpty &&
                lab != 'N/A' &&
                low != 'empty model' &&
                low != 'scanning' &&
                low != 'egg' &&
                low != 'detecting') ||
            appState.detectionRecords.isNotEmpty;
        final bool ok = appState.liveInspectionConnected;
        final Color frame = ok
            ? const Color(0xFF3A302A)
            : _DashboardPalette.warning.withValues(alpha: 0.35);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF171210),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: frame),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.videocam_outlined,
                    size: 18,
                    color: _DashboardPalette.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Live Inspection',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: _DashboardPalette.foreground,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final bool? ok = await showDialog<bool>(
                        context: context,
                        builder: (BuildContext ctx) => AlertDialog(
                          title: const Text('Reset today\'s records?'),
                          content: const Text(
                            'This clears Good / Cracked counts for today '
                            'in the app and deletes today\'s eggs from Firebase.',
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            FilledButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Reset'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        final bool farmOk = await appState.resetCounters();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                farmOk
                                    ? 'Today\'s inspection records were reset.'
                                    : 'Cleared on this device. Farm reset may still be syncing — check you are signed in as admin.',
                              ),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Reset'),
                    style: TextButton.styleFrom(
                      foregroundColor: _DashboardPalette.warning,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _InspectionSystemStatus(appState: appState),
              const SizedBox(height: 12),
              _EggCountRow(appState: appState),
              const SizedBox(height: 12),
              _EggResultCard(appState: appState, hasResult: hasResult),
              const SizedBox(height: 12),
              _IotReadingsPanel(appState: appState),
            ],
          ),
        );
      },
    );
  }
}

// ── System status bar ──────────────────────────────────────────────────────

class _InspectionSystemStatus extends StatelessWidget {
  const _InspectionSystemStatus({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final bool live = appState.liveInspectionConnected;
    final bool waiting = !live && appState.backendReachable;
    final Color dot = live
        ? _DashboardPalette.success
        : _DashboardPalette.warning;
    final String title = live
        ? 'Inspection System Running'
        : waiting
        ? 'System open — IoT offline'
        : 'System open — farm PC and IoT offline';
    final String badge = live
        ? 'LIVE'
        : 'OPEN';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: dot.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dot.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          _PulsingDot(color: dot, active: live || waiting),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: dot,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _friendlyInspectionStatus(
                    appState.liveInspectionStatus,
                    live,
                  ),
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: dot.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              badge,
              style: TextStyle(
                color: dot,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Combined quality + size result card ────────────────────────────────────

/// Shows the most recent egg's quality (Good / Cracked) side-by-side
/// with its weight class (Peewee → Jumbo).  When no egg has been seen yet the
/// card shows a neutral waiting state.
class _EggResultCard extends StatelessWidget {
  const _EggResultCard({required this.appState, required this.hasResult});

  final AppState appState;
  final bool hasResult;

  Color _qualityColor(String label) {
    final String s = label.toLowerCase();
    if (s.contains('no crack') ||
        s.contains('clean') ||
        s.contains('good') ||
        s.contains('ok')) {
      return _DashboardPalette.success;
    }
    if (s.contains('crack') || s.contains('broken')) {
      return _DashboardPalette.warning;
    }
    return _DashboardPalette.primary;
  }

  String _qualityShort(String label) {
    final String s = label.toLowerCase();
    if (s.contains('no crack') ||
        s.contains('clean') ||
        s.contains('good') ||
        s.contains('ok') ||
        s.contains('dirty') ||
        s.contains('soil')) {
      return 'Good';
    }
    if (s.contains('crack') || s.contains('broken')) return 'Cracked';
    return label;
  }

  // Each size class gets a distinct accent colour for its badge.
  static const Map<EggSizeClass, Color> _sizeColors = <EggSizeClass, Color>{
    EggSizeClass.peewee: Color(0xFF9E9E9E),
    EggSizeClass.small: Color(0xFF64B5F6),
    EggSizeClass.medium: Color(0xFF4DB6AC),
    EggSizeClass.large: Color(0xFF81C784),
    EggSizeClass.extraLarge: Color(0xFFFFB74D),
    EggSizeClass.jumbo: Color(0xFFBA68C8),
  };

  @override
  Widget build(BuildContext context) {
    if (!hasResult) {
      // ── Waiting / idle state ─────────────────────────────────────────────
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF211A16),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF3A302A)),
        ),
        child: const Row(
          children: <Widget>[
            Icon(
              Icons.egg_outlined,
              size: 28,
              color: _DashboardPalette.mutedForeground,
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Waiting for the first egg',
                    style: TextStyle(
                      color: _DashboardPalette.foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Start the live inspection server, then point the camera at an egg.',
                    style: TextStyle(
                      color: _DashboardPalette.mutedForeground,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    String displayLabel = appState.liveLastLabel;
    if ((displayLabel.isEmpty ||
            displayLabel == 'N/A' ||
            displayLabel.toLowerCase() == 'empty model') &&
        appState.detectionRecords.isNotEmpty) {
      displayLabel = appState.detectionRecords.first.label;
    }
    final Color qColor = _qualityColor(displayLabel);
    final String qShort = _qualityShort(displayLabel);
    final EggSizeClass sz = appState.liveLastSizeClass;
    final Color szColor = _sizeColors[sz] ?? _DashboardPalette.primary;
    final double weight = appState.liveLastWeightGrams;
    final double conf = appState.liveLastConfidence;
    final String meas = appState.liveLastMeasurementStatus;
    final bool pendingWeight = appState.liveAwaitingWeight ||
        (qShort == 'Good' && weight < 5.0) ||
        (appState.detectionRecords.isNotEmpty &&
            appState.detectionRecords.first.isPendingWeight);
    final bool measWarn =
        weight >= 5.0 && (meas == 'simulated' || meas == 'uncalibrated');

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _DashboardPalette.tabBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _DashboardPalette.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (pendingWeight)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0x332E7D32),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x664CAF50)),
              ),
              child: const Text(
                'RECORDED — pending weight (egg on pad / scale next)',
                style: TextStyle(
                  color: Color(0xFF81C784),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else if (measWarn)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0x33E8A838),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0x66E8A838)),
              ),
              child: Text(
                meas == 'simulated'
                    ? 'SIMULATED weight — integration test only (not production)'
                    : 'UNCALIBRATED weight — load-cell accuracy pending (Priority 6)',
                style: const TextStyle(
                  color: Color(0xFFE8A838),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          // ── Card header ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.egg_alt_rounded,
                  size: 16,
                  color: _DashboardPalette.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    pendingWeight
                        ? 'Last Inspection — pending weight'
                        : 'Last Inspection Result',
                    style: const TextStyle(
                      color: _DashboardPalette.foreground,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
                // Confidence pill
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: qColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: qColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    conf >= 1.0
                        ? '${conf.toStringAsFixed(1)}% conf.'
                        : 'RECORDED',
                    style: TextStyle(
                      color: qColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),
          const Divider(height: 1, color: _DashboardPalette.glassBorder),
          const SizedBox(height: 14),

          // ── Quality | Size  side-by-side ─────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Row(
              children: <Widget>[
                // Quality half
                Expanded(
                  child: _ResultHalf(
                    topLabel: 'QUALITY',
                    mainText: qShort,
                    subText: displayLabel,
                    accentColor: qColor,
                    badgeText: qShort.toUpperCase(),
                    icon: qShort == 'Good'
                        ? Icons.check_circle_rounded
                        : qShort == 'Cracked'
                        ? Icons.warning_rounded
                        : Icons.do_not_disturb_on_rounded,
                  ),
                ),

                // Vertical divider
                Container(
                  width: 1,
                  height: 72,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  color: _DashboardPalette.glassBorder,
                ),

                // Size half
                Expanded(
                  child: pendingWeight
                      ? const _ResultHalf(
                          topLabel: 'SIZE CLASS',
                          mainText: 'Pending',
                          subText: 'No weight yet — waiting on scale',
                          accentColor: Color(0xFFC4A574),
                          badgeText: 'WAIT',
                          icon: Icons.hourglass_top_rounded,
                        )
                      : _ResultHalf(
                          topLabel: 'SIZE CLASS',
                          mainText: sz.label,
                          subText:
                              '${weight > 0 ? weight.toStringAsFixed(1) : '—'} g'
                              '  ·  ${sz.rangeLabel}',
                          accentColor: szColor,
                          badgeText: sz.code,
                          icon: Icons.straighten_rounded,
                        ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ── Size class scale bar ─────────────────────────────────────────
          if (!pendingWeight)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: _SizeScaleBar(current: sz),
            )
          else
            const SizedBox(height: 2),
        ],
      ),
    );
  }
}

/// One half of the quality/size result card.
class _ResultHalf extends StatelessWidget {
  const _ResultHalf({
    required this.topLabel,
    required this.mainText,
    required this.subText,
    required this.accentColor,
    required this.badgeText,
    required this.icon,
  });

  final String topLabel;
  final String mainText;
  final String subText;
  final Color accentColor;
  final String badgeText;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // Section micro-label
        Text(
          topLabel,
          style: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 18, color: accentColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                mainText,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Badge chip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accentColor.withValues(alpha: 0.4)),
          ),
          child: Text(
            badgeText,
            style: TextStyle(
              color: accentColor,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subText,
          style: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontSize: 11,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Horizontal scale bar showing all six size classes with the current one
/// highlighted.
class _SizeScaleBar extends StatelessWidget {
  const _SizeScaleBar({required this.current});

  final EggSizeClass current;

  static const List<EggSizeClass> _order = <EggSizeClass>[
    EggSizeClass.peewee,
    EggSizeClass.small,
    EggSizeClass.medium,
    EggSizeClass.large,
    EggSizeClass.extraLarge,
    EggSizeClass.jumbo,
  ];

  static const Map<EggSizeClass, Color> _colors = <EggSizeClass, Color>{
    EggSizeClass.peewee: Color(0xFF9E9E9E),
    EggSizeClass.small: Color(0xFF64B5F6),
    EggSizeClass.medium: Color(0xFF4DB6AC),
    EggSizeClass.large: Color(0xFF81C784),
    EggSizeClass.extraLarge: Color(0xFFFFB74D),
    EggSizeClass.jumbo: Color(0xFFBA68C8),
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'SIZE SCALE',
          style: TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: _order.map((EggSizeClass sc) {
            final bool active = sc == current;
            final Color c = _colors[sc] ?? _DashboardPalette.primary;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  children: <Widget>[
                    // Coloured segment bar
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOut,
                      height: active ? 8 : 4,
                      decoration: BoxDecoration(
                        color: active ? c : c.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 5),
                    // Label below each segment
                    Text(
                      sc.code,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: active
                            ? c
                            : _DashboardPalette.mutedForeground.withValues(
                                alpha: 0.55,
                              ),
                        fontSize: active ? 10 : 9,
                        fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Egg count totals row ───────────────────────────────────────────────────

class _EggCountRow extends StatelessWidget {
  const _EggCountRow({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    // Prefer live metrics, but never show 0 when the board list has eggs
    // (farm /metrics can reset on backend restart while cached rows remain).
    int good = appState.liveGoodEggs;
    int cracked = appState.liveCrackedEggs;
    int boardGood = 0;
    int boardCrack = 0;
    for (final DetectionRecord row in appState.detectionRecords) {
      final String cat = row.category.toLowerCase();
      final String lab = row.label.toLowerCase();
      final bool isCrack = cat == 'crackedeggs' ||
          (lab.contains('crack') && !lab.contains('no crack'));
      if (isCrack) {
        boardCrack += 1;
      } else {
        boardGood += 1;
      }
    }
    if (boardGood > good) {
      good = boardGood;
    }
    if (boardCrack > cracked) {
      cracked = boardCrack;
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: _CountTile(
            label: 'Good',
            value: good,
            icon: Icons.check_circle_outline_rounded,
            accent: _DashboardPalette.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _CountTile(
            label: 'Cracked',
            value: cracked,
            icon: Icons.warning_amber_rounded,
            accent: _DashboardPalette.warning,
          ),
        ),
      ],
    );
  }
}

class _IotReadingsPanel extends StatelessWidget {
  const _IotReadingsPanel({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final List<IotEggReading> readings = appState.iotReadings;
    final List<DetectionRecord> farmRecs = appState.detectionRecords;
    final bool firestoreDenied =
        appState.liveInspectionStatus.toLowerCase().contains('permission-denied');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1412),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF332A24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'LIVE EGG RECORDS',
            style: TextStyle(
              color: _DashboardPalette.mutedForeground,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            firestoreDenied
                ? 'Farm PC records below. Firestore cloud sync blocked (permissions) — local pending still shown.'
                : 'Camera Clean/Crack records appear here immediately; weight fills when the pad reports grams.',
            style: TextStyle(
              color: firestoreDenied
                  ? const Color(0xFFE8A838)
                  : const Color(0xFFC4A574),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 10),
          if (readings.isEmpty && farmRecs.isEmpty)
            const Text(
              'No egg records yet. When the camera says Clean, a pending (no weight) row appears here.',
              style: TextStyle(color: _DashboardPalette.mutedForeground),
            )
          else ...<Widget>[
            if (farmRecs.isNotEmpty)
              ...farmRecs.take(8).map(
                (DetectionRecord rec) {
                  final String quality = _farmRecordQuality(rec);
                  final Color accent = _iotQualityColor(quality);
                  final bool pending = rec.isPendingWeight;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.egg, color: accent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text.rich(
                                TextSpan(
                                  children: <InlineSpan>[
                                    TextSpan(
                                      text: quality.toUpperCase(),
                                      style: TextStyle(
                                        color: accent,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    TextSpan(
                                      text: pending
                                          ? '  •  pending weight'
                                          : '  •  ${rec.weightGrams.toStringAsFixed(1)} g',
                                      style: TextStyle(
                                        color: pending
                                            ? const Color(0xFFC4A574)
                                            : _DashboardPalette.foreground,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (!pending)
                                      TextSpan(
                                        text: '  •  ${rec.sizeClass.label}',
                                        style: const TextStyle(
                                          color:
                                              _DashboardPalette.mutedForeground,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Text(
                                pending
                                    ? 'Camera recorded — waiting for scale'
                                    : 'Farm record',
                                style: TextStyle(
                                  color: pending
                                      ? const Color(0xFF81C784)
                                      : _DashboardPalette.mutedForeground,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          rec.timestamp.length >= 8
                              ? rec.timestamp.substring(
                                  rec.timestamp.length - 8,
                                )
                              : rec.timestamp,
                          style: const TextStyle(
                            color: _DashboardPalette.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              )
            else
              ...readings.take(8).map(
                (IotEggReading reading) {
                  final String quality = reading.displayGrade;
                  final Color accent = _iotQualityColor(quality);
                  final bool pending = reading.weightGrams < 5.0 &&
                      (reading.sizeClass.toLowerCase() == 'pending' ||
                          reading.sizeClass.isEmpty);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.egg, color: accent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text.rich(
                                TextSpan(
                                  children: <InlineSpan>[
                                    TextSpan(
                                      text: quality.toUpperCase(),
                                      style: TextStyle(
                                        color: accent,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    TextSpan(
                                      text: pending
                                          ? '  •  pending weight'
                                          : '  •  ${reading.weightGrams.toStringAsFixed(1)} g',
                                      style: TextStyle(
                                        color: pending
                                            ? const Color(0xFFC4A574)
                                            : _DashboardPalette.foreground,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (!pending && reading.sizeClass.isNotEmpty)
                                      TextSpan(
                                        text: '  •  ${reading.sizeClass}',
                                        style: const TextStyle(
                                          color:
                                              _DashboardPalette.mutedForeground,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (reading.isSimulated || reading.isUncalibrated)
                                Text(
                                  reading.measurementBanner,
                                  style: TextStyle(
                                    color: reading.isSimulated
                                        ? const Color(0xFFE8A838)
                                        : const Color(0xFFC4A574),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          _formatIotTime(reading.createdAt),
                          style: const TextStyle(
                            color: _DashboardPalette.mutedForeground,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}

String _farmRecordQuality(DetectionRecord rec) {
  final String s = '${rec.label} ${rec.category}'.toLowerCase();
  if (s.contains('crack') || s.contains('broken')) return 'Cracked';
  if (s.contains('clean') ||
      s.contains('good') ||
      s.contains('no crack') ||
      s.contains('goodeggs') ||
      s.contains('dirty') ||
      s.contains('soil') ||
      s.contains('dirtyeggs')) {
    return 'Good';
  }
  return rec.label.isNotEmpty ? rec.label : 'Egg';
}

String _formatIotTime(DateTime time) {
  final DateTime local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

Color _iotQualityColor(String quality) {
  switch (quality.toLowerCase()) {
    case 'good':
      return _DashboardPalette.success;
    case 'cracked':
      return _DashboardPalette.warning;
    case 'dirty':
      return _DashboardPalette.danger;
    default:
      return const Color(0xFFE4A11B);
  }
}

class _CountTile extends StatelessWidget {
  const _CountTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
  });

  final String label;
  final int value;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  value.toString(),
                  style: TextStyle(
                    color: accent,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.0,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pulsing dot ────────────────────────────────────────────────────────────

/// Small dot that pulses when active.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.active});

  final Color color;
  final bool active;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _fade = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    if (widget.active) {
      _ctrl.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_PulsingDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat(reverse: true);
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
      _ctrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
      ),
    );
  }
}

// ── Notifications card ─────────────────────────────────────────────────────

class _WorkerNotificationCard extends StatelessWidget {
  const _WorkerNotificationCard({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final int unread = appState.workerUnreadCount;
    return _GlassSection(
      titleIcon: Icons.notifications_outlined,
      title: 'Notifications',
      trailing: unread > 0
          ? TextButton(
              onPressed: appState.markAllNotificationsRead,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: _DashboardPalette.primary,
              ),
              child: const Text(
                'Mark all read',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            )
          : null,
      child: appState.workerNotifications.isEmpty
          ? const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'No notifications yet. Live farm status will appear here.',
                style: TextStyle(
                  color: _DashboardPalette.mutedForeground,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            )
          : Column(
              children: appState.workerNotifications
                  .map(
                    (WorkerNotification n) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _WorkerNotificationTile(
                        notification: n,
                        onTap: n.read
                            ? null
                            : () => appState.markNotificationRead(n.id),
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
  }
}

class _WorkerNotificationTile extends StatelessWidget {
  const _WorkerNotificationTile({
    required this.notification,
    this.onTap,
  });

  final WorkerNotification notification;
  final VoidCallback? onTap;

  Color get _accentColor {
    switch (notification.type) {
      case WorkerNotificationType.warning:
        return _DashboardPalette.warning;
      case WorkerNotificationType.success:
        return _DashboardPalette.success;
      case WorkerNotificationType.info:
        return _DashboardPalette.primary;
    }
  }

  IconData get _icon {
    switch (notification.type) {
      case WorkerNotificationType.warning:
        return Icons.warning_amber_rounded;
      case WorkerNotificationType.success:
        return Icons.check_circle_outline_rounded;
      case WorkerNotificationType.info:
        return Icons.info_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color accent = _accentColor;
    final bool unread = !notification.read;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: unread
                ? accent.withValues(alpha: 0.08)
                : _DashboardPalette.tabBackground,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: unread
                  ? accent.withValues(alpha: 0.35)
                  : _DashboardPalette.glassBorder,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(_icon, color: accent, size: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  notification.message,
                  style: TextStyle(
                    color: unread
                        ? _DashboardPalette.foreground
                        : _DashboardPalette.mutedForeground,
                    fontSize: 13,
                    fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (unread)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(top: 4, left: 6),
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassSection extends StatelessWidget {
  const _GlassSection({
    required this.title,
    required this.child,
    this.titleIcon,
    this.trailing,
  });

  final String title;
  final Widget child;
  final IconData? titleIcon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF16110F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF332A24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              if (titleIcon != null) ...<Widget>[
                Icon(titleIcon, color: _DashboardPalette.primary, size: 20),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFFC59E6C),
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _GradientProgressBar extends StatelessWidget {
  const _GradientProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 8,
      child: Stack(
        children: <Widget>[
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF2C2420),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          FractionallySizedBox(
            widthFactor: value.clamp(0.0, 1.0),
            child: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: <Color>[Color(0xFFEFB73E), Color(0xFF3DBA6A)],
                ),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

double _chartAxisMax(List<_SeriesPoint> data) {
  double maxVal = 0;
  for (final _SeriesPoint point in data) {
    if (point.value > maxVal) {
      maxVal = point.value;
    }
  }
  if (maxVal <= 0) {
    return 4;
  }
  final int top = (maxVal * 1.2).ceil();
  final int step = (top / 4).ceil().clamp(1, 1000000);
  return (step * 4).toDouble();
}

const List<String> _fullWeekDayLabels = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

class _DayHarvestCallout extends StatelessWidget {
  const _DayHarvestCallout({
    required this.day,
    required this.total,
    required this.good,
    required this.cracked,
  });

  final String day;
  final int total;
  final int good;
  final int cracked;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          day,
          style: const TextStyle(
            color: Color(0xFFF6F1E7),
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Total Eggs: $total',
          style: const TextStyle(
            color: Color(0xFFEFB73E),
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(color: Color(0xFFEFB73E), height: 1, thickness: 1),
        ),
        const Text(
          'Egg Breakdown',
          style: TextStyle(
            color: Color(0xFFB4A79A),
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        _DayHarvestCount(label: 'Good Eggs', value: good),
        const SizedBox(height: 6),
        _DayHarvestCount(label: 'Cracked Eggs', value: cracked),
      ],
    );
  }
}

class _DayHarvestCount extends StatelessWidget {
  const _DayHarvestCount({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFFEFB73E),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        Text(
          '$value',
          style: const TextStyle(
            color: Color(0xFFF6F1E7),
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

class _SimpleLineChart extends StatelessWidget {
  const _SimpleLineChart({
    required this.data,
    this.selectedIndex,
    this.onSelect,
    this.showAxis = false,
    this.showPointValues = true,
    this.calloutLines,
    this.callout,
  });

  final List<_SeriesPoint> data;
  final int? selectedIndex;
  final ValueChanged<int>? onSelect;
  final bool showAxis;
  final bool showPointValues;
  final List<String>? calloutLines;
  final Widget? callout;

  int _indexAt(double dx, double width) {
    if (data.length <= 1 || width <= 0) {
      return 0;
    }
    final double slot = width / (data.length - 1);
    return (dx / slot).round().clamp(0, data.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final bool detailed = showAxis &&
        (callout != null || (calloutLines != null && calloutLines!.isNotEmpty));
    final double tipWidth = callout != null ? 250 : 148;
    final double tipHeight = callout != null ? 168 : 118;
    return SizedBox(
      height: detailed ? (callout != null ? 300 : 236) : 210,
      child: Column(
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                const double axisWidth = 36;
                final double plotWidth = showAxis
                    ? (constraints.maxWidth - axisWidth).clamp(1, constraints.maxWidth)
                    : constraints.maxWidth;
                final double axisMax = showAxis ? _chartAxisMax(data) : 0;
                final int index = (selectedIndex ?? 0).clamp(0, data.length - 1);
                final double slot = data.length <= 1 ? plotWidth : plotWidth / (data.length - 1);
                final double x = index * slot;
                final double ratio = axisMax > 0 ? data[index].value / axisMax : 0;
                final double y =
                    constraints.maxHeight - (ratio * (constraints.maxHeight - 16)) - 8;
                double tipLeft = (showAxis ? axisWidth : 0) + x + 14;
                if (tipLeft + tipWidth > constraints.maxWidth - 2) {
                  tipLeft = (showAxis ? axisWidth : 0) + x - tipWidth - 14;
                }
                if (tipLeft < (showAxis ? axisWidth : 0)) {
                  tipLeft = showAxis ? axisWidth : 0;
                }
                double tipTop = y - 36;
                if (tipTop < 2) {
                  tipTop = 2;
                }
                if (tipTop + tipHeight > constraints.maxHeight - 2) {
                  tipTop = constraints.maxHeight - tipHeight - 2;
                }
                return Stack(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (showAxis)
                          SizedBox(
                            width: axisWidth,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: <Widget>[
                                for (int tick = 4; tick >= 0; tick--)
                                  Text(
                                    (axisMax * tick / 4).round().toString(),
                                    style: const TextStyle(
                                      color: Color(0xFFB4A79A),
                                      fontSize: 10,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTapUp: onSelect == null
                                ? null
                                : (TapUpDetails details) {
                                    onSelect!(
                                      _indexAt(details.localPosition.dx, plotWidth),
                                    );
                                  },
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: _LineChartPainter(
                                data: data,
                                selectedIndex: selectedIndex,
                                axisMax: showAxis ? axisMax : null,
                                showValues: showPointValues,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (detailed)
                      Positioned(
                        left: tipLeft,
                        top: tipTop,
                        child: IgnorePointer(
                          child: Container(
                            width: tipWidth,
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            decoration: BoxDecoration(
                              color: const Color(0xF21A1410),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0x66EFB73E)),
                            ),
                            child: callout ??
                                Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  calloutLines!.first,
                                  style: const TextStyle(
                                    color: Color(0xFFF6F1E7),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                for (final String line in calloutLines!.skip(1))
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      line,
                                      style: const TextStyle(
                                        color: Color(0xFFEFB73E),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (int index = 0; index < data.length; index++)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSelect == null ? null : () => onSelect!(index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        data[index].label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: index == selectedIndex
                              ? const Color(0xFFEFB73E)
                              : const Color(0xFFB4A79A),
                          fontSize: 11,
                          fontWeight: index == selectedIndex
                              ? FontWeight.w800
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({
    required this.data,
    this.selectedIndex,
    this.axisMax,
    this.showValues = true,
  });

  final List<_SeriesPoint> data;
  final int? selectedIndex;
  final double? axisMax;
  final bool showValues;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) {
      return;
    }

    final double maxVal = axisMax ??
        data
            .map((point) => point.value)
            .reduce((double a, double b) => a > b ? a : b);
    final double minVal = 0;

    final double widthBetweenPoints = size.width / (data.length - 1);
    final List<Offset> points = <Offset>[];

    for (int i = 0; i < data.length; i++) {
      final double x = i * widthBetweenPoints;
      final double ratio = maxVal > 0 ? (data[i].value - minVal) / maxVal : 0;
      final double y = size.height - (ratio * (size.height - 20)) - 10;
      points.add(Offset(x, y));
    }

    final Path path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      final Offset p0 = points[i - 1];
      final Offset p1 = points[i];
      final double controlX1 = p0.dx + (p1.dx - p0.dx) / 2;
      final double controlY1 = p0.dy;
      final double controlX2 = p0.dx + (p1.dx - p0.dx) / 2;
      final double controlY2 = p1.dy;
      path.cubicTo(controlX1, controlY1, controlX2, controlY2, p1.dx, p1.dy);
    }

    final Path fillPath = Path.from(path);
    fillPath.lineTo(size.width, size.height);
    fillPath.lineTo(0, size.height);
    fillPath.close();

    final Paint fillPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0x33EFB73E), Color(0x00EFB73E)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    canvas.drawPath(fillPath, fillPaint);

    if (axisMax != null) {
      final Paint gridPaint = Paint()
        ..color = const Color(0x22EFB73E)
        ..strokeWidth = 1;
      for (int tick = 0; tick <= 4; tick++) {
        final double gridY = size.height - (tick / 4 * (size.height - 16)) - 8;
        canvas.drawLine(Offset(0, gridY), Offset(size.width, gridY), gridPaint);
      }
    }

    final Paint strokePaint = Paint()
      ..color = const Color(0xFFEFB73E)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, strokePaint);

    final Paint dotOuterPaint = Paint()
      ..color = const Color(0xFFEFB73E)
      ..style = PaintingStyle.fill;

    final Paint dotInnerPaint = Paint()
      ..color = const Color(0xFF16110F)
      ..style = PaintingStyle.fill;

    if (selectedIndex != null &&
        selectedIndex! >= 0 &&
        selectedIndex! < points.length) {
      final Offset selected = points[selectedIndex!];
      canvas.drawLine(
        Offset(selected.dx, 0),
        Offset(selected.dx, size.height),
        Paint()
          ..color = const Color(0xFFE8D7B0)
          ..strokeWidth = 1.2,
      );
    }

    for (int i = 0; i < points.length; i++) {
      final Offset pt = points[i];
      final bool selected = i == selectedIndex;
      canvas.drawCircle(pt, selected ? 7 : 5, dotOuterPaint);
      canvas.drawCircle(pt, selected ? 3.5 : 2.5, dotInnerPaint);
      if (!showValues) {
        continue;
      }

      final TextPainter textPainter = TextPainter(
        text: TextSpan(
          text: data[i].value.toInt().toString(),
          style: const TextStyle(
            color: Color(0xFFF6F1E7),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(
        canvas,
        Offset(pt.dx - textPainter.width / 2, pt.dy - textPainter.height - 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter oldDelegate) => true;
}

class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.heightFactor, required this.color});

  final double heightFactor;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: heightFactor.clamp(0.01, 1.0),
      child: Container(
        width: 8,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

class _CircularScore extends StatelessWidget {
  const _CircularScore({
    required this.value,
    required this.label,
    required this.color,
  });

  final double value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 126,
      height: 126,
      child: Stack(
        fit: StackFit.expand,
        alignment: Alignment.center,
        children: <Widget>[
          CircularProgressIndicator(
            value: value,
            strokeWidth: 10,
            color: color,
            backgroundColor: const Color(0xFF2C2420),
          ),
          Center(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: _DashboardPalette.foreground),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _InventoryStatusRow extends StatelessWidget {
  const _InventoryStatusRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(Icons.egg_alt_outlined, color: color, size: 18),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            color: _DashboardPalette.foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _DrawerNavTile extends StatelessWidget {
  const _DrawerNavTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: selected
              ? _DashboardPalette.primary.withValues(alpha: 0.12)
              : _DashboardPalette.tabBackground,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? _DashboardPalette.primary.withValues(alpha: 0.28)
                : _DashboardPalette.glassBorder,
          ),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              item.icon,
              color: selected
                  ? _DashboardPalette.primary
                  : _DashboardPalette.mutedForeground,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.label,
                style: TextStyle(
                  color: selected
                      ? _DashboardPalette.foreground
                      : _DashboardPalette.mutedForeground,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
