import 'package:latlong2/latlong.dart';

import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';

export 'contact_filter_types.dart';

bool matchesContactQuery(Contact contact, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;

  if (contact.name.toLowerCase().contains(normalizedQuery)) {
    return true;
  }

  final hexPrefix = _extractHexPrefix(normalizedQuery);
  if (hexPrefix == null) return false;

  return contact.publicKeyHex.toLowerCase().startsWith(hexPrefix);
}

bool matchesDiscoveryContactQuery(Contact contact, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  if (normalizedQuery.isEmpty) return true;

  if (contact.name.toLowerCase().contains(normalizedQuery)) {
    return true;
  }

  final hexPrefix = _extractHexPrefix(normalizedQuery);
  if (hexPrefix == null) return false;

  return contact.publicKeyHex.toLowerCase().startsWith(hexPrefix);
}

String? _extractHexPrefix(String query) {
  var cleaned = query;
  if (cleaned.startsWith('<')) {
    cleaned = cleaned.substring(1).replaceAll(">", "");
  }
  if (cleaned.startsWith('0x')) {
    cleaned = cleaned.substring(2);
  }
  cleaned = cleaned.replaceAll(' ', '');
  if (cleaned.length < 2) return null;
  if (!RegExp(r'^[0-9a-f]+$').hasMatch(cleaned)) return null;
  return cleaned;
}

Contact? getRepeaterPrefixMatchNearLocation(
  List<Contact> contacts,
  int pubkeyFirstByte, {
  LatLng? searchPoint,
  bool preferFavorites = false,
}) {
  final candidates = contacts
      .where(
        (c) =>
            c.publicKey.isNotEmpty &&
            c.publicKey.first == pubkeyFirstByte &&
            (c.type == advTypeRepeater || c.type == advTypeRoom),
      )
      .toList();

  if (candidates.isEmpty) return null;

  candidates.sort((a, b) {
    if (preferFavorites) {
      final favA = a.isFavorite ? 1 : 0;
      final favB = b.isFavorite ? 1 : 0;
      final favCompare = favB.compareTo(favA);
      if (favCompare != 0) return favCompare;
    }

    final seenCompare = b.lastSeen.compareTo(a.lastSeen);
    if (seenCompare != 0) return seenCompare;

    return a.publicKeyHex.compareTo(b.publicKeyHex);
  });

  if (searchPoint == null) {
    return candidates.first;
  }

  final distance = Distance();
  Contact best = candidates.first;
  var bestDistance = double.infinity;

  for (final c in candidates) {
    if (c.hasLocation) {
      final d = distance(searchPoint, LatLng(c.latitude!, c.longitude!));
      if (d < bestDistance) {
        bestDistance = d;
        best = c;
      }
    }
  }

  return best;
}
