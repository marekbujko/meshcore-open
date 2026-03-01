import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

enum ContactSortOption { lastSeen, recentMessages, name }

enum ContactTypeFilter { all, favorites, users, repeaters, rooms }

class SortFilterMenuOption {
  final int value;
  final String label;
  final bool? checked;

  const SortFilterMenuOption({
    required this.value,
    required this.label,
    this.checked,
  });
}

class SortFilterMenuSection {
  final String title;
  final List<SortFilterMenuOption> options;

  const SortFilterMenuSection({required this.title, required this.options});
}

class SortFilterMenu extends StatelessWidget {
  final List<SortFilterMenuSection> sections;
  final ValueChanged<int> onSelected;
  final String tooltip;
  final Widget icon;

  const SortFilterMenu({
    super.key,
    required this.sections,
    required this.onSelected,
    required this.tooltip,
    this.icon = const Icon(Icons.filter_list_outlined),
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      icon: icon,
      tooltip: tooltip,
      onSelected: onSelected,
      itemBuilder: (context) {
        final theme = Theme.of(context);
        final labelStyle = theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        );
        final visibleSections = sections
            .where((section) => section.options.isNotEmpty)
            .toList();
        final entries = <PopupMenuEntry<int>>[];
        for (int i = 0; i < visibleSections.length; i++) {
          final section = visibleSections[i];
          entries.add(
            PopupMenuItem<int>(
              enabled: false,
              child: Text(section.title, style: labelStyle),
            ),
          );
          for (final option in section.options) {
            if (option.checked == null) {
              entries.add(
                PopupMenuItem<int>(
                  value: option.value,
                  child: Text(option.label),
                ),
              );
            } else {
              entries.add(
                CheckedPopupMenuItem<int>(
                  value: option.value,
                  checked: option.checked ?? false,
                  child: Text(option.label),
                ),
              );
            }
          }
          if (i < visibleSections.length - 1) {
            entries.add(const PopupMenuDivider());
          }
        }
        return entries;
      },
    );
  }
}

const int _actionSortRecentMessages = 1;
const int _actionSortName = 2;
const int _actionSortLastSeen = 3;
const int _actionFilterAll = 4;
const int _actionFilterFavorites = 5;
const int _actionFilterUsers = 6;
const int _actionFilterRepeaters = 7;
const int _actionFilterRooms = 8;
const int _actionToggleUnreadOnly = 9;
const int _actionNewGroup = 10;

class ContactsFilterMenu extends StatelessWidget {
  final ContactSortOption sortOption;
  final ContactTypeFilter typeFilter;
  final bool showUnreadOnly;
  final ValueChanged<ContactSortOption> onSortChanged;
  final ValueChanged<ContactTypeFilter> onTypeFilterChanged;
  final ValueChanged<bool> onUnreadOnlyChanged;
  final VoidCallback onNewGroup;

