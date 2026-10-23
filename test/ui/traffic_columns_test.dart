import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/daemon/traffic_analysis.dart';
import 'package:vzhukh/ui/macos/traffic_views.dart';
import 'package:vzhukh/ui/theme/app_theme.dart';

void main() {
  test('a narrow table drops the least wanted columns first', () {
    expect(TrafficColumn.fitting(1000, live: true), TrafficColumn.values);
    expect(TrafficColumn.fitting(1000, live: false), isNot(contains(TrafficColumn.rate)));
    expect(TrafficColumn.fitting(500, live: true), [TrafficColumn.conns, TrafficColumn.received, TrafficColumn.rate]);
    expect(TrafficColumn.fitting(340, live: true), [TrafficColumn.received]);
    expect(TrafficColumn.fitting(200, live: true), isEmpty);
  });

  final group = const GroupTraffic()([
    TrafficRow(
      app: 'A browser with a rather long name',
      host: 'cdn.example.com',
      port: 443,
      network: 'tcp',
      action: 'route',
      conns: 12,
      open: 3,
      errors: 2,
      upload: 123456789,
      download: 987654321,
      last: DateTime.now(),
    ),
  ], TrafficDim.app).single;

  for (final width in [240.0, 360.0, 520.0, 760.0, 1100.0]) {
    testWidgets('header and line fit $width wide', (tester) async {
      final columns = TrafficColumn.fitting(width, live: true);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(tv: false),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  TrafficTableHeader(sort: TrafficSort.received, columns: columns, onSort: (_) {}, title: 'App › Site › Host'),
                  TrafficGroupLine(
                    group: group,
                    label: 'A browser with a rather long name',
                    columns: columns,
                    expandable: true,
                    expanded: false,
                    selected: false,
                    onTap: () {},
                    onToggle: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      if (!columns.contains(TrafficColumn.errors)) {
        expect(find.textContaining('2 err', findRichText: true), findsOneWidget);
      }
    });
  }
}
