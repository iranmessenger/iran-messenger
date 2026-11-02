import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:irm_core/irm_core.dart';

import '../app_state.dart';
import '../platform/host.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

/// Server baked in at build time (`--dart-define=DEFAULT_SITE=...`), so
/// people only ever type a username and a password.
const defaultSite = String.fromEnvironment('DEFAULT_SITE');

/// Sign in, or create an account with just a username and a password.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.state});
  final AppState state;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _site = TextEditingController(
    text: isWebApp ? builtInSite : defaultSite,
  );
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _code = TextEditingController();
  bool _register = false;
  bool _showServer = !isWebApp && defaultSite.isEmpty;
  bool _hide = true;
  bool _busy = false;
  String? _error;

  String _explain(Object e) {
    if (e is ApiError) {
      return switch (e.code) {
        'irm_bad_login' => 'نام کاربری یا رمز درست نیست.',
        'irm_blocked' => 'این حساب غیرفعال شده است.',
        'irm_bad_invite' => 'کد دعوت نامعتبر، منقضی یا قبلا استفاده شده است.',
        'irm_invite_required' => 'ثبت‌نام در این سرور فقط با کد دعوت ممکن است.',
        'irm_username_taken' => 'این نام کاربری قبلا گرفته شده است.',
        'irm_bad_username' => 'نام کاربری معتبر نیست.',
        'irm_full' => 'ظرفیت سرور پر است؛ بعدا دوباره امتحان کنید.',
        'irm_rate_limited' => 'تلاش بیش از حد؛ کمی بعد دوباره امتحان کنید.',
        'irm_weak_password' => 'رمز باید دست‌کم ۸ نویسه باشد.',
        _ => 'سرور درخواست را نپذیرفت (${e.code}).',
      };
    }
    if (e is WafBlock) {
      return 'فایروال سرور جلوی درخواست را گرفت (کد ${e.evidence['status']}).';
    }
    if (isConnectionError(e)) {
      return 'اتصال به سرور برقرار نشد. اینترنت را بررسی کنید.';
    }
    return 'خطا: $e';
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = widget.state.messenger;
    try {
      if (_register) {
        await m.register(
          site: _site.text,
          username: _user.text,
          password: _pass.text,
          inviteCode: _code.text,
        );
      } else {
        await m.login(
          site: _site.text,
          username: _user.text,
          password: _pass.text,
        );
      }
      _pass.clear();
      await widget.state.applyBackground();
    } catch (e) {
      if (mounted) setState(() => _error = _explain(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tab(String label, bool register) {
    final on = _register == register;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _register = register;
          _error = null;
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 11),
          decoration: BoxDecoration(
            gradient: on ? Brand.gradient : null,
            borderRadius: BorderRadius.circular(12),
            boxShadow: on ? Brand.shadow(context, strength: 0.7) : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: on ? Colors.white : Brand.muted(context),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              children: [
                ClipPath(
                  clipper: const ArcClipper(depth: 40),
                  child: Container(
                    width: double.infinity,
                    padding: EdgeInsets.fromLTRB(24, top + 36, 24, 66),
                    decoration: const BoxDecoration(gradient: Brand.gradient),
                    child: Column(
                      children: [
                        Container(
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: Brand.shadow(context, strength: 1.6),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: const Image(
                            image: AssetImage('assets/brand/icon.webp'),
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'IRAN Messenger',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 25,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'پیام‌رسان خصوصی با رمزنگاری سراسری',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Transform.translate(
                  offset: const Offset(0, -40),
                  child: Entrance(
                    always: true,
                    child: Panel(
                      radius: 24,
                      margin: const EdgeInsets.symmetric(horizontal: 14),
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Brand.page(context),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Row(
                              children: [
                                _tab('ورود', false),
                                _tab('ثبت‌نام', true),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _user,
                            textDirection: TextDirection.ltr,
                            autocorrect: false,
                            decoration: const InputDecoration(
                              labelText: 'نام کاربری',
                              prefixIcon: Icon(
                                Icons.alternate_email_rounded,
                                size: 21,
                              ),
                            ),
                            validator: (v) =>
                                RegExp(
                                  r'^@?[a-zA-Z][a-zA-Z0-9_]{3,19}$',
                                ).hasMatch((v ?? '').trim())
                                ? null
                                : '۴ تا ۲۰ نویسه: حروف انگلیسی، رقم و _',
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _pass,
                            obscureText: _hide,
                            textDirection: TextDirection.ltr,
                            autocorrect: false,
                            decoration: InputDecoration(
                              labelText: 'رمز عبور',
                              prefixIcon: const Icon(
                                Icons.password_rounded,
                                size: 21,
                              ),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() => _hide = !_hide),
                                icon: Icon(
                                  _hide
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_rounded,
                                ),
                              ),
                            ),
                            validator: (v) =>
                                (v ?? '').length < 8 ? 'دست‌کم ۸ نویسه' : null,
                          ),
                          if (_register) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _code,
                              textDirection: TextDirection.ltr,
                              autocorrect: false,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                labelText: 'کد دعوت (اگر دارید)',
                                prefixIcon: Icon(Icons.key_rounded, size: 21),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'با کد دعوت، حساب شما همان لحظه فعال می‌شود. بدون کد، باید منتظر تایید مدیر بمانید.',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Brand.muted(context),
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 8),
                            Text(
                              'با ورود در این گوشی، دستگاه قبلی از حساب خارج می‌شود و پیام‌های قدیمی که فقط روی آن بودند برنمی‌گردند.',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: Brand.muted(context),
                              ),
                            ),
                          ],
                          if (_showServer) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _site,
                              textDirection: TextDirection.ltr,
                              keyboardType: TextInputType.url,
                              autocorrect: false,
                              decoration: const InputDecoration(
                                labelText: 'نشانی سرور',
                                hintText: 'https://example.ir',
                                prefixIcon: Icon(Icons.dns_rounded, size: 21),
                              ),
                              validator: (v) =>
                                  (v ?? '').trim().isEmpty ? 'لازم است' : null,
                            ),
                          ],
                          const SizedBox(height: 16),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          FilledButton(
                            onPressed: _busy ? null : _submit,
                            child: _busy
                                ? const SizedBox(
                                    height: 22,
                                    width: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.4,
                                    ),
                                  )
                                : Text(_register ? 'ساخت حساب' : 'ورود'),
                          ),
                          if (!_showServer && !isWebApp)
                            TextButton(
                              onPressed: () =>
                                  setState(() => _showServer = true),
                              child: Text(
                                'تغییر سرور',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: Brand.muted(context),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown after registering without an invite code, until approval.
class PendingScreen extends StatefulWidget {
  const PendingScreen({super.key, required this.state});
  final AppState state;

  @override
  State<PendingScreen> createState() => _PendingScreenState();
}

class _PendingScreenState extends State<PendingScreen> {
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    await widget.state.syncNow();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.state.messenger;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Panel(
            radius: 24,
            margin: const EdgeInsets.all(22),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: Brand.gradient,
                  ),
                  child: const Icon(
                    Icons.hourglass_top_rounded,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'در انتظار تایید مدیر',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  '@${m.myUsername ?? ''}',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'حساب شما ساخته شد. به محض تایید مدیر سرور، برنامه خودش باز می‌شود؛ لازم نیست دوباره ثبت‌نام کنید.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Brand.muted(context)),
                ),
                const SizedBox(height: 20),
                LinkBanner(state: widget.state),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _check,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: const Text('بررسی دوباره'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
