import 'package:flutter/material.dart';
import 'package:inled/models/expectation_visibility.dart';

class VisibilityGlyph extends StatelessWidget {
  const VisibilityGlyph({super.key, required this.visibility});

  final ExpectationVisibility visibility;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, String tip) = switch (visibility) {
      ExpectationVisibility.shadow => (
          Icons.nights_stay_outlined,
          'Shadow — not yet communicated',
        ),
      ExpectationVisibility.echo => (
          Icons.campaign_outlined,
          'Echo — handshake is on the record',
        ),
    };
    return Tooltip(
      message: tip,
      child: Icon(icon, size: 18, color: scheme.outline),
    );
  }
}
