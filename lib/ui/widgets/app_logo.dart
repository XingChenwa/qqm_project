import 'package:flutter/material.dart';

class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(size * .28),
    child: Image.asset(
      'assets/branding/logo.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
      semanticLabel: 'QQ 机器人管理器',
    ),
  );
}
