import 'package:flutter/material.dart';
import 'package:exled/screens/ledger_console_screen.dart';
import 'package:exled/theme.dart';
import 'package:exled/widgets/debug_menu_button.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CompanyOnboardingGate extends StatefulWidget {
  const CompanyOnboardingGate({
    super.key,
    required this.onThemeVariantChanged,
  });

  final ValueChanged<AppThemeVariant> onThemeVariantChanged;

  @override
  State<CompanyOnboardingGate> createState() => _CompanyOnboardingGateState();
}

enum _OnboardingState {
  loading,
  needsJoin,
  needsCreate,
  ready,
  error,
}

class _CompanyOnboardingGateState extends State<CompanyOnboardingGate> {
  final _companyNameController = TextEditingController();
  final _titleController = TextEditingController();
  final _domainController = TextEditingController();

  _OnboardingState _state = _OnboardingState.loading;
  String? _error;
  Map<String, dynamic>? _matchedCompany;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _companyNameController.dispose();
    _titleController.dispose();
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      if (!mounted) return;
      setState(() {
        _state = _OnboardingState.error;
        _error = 'No authenticated user found.';
      });
      return;
    }
    final email = user.email?.trim();
    if (email == null || !email.contains('@')) {
      if (!mounted) return;
      setState(() {
        _state = _OnboardingState.error;
        _error = 'Signed-in user has no valid email.';
      });
      return;
    }
    final domain = email.split('@').last.toLowerCase();
    final localPart = email.split('@').first;
    _domainController.text = domain;
    if (_titleController.text.trim().isEmpty) {
      _titleController.text = 'Founder';
    }

    try {
      final linkedPeopleRows = await client
          .from('people')
          .select('id')
          .eq('auth_user_id', user.id)
          .limit(1);

      if ((linkedPeopleRows as List).isNotEmpty) {
        if (!mounted) return;
        setState(() => _state = _OnboardingState.ready);
        return;
      }

      final companyRows = await client
          .from('companies')
          .select('id,name,domain')
          .eq('domain', domain)
          .limit(1);

      if ((companyRows as List).isNotEmpty) {
        if (!mounted) return;
        _companyNameController.text =
            (companyRows.first['name'] as String?) ?? localPart;
        setState(() {
          _matchedCompany = Map<String, dynamic>.from(companyRows.first);
          _state = _OnboardingState.needsJoin;
        });
        return;
      }

      if (!mounted) return;
      setState(() => _state = _OnboardingState.needsCreate);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _OnboardingState.error;
        _error =
            'Could not load company onboarding data.\n'
            'Ensure tables "companies" and "people" exist and are readable.\n'
            'Details: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _OnboardingState.error;
        _error = 'Unexpected onboarding error: $e';
      });
    }
  }

  Future<void> _joinMatchedCompany() async {
    final user = Supabase.instance.client.auth.currentUser;
    final company = _matchedCompany;
    if (user == null || company == null) return;
    final companyId = company['id'] as String?;
    if (companyId == null) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _upsertPersonForCompany(companyId: companyId);
      if (!mounted) return;
      setState(() => _state = _OnboardingState.ready);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not join company space.\nDetails: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not join company space.\nDetails: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _createCompanyAndJoin() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final companyName = _companyNameController.text.trim();
    final title = _titleController.text.trim();
    final domain = _domainController.text.trim().toLowerCase();

    if (companyName.isEmpty) {
      setState(() => _error = 'Please enter the company name.');
      return;
    }
    if (domain.isEmpty || !domain.contains('.')) {
      setState(() => _error = 'Please enter a valid company email domain.');
      return;
    }
    if (title.isEmpty) {
      setState(() => _error = 'Please enter your title.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      String companyId;
      try {
        final inserted = await Supabase.instance.client
            .from('companies')
            .insert({
              'name': companyName,
              'domain': domain,
              'created_by': user.id,
              'title': title,
            })
            .select('id')
            .single();
        companyId = inserted['id'] as String;
      } on PostgrestException catch (_) {
        final existing = await Supabase.instance.client
            .from('companies')
            .select('id')
            .eq('domain', domain)
            .limit(1);
        if ((existing as List).isEmpty) rethrow;
        companyId = existing.first['id'] as String;
      }

      await _upsertPersonForCompany(
        companyId: companyId,
        title: title,
      );

      if (!mounted) return;
      setState(() => _state = _OnboardingState.ready);
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not create company space.\nDetails: ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not create company space.\nDetails: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _upsertPersonForCompany({
    required String companyId,
    String? title,
  }) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final email = (user.email ?? '').trim().toLowerCase();
    if (email.isEmpty) {
      throw Exception('Signed-in user has no email.');
    }
    final localPart = email.split('@').first;
    final defaultHandle =
        localPart.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '').toLowerCase();
    final displayName = localPart.isEmpty
        ? email
        : '${localPart[0].toUpperCase()}${localPart.substring(1)}';

    final existing = await Supabase.instance.client
        .from('people')
        .select('id')
        .eq('company_id', companyId)
        .eq('email', email)
        .limit(1);

    if ((existing as List).isNotEmpty) {
      final personId = existing.first['id'] as String;
      final updatePayload = <String, dynamic>{
        'auth_user_id': user.id,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
      final cleanedTitle = title?.trim();
      if (cleanedTitle != null && cleanedTitle.isNotEmpty) {
        updatePayload['title'] = cleanedTitle;
      }
      await Supabase.instance.client
          .from('people')
          .update(updatePayload)
          .eq('id', personId);
      return;
    }

    await Supabase.instance.client.from('people').insert({
      'company_id': companyId,
      'email': email,
      'display_name': displayName,
      'handle': defaultHandle.isEmpty ? 'user' : defaultHandle,
      'title': (title?.trim().isNotEmpty ?? false) ? title!.trim() : null,
      'auth_user_id': user.id,
      'role': 0,
      'status': 1,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _OnboardingState.ready) {
      return LedgerConsoleScreen(
        onThemeVariantChanged: widget.onThemeVariantChanged,
      );
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Company setup'),
        actions: const [DebugMenuButton(), SizedBox(width: 4)],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: switch (_state) {
                  _OnboardingState.loading => const _LoadingPanel(),
                  _OnboardingState.needsJoin => _JoinPanel(
                      company: _matchedCompany,
                      onJoin: _joinMatchedCompany,
                      saving: _saving,
                      error: _error,
                    ),
                  _OnboardingState.needsCreate => _CreatePanel(
                      domainController: _domainController,
                      companyNameController: _companyNameController,
                      titleController: _titleController,
                      onCreate: _createCompanyAndJoin,
                      saving: _saving,
                      error: _error,
                    ),
                  _OnboardingState.error => _ErrorPanel(
                      error: _error ?? 'Unknown onboarding error.',
                      onRetry: _bootstrap,
                    ),
                  _OnboardingState.ready => const SizedBox.shrink(),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingPanel extends StatelessWidget {
  const _LoadingPanel();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 14),
        Text('Checking your company workspace...'),
      ],
    );
  }
}

class _JoinPanel extends StatelessWidget {
  const _JoinPanel({
    required this.company,
    required this.onJoin,
    required this.saving,
    required this.error,
  });

  final Map<String, dynamic>? company;
  final VoidCallback onJoin;
  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final name = company?['name']?.toString() ?? 'your company';
    final domain = company?['domain']?.toString() ?? 'your domain';
    final errColor = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Company workspace found',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        Text(
          'We found an existing workspace for @$domain: "$name".\n'
          'Join this workspace to continue.',
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: TextStyle(color: errColor)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: saving ? null : onJoin,
          child: Text(saving ? 'Joining...' : 'Join workspace'),
        ),
      ],
    );
  }
}

