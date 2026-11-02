import 'summarizer.dart';

/// Iran has kept standard time all year since 2022.
const tehranOffset = Duration(hours: 3, minutes: 30);

DateTime tehranNow([DateTime? now]) =>
    (now ?? DateTime.now()).toUtc().add(tehranOffset);

/// The report period a moment belongs to, e.g. "2026-10-13T12" for the
/// 12:00–18:00 period when reports go out every 6 hours (Tehran time).
String slotOf(DateTime tehran, int everyHours) {
  final hour = tehran.hour - tehran.hour % everyHours;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${tehran.year}-${two(tehran.month)}-${two(tehran.day)}T${two(hour)}';
}

const _faDigits = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
String fa(Object v) =>
    '$v'.replaceAllMapped(RegExp(r'\d'), (m) => _faDigits[int.parse(m[0]!)]);

const _months = [
  'فروردین',
  'اردیبهشت',
  'خرداد',
  'تیر',
  'مرداد',
  'شهریور',
  'مهر',
  'آبان',
  'آذر',
  'دی',
  'بهمن',
  'اسفند',
];

/// Gregorian date to Solar Hijri [year, month, day].
List<int> toJalali(DateTime t) {
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  final gy = t.year, gm = t.month, gd = t.day;
  final gy2 = gm > 2 ? gy + 1 : gy;
  var days =
      355666 +
      365 * gy +
      (gy2 + 3) ~/ 4 -
      (gy2 + 99) ~/ 100 +
      (gy2 + 399) ~/ 400 +
      gd +
      gdm[gm - 1];
  var jy = -1595 + 33 * (days ~/ 12053);
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  final jm = days < 186 ? 1 + days ~/ 31 : 7 + (days - 186) ~/ 30;
  final jd = 1 + (days < 186 ? days % 31 : (days - 186) % 30);
  return [jy, jm, jd];
}

/// "https://site/news/123/%D8%AE%D8%A8%D8%B1" shown as ".../123/خبر":
/// the same address, readable. Left as it is if it cannot be decoded.
String readableUrl(String url) {
  try {
    final decoded = Uri.decodeFull(url);
    // Spaces would cut the link short in the chat; keep those encoded.
    return decoded.replaceAll(' ', '%20');
  } on ArgumentError {
    return url;
  } on FormatException {
    return url;
  }
}

/// The message posted to the groups. Built here, not by the AI, so every
/// source name and link is the one the feed gave.
String buildReport(List<Summary> items, DateTime tehran) {
  final j = toJalali(tehran);
  final b = StringBuffer()
    ..writeln('📰 خلاصه خبرها')
    ..writeln(
      fa(
        '${j[2]} ${_months[j[1] - 1]} ${j[0]} · ساعت ${tehran.hour.toString().padLeft(2, '0')}:${tehran.minute.toString().padLeft(2, '0')}',
      ),
    );
  for (final entry in categories.entries) {
    final group = items.where((s) => s.category == entry.key).toList();
    if (group.isEmpty) continue;
    b
      ..writeln()
      ..writeln('▪️ ${entry.value}');
    for (final s in group) {
      b
        ..writeln()
        ..writeln('• ${s.title}')
        ..writeln(s.text)
        ..writeln('منبع: ${s.article.source}')
        ..writeln(readableUrl(s.article.url));
    }
  }
  b
    ..writeln()
    ..write(
      'این خلاصه را هوش مصنوعی از خبرهای منابع بالا ساخته است و ممکن است خطا داشته باشد؛ برای جزئیات، لینک خود خبر را ببینید.',
    );
  return b.toString();
}
