/// Derive a human-readable company label from an email domain (without TLD).
///
/// Examples: `tauworks.org` → `Tauworks`, `mail.acme.com` → `Acme`,
/// `acme.co.uk` → `Acme`.
String companyNameFromEmailDomain(String domain) {
  final normalized = domain.trim().toLowerCase();
  if (normalized.isEmpty) return '';

  final parts = normalized.split('.').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  if (parts.length == 1) return _titleCaseSlug(parts.first);

  const twoPartSuffixes = <String>{
    'co.uk',
    'org.uk',
    'ac.uk',
    'gov.uk',
    'com.au',
    'net.au',
    'org.au',
    'co.nz',
    'co.za',
    'co.jp',
    'com.br',
    'com.mx',
  };

  if (parts.length >= 3) {
    final suffix = '${parts[parts.length - 2]}.${parts[parts.length - 1]}';
    if (twoPartSuffixes.contains(suffix)) {
      return _titleCaseSlug(parts[parts.length - 3]);
    }
  }

  return _titleCaseSlug(parts[parts.length - 2]);
}

String _titleCaseSlug(String slug) {
  if (slug.isEmpty) return slug;
  return '${slug[0].toUpperCase()}${slug.substring(1)}';
}
