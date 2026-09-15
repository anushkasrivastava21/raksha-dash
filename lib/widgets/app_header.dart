import 'package:flutter/material.dart';
import '../screens/base.dart';

/// Reusable global App Bar Header matching reference specification.
class AppHeader extends StatelessWidget implements PreferredSizeWidget {
  final double height;

  const AppHeader({
    super.key,
    this.height = 64.0,
  });

  static const Color _bgSurface = Color(0xFFFCF9F8);
  static const Color _onSurface = Color(0xFF1C1B1B);
  static const Color _primaryCobalt = Color(0xFF004AC6);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      width: double.infinity,
      decoration: const BoxDecoration(
        color: _bgSurface,
        border: Border(
          bottom: BorderSide(color: _onSurface, width: 2.0),
        ),
      ),
      child: GestureDetector(
        onTap: () {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const BaseScreen()),
            (route) => false,
          );
        },
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              Icons.shield,
              color: _primaryCobalt,
              size: 26,
            ),
            SizedBox(width: 8),
            Text(
              'RAKSHA',
              style: TextStyle(
                fontFamily: 'Space Mono',
                fontSize: 26,
                fontWeight: FontWeight.w700,
                color: _primaryCobalt,
                letterSpacing: -1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Size get preferredSize => Size.fromHeight(height);
}
