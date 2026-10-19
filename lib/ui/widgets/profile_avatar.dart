import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../utils/profile_helpers.dart';
import '../themes/app_theme.dart';

class ProfileAvatar extends StatelessWidget {
  final String name;
  final String url;
  final double radius;
  final bool isGroup;
  const ProfileAvatar({
    super.key,
    required this.name,
    this.url = '',
    this.radius = 20,
    this.isGroup = false,
  });

  Widget _fallback(BuildContext context, String hint) => Tooltip(
    message: hint,
    child: CircleAvatar(
      radius: radius,
      backgroundColor: isGroup ? AppTheme.qqGreen : AppTheme.qqBlue,
      child: Text(
        name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase(),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: radius * .65,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (isGroup) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: AppTheme.qqGreen.withValues(alpha: .12),
        child: Icon(
          Icons.groups_rounded,
          color: AppTheme.qqGreen,
          size: radius,
        ),
      );
    }
    final avatar = profileAvatar(url);
    if (avatar.isEmpty) return _fallback(context, '平台未提供头像');
    return ClipOval(
      child: CachedNetworkImage(
        imageUrl: avatar,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        memCacheWidth: (radius * 2 * MediaQuery.devicePixelRatioOf(context))
            .ceil(),
        placeholder: (_, _) => _fallback(context, '正在加载头像'),
        errorWidget: (_, _, _) => _fallback(context, '头像暂时无法加载'),
      ),
    );
  }
}
