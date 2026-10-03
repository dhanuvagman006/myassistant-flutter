import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:google_fonts/google_fonts.dart';

/// THE APP'S FONTS SHIP INSIDE THE APP. Owner, 2026-09-24: "improve the
/// clarity of the app". Manrope and Space Grotesk used to be downloaded
/// the first time a screen asked for them, so a fresh install (or any
/// launch without internet) drew every line in the phone's fallback font
/// and then swapped it — text jumped and re-wrapped under the reader.
///
/// assets/google_fonts/ now holds every weight both families have, byte
/// for byte the files google_fonts 6.3.3 would fetch (checked against the
/// package's own sha256 and length when they were added), named the way
/// the package looks them up (Manrope-SemiBold.ttf …). With all of them
/// bundled, fetching is switched off: no network, no swap.
const bundledFontFamilies = <String, List<String>>{
  'Manrope': [
    'ExtraLight', 'Light', 'Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold',
  ],
  'SpaceGrotesk': ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold'],
};

void useBundledFonts() {
  GoogleFonts.config.allowRuntimeFetching = false;
  // Both are under the SIL Open Font License, which asks that the licence
  // travels with the font: it shows on the app's licences page.
  LicenseRegistry.addLicense(() async* {
    for (final family in bundledFontFamilies.keys) {
      final text = await rootBundle.loadString('assets/google_fonts/OFL-$family.txt');
      yield LicenseEntryWithLineBreaks(['google_fonts', family], text);
    }
  });
}
