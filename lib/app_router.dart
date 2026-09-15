import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'tflite_interpreter.dart';

import 'app_state.dart';
import 'auth_api.dart';
import 'iot_egg_reading.dart';
import 'flutter_conversion.dart';

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
    AppPaths.classification,
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
      case AppPaths.classification:
        return _page(settings, EggClassificationScreen(appState: appState));
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

enum _AuthMode { login, signup }

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
  static const int _minPasswordLength = 8;

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _fullNameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  _AuthMode _mode = _AuthMode.login;
  AppRole _signupRole = AppRole.worker;
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _fullNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _setMode(_AuthMode mode) {
    setState(() {
      _mode = mode;
      _error = null;
    });
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
    if (_mode == _AuthMode.signup) {
      final String? passwordError = _validatePassword(password);
      if (passwordError != null) {
        setState(() => _error = passwordError);
        return;
      }
    }

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      if (_mode == _AuthMode.login) {
        await widget.appState.login(email: email, password: password);
        if (!mounted) {
          return;
        }
        Navigator.of(context).pushReplacementNamed(AppPaths.dashboard);
        return;
      }

      final AuthMailResult result = await widget.appState.signup(
        name: _fullNameController.text.trim(),
        email: email,
        password: password,
        role: _signupRole == AppRole.admin ? 'admin' : 'worker',
      );
      if (!mounted) {
        return;
      }
      if (widget.appState.isAuthenticated) {
        Navigator.of(context).pushReplacementNamed(AppPaths.dashboard);
        return;
      }
      _openVerifyEmail(
        email: email,
        password: password,
        verificationCode: result.verificationCode,
        message: result.message,
      );
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.isUnverified) {
        _openVerifyEmail(
          email: email,
          password: password,
          verificationCode: error.verificationCode,
          message: error.message,
        );
        return;
      }
      if (error.code == 'email_taken') {
        try {
          await widget.appState.login(email: email, password: password);
          if (!mounted) {
            return;
          }
          Navigator.of(context).pushReplacementNamed(AppPaths.dashboard);
          return;
        } on AuthException catch (loginError) {
          if (loginError.isUnverified) {
            _openVerifyEmail(
              email: email,
              password: password,
              verificationCode: loginError.verificationCode,
              message: loginError.message,
            );
            return;
          }
          setState(() {
            _error =
                'This email already has an account. Sign in with that password, or use Forgot password.';
            _mode = _AuthMode.login;
          });
          return;
        }
      }
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(
        () => _error =
            'Wrong email or password, or the form is incomplete.',
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  String get _ctaLabel {
    if (_mode == _AuthMode.signup) {
      return 'CREATE ACCOUNT';
    }
    return 'SIGN IN';
  }

  String? _validateEmail(String? value) {
    final String trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return 'Email is required';
    }
    if (!trimmed.contains('@') || !trimmed.contains('.')) {
      return 'Enter a valid email';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final String password = value ?? '';
    if (password.length < _minPasswordLength) {
      return 'Minimum $_minPasswordLength characters';
    }
    if (!RegExp(r'[A-Za-z]').hasMatch(password)) {
      return 'Include a letter';
    }
    if (!RegExp(r'\d').hasMatch(password)) {
      return 'Include a number';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: <Widget>[
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
                    _AuthPalette.overlayTop,
                    _AuthPalette.overlayBottom,
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth < 552
                    ? constraints.maxWidth - 32
                    : 520;
                return Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: width,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.asset(
                                'assets/app-icon.png',
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'EGG SORTING',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _AuthPalette.foreground,
                                fontSize: 32,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 4,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const _SystemWordmark(),
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: _AuthPalette.glassBackground,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: _AuthPalette.glassBorder,
                                  ),
                                  boxShadow: const <BoxShadow>[
                                    BoxShadow(
                                      color: Color(0x66000000),
                                      blurRadius: 32,
                                      offset: Offset(0, 12),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.all(20),
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: <Widget>[
                                      Container(
                                        decoration: BoxDecoration(
                                          color: _AuthPalette.tabBackground,
                                          borderRadius:
                                              BorderRadius.circular(14),
                                        ),
                                        padding: const EdgeInsets.all(4),
                                        child: Row(
                                          children: <Widget>[
                                            Expanded(
                                              child: _AuthModeButton(
                                                label: 'SIGN IN',
                                                selected:
                                                    _mode == _AuthMode.login,
                                                onTap: () =>
                                                    _setMode(_AuthMode.login),
                                              ),
                                            ),
                                            Expanded(
                                              child: _AuthModeButton(
                                                label: 'CREATE ACCOUNT',
                                                selected:
                                                    _mode == _AuthMode.signup,
                                                onTap: () =>
                                                    _setMode(_AuthMode.signup),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 18),
                                      if (_mode == _AuthMode.signup) ...<Widget>[
                                        _AuthTextField(
                                          controller: _fullNameController,
                                          hintText: 'Full name',
                                          prefixIcon: Icons.person_outline,
                                          textInputAction: TextInputAction.next,
                                          validator: (String? value) {
                                            if ((value ?? '').trim().isEmpty) {
                                              return 'Name is required';
                                            }
                                            return null;
                                          },
                                        ),
                                        const SizedBox(height: 12),
                                        const Text(
                                          'Account type',
                                          style: TextStyle(
                                            color: _AuthPalette.mutedForeground,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: 0.8,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Container(
                                          decoration: BoxDecoration(
                                            color: _AuthPalette.tabBackground,
                                            borderRadius:
                                                BorderRadius.circular(14),
                                          ),
                                          padding: const EdgeInsets.all(4),
                                          child: Row(
                                            children: <Widget>[
                                              Expanded(
                                                child: _AuthModeButton(
                                                  label: 'ADMIN',
                                                  selected: _signupRole ==
                                                      AppRole.admin,
                                                  onTap: () => setState(() {
                                                    _signupRole = AppRole.admin;
                                                  }),
                                                ),
                                              ),
                                              Expanded(
                                                child: _AuthModeButton(
                                                  label: 'WORKER',
                                                  selected: _signupRole ==
                                                      AppRole.worker,
                                                  onTap: () => setState(() {
                                                    _signupRole =
                                                        AppRole.worker;
                                                  }),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                      ],
                                      _AuthTextField(
                                        controller: _emailController,
                                        hintText: 'Email',
                                        prefixIcon:
                                            Icons.mail_outline_rounded,
                                        keyboardType:
                                            TextInputType.emailAddress,
                                        textInputAction: TextInputAction.next,
                                        validator: _validateEmail,
                                      ),
                                      const SizedBox(height: 12),
                                      _AuthTextField(
                                        controller: _passwordController,
                                        hintText: _mode == _AuthMode.signup
                                            ? 'Password (8+ chars, letter and number)'
                                            : 'Password',
                                        prefixIcon:
                                            Icons.lock_outline_rounded,
                                        obscureText: _obscurePassword,
                                        textInputAction: TextInputAction.done,
                                        validator: _mode == _AuthMode.signup
                                            ? _validatePassword
                                            : (String? value) {
                                                if ((value ?? '').isEmpty) {
                                                  return 'Password is required';
                                                }
                                                return null;
                                              },
                                        suffixIcon: IconButton(
                                          onPressed: () {
                                            setState(() {
                                              _obscurePassword =
                                                  !_obscurePassword;
                                            });
                                          },
                                          icon: Icon(
                                            _obscurePassword
                                                ? Icons.visibility_outlined
                                                : Icons
                                                    .visibility_off_outlined,
                                            color:
                                                _AuthPalette.mutedForeground,
                                          ),
                                        ),
                                        onFieldSubmitted: (_) => _submit(),
                                      ),
                                      if (_error != null) ...<Widget>[
                                        const SizedBox(height: 12),
                                        Text(
                                          _error!,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Color(0xFFED6A5A),
                                            height: 1.35,
                                          ),
                                        ),
                                      ],
                                      if (_mode == _AuthMode.login) ...<Widget>[
                                        Align(
                                          alignment: Alignment.centerRight,
                                          child: TextButton(
                                            onPressed: () => Navigator.of(
                                              context,
                                            ).pushNamed(
                                              AppPaths.forgotPassword,
                                            ),
                                            child: const Text(
                                              'Forgot password?',
                                              style: TextStyle(
                                                color: _AuthPalette.primary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ] else
                                        const SizedBox(height: 12),
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          boxShadow: const <BoxShadow>[
                                            BoxShadow(
                                              color: Color(0x66EFB73E),
                                              blurRadius: 24,
                                              offset: Offset(0, 8),
                                            ),
                                          ],
                                        ),
                                        child: FilledButton(
                                          onPressed:
                                              _submitting ? null : _submit,
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                _AuthPalette.primary,
                                            foregroundColor: _AuthPalette
                                                .primaryForeground,
                                            disabledBackgroundColor:
                                                _AuthPalette.primary
                                                    .withValues(alpha: 0.55),
                                            padding:
                                                const EdgeInsets.symmetric(
                                              vertical: 16,
                                            ),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            textStyle: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w800,
                                              letterSpacing: 1.4,
                                            ),
                                          ),
                                          child: _submitting
                                              ? const SizedBox(
                                                  width: 22,
                                                  height: 22,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2.4,
                                                    color: _AuthPalette
                                                        .primaryForeground,
                                                  ),
                                                )
                                              : Text(_ctaLabel),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        _mode == _AuthMode.login
                                            ? 'ESP32 and port 8000 are not required to open Admin. Live camera stays Waiting until the station is on.'
                                            : 'Choose Admin or Worker, then enter the 6-digit code on the next screen.',
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: _AuthPalette
                                                  .mutedForeground,
                                              height: 1.4,
                                            ),
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
                );
              },
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
  String? _visibleCode;

  @override
  void initState() {
    super.initState();
    final String digits = _digitsOnly(widget.verificationCode ?? '');
    if (digits.length == 6) {
      _tokenController.text = digits;
      _visibleCode = digits;
    }
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
      final String digits = _digitsOnly(result.verificationCode ?? '');
      if (digits.length == 6) {
        _tokenController.text = digits;
        setState(() {
          _visibleCode = digits;
          _message = result.message;
        });
      } else {
        _tokenController.clear();
        setState(() => _message = result.message);
      }
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
                      ? 'Open the Egg System email and type the code below. Codes stay valid for 15 minutes.'
                      : 'We emailed ${widget.email}. If nothing arrived, use the 6-digit code shown below. It stays valid for 15 minutes.',
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
            if (_visibleCode != null) ...<Widget>[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0x33EFB73E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0x88EFB73E)),
                ),
                child: Column(
                  children: <Widget>[
                    const Text(
                      'Your verification code',
                      style: TextStyle(
                        color: _AuthPalette.mutedForeground,
                        fontSize: 12,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _visibleCode!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _AuthPalette.foreground,
                        fontSize: 32,
                        letterSpacing: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
                'Resend 6-digit code',
                style: TextStyle(color: _AuthPalette.mutedForeground),
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

class _SystemWordmark extends StatelessWidget {
  const _SystemWordmark();

  @override
  Widget build(BuildContext context) {
    final double indent =
        MediaQuery.sizeOf(context).width < 420 ? 8 : 72;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Divider(
            color: _AuthPalette.primary,
            thickness: 1,
            indent: indent,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            'SYSTEM',
            style: TextStyle(
              color: _AuthPalette.primary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 4.8,
            ),
          ),
        ),
        Expanded(
          child: Divider(
            color: _AuthPalette.primary,
            thickness: 1,
            endIndent: indent,
          ),
        ),
      ],
    );
  }
}

class _AuthModeButton extends StatelessWidget {
  const _AuthModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: selected ? _AuthPalette.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: selected
              ? _AuthPalette.primaryForeground
              : _AuthPalette.mutedForeground,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.1,
          ),
        ),
        child: Text(label, textAlign: TextAlign.center),
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

class EggClassificationScreen extends StatefulWidget {
  const EggClassificationScreen({super.key, required this.appState});

  final AppState appState;

  @override
  State<EggClassificationScreen> createState() =>
      _EggClassificationScreenState();
}

class _EggClassificationScreenState extends State<EggClassificationScreen> {
  Interpreter? _interpreter;
  String _prediction = 'No prediction yet';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      if (kIsWeb) {
        setState(() {
          _prediction = 'Model loading is not supported on web.';
          _isLoading = false;
        });
        return;
      }

      final interpreter = await Interpreter.fromAsset(
        'models/egg_model.tflite',
      );
      setState(() {
        _interpreter = interpreter;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _prediction = 'Failed to load model';
        _isLoading = false;
      });
    }
  }

  Future<void> _classifySampleImage() async {
    if (_interpreter == null) {
      setState(() => _prediction = 'Interpreter unavailable on this platform.');
      return;
    }

    final data = await rootBundle.load('assets/models/labels.txt');
    final labels = String.fromCharCodes(data.buffer.asUint8List()).split('\n');

    final bytes = await rootBundle.load('assets/egg-logo.png');
    final original = img.decodeImage(bytes.buffer.asUint8List());
    if (original == null) {
      setState(() => _prediction = 'Failed to decode image');
      return;
    }

    final resized = img.copyResize(original, width: 224, height: 224);
    final input = List.generate(
      1,
      (_) => List.generate(
        224,
        (_) => List.generate(224, (_) => List.filled(3, 0.0)),
      ),
    );
    for (var y = 0; y < 224; y++) {
      for (var x = 0; x < 224; x++) {
        final pixel = resized.getPixel(x, y);
        final int px = pixel as int;
        input[0][y][x][0] = ((px >> 16) & 0xFF) / 255.0;
        input[0][y][x][1] = ((px >> 8) & 0xFF) / 255.0;
        input[0][y][x][2] = (px & 0xFF) / 255.0;
      }
    }

    final output = List<List<double>>.generate(
      1,
      (_) => List<double>.filled(labels.length, 0.0),
    );
    _interpreter!.run(input, output);

    final List<double> scores = List<double>.from(output[0]);
    final maxIndex = scores.indexOf(scores.reduce((a, b) => a > b ? a : b));
    setState(() {
      _prediction =
          '${labels[maxIndex]} (score ${scores[maxIndex].toStringAsFixed(2)})';
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool webUnsupported = kIsWeb;
    return Scaffold(
      appBar: AppBar(title: const Text('Egg Classifier')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_isLoading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 24),
              const Text('Loading model...'),
            ] else ...[
              Text(_prediction, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              if (webUnsupported) ...[
                const Text(
                  'This classifier is not supported in Chrome/web. Use Android, iOS, Windows, or Linux instead.',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
              ],
              ElevatedButton(
                onPressed: webUnsupported ? null : _classifySampleImage,
                child: Text(
                  webUnsupported
                      ? 'Unavailable on Web'
                      : 'Classify sample egg image',
                ),
              ),
            ],
          ],
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
  static const Color featureBackground = Color(0x7F3B312B);
  static const Color featureBorder = Color(0x19F6F1E7);
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
  });
  final String label;
  final String value;
  final String unit;
  final IconData icon;
  final Color accent;
  final String route;
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

class _SalesLossPoint {
  const _SalesLossPoint(this.label, this.sales, this.losses);
  final String label;
  final double sales;
  final double losses;
}

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final DemoUser user = appState.currentUser!;
    final bool isWorker = !appState.isAdmin;

    // ── Worker stat cards — driven by live AppState data ──────────────────
    final List<_DashboardStat> stats = isWorker
        ? <_DashboardStat>[
            _DashboardStat(
              label: 'Today\'s Collection',
              value: appState.workerTodayCollection.toString(),
              unit: 'Eggs Collected',
              icon: Icons.trending_up_rounded,
              accent: _DashboardPalette.success,
              route: AppPaths.production,
            ),
            _DashboardStat(
              label: 'Grading Progress',
              value:
                  '${appState.liveGoodEggs > 0 ? ((appState.liveGoodEggs / (appState.liveGoodEggs + appState.liveCrackedEggs + appState.liveDirtyEggs).clamp(1, 999999)) * 100).toStringAsFixed(0) : '0'}%',
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
            _DashboardStat(
              label: 'Pending Tasks',
              value: appState.workerPendingTaskCount.toString(),
              unit: 'To complete',
              icon: Icons.list_alt_rounded,
              accent: appState.workerPendingTaskCount > 0
                  ? _DashboardPalette.warning
                  : _DashboardPalette.success,
              route: AppPaths.dashboard,
            ),
          ]
        : <_DashboardStat>[
            _DashboardStat(
              label: 'Today\'s Production',
              value: appState.todayProductionTotal.toString(),
              unit: 'Eggs',
              icon: Icons.trending_up_rounded,
              accent: _DashboardPalette.success,
              route: AppPaths.production,
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
              value: '₱0',
              unit: 'Eggs Sold',
              icon: Icons.payments_outlined,
              accent: _DashboardPalette.primary,
              route: AppPaths.inventory,
            ),
            _DashboardStat(
              label: 'Damaged / Rejected',
              value: '${appState.liveCrackedEggs + appState.liveDirtyEggs}',
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
              label: 'Egg Classifier',
              route: AppPaths.classification,
              icon: Icons.smart_toy_outlined,
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
              label: 'Egg Classifier',
              route: AppPaths.classification,
              icon: Icons.smart_toy_outlined,
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
          final Widget kpis = _DashboardStatGrid(stats: stats);
          final Widget links = _QuickLinkGrid(items: quickLinks);
          final Widget inspect = _LiveInspectionLedger(appState: appState);
          final Widget panels = isWorker
              ? _WorkerDashboardPanels(appState: appState)
              : _AdminDashboardPanels(appState: appState);

          if (!split) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                kpis,
                const SizedBox(height: 14),
                links,
                const SizedBox(height: 16),
                inspect,
                const SizedBox(height: 16),
                panels,
                const SizedBox(height: 10),
                zoneLine,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              kpis,
              const SizedBox(height: 14),
              links,
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(flex: 11, child: inspect),
                  const SizedBox(width: 16),
                  Expanded(flex: 9, child: panels),
                ],
              ),
              const SizedBox(height: 10),
              zoneLine,
            ],
          );
        },
      ),
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
  static const int _maxMovementQuantity = 100000;
  static const int _maxDeviceIdLength = 64;
  static const int _maxDeviceNameLength = 100;

  final TextEditingController _movementQtyController = TextEditingController();
  final TextEditingController _deviceIdController = TextEditingController();
  final TextEditingController _deviceNameController = TextEditingController();

  late List<InventoryItem> _items;
  late List<InventoryZone> _zones;
  late List<InventoryMovement> _movements;
  late List<InventoryDevice> _devices;
  InventoryItem? _selectedItem;
  String _movementType = 'stock_out';
  String _zoneFilter = 'all';
  String _deviceZone = 'none';
  bool _showDeviceForm = false;
  String? _issuedSecret;
  Map<String, String> _movementErrors = <String, String>{};
  Map<String, String> _deviceErrors = <String, String>{};

  @override
  void initState() {
    super.initState();
    _items = List<InventoryItem>.from(widget.appState.inventoryItems);
    _zones = List<InventoryZone>.from(widget.appState.inventoryZones);
    _movements = List<InventoryMovement>.from(
      widget.appState.inventoryMovements,
    );
    _devices = List<InventoryDevice>.from(widget.appState.inventoryDevices);
  }

  @override
  void dispose() {
    _movementQtyController.dispose();
    _deviceIdController.dispose();
    _deviceNameController.dispose();
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

  List<InventoryDevice> get _visibleDevices {
    if (_zoneFilter == 'all') {
      return _devices;
    }
    return _devices
        .where((InventoryDevice device) => device.zoneId == _zoneFilter)
        .toList();
  }

  int get _totalStockUnits => _visibleItems.fold<int>(
    0,
    (int sum, InventoryItem item) => sum + item.quantity,
  );

  int get _lowStockCount => _visibleItems
      .where((InventoryItem item) => item.quantity <= item.minThreshold)
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

  int get _activeDeviceCount =>
      _visibleDevices.where((InventoryDevice device) => device.isActive).length;

  InventoryZone? _zoneById(String? zoneId) {
    for (final InventoryZone zone in _zones) {
      if (zone.id == zoneId) {
        return zone;
      }
    }
    return null;
  }

  InventoryItem? _itemById(String itemId) {
    for (final InventoryItem item in _items) {
      if (item.id == itemId) {
        return item;
      }
    }
    return null;
  }

  void _openMovement(InventoryItem item, String type) {
    setState(() {
      _selectedItem = item;
      _movementType = type;
      _movementQtyController.clear();
      _movementErrors = <String, String>{};
    });
  }

  void _closeMovement() {
    setState(() {
      _selectedItem = null;
      _movementErrors = <String, String>{};
      _movementQtyController.clear();
    });
  }

  void _submitMovement() {
    final InventoryItem? item = _selectedItem;
    if (item == null) {
      return;
    }

    final Map<String, String> errors = <String, String>{};
    final int? quantity = int.tryParse(_movementQtyController.text.trim());

    if (quantity == null || quantity <= 0) {
      errors['quantity'] = 'Enter a valid quantity';
    } else if (quantity > _maxMovementQuantity) {
      errors['quantity'] = 'Max $_maxMovementQuantity';
    }

    final bool incoming =
        _movementType == 'stock_in' || _movementType == 'refill';
    if (quantity != null && !incoming && quantity > item.quantity) {
      errors['quantity'] = 'Not enough stock available';
    }
    if (quantity != null &&
        incoming &&
        item.quantity + quantity > item.maxCapacity) {
      errors['quantity'] = 'Exceeds max capacity of ${item.maxCapacity}';
    }

    if (errors.isNotEmpty) {
      setState(() => _movementErrors = errors);
      return;
    }

    final int delta = incoming ? quantity! : -quantity!;
    final int nextQuantity = item.quantity + delta;
    final DateTime now = DateTime.now();
    final InventoryItem updatedItem = InventoryItem(
      id: item.id,
      name: item.name,
      sku: item.sku,
      category: item.category,
      zoneId: item.zoneId,
      quantity: nextQuantity,
      minThreshold: item.minThreshold,
      maxCapacity: item.maxCapacity,
      unit: item.unit,
    );
    final InventoryMovement movement = InventoryMovement(
      id: 'mov-${now.microsecondsSinceEpoch}',
      itemId: item.id,
      movementType: _movementType,
      source: 'user',
      quantityDelta: delta,
      quantityAfter: nextQuantity,
      timestamp: _formatInventoryTimestamp(now),
      note: incoming
          ? 'Manual ${_movementTypeLabel(_movementType).toLowerCase()} recorded'
          : 'Manual ${_movementTypeLabel(_movementType).toLowerCase()} dispatched',
    );

    setState(() {
      _items = _items
          .map(
            (InventoryItem entry) => entry.id == item.id ? updatedItem : entry,
          )
          .toList();
      _movements = <InventoryMovement>[movement, ..._movements];
      _selectedItem = null;
      _movementQtyController.clear();
      _movementErrors = <String, String>{};
    });
    _persistInventory();
  }

  void _simulateIot(InventoryItem item) {
    final int quantity = item.quantity >= 25 ? 25 : item.quantity;
    if (quantity == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Item is empty and cannot simulate release'),
        ),
      );
      return;
    }

    final int nextQuantity = item.quantity - quantity;
    final DateTime now = DateTime.now();
    final InventoryItem updatedItem = InventoryItem(
      id: item.id,
      name: item.name,
      sku: item.sku,
      category: item.category,
      zoneId: item.zoneId,
      quantity: nextQuantity,
      minThreshold: item.minThreshold,
      maxCapacity: item.maxCapacity,
      unit: item.unit,
    );
    final InventoryMovement movement = InventoryMovement(
      id: 'mov-${now.microsecondsSinceEpoch}',
      itemId: item.id,
      movementType: 'release',
      source: 'iot_device',
      quantityDelta: -quantity,
      quantityAfter: nextQuantity,
      timestamp: _formatInventoryTimestamp(now),
      note: 'Simulated IoT release event',
    );

    setState(() {
      _items = _items
          .map(
            (InventoryItem entry) => entry.id == item.id ? updatedItem : entry,
          )
          .toList();
      _movements = <InventoryMovement>[movement, ..._movements];
    });
    _persistInventory();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Simulated IoT release for ${item.name}')),
    );
  }

  void _toggleDeviceForm() {
    setState(() {
      _showDeviceForm = !_showDeviceForm;
      if (!_showDeviceForm) {
        _deviceErrors = <String, String>{};
        _issuedSecret = null;
      }
    });
  }

  void _registerDevice() {
    final Map<String, String> errors = <String, String>{};
    final String deviceId = _deviceIdController.text.trim();
    final String deviceName = _deviceNameController.text.trim();

    if (deviceId.isEmpty) {
      errors['deviceId'] = 'Enter a unique device ID';
    } else if (deviceId.length > _maxDeviceIdLength) {
      errors['deviceId'] = 'Max $_maxDeviceIdLength characters';
    } else if (_devices.any(
      (InventoryDevice item) => item.deviceId == deviceId,
    )) {
      errors['deviceId'] = 'Device ID already exists';
    }

    if (deviceName.isEmpty) {
      errors['deviceName'] = 'Enter a display name';
    } else if (deviceName.length > _maxDeviceNameLength) {
      errors['deviceName'] = 'Max $_maxDeviceNameLength characters';
    }

    if (errors.isNotEmpty) {
      setState(() => _deviceErrors = errors);
      return;
    }

    final DateTime now = DateTime.now();
    final InventoryDevice device = InventoryDevice(
      id: 'device-${now.microsecondsSinceEpoch}',
      deviceId: deviceId,
      name: deviceName,
      zoneId: _deviceZone == 'none' ? null : _deviceZone,
      isActive: true,
      lastSeenLabel: 'Just now',
    );

    setState(() {
      _devices = <InventoryDevice>[device, ..._devices];
      _issuedSecret = _generateDeviceSecret(deviceId, now);
      _deviceErrors = <String, String>{};
      _deviceIdController.clear();
      _deviceNameController.clear();
      _deviceZone = 'none';
    });
    _persistInventory();
  }

  void _persistInventory() {
    widget.appState.replaceInventoryState(
      items: _items,
      movements: _movements,
      devices: _devices,
      zones: _zones,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool narrow = MediaQuery.sizeOf(context).width < 860;
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
      _ProductionStat(
        icon: Icons.memory_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Active Devices',
        value: _activeDeviceCount.toString(),
        suffix: 'online',
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
                      'Track stock, record movements, and monitor warehouse devices',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: _DashboardPalette.mutedForeground,
                      ),
                    ),
                  ],
                ),
              ),
              if (!narrow)
                FilledButton.icon(
                  onPressed: _toggleDeviceForm,
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
                    _showDeviceForm
                        ? Icons.close_rounded
                        : Icons.memory_rounded,
                  ),
                  label: Text(
                    _showDeviceForm
                        ? 'Close Device Form'
                        : 'Register IoT Device',
                  ),
                ),
            ],
          ),
          if (narrow) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _toggleDeviceForm,
                style: FilledButton.styleFrom(
                  backgroundColor: _DashboardPalette.primary,
                  foregroundColor: _DashboardPalette.primaryForeground,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: Icon(
                  _showDeviceForm ? Icons.close_rounded : Icons.memory_rounded,
                ),
                label: Text(
                  _showDeviceForm ? 'Close Device Form' : 'Register IoT Device',
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          _ProductionStatGrid(stats: stats),
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
            title: 'Live Stock Levels',
            titleIcon: Icons.refresh_rounded,
            child: _InventoryStockGrid(
              items: _visibleItems,
              zoneNameFor: (String? zoneId) =>
                  _zoneById(zoneId)?.name ?? 'Unassigned',
              onStockIn: (InventoryItem item) =>
                  _openMovement(item, 'stock_in'),
              onStockOut: (InventoryItem item) =>
                  _openMovement(item, 'stock_out'),
              onSimulateIot: _simulateIot,
            ),
          ),
          if (_selectedItem != null) ...<Widget>[
            const SizedBox(height: 18),
            _GlassSection(
              title: 'Record Movement',
              titleIcon: Icons.swap_horiz_rounded,
              child: _InventoryMovementForm(
                item: _selectedItem!,
                zoneName:
                    _zoneById(_selectedItem!.zoneId)?.name ?? 'Unassigned',
                movementType: _movementType,
                quantityController: _movementQtyController,
                errors: _movementErrors,
                onTypeSelected: (String type) {
                  setState(() => _movementType = type);
                },
                onCancel: _closeMovement,
                onSubmit: _submitMovement,
              ),
            ),
          ],
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Recent Movements',
            titleIcon: Icons.history_rounded,
            child: _InventoryMovementsTable(
              movements: _visibleMovements,
              itemById: _itemById,
            ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Registered IoT Devices',
            titleIcon: Icons.memory_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _InventoryDevicesTable(
                  devices: _visibleDevices,
                  zoneNameFor: (String? zoneId) =>
                      _zoneById(zoneId)?.name ?? 'Unassigned',
                ),
                if (_showDeviceForm || _issuedSecret != null) ...<Widget>[
                  const Divider(
                    height: 30,
                    color: _DashboardPalette.glassBorder,
                  ),
                  _InventoryDeviceForm(
                    deviceIdController: _deviceIdController,
                    deviceNameController: _deviceNameController,
                    zones: _zones,
                    selectedZone: _deviceZone,
                    issuedSecret: _issuedSecret,
                    errors: _deviceErrors,
                    onZoneChanged: (String? value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => _deviceZone = value);
                    },
                    onSubmit: _registerDevice,
                    onCloseSecret: () {
                      setState(() => _issuedSecret = null);
                    },
                  ),
                ],
              ],
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

class _InventoryStockGrid extends StatelessWidget {
  const _InventoryStockGrid({
    required this.items,
    required this.zoneNameFor,
    required this.onStockIn,
    required this.onStockOut,
    required this.onSimulateIot,
  });

  final List<InventoryItem> items;
  final String Function(String? zoneId) zoneNameFor;
  final ValueChanged<InventoryItem> onStockIn;
  final ValueChanged<InventoryItem> onStockOut;
  final ValueChanged<InventoryItem> onSimulateIot;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Text(
            'No items available in the selected zone',
            style: TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool large = constraints.maxWidth >= 1120;
        final bool medium = constraints.maxWidth >= 720;
        final double width = large
            ? (constraints.maxWidth - 24) / 3
            : medium
            ? (constraints.maxWidth - 12) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: items
              .map(
                (InventoryItem item) => SizedBox(
                  width: width,
                  child: _InventoryStockCard(
                    item: item,
                    zoneName: zoneNameFor(item.zoneId),
                    onStockIn: () => onStockIn(item),
                    onStockOut: () => onStockOut(item),
                    onSimulateIot: () => onSimulateIot(item),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }
}

class _InventoryStockCard extends StatelessWidget {
  const _InventoryStockCard({
    required this.item,
    required this.zoneName,
    required this.onStockIn,
    required this.onStockOut,
    required this.onSimulateIot,
  });

  final InventoryItem item;
  final String zoneName;
  final VoidCallback onStockIn;
  final VoidCallback onStockOut;
  final VoidCallback onSimulateIot;

  @override
  Widget build(BuildContext context) {
    final bool low = item.quantity <= item.minThreshold;
    final double fill = item.maxCapacity == 0
        ? 0
        : (item.quantity / item.maxCapacity).clamp(0, 1).toDouble();
    final Color accent = low
        ? _DashboardPalette.warning
        : _DashboardPalette.primary;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: low
            ? _DashboardPalette.warning.withValues(alpha: 0.08)
            : _DashboardPalette.tabBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: low
              ? _DashboardPalette.warning.withValues(alpha: 0.4)
              : _DashboardPalette.glassBorder,
        ),
      ),
      child: Column(
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
                      item.name,
                      style: const TextStyle(
                        color: _DashboardPalette.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.sku,
                      style: const TextStyle(
                        color: _DashboardPalette.mutedForeground,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (low)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _DashboardPalette.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'LOW',
                    style: TextStyle(
                      color: _DashboardPalette.warning,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          RichText(
            text: TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: item.quantity.toString(),
                  style: const TextStyle(
                    color: _DashboardPalette.foreground,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                TextSpan(
                  text: ' ${item.unit}',
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${item.category} · $zoneName',
            style: const TextStyle(color: _DashboardPalette.mutedForeground),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: fill,
              minHeight: 9,
              color: accent,
              backgroundColor: _DashboardPalette.border,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Threshold ${item.minThreshold} ${item.unit} · Capacity ${item.maxCapacity}',
            style: const TextStyle(
              color: _DashboardPalette.mutedForeground,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onStockIn,
                  style: FilledButton.styleFrom(
                    foregroundColor: _DashboardPalette.success,
                    backgroundColor: _DashboardPalette.success.withValues(
                      alpha: 0.12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('In'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onStockOut,
                  style: FilledButton.styleFrom(
                    foregroundColor: _DashboardPalette.danger,
                    backgroundColor: _DashboardPalette.danger.withValues(
                      alpha: 0.12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.remove_rounded, size: 18),
                  label: const Text('Out'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onSimulateIot,
                  style: FilledButton.styleFrom(
                    foregroundColor: _DashboardPalette.primary,
                    backgroundColor: _DashboardPalette.primary.withValues(
                      alpha: 0.12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.memory_rounded, size: 18),
                  label: const Text('IoT'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InventoryMovementForm extends StatelessWidget {
  const _InventoryMovementForm({
    required this.item,
    required this.zoneName,
    required this.movementType,
    required this.quantityController,
    required this.errors,
    required this.onTypeSelected,
    required this.onCancel,
    required this.onSubmit,
  });

  final InventoryItem item;
  final String zoneName;
  final String movementType;
  final TextEditingController quantityController;
  final Map<String, String> errors;
  final ValueChanged<String> onTypeSelected;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    const List<String> types = <String>[
      'stock_in',
      'refill',
      'stock_out',
      'release',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${item.name} · ${item.quantity} ${item.unit} available · $zoneName',
          style: const TextStyle(
            color: _DashboardPalette.mutedForeground,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Movement Type',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: _DashboardPalette.mutedForeground,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: types
              .map(
                (String type) => _GradingChoiceButton(
                  label: _movementTypeLabel(type),
                  selected: movementType == type,
                  onTap: () => onTypeSelected(type),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: 16),
        _ProductionField(
          label: 'Quantity',
          errorText: errors['quantity'],
          child: _ProductionTextField(
            controller: quantityController,
            hintText: 'e.g. 25',
            keyboardType: TextInputType.number,
          ),
        ),
        const SizedBox(height: 18),
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
              child: const Text('Record Movement'),
            ),
          ],
        ),
      ],
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

class _InventoryDevicesTable extends StatelessWidget {
  const _InventoryDevicesTable({
    required this.devices,
    required this.zoneNameFor,
  });

  final List<InventoryDevice> devices;
  final String Function(String? zoneId) zoneNameFor;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 36),
        child: Center(
          child: Text(
            'No devices registered in this zone',
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
          DataColumn(label: Text('Device ID')),
          DataColumn(label: Text('Name')),
          DataColumn(label: Text('Zone')),
          DataColumn(label: Text('Last Seen')),
          DataColumn(label: Text('Status')),
        ],
        rows: devices
            .map(
              (InventoryDevice device) => DataRow(
                cells: <DataCell>[
                  DataCell(
                    Text(
                      device.deviceId,
                      style: const TextStyle(
                        color: _DashboardPalette.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  DataCell(Text(device.name)),
                  DataCell(Text(zoneNameFor(device.zoneId))),
                  DataCell(Text(device.lastSeenLabel)),
                  DataCell(
                    _InventoryPill(
                      label: device.isActive ? 'Active' : 'Inactive',
                      color: device.isActive
                          ? _DashboardPalette.success
                          : _DashboardPalette.mutedForeground,
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

class _InventoryDeviceForm extends StatelessWidget {
  const _InventoryDeviceForm({
    required this.deviceIdController,
    required this.deviceNameController,
    required this.zones,
    required this.selectedZone,
    required this.issuedSecret,
    required this.errors,
    required this.onZoneChanged,
    required this.onSubmit,
    required this.onCloseSecret,
  });

  final TextEditingController deviceIdController;
  final TextEditingController deviceNameController;
  final List<InventoryZone> zones;
  final String selectedZone;
  final String? issuedSecret;
  final Map<String, String> errors;
  final ValueChanged<String?> onZoneChanged;
  final VoidCallback onSubmit;
  final VoidCallback onCloseSecret;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (issuedSecret != null) ...<Widget>[
          Text(
            'Device registered. Save this secret now:',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: _DashboardPalette.success,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _DashboardPalette.tabBackground,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _DashboardPalette.glassBorder),
            ),
            child: SelectableText(
              issuedSecret!,
              style: const TextStyle(
                color: _DashboardPalette.foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: onCloseSecret,
            child: const Text(
              'Hide secret',
              style: TextStyle(color: _DashboardPalette.mutedForeground),
            ),
          ),
          const SizedBox(height: 18),
        ],
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool medium = constraints.maxWidth >= 860;
            final double width = medium
                ? (constraints.maxWidth - 24) / 3
                : constraints.maxWidth;

            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Device ID',
                    errorText: errors['deviceId'],
                    child: _ProductionTextField(
                      controller: deviceIdController,
                      hintText: 'e.g. machine-04',
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Display Name',
                    errorText: errors['deviceName'],
                    child: _ProductionTextField(
                      controller: deviceNameController,
                      hintText: 'e.g. Conveyor Counter',
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ProductionField(
                    label: 'Zone',
                    child: _DropdownShell(
                      value: selectedZone,
                      items: <String>[
                        'none',
                        ...zones.map((InventoryZone zone) => zone.id),
                      ],
                      labels: <String, String>{
                        'none': 'Unassigned',
                        for (final InventoryZone zone in zones)
                          zone.id: zone.name,
                      },
                      onChanged: onZoneChanged,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: onSubmit,
          style: FilledButton.styleFrom(
            backgroundColor: _DashboardPalette.primary,
            foregroundColor: _DashboardPalette.primaryForeground,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          child: const Text('Register & Generate Secret'),
        ),
      ],
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

String _formatInventoryTimestamp(DateTime value) {
  final String year = value.year.toString().padLeft(4, '0');
  final String month = value.month.toString().padLeft(2, '0');
  final String day = value.day.toString().padLeft(2, '0');
  final String hour = value.hour.toString().padLeft(2, '0');
  final String minute = value.minute.toString().padLeft(2, '0');
  return '$year-$month-$day $hour:$minute';
}

String _generateDeviceSecret(String deviceId, DateTime value) {
  final String stamp = value.microsecondsSinceEpoch.toRadixString(16);
  return 'egg-$deviceId-$stamp';
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
    switch (_selectedPeriod) {
      case _ReportPeriod.daily:
        return 'April 15, 2026';
      case _ReportPeriod.weekly:
        return 'Apr 09 - Apr 15, 2026';
      case _ReportPeriod.monthly:
        return 'April 2026';
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

  String get _exportPreview {
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
    final String fileName = 'egg-report-$_periodName-2026-04-15.csv';
    setState(() => _lastExportFileName = fileName);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Prepared local export preview: $fileName')),
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
                      'Exportable daily, weekly, and monthly admin summaries',
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
                label: const Text('Export CSV'),
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
                        fileName:
                            _lastExportFileName ??
                            'egg-report-$_periodName-2026-04-15.csv',
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

  @override
  Widget build(BuildContext context) {
    final DemoUser user = widget.appState.currentUser!;
    final bool isAdmin = widget.appState.isAdmin;
    final String passwordUpdated = user.passwordChangedAt == null
        ? 'Never'
        : user.passwordChangedAt!.replaceFirst('T', ' ').replaceFirst('Z', ' UTC');
    final String sessionLabel = widget.appState.sessionExpiresAt == null
        ? 'Active on this device'
        : 'Expires ${widget.appState.sessionExpiresAt!.toLocal()}';
    final List<_ProductionStat> stats = <_ProductionStat>[
      _ProductionStat(
        icon: Icons.badge_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Role',
        value: isAdmin ? 'Admin' : 'Worker',
        suffix: 'access',
      ),
      _ProductionStat(
        icon: Icons.verified_user_outlined,
        iconColor: _DashboardPalette.success,
        label: 'Status',
        value: user.emailVerified ? 'Verified' : 'Unverified',
        suffix: 'account',
      ),
      _ProductionStat(
        icon: Icons.location_on_outlined,
        iconColor: _DashboardPalette.primary,
        label: 'Zone',
        value: user.assignedZone,
        suffix: 'assigned',
      ),
      _ProductionStat(
        icon: Icons.schedule_outlined,
        iconColor: _DashboardPalette.warning,
        label: 'Last Update',
        value: user.passwordChangedAt == null ? 'Never' : 'Updated',
        suffix: 'password',
      ),
    ];

    return EggScaffold(
      appState: widget.appState,
      title: 'Profile',
      selectedRoute: AppPaths.profile,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _DashboardPalette.primary.withValues(alpha: 0.35)),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'MY PROFILE',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: _DashboardPalette.foreground,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Account details and security settings',
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
                      title: 'Account',
                      titleIcon: Icons.account_circle_outlined,
                      child: Column(
                        children: <Widget>[
                          _ProfileInfoRow(
                            icon: Icons.person_outline_rounded,
                            label: 'Full Name',
                            value: user.name,
                          ),
                          _ProfileInfoRow(
                            icon: Icons.mail_outline_rounded,
                            label: 'Email',
                            value: user.email,
                          ),
                          _ProfileInfoRow(
                            icon: Icons.shield_outlined,
                            label: 'Role',
                            value: user.role.name.toUpperCase(),
                          ),
                          _ProfileInfoRow(
                            icon: Icons.verified_outlined,
                            label: 'Status',
                            value: user.emailVerified
                                ? 'Email confirmed'
                                : 'Email not verified',
                          ),
                          _ProfileInfoRow(
                            icon: Icons.location_on_outlined,
                            label: 'Assigned Zone',
                            value: user.assignedZone,
                            isLast: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: _GlassSection(
                      title: 'Session',
                      titleIcon: Icons.devices_outlined,
                      child: Column(
                        children: <Widget>[
                          _ProfileInfoRow(
                            icon: Icons.lock_clock_outlined,
                            label: 'Session State',
                            value: sessionLabel,
                          ),
                          _ProfileInfoRow(
                            icon: Icons.calendar_today_outlined,
                            label: 'Profile Synced',
                            value: _formatDashboardDate(),
                          ),
                          _ProfileInfoRow(
                            icon: Icons.manage_accounts_outlined,
                            label: 'Access Scope',
                            value: isAdmin
                                ? 'Admin control room'
                                : 'Worker workflow',
                          ),
                          _ProfileInfoRow(
                            icon: Icons.key_outlined,
                            label: 'Password Status',
                            value: user.passwordChangedAt == null
                                ? 'Pending first update'
                                : 'Updated on $passwordUpdated',
                            isLast: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Change Password',
            titleIcon: Icons.key_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Use at least $_minPasswordLength characters with a letter and a number. Other sessions will be signed out.',
                  style: const TextStyle(
                    color: _DashboardPalette.mutedForeground,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool medium = constraints.maxWidth >= 760;
                    final double width = medium
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth;

                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: <Widget>[
                        SizedBox(
                          width: constraints.maxWidth,
                          child: _ProductionField(
                            label: 'Current Password',
                            errorText: _errors['current'],
                            child: _ProductionTextField(
                              controller: _currentPasswordController,
                              hintText: 'Enter current password',
                              obscureText: !_showCurrentPassword,
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(
                                    () => _showCurrentPassword =
                                        !_showCurrentPassword,
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
                        ),
                        SizedBox(
                          width: width,
                          child: _ProductionField(
                            label: 'New Password',
                            errorText: _errors['password'],
                            child: _ProductionTextField(
                              controller: _passwordController,
                              hintText: 'Enter new password',
                              obscureText: !_showPassword,
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(
                                    () => _showPassword = !_showPassword,
                                  );
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
                            label: 'Confirm Password',
                            errorText: _errors['confirm'],
                            child: _ProductionTextField(
                              controller: _confirmPasswordController,
                              hintText: 'Confirm new password',
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
                const SizedBox(height: 18),
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
                      borderRadius: BorderRadius.circular(14),
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
                  label: const Text('Update Password'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _GlassSection(
            title: 'Sign Out',
            titleIcon: Icons.logout_rounded,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'End your session on this device.',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: _DashboardPalette.foreground,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Use this when switching staff members or leaving a shared workstation.',
                        style: TextStyle(
                          color: _DashboardPalette.mutedForeground,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                FilledButton.tonalIcon(
                  onPressed: _signOut,
                  style: FilledButton.styleFrom(
                    foregroundColor: _DashboardPalette.danger,
                    backgroundColor: _DashboardPalette.danger.withValues(
                      alpha: 0.12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Logout'),
                ),
              ],
            ),
          ),
        ],
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
    final List<_NavItem> navItems = <_NavItem>[
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
                  physics: const NeverScrollableScrollPhysics(),
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
  });

  final AppState appState;
  final String title;
  final String selectedRoute;
  final Widget body;

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

  // Worker bottom-nav items (mobile only, non-admin).
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
      label: 'Grading',
      route: AppPaths.grading,
      icon: Icons.fact_check_outlined,
    ),
    _NavItem(
      label: 'Classify',
      route: AppPaths.classification,
      icon: Icons.smart_toy_outlined,
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

    final List<_NavItem> navItems = <_NavItem>[
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
        label: 'Grading',
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
                (selectedRoute == AppPaths.dashboard && wide)
                    ? 'Farm dashboard'
                    : title.toUpperCase(),
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
        if (user != null) ...<Widget>[
          if (wide) ...<Widget>[
            Flexible(
              child: Text(
                user.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _DashboardPalette.mutedForeground,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _DashboardPalette.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: _DashboardPalette.primary.withValues(alpha: 0.24),
              ),
            ),
            child: Text(
              user.role.name.toUpperCase(),
              style: const TextStyle(
                color: _DashboardPalette.primary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          if (wide) ...<Widget>[
            const SizedBox(width: 12),
            const Icon(
              Icons.notifications_none_outlined,
              color: _DashboardPalette.mutedForeground,
              size: 22,
            ),
          ],
          const SizedBox(width: 10),
          IconButton(
            onPressed: () {
              appState.signOut();
              Navigator.of(context).pushNamedAndRemoveUntil(
                AppPaths.auth,
                (Route<dynamic> route) => false,
              );
            },
            icon: const Icon(Icons.logout_rounded),
            color: _DashboardPalette.mutedForeground,
            style: IconButton.styleFrom(
              backgroundColor: _DashboardPalette.tabBackground,
            ),
          ),
        ],
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
                    _ConnectionBanner(appState: appState),
                    const SizedBox(height: 12),
                    body,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );

    final bool showBottomNav = !wide && !appState.isAdmin;
    final int bottomIndex = showBottomNav
        ? _workerBottomItems
              .indexWhere((item) => item.route == selectedRoute)
              .clamp(0, _workerBottomItems.length - 1)
        : 0;

    return Scaffold(
      backgroundColor: const Color(0xFF100C0A),
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
                    final String route = _workerBottomItems[i].route;
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
                  items: _workerBottomItems
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
                          children: navItems
                              .map(
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
                              )
                              .toList(),
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
                    _DashboardPalette.overlayTop,
                    _DashboardPalette.overlayBottom,
                  ],
                ),
              ),
            ),
          ),
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
    // Badge unread count on Notifications (Home tab proxies to dashboard).
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
    // Badge pending task count on Production tab.
    if (item.route == AppPaths.production &&
        appState.workerPendingTaskCount > 0) {
      icon = Badge(
        label: Text(
          appState.workerPendingTaskCount.toString(),
          style: const TextStyle(fontSize: 9),
        ),
        backgroundColor: _DashboardPalette.danger,
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
        onTap: () => Navigator.of(context).pushReplacementNamed(stat.route),
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF3A302A)),
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

class _AdminDashboardPanels extends StatelessWidget {
  const _AdminDashboardPanels({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    const List<_SeriesPoint> productionData = <_SeriesPoint>[];
    const List<_SalesLossPoint> salesLossData = <_SalesLossPoint>[];

    return Column(
      children: <Widget>[
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool wide = constraints.maxWidth >= 1060;
            final bool medium = constraints.maxWidth >= 740;
            final double full = constraints.maxWidth;
            final double half = (constraints.maxWidth - 16) / 2;
            final double third = (constraints.maxWidth - 32) / 3;

            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: <Widget>[
                SizedBox(
                  width: wide
                      ? third
                      : medium
                      ? half
                      : full,
                  child: _GlassSection(
                    title: 'Production Overview',
                    child: _SimpleLineChart(data: productionData),
                  ),
                ),
                SizedBox(
                  width: wide
                      ? third
                      : medium
                      ? half
                      : full,
                  child: _GlassSection(
                    title: 'Inventory Status',
                    child: Column(
                      children: <Widget>[
                        _InventoryStatusRow(
                          label: 'Good Eggs',
                          value: '2,800',
                          color: _DashboardPalette.success,
                        ),
                        const SizedBox(height: 12),
                        _InventoryStatusRow(
                          label: 'Cracked Eggs',
                          value: '420',
                          color: _DashboardPalette.primary,
                        ),
                        const SizedBox(height: 18),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: _DashboardPalette.tabBackground,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _DashboardPalette.glassBorder,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Row(
                                children: <Widget>[
                                  Icon(
                                    Icons.inventory_2_outlined,
                                    color: _DashboardPalette.primary,
                                    size: 18,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Inventory Flow',
                                    style: TextStyle(
                                      color: _DashboardPalette.foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: <Widget>[
                                  const Text(
                                    'FIFO Tracking',
                                    style: TextStyle(
                                      color: _DashboardPalette.mutedForeground,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: _GradientProgressBar(value: 0),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: wide ? third : full,
                  child: _GlassSection(
                    title: 'Alerts & Notifications',
                    titleIcon: Icons.notifications_active_outlined,
                    child: Column(
                      children: appState.alerts
                          .map(
                            (AlertMessage alert) => Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _AlertTile(alert: alert),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
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
                    title: 'Grading Summary',
                    child: Row(
                      children: <Widget>[
                        _CircularScore(
                          value: 0.8,
                          label: '80%',
                          color: _DashboardPalette.success,
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            children: appState.gradingSummary
                                .map(
                                  (GradingSummary item) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _LegendRow(
                                      label: item.label,
                                      value: '${item.quantity}%',
                                      color: item.color,
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _GlassSection(
                    title: 'Sales & Losses',
                    child: _SalesLossChart(data: salesLossData),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ── Live Inspection section ────────────────────────────────────────────────

String _friendlyInspectionStatus(String raw, bool ok) {
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

/// Main live-inspection panel on the dashboard.
/// Shows: system status bar, last quality result, last size classification,
/// and the three egg-count totals — all updating every 2 s from the backend.
class _LiveInspectionLedger extends StatelessWidget {
  const _LiveInspectionLedger({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final bool hasResult =
        appState.liveLastLabel != 'N/A' && appState.liveLastLabel.isNotEmpty;
    final bool ok = appState.liveInspectionConnected;
    final bool waiting = !ok && appState.backendReachable;
    final Color frame = ok
        ? const Color(0xFF3A302A)
        : waiting
        ? _DashboardPalette.warning.withValues(alpha: 0.35)
        : _DashboardPalette.danger.withValues(alpha: 0.35);

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
              Text(
                'Live Inspection',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _DashboardPalette.foreground,
                  fontWeight: FontWeight.w800,
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
        : waiting
        ? _DashboardPalette.warning
        : _DashboardPalette.danger;
    final String title = live
        ? 'Inspection System Running'
        : waiting
        ? 'Waiting for ESP32-CAM'
        : 'Inspection System Offline';
    final String badge = live
        ? 'LIVE'
        : waiting
        ? 'WAITING'
        : 'OFFLINE';

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

/// Shows the most recent egg's quality (Good / Cracked / Dirty) side-by-side
/// with its weight class (Peewee → Jumbo).  When no egg has been seen yet the
/// card shows a neutral waiting state.
class _EggResultCard extends StatelessWidget {
  const _EggResultCard({required this.appState, required this.hasResult});

  final AppState appState;
  final bool hasResult;

  Color _qualityColor(String label) {
    final String s = label.toLowerCase();
    if (s.contains('no crack') || s.contains('good') || s.contains('ok')) {
      return _DashboardPalette.success;
    }
    if (s.contains('crack') || s.contains('broken')) {
      return _DashboardPalette.warning;
    }
    if (s.contains('dirty') || s.contains('soil') || s.contains('stain')) {
      return _DashboardPalette.danger;
    }
    return _DashboardPalette.primary;
  }

  String _qualityShort(String label) {
    final String s = label.toLowerCase();
    if (s.contains('no crack') || s.contains('good') || s.contains('ok')) {
      return 'Good';
    }
    if (s.contains('crack') || s.contains('broken')) return 'Cracked';
    if (s.contains('dirty') || s.contains('soil')) return 'Dirty';
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

    final Color qColor = _qualityColor(appState.liveLastLabel);
    final String qShort = _qualityShort(appState.liveLastLabel);
    final EggSizeClass sz = appState.liveLastSizeClass;
    final Color szColor = _sizeColors[sz] ?? _DashboardPalette.primary;
    final double weight = appState.liveLastWeightGrams;
    final double conf = appState.liveLastConfidence;

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
                const Expanded(
                  child: Text(
                    'Last Inspection Result',
                    style: TextStyle(
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
                    '${conf.toStringAsFixed(1)}% conf.',
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
                    subText: appState.liveLastLabel,
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
                  child: _ResultHalf(
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
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: _SizeScaleBar(current: sz),
          ),
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
    return Row(
      children: <Widget>[
        Expanded(
          child: _CountTile(
            label: 'Good',
            value: appState.liveGoodEggs,
            icon: Icons.check_circle_outline_rounded,
            accent: _DashboardPalette.success,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _CountTile(
            label: 'Cracked',
            value: appState.liveCrackedEggs,
            icon: Icons.warning_amber_rounded,
            accent: _DashboardPalette.warning,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _CountTile(
            label: 'Dirty',
            value: appState.liveDirtyEggs,
            icon: Icons.do_not_disturb_on_outlined,
            accent: _DashboardPalette.danger,
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
            'IOT SCALE (FIRESTORE)',
            style: TextStyle(
              color: _DashboardPalette.mutedForeground,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          if (readings.isEmpty)
            const Text(
              'Waiting for ESP32-CAM weight posts to egg_readings…',
              style: TextStyle(color: _DashboardPalette.mutedForeground),
            )
          else
            ...readings.take(8).map(
              (IotEggReading reading) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.egg, color: Color(0xFFE4A11B), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${reading.grade}  •  ${reading.weightGrams.toStringAsFixed(1)} g',
                        style: const TextStyle(
                          color: _DashboardPalette.foreground,
                          fontWeight: FontWeight.w700,
                        ),
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
              ),
            ),
        ],
      ),
    );
  }
}

String _formatIotTime(DateTime time) {
  final DateTime local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
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

// ═══════════════════════════════════════════════════════════════════════════
// WORKER DASHBOARD PANELS
// ═══════════════════════════════════════════════════════════════════════════

/// The main worker panel — four fully-functional cards driven by AppState.
class _WorkerDashboardPanels extends StatelessWidget {
  const _WorkerDashboardPanels({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool twoCol = constraints.maxWidth >= 820;
        final double w = twoCol
            ? (constraints.maxWidth - 16) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: <Widget>[
            SizedBox(
              width: w,
              child: _WorkerTaskCard(appState: appState),
            ),
            SizedBox(
              width: w,
              child: _WorkerSubmissionCard(appState: appState),
            ),
            SizedBox(
              width: w,
              child: _WorkerNotificationCard(appState: appState),
            ),
            SizedBox(
              width: w,
              child: _WorkerActivityCard(appState: appState),
            ),
          ],
        );
      },
    );
  }
}

// ── Pending Tasks card ─────────────────────────────────────────────────────

class _WorkerTaskCard extends StatelessWidget {
  const _WorkerTaskCard({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final int pending = appState.workerPendingTaskCount;
    return _GlassSection(
      titleIcon: Icons.checklist_rounded,
      title: 'Pending Tasks',
      trailing: pending > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _DashboardPalette.warning.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$pending left',
                style: const TextStyle(
                  color: _DashboardPalette.warning,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _DashboardPalette.success.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'All done',
                style: TextStyle(
                  color: _DashboardPalette.success,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
      child: Column(
        children: appState.workerTasks.entries
            .map(
              (MapEntry<String, bool> entry) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _WorkerTaskTile(
                  label: entry.key,
                  done: entry.value,
                  onToggle: () => appState.toggleWorkerTask(entry.key),
                  onNavigate: () {
                    final String route =
                        entry.key.toLowerCase().contains('grad') ||
                            entry.key.toLowerCase().contains('damaged')
                        ? AppPaths.grading
                        : AppPaths.production;
                    Navigator.of(context).pushReplacementNamed(route);
                  },
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _WorkerTaskTile extends StatelessWidget {
  const _WorkerTaskTile({
    required this.label,
    required this.done,
    required this.onToggle,
    required this.onNavigate,
  });

  final String label;
  final bool done;
  final VoidCallback onToggle;
  final VoidCallback onNavigate;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onNavigate,
        borderRadius: BorderRadius.circular(14),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: done
                ? _DashboardPalette.success.withValues(alpha: 0.07)
                : _DashboardPalette.tabBackground,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: done
                  ? _DashboardPalette.success.withValues(alpha: 0.35)
                  : _DashboardPalette.glassBorder,
            ),
          ),
          child: Row(
            children: <Widget>[
              // Tap the checkbox to toggle done; tap the row to navigate
              GestureDetector(
                onTap: onToggle,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: done
                        ? _DashboardPalette.success
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: done
                          ? _DashboardPalette.success
                          : _DashboardPalette.mutedForeground,
                      width: 1.5,
                    ),
                  ),
                  child: done
                      ? const Icon(
                          Icons.check_rounded,
                          size: 15,
                          color: Colors.black,
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    color: done
                        ? _DashboardPalette.mutedForeground
                        : _DashboardPalette.foreground,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: done ? TextDecoration.lineThrough : null,
                    decorationColor: _DashboardPalette.mutedForeground,
                  ),
                ),
              ),
              Icon(
                Icons.arrow_forward_ios_rounded,
                size: 13,
                color: done
                    ? _DashboardPalette.mutedForeground.withValues(alpha: 0.4)
                    : _DashboardPalette.mutedForeground,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Submission Status card ─────────────────────────────────────────────────

class _WorkerSubmissionCard extends StatelessWidget {
  const _WorkerSubmissionCard({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final int submitted = appState.workerSubmissions.values
        .where((bool v) => v)
        .length;
    final int total = appState.workerSubmissions.length;

    return _GlassSection(
      titleIcon: Icons.assignment_turned_in_outlined,
      title: 'Submission Status',
      trailing: Text(
        '$submitted / $total submitted',
        style: TextStyle(
          color: submitted == total
              ? _DashboardPalette.success
              : _DashboardPalette.mutedForeground,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: Column(
        children: <Widget>[
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: submitted / total,
              minHeight: 6,
              backgroundColor: _DashboardPalette.glassBorder,
              valueColor: const AlwaysStoppedAnimation<Color>(
                _DashboardPalette.success,
              ),
            ),
          ),
          const SizedBox(height: 14),
          ...appState.workerSubmissions.entries.map(
            (MapEntry<String, bool> entry) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _WorkerSubmissionTile(
                label: entry.key,
                submitted: entry.value,
                onSubmit: entry.value
                    ? null
                    : () => appState.markSubmitted(entry.key),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkerSubmissionTile extends StatelessWidget {
  const _WorkerSubmissionTile({
    required this.label,
    required this.submitted,
    required this.onSubmit,
  });

  final String label;
  final bool submitted;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: submitted
            ? _DashboardPalette.success.withValues(alpha: 0.07)
            : _DashboardPalette.tabBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: submitted
              ? _DashboardPalette.success.withValues(alpha: 0.30)
              : _DashboardPalette.glassBorder,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            submitted
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            color: submitted
                ? _DashboardPalette.success
                : _DashboardPalette.mutedForeground,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: submitted
                    ? _DashboardPalette.mutedForeground
                    : _DashboardPalette.foreground,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (!submitted)
            TextButton(
              onPressed: onSubmit,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                backgroundColor: _DashboardPalette.primary.withValues(
                  alpha: 0.12,
                ),
                foregroundColor: _DashboardPalette.primary,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'Submit',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _DashboardPalette.success.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Done',
                style: TextStyle(
                  color: _DashboardPalette.success,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
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
      child: Column(
        children: appState.workerNotifications
            .map(
              (WorkerNotification n) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _WorkerNotificationTile(notification: n),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _WorkerNotificationTile extends StatelessWidget {
  const _WorkerNotificationTile({required this.notification});

  final WorkerNotification notification;

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
    return AnimatedContainer(
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
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}

// ── Recent Activity card ───────────────────────────────────────────────────

class _WorkerActivityCard extends StatelessWidget {
  const _WorkerActivityCard({required this.appState});

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final List<WorkerActivity> items = appState.workerActivities.length > 5
        ? appState.workerActivities.sublist(0, 5)
        : appState.workerActivities;

    return _GlassSection(
      titleIcon: Icons.timeline_rounded,
      title: 'Recent Activity',
      child: Column(
        children: items
            .asMap()
            .entries
            .map(
              (MapEntry<int, WorkerActivity> entry) => Padding(
                padding: const EdgeInsets.only(bottom: 0),
                child: _WorkerActivityTile(
                  activity: entry.value,
                  isLast: entry.key == items.length - 1,
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _WorkerActivityTile extends StatelessWidget {
  const _WorkerActivityTile({required this.activity, required this.isLast});

  final WorkerActivity activity;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // Timeline spine
          SizedBox(
            width: 32,
            child: Column(
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: _DashboardPalette.primary.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    activity.icon,
                    size: 14,
                    color: _DashboardPalette.primary,
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      color: _DashboardPalette.glassBorder,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: 4),
                  Text(
                    activity.message,
                    style: const TextStyle(
                      color: _DashboardPalette.foreground,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    activity.time,
                    style: const TextStyle(
                      color: _DashboardPalette.mutedForeground,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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

class _SimpleLineChart extends StatelessWidget {
  const _SimpleLineChart({required this.data});

  final List<_SeriesPoint> data;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 210,
      child: Column(
        children: <Widget>[
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _LineChartPainter(data: data),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: data.map((_SeriesPoint point) {
              return Text(
                point.label,
                style: const TextStyle(color: Color(0xFFB4A79A), fontSize: 11),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  _LineChartPainter({required this.data});

  final List<_SeriesPoint> data;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) {
      return;
    }

    final double maxVal = data
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

    for (int i = 0; i < points.length; i++) {
      final Offset pt = points[i];
      canvas.drawCircle(pt, 5, dotOuterPaint);
      canvas.drawCircle(pt, 2.5, dotInnerPaint);

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

class _SalesLossChart extends StatelessWidget {
  const _SalesLossChart({required this.data});

  final List<_SalesLossPoint> data;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const SizedBox(
        height: 220,
        child: Center(
          child: Text(
            'No sales yet',
            style: TextStyle(color: _DashboardPalette.mutedForeground),
          ),
        ),
      );
    }
    final double maxValue = data
        .map((point) => point.sales.toDouble())
        .reduce((double a, double b) => a > b ? a : b);

    return SizedBox(
      height: 220,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: data
            .map(
              (_SalesLossPoint point) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              _MiniBar(
                                heightFactor: point.sales / maxValue,
                                color: _DashboardPalette.primary,
                              ),
                              const SizedBox(width: 6),
                              _MiniBar(
                                heightFactor: point.losses / 45,
                                color: _DashboardPalette.danger,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        point.label,
                        style: const TextStyle(
                          color: _DashboardPalette.mutedForeground,
                          fontSize: 11,
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

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert});

  final AlertMessage alert;

  @override
  Widget build(BuildContext context) {
    final bool high = alert.severity == 'high';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _DashboardPalette.tabBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _DashboardPalette.glassBorder),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            high ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            color: high ? _DashboardPalette.danger : _DashboardPalette.warning,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              alert.title,
              style: const TextStyle(color: _DashboardPalette.foreground),
            ),
          ),
        ],
      ),
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
