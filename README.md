# IRAN Messenger — ایران مسنجر

پیام‌رسان رایگان و متن‌باز با رمزنگاری سراسری، که هر گروهی می‌تواند سرور خودش را روی یک سایت وردپرسی راه بیندازد. برای روزهایی ساخته شده که اینترنت بین‌الملل قطع است ولی شبکه داخلی کار می‌کند.

> **پیش از استفاده حتما [تهدیدها و محدودیت‌ها](docs/threats-fa.md) را بخوانید.** رمزنگاری یعنی سرور متن پیام را نمی‌بیند؛ یعنی ناشناس بودن نیست، و در قطعی کامل شبکه (حتی داخلی) هیچ پیام‌رسان سرورمحوری کار نمی‌کند.

*English summary below.*

## چه کار می‌کند

- گفتگوی دونفره و گروهی با پروتکل سیگنال؛ متن، عکس، ویدیو، پیام صوتی، فایل تا ۴۰ مگابایت، گیف و استیکر.
- پاسخ، ویرایش، واکنش، بازارسال، نظرسنجی، حذف برای همه، و BUZZ.
- هیچ وابستگی به گوگل یا هیچ سرویس خارجی: پیام‌ها با یک سرویس پس‌زمینه از سرور خودتان گرفته می‌شود، پس با قطع اینترنت بین‌الملل هم می‌رسد.
- عضویت فقط با دعوت یا تأیید مدیر؛ کسی نمی‌تواند فهرست اعضا را ببیند.
- **شماره موبایل نه پرسیده می‌شود و نه ذخیره**؛ پیدا کردن افراد فقط با نام کاربری دقیق.
- پاسخ‌های سرور امضاشده‌اند؛ اگر کسی وسط راه دست‌کاری کند، برنامه رد می‌کند.
- رله: یک سایت دوم می‌تواند واسطه شود وقتی نشانی اصلی مسدود است. رله هم فقط داده رمزشده می‌بیند.
- اپ اندروید، و اپ وب برای آیفون و مرورگر که از خود سرور باز می‌شود.

## اجزا

| پوشه | چیست |
|---|---|
| `plugin/iran-messenger` | سرور: افزونه وردپرس |
| `plugin/iran-messenger-relay` | رله اختیاری روی سایت وردپرسی دوم |
| `app` | اپ اندروید و وب (فلاتر) |
| `packages/irm_core` | هسته مشترک رمزنگاری و همگام‌سازی، و آزمون‌های سراسری |
| `bot` | ربات اختیاری خلاصه خبر برای گروه‌ها |
| `scripts` | ساخت نسخه وب، ساخت آیکون‌ها و صداها، راه‌اندازی سرور محلی آزمایشی |

## راه‌اندازی سرور

۱. یک سایت وردپرس (نسخه ۶٫۲ به بالا، PHP ۷٫۴ به بالا با `openssl` و `sodium`) با گواهی `https`.
۲. پوشه `plugin/iran-messenger` را (بعد از `scripts/build-web.sh` تا اپ وب هم داخلش باشد) زیپ کنید و نصب و فعال کنید.
۳. در پیشخوان، منوی **IRAN Messenger**: کد دعوت بسازید و برای اعضا بفرستید. اعضای بدون کد منتظر تأیید شما می‌مانند.
۴. نشانی سرور را همراه کد دعوت به اعضا بدهید؛ در برنامه موقع ثبت‌نام وارد می‌شود.

جزئیات بیشتر، رله و ساخت اپ: [docs/build.md](docs/build.md).

## ساخت اپ

راهنمای کامل در [docs/build.md](docs/build.md). هر کس برنامه را منتشر می‌کند باید کلید امضای خودش را بسازد؛ هیچ کلیدی همراه این مخزن نیست.

## مجوز

`GPL-3.0-or-later` — فایل [LICENSE](LICENSE). کد، تصویر و فونت گرفته‌شده از پروژه‌های دیگر با مجوز خودشان در [app/THIRD_PARTY_NOTICES.md](app/THIRD_PARTY_NOTICES.md) آمده‌اند.

## گزارش آسیب‌پذیری

[SECURITY.md](SECURITY.md) را ببینید. آسیب‌پذیری را عمومی گزارش نکنید.

---

## English summary

IRAN Messenger is a free, open-source, end-to-end encrypted messenger (Signal protocol) whose server is a WordPress plugin that any group can host. It has no Google or other third-party dependency, so it keeps working over a domestic network when the international internet is cut. Membership is by invitation or admin approval, phone numbers are never collected, server answers are signed, and optional relays can forward traffic when the main address is blocked. Android and web (iPhone) clients are included.

Read [docs/threats-fa.md](docs/threats-fa.md) (Persian) before relying on it: encryption hides message content, not who talks to whom, and no server-based messenger works during a full network shutdown. The code has not had an independent security audit.

Licence: GPL-3.0-or-later.
