import 'package:flutter/material.dart';

import '../core/ui.dart';
import '../utils/model_file_role.dart';

class ModelFileFilter extends StatelessWidget {
  const ModelFileFilter(
      {super.key, required this.selected, required this.onChanged});

  final ModelFileKind? selected;
  final ValueChanged<ModelFileKind?> onChanged;

  @override
  Widget build(BuildContext context) => AppChips<ModelFileKind?>(
        items: [
          (null, 'All'),
          for (final kind in ModelFileKind.values) (kind, kind.label),
        ],
        selected: selected,
        onSelected: onChanged,
      );
}
