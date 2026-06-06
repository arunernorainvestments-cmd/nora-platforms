import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/ubi_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ContributeScreen extends ConsumerStatefulWidget {
  const ContributeScreen({super.key});

  @override
  ConsumerState<ContributeScreen> createState() => _ContributeScreenState();
}

class _ContributeScreenState extends ConsumerState<ContributeScreen> {
  int _selectedCents = 1000; // $10 default
  bool _isRecurring = false;
  bool _isAnonymousDisplay = false;
  final _emailController = TextEditingController();
  bool _isSubmitting = false;

  final _amounts = [500, 1000, 2500, 5000, 10000, 25000];

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final isLoggedIn = Supabase.instance.client.auth.currentUser != null;
    if (!isLoggedIn && _emailController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your email for anonymous contributions.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final body = {
        'amount_usd_cents': _selectedCents,
        'is_recurring': _isRecurring,
        'is_anonymous_display': _isAnonymousDisplay,
        if (!isLoggedIn && _emailController.text.isNotEmpty)
          'contributor_email': _emailController.text.trim(),
      };

      await Supabase.instance.client.functions.invoke(
        'ubi-contribute',
        body: body,
      );

      if (!mounted) return;
      ref.invalidate(ubiPoolBalanceProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thank you for your contribution!')),
      );
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Contribution failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(ubiPoolConfigProvider);
    final isLoggedIn = Supabase.instance.client.auth.currentUser != null;
    final dollars = (_selectedCents / 100).toStringAsFixed(0);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Contribute',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: configAsync.when(
        data: (config) {
          if (!config.isOpenForContributions) {
            return const Center(
              child: Text('Contributions are temporarily paused.',
                  style: TextStyle(color: AppTheme.textSecondary)),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('How much would you like to contribute?',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _amounts.map((cents) {
                  final selected = cents == _selectedCents;
                  final label = '\$${(cents / 100).toStringAsFixed(0)}';
                  return ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) => setState(() => _selectedCents = cents),
                    backgroundColor: AppTheme.surface,
                    selectedColor: AppTheme.primary.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: selected ? AppTheme.primary : AppTheme.textSecondary,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: selected ? AppTheme.primary : AppTheme.cardBorder,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              SwitchListTile(
                value: _isRecurring,
                onChanged: (v) => setState(() => _isRecurring = v),
                title: const Text('Monthly recurring',
                    style: TextStyle(color: AppTheme.textPrimary)),
                subtitle: const Text('Automatically contribute each month',
                    style: TextStyle(color: AppTheme.textSecondary)),
                activeThumbColor: AppTheme.primary,
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                value: _isAnonymousDisplay,
                onChanged: (v) => setState(() => _isAnonymousDisplay = v),
                title: const Text('Keep my contribution anonymous',
                    style: TextStyle(color: AppTheme.textPrimary)),
                subtitle: const Text('Your name will not appear in the contributor list',
                    style: TextStyle(color: AppTheme.textSecondary)),
                activeThumbColor: AppTheme.primary,
                contentPadding: EdgeInsets.zero,
              ),
              if (!isLoggedIn) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _emailController,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Email (optional — for receipt)',
                    labelStyle: const TextStyle(color: AppTheme.textSecondary),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.cardBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppTheme.cardBorder),
                    ),
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
              ],
              const SizedBox(height: 24),
              if (config.isSimulated)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
                  ),
                  child: const Text(
                    'Simulated mode — no real money is collected. '
                    'Contributions go to the test pool balance.',
                    style: TextStyle(color: AppTheme.primary, fontSize: 12),
                  ),
                ),
              FilledButton(
                onPressed: _isSubmitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.secondary,
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 48),
                ),
                child: _isSubmitting
                    ? const CircularProgressIndicator(color: Colors.black)
                    : Text('Contribute \$$dollars',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              const SizedBox(height: 12),
              const Text(
                'Contributions are voluntary donations to a community mutual aid pool. '
                'They are not tax-deductible and have no guaranteed return.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: AppTheme.danger))),
      ),
    );
  }
}
