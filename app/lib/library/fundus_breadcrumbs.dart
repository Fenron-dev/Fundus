import 'package:flutter/material.dart';

/// A logical navigation segment used by the library shell.
///
/// Breadcrumbs describe the route the user took through Fundus (vault,
/// section, collection, work, chapter), not necessarily the physical path on
/// disk.  The physical path remains a detail/fact of the work.
@immutable
class FundusBreadcrumb {
  const FundusBreadcrumb({required this.label, this.onTap, this.icon});

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
}

/// Compact, horizontally scrollable breadcrumb navigation shared by desktop
/// and mobile.  The current segment is rendered as the active destination;
/// previous segments are actionable when an `onTap` callback is supplied.
class FundusBreadcrumbs extends StatelessWidget {
  const FundusBreadcrumbs({
    super.key,
    required this.items,
    this.onBack,
    this.onForward,
    this.compact = false,
  });

  final List<FundusBreadcrumb> items;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = theme.colorScheme.onSurface;
    final mutedColor = theme.colorScheme.onSurfaceVariant;
    final accentColor = theme.colorScheme.primary;
    return SizedBox(
      height: compact ? 30 : 34,
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Zurück',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, size: 18),
            ),
          if (onForward != null)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Vorwärts',
              onPressed: onForward,
              icon: const Icon(Icons.arrow_forward, size: 18),
            ),
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemCount: items.length,
              separatorBuilder: (_, index) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  Icons.chevron_right,
                  size: compact ? 14 : 16,
                  color: mutedColor,
                ),
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                final active = index == items.length - 1;
                final child = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (item.icon != null) ...[
                      Icon(
                        item.icon,
                        size: compact ? 14 : 16,
                        color: active ? accentColor : mutedColor,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: active ? activeColor : mutedColor,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                );
                return item.onTap == null || active
                    ? child
                    : InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: item.onTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: child,
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
