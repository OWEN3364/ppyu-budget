// lib/features/ads/ad_banner_widget.dart
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// The banner's rendered height, in logical pixels. Screens with a
/// FloatingActionButton need this to lift the FAB clear of the banner —
/// the banner is mounted below every Scaffold via MaterialApp's `builder`,
/// so no individual Scaffold knows it's there on its own.
final double adBannerHeight = AdSize.banner.height.toDouble();

/// A fixed-size (320x50) banner ad, meant to sit at the bottom of every
/// screen via MaterialApp's `builder`. Renders nothing until the ad has
/// actually loaded (AdWidget requires a loaded ad before it's mounted —
/// see this plan's Global Constraints), and collapses back to nothing if
/// the load fails, so a network hiccup never breaks layout or shows an
/// error to the user — the banner is a purely optional extra.
class AdBannerWidget extends StatefulWidget {
  const AdBannerWidget({super.key});

  @override
  State<AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<AdBannerWidget> {
  BannerAd? _bannerAd;

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  void _loadAd() {
    final adUnitId = dotenv.env['ADMOB_BANNER_UNIT_ID'];
    if (adUnitId == null || adUnitId.isEmpty) return;
    BannerAd(
      adUnitId: adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() => _bannerAd = ad as BannerAd);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
        },
      ),
    ).load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _bannerAd;
    if (ad == null) return const SizedBox.shrink();
    return SafeArea(
      top: false,
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
