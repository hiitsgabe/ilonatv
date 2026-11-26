import 'package:flutter/material.dart';

import '../tv_client.dart';
import '../tvs.dart';

class RemotePage extends StatelessWidget {
  const RemotePage({super.key, required this.tv, required this.client});

  final Tv tv;
  final TvClient client;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(tv.label)),
    body: Center(child: Text(tv.label)),
  );
}
