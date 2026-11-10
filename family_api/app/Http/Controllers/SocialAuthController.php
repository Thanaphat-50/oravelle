<?php

namespace App\Http\Controllers;

use App\Models\SocialAccount;
use App\Models\User;
use App\Services\SocialIdentityVerifier;
use App\Services\SocialLoginException;
use App\Support\AppSessions;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;

// =======================================================
// เข้าสู่ระบบ / สมัคร ด้วย Google, LINE, Facebook
//
// - เคยผูกบัญชีนี้แล้ว → เข้าสู่ระบบบัญชีเดิม
// - Google ยืนยันอีเมลแล้ว และอีเมลตรงกับบัญชีเดิม → ผูกให้อัตโนมัติ
// - LINE / Facebook อีเมลตรงกับบัญชีเดิม → ไม่ผูกเอง
//   (ให้เข้าสู่ระบบด้วยรหัสผ่านแล้วเชื่อมในหน้าตั้งค่า กันคนอื่นสวมรอย)
// - ไม่ตรงกับใคร → สร้างบัญชีใหม่ (ยังไม่มีรหัสผ่าน)
// =======================================================

class SocialAuthController extends Controller
{
    public function __construct(private SocialIdentityVerifier $verifier)
    {
    }

    // GET /api/auth/providers → เจ้าที่เปิดใช้ + ข้อมูลที่แอปต้องใช้
    public function providers()
    {
        return response()->json([
            'status' => true,
            'providers' => $this->verifier->publicConfig($this->facebookRedirectUri()),
        ]);
    }

    // POST /api/auth/social/{provider}
    public function login(Request $request, string $provider)
    {
        $identity = $this->identityFrom($request, $provider);

        if ($identity instanceof \Illuminate\Http\JsonResponse) {
            return $identity;
        }

        $linked = SocialAccount::where('provider', $provider)
            ->where('provider_user_id', $identity['id'])
            ->first();

        if ($linked) {
            return $this->signIn($linked->user, false);
        }

        $email = $identity['email'] ? Str::lower(trim($identity['email'])) : null;

        $existing = $email ? User::where('email', $email)->first() : null;

        if ($existing && !$identity['email_verified']) {
            // แอปใช้ email + sign_in_with แสดงหน้าต่างพาไปเข้าสู่ระบบด้วยวิธีเดิม
            return response()->json([
                'status' => false,
                'code' => 'email_in_use',
                'message' => 'อีเมล ' . $email . ' มีบัญชีอยู่แล้ว กรุณาเข้าสู่ระบบด้วยวิธีเดิม แล้วเชื่อม '
                    . SocialAccount::LABELS[$provider] . ' ได้ที่ ตั้งค่า → บัญชีที่เชื่อมต่อ',
                'email' => $email,
                'sign_in_with' => [
                    'password' => $existing->hasPassword(),
                    'providers' => $existing->socialAccounts()->pluck('provider')->values(),
                ],
            ], 409);
        }

        [$user, $created] = DB::transaction(function () use ($existing, $identity, $provider, $email) {
            $user = $existing;

            $created = false;

            if (!$user) {
                $user = new User();
                $user->name = $this->nameFrom($identity, $provider);
                $user->email = $email;
                $user->password = null;

                if ($email && $identity['email_verified']) {
                    $user->email_verified_at = now();
                }

                $user->save();

                $created = true;
            }

            SocialAccount::create([
                'user_id' => $user->id,
                'provider' => $provider,
                'provider_user_id' => $identity['id'],
                'email' => $email,
            ]);

            return [$user, $created];
        });

        return $this->signIn($user, $created);
    }

    // GET /api/social-accounts → บัญชีที่เชื่อมแล้ว (หน้าตั้งค่า)
    public function index(Request $request)
    {
        return response()->json([
            'status' => true,
            ...$this->accountsPayload($request->user()),
        ]);
    }

    // POST /api/social-accounts/{provider} → เชื่อมกับบัญชีที่ล็อกอินอยู่
    public function link(Request $request, string $provider)
    {
        $user = $request->user();

        $identity = $this->identityFrom($request, $provider);

        if ($identity instanceof \Illuminate\Http\JsonResponse) {
            return $identity;
        }

        $owner = SocialAccount::where('provider', $provider)
            ->where('provider_user_id', $identity['id'])
            ->first();

        if ($owner && (int) $owner->user_id !== (int) $user->id) {
            return response()->json([
                'status' => false,
                'message' => 'บัญชี ' . SocialAccount::LABELS[$provider] . ' นี้เชื่อมกับผู้ใช้อื่นอยู่แล้ว',
            ], 409);
        }

        if (!$owner && $user->socialAccounts()->where('provider', $provider)->exists()) {
            return response()->json([
                'status' => false,
                'message' => 'คุณเชื่อม ' . SocialAccount::LABELS[$provider] . ' บัญชีอื่นไว้แล้ว ยกเลิกการเชื่อมก่อน',
            ], 409);
        }

        if (!$owner) {
            SocialAccount::create([
                'user_id' => $user->id,
                'provider' => $provider,
                'provider_user_id' => $identity['id'],
                'email' => $identity['email'] ? Str::lower(trim($identity['email'])) : null,
            ]);
        }

        return response()->json([
            'status' => true,
            'message' => 'เชื่อม ' . SocialAccount::LABELS[$provider] . ' แล้ว',
            ...$this->accountsPayload($user),
        ]);
    }

