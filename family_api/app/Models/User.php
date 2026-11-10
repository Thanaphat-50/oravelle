<?php

namespace App\Models;

use Filament\Models\Contracts\FilamentUser;
use Filament\Panel;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use App\Support\MediaStorage;
use Illuminate\Notifications\Notifiable;
use Laravel\Sanctum\HasApiTokens;

class User extends Authenticatable implements FilamentUser
{
    /** @use HasFactory<\Database\Factories\UserFactory> */
    use HasApiTokens, HasFactory, Notifiable;

    protected $fillable = [
        'name',
        'email',
        'password',
    ];

    protected $hidden = [
        'password',
        'remember_token',
        'is_admin',
        // ส่งผ่าน /api/settings ของเจ้าของบัญชีเท่านั้น
        'notification_settings',
        // ส่งผ่าน introPayload() เท่านั้น
        'bio',
        'occupation',
        'education',
        'province',
        'interests',
    ];

    // ข้อมูลแนะนำตัวบนหน้าโปรไฟล์ (คนในชุมชนเห็นได้)
    public const INTRO_FIELDS = ['bio', 'occupation', 'education', 'province', 'interests'];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
            'community_terms_accepted_at' => 'datetime',
            'is_admin' => 'boolean',
            'location_sharing' => 'boolean',
            'notification_settings' => 'array',
        ];
    }

    // ผู้ใช้ต้องการรับการแจ้งเตือนประเภทนี้ไหม (ค่าเริ่มต้น = รับ)
    // ประเภทที่ปิดไม่ได้ เช่น ผลตรวจร้านค้า รับเสมอ
    public function wantsNotification(string $type): bool
    {
        if (!in_array($type, AppNotification::OPTIONAL_TYPES, true)) {
            return true;
        }

        return ($this->notification_settings[$type] ?? true) === true;
    }

    // เข้าหน้า Admin (/admin) ได้เฉพาะผู้ดูแลระบบ
    public function canAccessPanel(Panel $panel): bool
    {
        return $this->is_admin === true;
    }

    // ผู้ใช้ที่เราบล็อก (ซ่อนโพสต์/ความคิดเห็นของเขาในฟีดชุมชน)
    public function blockedUsers()
    {
        return $this->belongsToMany(
            User::class,
            'user_blocks',
            'user_id',
            'blocked_user_id'
        )->withTimestamps();
    }

    // คำขอลบบัญชี (ผู้ดูแลเป็นคนลบ)
    public function deletionRequests()
    {
        return $this->hasMany(AccountDeletionRequest::class);
    }

    // คนที่เราติดตาม
    public function following()
    {
        return $this->belongsToMany(User::class, 'follows', 'follower_id', 'followee_id')
            ->withTimestamps();
    }

    // คนที่ติดตามเรา
    public function followers()
    {
        return $this->belongsToMany(User::class, 'follows', 'followee_id', 'follower_id')
            ->withTimestamps();
    }

    public function interactions()
    {
        return $this->hasMany(Interaction::class);
    }

    // บัญชี Google / LINE / Facebook ที่เชื่อมไว้
    public function socialAccounts()
    {
        return $this->hasMany(SocialAccount::class);
    }

    // สมัครด้วย Google / LINE / Facebook → อาจยังไม่ได้ตั้งรหัสผ่าน
    public function hasPassword(): bool
    {
        return filled($this->getAttributes()['password'] ?? null);
    }

    // มือถือที่ล็อกอินอยู่ (ส่งแจ้งเตือนเด้ง)
    public function deviceTokens()
    {
        return $this->hasMany(DeviceToken::class);
    }

    public function introPayload(): array
    {
        return collect(self::INTRO_FIELDS)
            ->mapWithKeys(fn (string $field) => [$field => $this->getAttribute($field)])
            ->all();
    }

    // รายงานที่ผู้ใช้คนนี้ถูกรายงาน (Admin ดูในหน้าผู้ใช้)
    public function reportsReceived()
    {
        return $this->hasMany(UserReport::class, 'reported_user_id')->latest();
    }

    protected $appends = [
        'profile_image_url',
        'profile_photo_url',
    ];

    public function getProfileImageUrlAttribute(): ?string
    {
        return $this->profilePhotoUrl();
    }

    public function getProfilePhotoUrlAttribute(): ?string
    {
        return $this->profilePhotoUrl();
    }

    // Disk ที่เก็บรูปโปรไฟล์ (ใช้ร่วมกับรูปในโพสต์)
    // ในเครื่องใช้ public / บน Cloud ใช้ Default Disk ที่เชื่อมกับ Bucket
    public static function profilePhotoDisk(): string
    {
        return MediaStorage::disk();
    }

    private function profilePhotoUrl(): ?string
    {
        return MediaStorage::url($this->profile_photo);
    }

    // มีตัวตนในชุมชน: โพสต์ชุมชน หรือความคิดเห็นในโพสต์ชุมชน ที่ไม่ถูกซ่อน
    // → คนอื่นเปิดโปรไฟล์ชุมชนได้ / ค้นหาชื่อเจอ (คนที่ใช้แค่ในกลุ่มไม่ถูกค้นเจอจากคนนอก)
    public function scopeWithCommunityPresence($query)
    {
        return $query->where(function ($users) {
            $users->whereIn('users.id', Post::select('user_id')
                ->where('visibility', 'community')
                ->whereNull('hidden_at'))
                ->orWhereIn('users.id', Comment::select('comments.user_id')
                    ->whereNull('comments.hidden_at')
                    ->whereHas('post', fn ($posts) => $posts
                        ->where('visibility', 'community')
                        ->whereNull('hidden_at')));
        });
    }
}
