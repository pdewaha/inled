import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:exled/supabase_config.dart';
import 'package:exled/theme.dart';
import 'package:exled/widgets/debug_menu_button.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthWelcomeScreen extends StatelessWidget {
  const AuthWelcomeScreen({
    super.key,
    required this.onThemeVariantChanged,
  });

  final ValueChanged<AppThemeVariant> onThemeVariantChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          supabaseIsLeamDevHost ? 'exled · dev' : 'exled',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          const DebugMenuButton(),
          MenuAnchor(
            menuChildren: [
              for (final v in AppThemeVariant.values)
                MenuItemButton(
                  onPressed: () => onThemeVariantChanged(v),
                  leadingIcon: Icon(_iconFor(v)),
                  child: Text(_labelFor(v)),
                ),
            ],
            builder: (context, controller, child) {
              return IconButton(
                tooltip: 'Theme',
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.palette_outlined),
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Welcome to exled',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'exled helps teams turn day-to-day commitments into a visible, '
                      'living expectations ledger. We capture promises, tag owners, '
                      'track progress, and keep accountability transparent across the '
                      'organization.',
                      style: theme.textTheme.bodyLarge?.copyWith(height: 1.4),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Core ideas behind the application:',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const _IdeaBullet(
                      text:
                          'Shared clarity: everyone can see what was agreed and by whom.',
                    ),
                    const _IdeaBullet(
                      text:
                          'Fast capture: commitments are logged immediately while context is fresh.',
                    ),
                    const _IdeaBullet(
                      text:
                          'Follow-through: expectations stay visible until resolved.',
                    ),
                    const _IdeaBullet(
                      text:
                          'Trust by design: lightweight, auditable communication over hidden chat threads.',
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => _showLoginDialog(context),
                      icon: const Icon(Icons.login),
                      label: const Text('Login'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showLoginDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _LoginOtpDialog(),
    );
  }
}

class _LoginOtpDialog extends StatefulWidget {
  const _LoginOtpDialog();

  @override
  State<_LoginOtpDialog> createState() => _LoginOtpDialogState();
}

class _LoginOtpDialogState extends State<_LoginOtpDialog> {
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _otpFocusNode = FocusNode(debugLabel: 'loginOtp');
  final _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  String? _emailError;
  String? _otpError;
  String? _email;
  bool _awaitingOtp = false;
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _otpFocusNode.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (!_emailRegex.hasMatch(email)) {
      setState(() {
        _emailError = 'Please enter a valid email address.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _emailError = null;
      _otpError = null;
    });

    try {
      await Supabase.instance.client.auth.signInWithOtp(email: email);
      if (!mounted) return;
      setState(() {
        _awaitingOtp = true;
        _email = email;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_awaitingOtp) return;
        _otpFocusNode.requestFocus();
      });
    } catch (e) {
      if (!mounted) return;
      final friendly = _formatAuthError(e, action: 'send OTP');
      setState(() {
        _emailError = friendly;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _verifyOtp() async {
    final token = _otpController.text.trim();
    if (token.length < 6) {
      setState(() {
        _otpError = 'Please enter the 6-digit OTP code.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _otpError = null;
    });

    try {
      await Supabase.instance.client.auth.verifyOTP(
        type: OtpType.email,
        email: _email!,
        token: token,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final friendly = _formatAuthError(e, action: 'verify OTP');
      setState(() {
        _otpError = friendly;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _formatAuthError(Object e, {required String action}) {
    final raw = e.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('failed to fetch') ||
        lower.contains('network') ||
        lower.contains('connection') ||
        lower.contains('cors')) {
      final host = Uri.tryParse(supabaseUrl)?.host ?? supabaseUrl;
      if (kIsWeb) {
        return 'Could not $action due to a network/CORS issue.\n'
            'This app is calling $host from the browser. On localhost, that '
            'server must allow your page origin (e.g. http://localhost:8080) in '
            'Supabase Auth URL settings and API gateway CORS.\n'
            'Or run on Windows desktop (`flutter run -d windows`), or use '
            '`--dart-define=SUPABASE_URL=...` for another backend.\n'
            'Details: $raw';
      }
      return 'Could not $action due to a network/CORS issue.\n'
          'Please verify $host is reachable and auth endpoints allow this app.\n'
          'Details: $raw';
    }
    if (lower.contains('smtp') ||
        lower.contains('email not confirmed') ||
        lower.contains('mailer') ||
        lower.contains('email rate limit')) {
      return 'Could not $action because email auth appears misconfigured or limited.\n'
          'Check Supabase Auth email provider/SMTP settings and rate limits.\n'
          'Details: $raw';
    }
    return 'Could not $action.\nDetails: $raw';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_awaitingOtp ? 'Enter OTP' : 'Login'),
      content: SizedBox(
        width: 420,
        child: _awaitingOtp ? _buildOtpStep() : _buildEmailStep(),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _loading ? null : (_awaitingOtp ? _verifyOtp : _sendOtp),
          child: Text(_awaitingOtp ? 'Confirm OTP' : 'Send OTP'),
        ),
      ],
    );
  }

  Widget _buildEmailStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Enter your email to receive a one-time password and start your session.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _emailController,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: 'Email',
            hintText: 'name@company.com',
          ),
          onSubmitted: (_) {
            if (!_loading) {
              _sendOtp();
            }
          },
        ),
        if (_emailError != null) ...[
          const SizedBox(height: 10),
          Text(
            _emailError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildOtpStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'We sent an OTP to $_email. Enter it below to complete sign in.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _otpController,
          focusNode: _otpFocusNode,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'OTP code',
            hintText: '6-digit code',
          ),
          onSubmitted: (_) {
            if (!_loading) {
              _verifyOtp();
            }
          },
        ),
        if (_otpError != null) ...[
          const SizedBox(height: 10),
          Text(
            _otpError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}

class _IdeaBullet extends StatelessWidget {
  const _IdeaBullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(
              Icons.check_circle_outline,
              size: 18,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

IconData _iconFor(AppThemeVariant v) => switch (v) {
      AppThemeVariant.light => Icons.light_mode_outlined,
      AppThemeVariant.dark => Icons.dark_mode_outlined,
    };

String _labelFor(AppThemeVariant v) => switch (v) {
      AppThemeVariant.light => 'Light',
      AppThemeVariant.dark => 'Dark',
    };
