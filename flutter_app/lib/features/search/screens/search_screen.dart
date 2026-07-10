import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/search_providers.dart';
import '../models/profile_search_result.dart';
import '../../../core/widgets/settings_menu_button.dart';
import '../../../core/widgets/n_back_button.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const NBackButton(fallback: '/home'),
        title: const Text('Search'),
        actions: const [SettingsMenuButton()],
      ),
      body: Column(
        children: [
          // ── Search bar ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                hintText: 'Search creators and celebrities…',
                hintStyle: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 15),
                prefixIcon: const Icon(Icons.search,
                    color: AppTheme.textSecondary, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear,
                            color: AppTheme.textSecondary, size: 18),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: AppTheme.surface,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide:
                      const BorderSide(color: AppTheme.primary, width: 2),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 14),
              ),
            ),
          ),

          // ── Results ───────────────────────────────────────────────────
          Expanded(
            child: _query.length < 2
                ? const _EmptyHint()
                : _SearchResults(query: _query),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESULTS
// ─────────────────────────────────────────────────────────────────────────────

class _SearchResults extends ConsumerWidget {
  final String query;
  const _SearchResults({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resultsAsync = ref.watch(searchAllProvider(query));

    return resultsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(
            color: AppTheme.primary, strokeWidth: 2),
      ),
      error: (_, __) => const Center(
        child: Text('Search failed — try again',
            style: TextStyle(color: AppTheme.textSecondary)),
      ),
      data: (results) {
        if (results.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_search_outlined,
                    size: 48, color: AppTheme.textSecondary),
                const SizedBox(height: 16),
                const Text(
                  'No results found',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Try a different name or username',
                  style: TextStyle(
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                      fontSize: 13),
                ),
              ],
            ),
          );
        }

        final celebs = results
            .where((r) => r.kind == SearchResultKind.celebrity)
            .toList();
        final users = results
            .where((r) => r.kind == SearchResultKind.user)
            .toList();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            if (celebs.isNotEmpty) ...[
              _SectionHeader(label: 'CELEBRITIES', count: celebs.length),
              ...celebs.map((r) => _ResultRow(result: r)),
            ],
            if (users.isNotEmpty) ...[
              if (celebs.isNotEmpty) const SizedBox(height: 8),
              _SectionHeader(label: 'PEOPLE', count: users.length),
              ...users.map((r) => _ResultRow(result: r)),
            ],
          ],
        );
      },
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  const _SectionHeader({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textSecondary.withValues(alpha: 0.6),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: AppTheme.textSecondary.withValues(alpha: 0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Result row ────────────────────────────────────────────────────────────────

class _ResultRow extends StatelessWidget {
  final SearchResult result;
  const _ResultRow({required this.result});

  static Color _avatarColor(String seed) {
    const palette = [
      Color(0xFF6C63FF), Color(0xFF00C896), Color(0xFFFF6B35),
      Color(0xFFEE1D52), Color(0xFF9146FF), Color(0xFFFFD700),
      Color(0xFF00BCD4), Color(0xFF9C27B0), Color(0xFF3F51B5),
      Color(0xFFFF8F00), Color(0xFF8BC34A), Color(0xFF009688),
    ];
    final index = seed.codeUnits.fold(0, (sum, c) => sum + c) % palette.length;
    return palette[index];
  }

  static String _initials(String name) {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.length >= 2) return '${words[0][0]}${words[1][0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  bool get _isCeleb => result.kind == SearchResultKind.celebrity;

  void _navigate(BuildContext context) {
    if (_isCeleb) {
      context.push('/news/${result.id}');
    } else {
      context.push('/u/${result.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor(result.name);
    final initials = _initials(result.name);
    final accentColor =
        _isCeleb ? AppTheme.secondary : AppTheme.primary;

    return InkWell(
      onTap: () => _navigate(context),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(
                    color: color.withValues(alpha: 0.4), width: 1.5),
              ),
              child: Center(
                child: Text(
                  initials,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),

            // Name + tags
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isCeleb ? result.name : '@${result.name}',
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      _Tag(
                        label: _isCeleb ? 'Celebrity' : 'Creator',
                        color: accentColor,
                      ),
                      if (result.category != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          result.category!,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      if (!_isCeleb && result.subcategory != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          result.subcategory!,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: AppTheme.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EMPTY HINT (< 2 characters typed)
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.manage_search_outlined,
              size: 56, color: AppTheme.textSecondary),
          const SizedBox(height: 16),
          const Text(
            'Search creators and celebrities',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Type at least 2 characters',
            style: TextStyle(
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