class _CreatePanel extends StatelessWidget {
  const _CreatePanel({
    required this.domainController,
    required this.companyNameController,
    required this.titleController,
    required this.onCreate,
    required this.saving,
    required this.error,
  });

  final TextEditingController domainController;
  final TextEditingController companyNameController;
  final TextEditingController titleController;
  final VoidCallback onCreate;
  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final errColor = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Create your company workspace',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        Text(
          'Is "@${domainController.text}" your company email domain?\n'
          'Set the company name and create the workspace. '
          'From then on, users signing in with this domain will join this space.',
        ),
        const SizedBox(height: 14),
        TextField(
          controller: domainController,
          decoration: const InputDecoration(
            labelText: 'Company email domain',
            hintText: 'example.com',
          ),
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: companyNameController,
          decoration: const InputDecoration(
            labelText: 'Company name',
            hintText: 'CMCM',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: titleController,
          decoration: const InputDecoration(
            labelText: 'Your title',
            hintText: 'Founder / CTO / Team Lead',
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!, style: TextStyle(color: errColor)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: saving ? null : onCreate,
          child: Text(saving ? 'Creating...' : 'Create workspace'),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({
    required this.error,
    required this.onRetry,
  });

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final errColor = Theme.of(context).colorScheme.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Company setup error',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        Text(error, style: TextStyle(color: errColor)),
        const SizedBox(height: 16),
        FilledButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