  const ContactsFilterMenu({
    super.key,
    required this.sortOption,
    required this.typeFilter,
    required this.showUnreadOnly,
    required this.onSortChanged,
    required this.onTypeFilterChanged,
    required this.onUnreadOnlyChanged,
    required this.onNewGroup,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SortFilterMenu(
      tooltip: l10n.listFilter_tooltip,
      sections: [
        SortFilterMenuSection(
          title: l10n.listFilter_sortBy,
          options: [
            SortFilterMenuOption(
              value: _actionSortRecentMessages,
              label: l10n.listFilter_latestMessages,
              checked: sortOption == ContactSortOption.recentMessages,
            ),
            SortFilterMenuOption(
              value: _actionSortLastSeen,
              label: l10n.listFilter_heardRecently,
              checked: sortOption == ContactSortOption.lastSeen,
            ),
            SortFilterMenuOption(
              value: _actionSortName,
              label: l10n.listFilter_az,
              checked: sortOption == ContactSortOption.name,
            ),
          ],
        ),
        SortFilterMenuSection(
          title: l10n.listFilter_filters,
          options: [
            SortFilterMenuOption(
              value: _actionFilterAll,
              label: l10n.listFilter_all,
              checked: typeFilter == ContactTypeFilter.all,
            ),
            SortFilterMenuOption(
              value: _actionFilterFavorites,
              label: l10n.listFilter_favorites,
              checked: typeFilter == ContactTypeFilter.favorites,
            ),
            SortFilterMenuOption(
              value: _actionFilterUsers,
              label: l10n.listFilter_users,
              checked: typeFilter == ContactTypeFilter.users,
            ),
            SortFilterMenuOption(
              value: _actionFilterRepeaters,
              label: l10n.listFilter_repeaters,
              checked: typeFilter == ContactTypeFilter.repeaters,
            ),
            SortFilterMenuOption(
              value: _actionFilterRooms,
              label: l10n.listFilter_roomServers,
              checked: typeFilter == ContactTypeFilter.rooms,
            ),
            SortFilterMenuOption(
              value: _actionToggleUnreadOnly,
              label: l10n.listFilter_unreadOnly,
              checked: showUnreadOnly,
            ),
            SortFilterMenuOption(
              value: _actionNewGroup,
              label: l10n.listFilter_newGroup,
            ),
          ],
        ),
      ],
      onSelected: (action) {
        switch (action) {
          case _actionSortRecentMessages:
            onSortChanged(ContactSortOption.recentMessages);
            break;
          case _actionSortName:
            onSortChanged(ContactSortOption.name);
            break;
          case _actionSortLastSeen:
            onSortChanged(ContactSortOption.lastSeen);
            break;
          case _actionFilterAll:
            onTypeFilterChanged(ContactTypeFilter.all);
            break;
          case _actionFilterUsers:
            onTypeFilterChanged(ContactTypeFilter.users);
            break;
          case _actionFilterFavorites:
            onTypeFilterChanged(ContactTypeFilter.favorites);
            break;
          case _actionFilterRepeaters:
            onTypeFilterChanged(ContactTypeFilter.repeaters);
            break;
          case _actionFilterRooms:
            onTypeFilterChanged(ContactTypeFilter.rooms);
            break;
          case _actionToggleUnreadOnly:
            onUnreadOnlyChanged(!showUnreadOnly);
            break;
          case _actionNewGroup:
            onNewGroup();
            break;
        }
      },
    );
  }
}

class DiscoveryContactsFilterMenu extends StatelessWidget {
  final ContactSortOption sortOption;
  final ContactTypeFilter typeFilter;
  final ValueChanged<ContactSortOption> onSortChanged;
  final ValueChanged<ContactTypeFilter> onTypeFilterChanged;

  const DiscoveryContactsFilterMenu({
    super.key,
    required this.sortOption,
    required this.typeFilter,
    required this.onSortChanged,
    required this.onTypeFilterChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SortFilterMenu(
      tooltip: l10n.listFilter_tooltip,
      sections: [
        SortFilterMenuSection(
          title: l10n.listFilter_sortBy,
          options: [
            SortFilterMenuOption(
              value: _actionSortLastSeen,
              label: l10n.listFilter_heardRecently,
              checked: sortOption == ContactSortOption.lastSeen,
            ),
            SortFilterMenuOption(
              value: _actionSortName,
              label: l10n.listFilter_az,
              checked: sortOption == ContactSortOption.name,
            ),
          ],
        ),
        SortFilterMenuSection(
          title: l10n.listFilter_filters,
          options: [
            SortFilterMenuOption(
              value: _actionFilterAll,
              label: l10n.listFilter_all,
              checked: typeFilter == ContactTypeFilter.all,
            ),
            SortFilterMenuOption(
              value: _actionFilterUsers,
              label: l10n.listFilter_users,
              checked: typeFilter == ContactTypeFilter.users,
            ),
            SortFilterMenuOption(
              value: _actionFilterRepeaters,
              label: l10n.listFilter_repeaters,
              checked: typeFilter == ContactTypeFilter.repeaters,
            ),
            SortFilterMenuOption(
              value: _actionFilterRooms,
              label: l10n.listFilter_roomServers,
              checked: typeFilter == ContactTypeFilter.rooms,
            ),
          ],
        ),
      ],
      onSelected: (action) {
        switch (action) {
          case _actionSortName:
            onSortChanged(ContactSortOption.name);
            break;
          case _actionSortLastSeen:
            onSortChanged(ContactSortOption.lastSeen);
            break;
          case _actionFilterAll:
            onTypeFilterChanged(ContactTypeFilter.all);
            break;
          case _actionFilterUsers:
            onTypeFilterChanged(ContactTypeFilter.users);
            break;
          case _actionFilterFavorites:
            onTypeFilterChanged(ContactTypeFilter.favorites);
            break;
          case _actionFilterRepeaters:
            onTypeFilterChanged(ContactTypeFilter.repeaters);
            break;
          case _actionFilterRooms:
            onTypeFilterChanged(ContactTypeFilter.rooms);
            break;
        }
      },
    );
  }
}