    // DELETE /api/social-accounts/{provider}
    public function unlink(Request $request, string $provider)
    {
        $user = $request->user();

        if (!in_array($provider, SocialAccount::PROVIDERS, true)) {
            abort(404);
        }

        $others = $user->socialAccounts()->where('provider', '!=', $provider)->count();

        // ต้องเหลือทางเข้าสู่ระบบอย่างน้อย 1 ทาง
        if (!$user->hasPassword() && $others === 0) {
            return response()->json([
                'status' => false,
                'message' => 'ตั้งรหัสผ่านก่อน จึงจะยกเลิกการเชื่อมได้ (ไม่อย่างนั้นจะเข้าสู่ระบบไม่ได้)',
            ], 422);
        }

        $user->socialAccounts()->where('provider', $provider)->delete();

        return response()->json([
            'status' => true,
            'message' => 'ยกเลิกการเชื่อม ' . SocialAccount::LABELS[$provider] . ' แล้ว',
            ...$this->accountsPayload($user),
        ]);
    }

    // GET /auth/facebook/callback (หน้าเว็บ)
    // Facebook ส่งกลับมาที่นี่ → ส่งต่อเข้าแอปด้วย klaikan://
    public function facebookCallback(Request $request)
    {
        $query = http_build_query(array_filter([
            'code' => $request->query('code'),
            'state' => $request->query('state'),
            'error' => $request->query('error'),
        ], fn ($value) => is_string($value) && $value !== ''));

        return response()->view('auth.social-callback', [
            'appUrl' => 'klaikan://auth/facebook' . ($query === '' ? '' : '?' . $query),
        ]);
    }

    // =====================================================
    // Helpers
    // =====================================================

    private function identityFrom(Request $request, string $provider)
    {
        if (!in_array($provider, SocialAccount::PROVIDERS, true)) {
            abort(404);
        }

        $data = $request->validate([
            'id_token' => [Rule::requiredIf($provider !== 'facebook'), 'nullable', 'string', 'max:8192'],
            'code' => [Rule::requiredIf($provider === 'facebook'), 'nullable', 'string', 'max:2048'],
        ]);

        try {
            return $this->verifier->verify($provider, [
                'id_token' => $data['id_token'] ?? null,
                'code' => $data['code'] ?? null,
                'redirect_uri' => $this->facebookRedirectUri(),
            ]);
        } catch (SocialLoginException $e) {
            return response()->json([
                'status' => false,
                'message' => $e->getMessage(),
            ], 422);
        }
    }

    private function signIn(User $user, bool $created)
    {
        // เซสชันของแอป + ข้อมูลอุปกรณ์จากคำขอเข้าสู่ระบบนี้
        $token = AppSessions::issue($user, request());

        return response()->json([
            'status' => true,
            'message' => $created ? 'สร้างบัญชีเรียบร้อยแล้ว' : 'Login successful',
            'created' => $created,
            'user' => $user,
            'token' => $token,
        ], $created ? 201 : 200);
    }

    private function nameFrom(array $identity, string $provider): string
    {
        $name = trim((string) ($identity['name'] ?? ''));

        if ($name === '' && $identity['email']) {
            $name = Str::before($identity['email'], '@');
        }

        return $name === '' ? 'ผู้ใช้ ' . SocialAccount::LABELS[$provider] : Str::limit($name, 255, '');
    }

    private function accountsPayload(User $user): array
    {
        $linked = $user->socialAccounts()->get(['provider', 'email', 'created_at'])->keyBy('provider');

        return [
            'has_password' => $user->hasPassword(),
            'accounts' => collect(SocialAccount::PROVIDERS)->map(fn ($provider) => [
                'provider' => $provider,
                'label' => SocialAccount::LABELS[$provider],
                'enabled' => $this->verifier->enabled($provider),
                'linked' => $linked->has($provider),
                'email' => $linked->get($provider)?->email,
            ])->values(),
        ];
    }

    private function facebookRedirectUri(): string
    {
        return route('auth.facebook.callback');
    }
}
