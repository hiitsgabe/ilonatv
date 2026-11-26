import 'package:flutter/material.dart';

import '../data/weather.dart';
import '../i18n.dart';

/// "Lisbon · ☁ 14° · feels like 12°". Nothing until there is a forecast, and
/// nothing with no city.
class WeatherLine extends StatelessWidget {
  final WeatherSource source;
  final String city;
  const WeatherLine({super.key, required this.source, required this.city});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: source,
    builder: (context, _) {
      final w = source.current;
      if (w == null || city.isEmpty) return const SizedBox.shrink();
      const style = TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w400,
        color: Color(0xD9FFFFFF),
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$city · ', style: style),
          Icon(weatherIcon(w.code), size: 22, color: style.color),
          Text(
            ' ${w.temp.round()}° · ${t('feelsLike')} ${w.feelsLike.round()}°',
            style: style,
          ),
        ],
      );
    },
  );
}
