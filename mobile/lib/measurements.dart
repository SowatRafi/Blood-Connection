// Keep one metric value for API/BMI calculations; unit selection changes presentation, never physiology.
import 'package:flutter/material.dart';

const heightUnits = {
  'cm': 'Centimetres (cm)',
  'm': 'Metres (m)',
  'ft_in': 'Feet & inches',
  'in': 'Inches (in)',
};
const weightUnits = {
  'kg': 'Kilograms (kg)',
  'lb': 'Pounds (lb)',
  'st_lb': 'Stone & pounds',
};
const poundsToKg = .45359237;

// Decimal commas are accepted as decimals; grouping separators are intentionally not inferred.
double? measurementNumber(String input) {
  final number = double.tryParse(input.trim().replaceAll(',', '.'));
  return number != null && number.isFinite ? number : null;
}

double? metricMeasurement(String unit, String first, [String second = '']) {
  final a = measurementNumber(first);
  if (a == null || a < 0) return null;
  final b = second.trim().isEmpty ? 0.0 : measurementNumber(second);
  if (unit == 'ft_in' || unit == 'st_lb') {
    final radix = unit == 'ft_in' ? 12 : 14;
    if (a != a.truncateToDouble() || b == null || b < 0 || b >= radix) {
      return null;
    }
  }
  final value = switch (unit) {
    'cm' || 'kg' => a,
    'm' => a * 100,
    'in' => a * 2.54,
    'ft_in' => (a * 12 + b!) * 2.54,
    'lb' => a * poundsToKg,
    'st_lb' => (a * 14 + b!) * poundsToKg,
    _ => double.nan,
  };
  return value.isFinite ? value : null;
}

// Two decimals keep conversions readable; the unchanged canonical value retains full precision.
String measurementText(double value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

(String, String) displayMeasurement(String unit, double? metric) {
  if (metric == null || !metric.isFinite) return ('', '');
  final total = switch (unit) {
    'm' => metric / 100,
    'in' || 'ft_in' => metric / 2.54,
    'lb' || 'st_lb' => metric / poundsToKg,
    _ => metric,
  };
  if (unit != 'ft_in' && unit != 'st_lb') return (measurementText(total), '');
  final radix = unit == 'ft_in' ? 12 : 14;
  var whole = (total / radix).floor();
  var rest = double.parse((total - whole * radix).toStringAsFixed(2));
  if (rest >= radix) {
    whole++;
    rest = 0;
  }
  return (whole.toString(), measurementText(rest));
}

class MeasurementField extends StatefulWidget {
  final bool height, enabled;
  final String unit;
  final double? metricValue;
  final ValueChanged<double?> onChanged;
  final ValueChanged<String> onUnitChanged;
  const MeasurementField({
    super.key,
    required this.height,
    required this.unit,
    required this.metricValue,
    required this.onChanged,
    required this.onUnitChanged,
    this.enabled = true,
  });
  @override
  State<MeasurementField> createState() => _MeasurementFieldState();
}

class _MeasurementFieldState extends State<MeasurementField> {
  final first = TextEditingController(), second = TextEditingController();
  bool edited = false;
  late String formattedUnit;
  String get kind => widget.height ? 'height' : 'weight';
  bool get paired => widget.unit == 'ft_in' || widget.unit == 'st_lb';

  @override
  void initState() {
    super.initState();
    showValue();
  }

  @override
  void didUpdateWidget(covariant MeasurementField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reformat only when units change, keeping the caret and incomplete input stable while typing.
    if (oldWidget.unit != widget.unit && formattedUnit != widget.unit) {
      // External preference changes must not notify an ancestor Form while it is building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showValue();
      });
    }
  }

  void showValue([String? unit]) {
    edited = false;
    formattedUnit = unit ?? widget.unit;
    final values = displayMeasurement(formattedUnit, widget.metricValue);
    first.text = values.$1;
    second.text = values.$2;
  }

  @override
  void dispose() {
    first.dispose();
    second.dispose();
    super.dispose();
  }

  String? validate(String? _) {
    // Display rounding must not invalidate an unchanged measurement exactly at an API boundary.
    final value = edited
        ? metricMeasurement(widget.unit, first.text, second.text)
        : widget.metricValue;
    if (paired && (measurementNumber(first.text) ?? -1) % 1 != 0) {
      return widget.height ? 'Enter whole feet.' : 'Enter whole stone.';
    }
    if (paired && second.text.isNotEmpty) {
      final part = measurementNumber(second.text);
      if (part == null || part < 0 || part >= (widget.height ? 12 : 14)) {
        return widget.height
            ? 'Inches must be 0 to less than 12.'
            : 'Pounds must be 0 to less than 14.';
      }
    }
    if (value == null) return 'Enter a valid $kind.';
    final min = widget.height ? 100.0 : 30.0,
        max = widget.height ? 250.0 : 300.0;
    // Existing API limits apply identically whichever input unit was selected.
    if (value < min || value > max) {
      return widget.height
          ? 'Height must be 100–250 cm (about 3 ft 3 in–8 ft 2 in).'
          : 'Weight must be 30–300 kg (about 66–661 lb).';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final labels = widget.height ? heightUnits : weightUnits;
    Widget input(
      TextEditingController controller,
      String label,
      String suffix,
    ) => TextFormField(
      key: ValueKey('$kind-$suffix'),
      controller: controller,
      enabled: widget.enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: suffix,
        errorMaxLines: 3,
      ),
      validator: validate,
      onChanged: (_) {
        edited = true;
        widget.onChanged(
          metricMeasurement(widget.unit, first.text, second.text),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('$kind-unit-${widget.unit}'),
          initialValue: widget.unit,
          isExpanded: true,
          itemHeight: null,
          decoration: InputDecoration(
            labelText: widget.height ? 'Height unit' : 'Weight unit',
          ),
          items: labels.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: widget.enabled
              ? (value) {
                  if (value != null) {
                    // Convert during the input event, before the form rebuilds, so labels and values change together.
                    showValue(value);
                    widget.onUnitChanged(value);
                  }
                }
              : null,
        ),
        const SizedBox(height: 12),
        if (paired)
          LayoutBuilder(
            builder: (context, constraints) {
              final a = input(
                first,
                widget.height ? 'Feet' : 'Stone',
                widget.height ? 'ft' : 'st',
              );
              final b = input(
                second,
                widget.height ? 'Inches' : 'Pounds',
                widget.height ? 'in' : 'lb',
              );
              // Large text gets two full-width fields instead of squeezed labels or hidden errors.
              if (MediaQuery.textScalerOf(context).scale(16) > 24 ||
                  constraints.maxWidth < 280) {
                return Column(children: [a, const SizedBox(height: 12), b]);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: a),
                  const SizedBox(width: 12),
                  Expanded(child: b),
                ],
              );
            },
          )
        else
          input(first, widget.height ? 'Height' : 'Weight', widget.unit),
      ],
    );
  }
}
