import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:exled/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Debug-only AppBar menu (API host, quick tests). Hidden in release builds.
class DebugMenuButton extends StatelessWidget {
  const DebugMenuButton({
    super.key,
    this.onReloadExpectations,
    this.activityUnreadCount,
  });

  /// Ledger: reload expectations + refresh activity snapshot.
  final Future<void> Function()? onReloadExpectations;

  /// Shown in menu when provided.
  final int? activityUnreadCount;

  static bool get enabled => kDebugMode;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();

    return MenuAnchor(
      menuChildren: _menuChildren(context),
      builder: (context, controller, child) {
        return IconButton(
          tooltip: 'Debug',
          onPressed: () =>
              controller.isOpen ? controller.close() : controller.open(),
          icon: Icon(
            Icons.bug_report_outlined,
            color: Theme.of(context).colorScheme.tertiary,
          ),
        );
      },
    );
  }

  List<Widget> _menuChildren(BuildContext context) {
    final host = Uri.tryParse(supabaseUrl)?.host ?? supabaseUrl;
    final backend = debugSupabaseBackend;
    final canSwitchBackend = debugSupabaseBackendSwitchEnabled;

    return [
      MenuItemButton(
        onPressed: null,
        child: Text(
          'API: $host',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (canSwitchBackend) ...[
        _backendItem(
          context,
          label: 'Dev · ${Uri.parse(supabaseDevUrl).host}',
          value: SupabaseBackend.dev,
          selected: backend == SupabaseBackend.dev,
        ),
        _backendItem(
          context,
          label: 'Prod · ${Uri.parse(supabaseProdUrl).host}',
          value: SupabaseBackend.prod,
          selected: backend == SupabaseBackend.prod,
        ),
      ] else
        MenuItemButton(
          onPressed: null,
          child: Text(
            'Backend pinned (SUPABASE_URL define)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      const Divider(),
      MenuItemButton(
        onPressed: () => _copyText(context, supabaseUrl, 'API URL'),
        leadingIcon: const Icon(Icons.link, size: 20),
        child: const Text('Copy API URL'),
      ),
      MenuItemButton(
        onPressed: () => unawaited(_showConnectionInfo(context)),
        leadingIcon: const Icon(Icons.info_outline, size: 20),
        child: const Text('Connection info…'),
      ),
      const Divider(),
      MenuItemButton(
        onPressed: () => unawaited(_pingDatabase(context)),
        leadingIcon: const Icon(Icons.wifi_tethering, size: 20),
        child: const Text('Ping database'),
      ),
      MenuItemButton(
        onPressed: () => unawaited(_sendTestSmtpEmail(context)),
        leadingIcon: const Icon(Icons.outgoing_mail, size: 20),
        child: const Text('Send test SMTP email…'),
      ),
      MenuItemButton(
        onPressed: () => unawaited(_drainActivityEmails(context)),
        leadingIcon: const Icon(Icons.mail_outline, size: 20),
        child: const Text('Send pending activity emails'),
      ),
      if (onReloadExpectations != null) ...[
        const Divider(),
        if (activityUnreadCount != null)
          MenuItemButton(
            onPressed: null,
            child: Text('Activity bell unread: $activityUnreadCount'),
          ),
        MenuItemButton(
          onPressed: () => unawaited(_reloadLedger(context)),
          leadingIcon: const Icon(Icons.refresh, size: 20),
          child: const Text('Reload expectations'),
        ),
      ],
    ];
  }

  MenuItemButton _backendItem(
    BuildContext context, {
    required String label,
    required SupabaseBackend value,
    required bool selected,
  }) {
    return MenuItemButton(
      onPressed: selected
          ? null
          : () => unawaited(_switchBackend(context, value)),
      leadingIcon: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 20,
      ),
      child: Text(label),
    );
  }

  Future<void> _switchBackend(BuildContext context, SupabaseBackend next) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await switchDebugSupabaseBackend(next);
      final newHost = Uri.tryParse(supabaseUrl)?.host ?? supabaseUrl;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Switched to ${supabaseBackendShortLabel(next)} ($newHost). Sign in again.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not switch backend: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  String get host => Uri.tryParse(supabaseUrl)?.host ?? supabaseUrl;

  Future<void> _reloadLedger(BuildContext context) async {
    final reload = onReloadExpectations;
    if (reload == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await reload();
      if (!context.mounted) return;
      messenger?.showSnackBar(
        const SnackBar(content: Text('Expectations reloaded.')),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger?.showSnackBar(
        SnackBar(content: Text('Reload failed: $e')),
      );
    }
  }

  static void _copyText(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  static Future<void> _showConnectionInfo(BuildContext context) async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    String? personLine;
    if (user != null) {
      try {
        final rows = await client
            .from('people')
            .select('id,handle,email')
            .eq('auth_user_id', user.id)
            .limit(1);
        if ((rows as List).isNotEmpty) {
          final p = rows.first as Map<String, dynamic>;
          final handle = (p['handle'] as String?) ?? '';
          final email = (p['email'] as String?) ?? '';
          personLine =
              'person ${p['id']}\n@$handle${email.isNotEmpty ? '\n$email' : ''}';
        }
      } catch (_) {}
    }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Debug connection'),
        content: SelectableText(
          [
            'URL: $supabaseUrl',
            'Backend: ${supabaseBackendShortLabel(debugSupabaseBackend)}',
            if (user != null) 'auth: ${user.id}',
            if (personLine != null) personLine,
          ].join('\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static Future<void> _pingDatabase(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await Supabase.instance.client.from('people').select('id').limit(1);
      messenger?.showSnackBar(
        const SnackBar(content: Text('Database reachable.')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Ping failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  static const String _defaultTestEmail = 'pdewaha@gmail.com';

  static Future<void> _sendTestSmtpEmail(BuildContext context) async {
    final controller = TextEditingController(text: _defaultTestEmail);
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test SMTP email'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Recipient',
            hintText: 'email@example.com',
          ),
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (email == null || email.isEmpty) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Sending test email (may take up to ~60s)…'),
        duration: Duration(seconds: 90),
      ),
    );

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'send-activity-email',
        body: {'test_email': email},
      );
      final data = res.data;
      final sent = data is Map && data['sent'] == true;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            sent
                ? 'Test email sent to $email. Check inbox/spam.'
                : data == null
                    ? 'Test email request finished.'
                    : '$data',
          ),
          duration: const Duration(seconds: 8),
        ),
      );
    } on FunctionException catch (e) {
      final details = '${e.details ?? e.reasonPhrase}';
      final hint = details.contains('test_email disabled') ||
              details.contains('ALLOW_DEBUG_TEST_EMAIL')
          ? ' Set ALLOW_DEBUG_TEST_EMAIL=true on functions service.'
          : e.status == 502 ||
                  details.contains('upstream') ||
                  details.contains('invalid response')
              ? ' SMTP hung or worker crashed. On beacon: docker compose logs functions --tail 80'
              : details.contains('timed out')
                  ? ' SMTP timeout — check functions SMTP_* env matches GoTrue.'
                  : '';
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Test email failed (${e.status}): $details$hint',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Test email failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  static Future<void> _drainActivityEmails(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'send-activity-email',
        body: {'process_pending': true, 'limit': 20},
      );
      final data = res.data;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            data == null
                ? 'Activity email function returned.'
                : '$data',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } on FunctionException catch (e) {
      final details = '${e.details ?? e.reasonPhrase}';
      final hint = details.contains('entrypoint') ||
              details.contains('InvalidWorkerCreation')
          ? ' On beacon: bash scripts/setup-beacon-edge-functions.sh (needs main/ + send-activity-email/).'
          : details.contains('name resolution')
              ? ' Set functions env: SUPABASE_URL=http://kong:8000, SMTP_* (same as GoTrue). Test ?health=1'
              : details.contains('SMTP')
                  ? ' Copy GOTRUE_SMTP_* into the functions container env.'
                  : '';
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Activity email failed (${e.status}): $details$hint',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
          duration: const Duration(seconds: 8),
        ),
      );
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Activity email failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }
}
