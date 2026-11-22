import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n.dart';
import 'theme.dart';

const supportEmail = 'passlune.app@gmail.com';

class AboutPage extends StatefulWidget {
  final String appName;
  const AboutPage({super.key, required this.appName});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((i) {
      if (mounted) setState(() => _version = '${i.version} (${i.buildNumber})');
    }).catchError((Object _) {});
  }

  Future<void> _mail() async {
    final os = Platform.operatingSystem;
    final uri = Uri(
      scheme: 'mailto',
      path: supportEmail,
      query: 'subject=${Uri.encodeComponent('${widget.appName} ${t('destek', 'support')}')}'
          '&body=${Uri.encodeComponent('\n\n---\n${widget.appName} $_version · $os')}',
    );
    if (!await launchUrl(uri) && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t('E-posta uygulaması bulunamadı: ', 'No e-mail app found: ') + supportEmail)));
    }
  }

  void _privacy() => showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('Gizlilik', 'Privacy')),
          content: SingleChildScrollView(
            child: Text(t(
              '• Kasandaki her şey cihazında, ana şifrenden Argon2id ile türetilen bir anahtarla AES-256-GCM ile şifrelenir. Ana şifre hiçbir yere kaydedilmez ve gönderilmez.\n\n'
                  '• Google Drive senkronunu açarsan yalnızca şifreli dosya, Drive\'ında bu uygulamanın görebildiği gizli bir alana yüklenir. Biz (geliştirici) bu veriye erişemeyiz.\n\n'
                  '• Reklam, analiz ya da takip yoktur. Hesap açmak gerekmez.\n\n'
                  '• Drive\'daki kopyayı silmek için Google hesabının "Üçüncü taraf uygulamaları" sayfasından uygulamanın erişimini kaldırabilirsin.',
              '• Everything in your vault is encrypted on your device with AES-256-GCM, using a key derived from your master password with Argon2id. The master password is never stored or sent anywhere.\n\n'
                  '• If you turn on Google Drive sync, only the encrypted file is uploaded, to a hidden area of your Drive that only this app can see. We (the developer) cannot access it.\n\n'
                  '• No ads, analytics or tracking. No account needed.\n\n'
                  '• To delete the copy on Drive, remove the app\'s access on your Google Account\'s "Third-party apps" page.',
            )),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(t('Tamam', 'OK')))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pal = UiPrefs.instance.palette;
    final tt = Theme.of(context).textTheme;
    Widget tile(IconData icon, String title, String? sub, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: pal.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: pal.border)),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Icon(icon, color: pal.accent),
              title: Text(title),
              subtitle: sub == null ? null : Text(sub, style: TextStyle(color: pal.muted)),
              trailing: Icon(Icons.chevron_right, color: pal.muted),
              onTap: onTap,
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t('Hakkında', 'About'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(child: VaultMark(size: 88, color: pal.accent)),
          const SizedBox(height: 14),
          Text(widget.appName,
              textAlign: TextAlign.center, style: tt.headlineSmall!.copyWith(fontWeight: FontWeight.w800, letterSpacing: 3)),
          Text(t('Şifre kasası', 'Password vault'), textAlign: TextAlign.center, style: TextStyle(color: pal.accent)),
          if (_version.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${t('Sürüm', 'Version')} $_version',
                  textAlign: TextAlign.center, style: TextStyle(color: pal.muted)),
            ),
          const SizedBox(height: 24),
          tile(Icons.mail_outline, t('Destek ve geri bildirim', 'Support and feedback'), supportEmail, _mail),
          tile(Icons.privacy_tip_outlined, t('Gizlilik', 'Privacy'), null, _privacy),
          tile(Icons.description_outlined, t('Açık kaynak lisansları', 'Open-source licences'), null,
              () => showLicensePage(context: context, applicationName: widget.appName, applicationVersion: _version)),
          const SizedBox(height: 16),
          Text('© 2026 Passlune', textAlign: TextAlign.center, style: TextStyle(color: pal.muted, fontSize: 12)),
        ],
      ),
    );
  }
}
