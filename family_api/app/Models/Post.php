<?php

namespace App\Models;

use App\Support\MediaStorage;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\DB;

class Post extends Model
{
    // หมวดหมู่ของโพสต์ชุมชน (โพสต์ครอบครัวไม่มีหมวด)
    public const CATEGORIES = [
        'general',
        'qa',
        'news',
        'help',
        'event',
    ];

    public const CATEGORY_LABELS = [
        'general' => 'ทั่วไป',
        'qa' => 'ถาม-ตอบ',
        'news' => 'ข่าวสาร',
        'help' => 'ช่วยเหลือ',
        'event' => 'กิจกรรม',
    ];

    protected $fillable = [
        'family_id',
        'user_id',
        'visibility',
        'category',
        'content',
        'shared_post_id',
    ];

    // ข้อความบนแผนที่ (เช่น "ทำงานอยู่") แสดงข้างตำแหน่งของเจ้าของนานเท่านี้
    public const MAP_STATUS_HOURS = 12;

    protected $casts = [
        'hidden_at' => 'datetime',
        // ข้อความเปลี่ยนจริงครั้งล่าสุด (NULL = ไม่เคยแก้) / เพิ่มทุกครั้งที่ข้อความเปลี่ยน
        'edited_at' => 'datetime',
        'edit_version' => 'integer',
        'map_status_until' => 'datetime',
    ];

    // on_map → แอปแสดงป้าย "บนแผนที่" และเมนูเอาออก
    protected $appends = [
        'on_map',
    ];

    public function getOnMapAttribute(): bool
    {
        // บาง Query เลือกเฉพาะบางคอลัมน์ → ไม่มีค่านี้ = ไม่ได้อยู่บนแผนที่
        $until = $this->getAttributes()['map_status_until'] ?? null;

        return $until !== null && $this->asDateTime($until)->isFuture();
    }

    // แสดงบนแผนที่ได้เฉพาะโพสต์ครอบครัวที่มีข้อความ
    public function canShowOnMap(): bool
    {
        return !$this->isCommunity() && trim((string) $this->content) !== '';
    }

    // แสดงบนแผนที่ แทนข้อความเดิมของเจ้าของ (คนละ 1 ข้อความ)
    public function showOnMap(): void
    {
        DB::transaction(function () {
            static::where('user_id', $this->user_id)
                ->whereKeyNot($this->getKey())
                ->whereNotNull('map_status_until')
                ->update(['map_status_until' => null]);

            $this->map_status_until = now()->addHours(self::MAP_STATUS_HOURS);

            $this->save();
        });
    }

    // ข้อความบนแผนที่ที่ยังไม่หมดเวลา
    public function scopeOnMap($query)
    {
        return $query->where('visibility', 'family')
            ->whereNull('hidden_at')
            ->where('map_status_until', '>', now());
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    // โพสต์ต้นฉบับ (เมื่อโพสต์นี้เป็นการแชร์ต่อ)
    public function sharedPost()
    {
        return $this->belongsTo(Post::class, 'shared_post_id');
    }

    // วิดีโอ (โพสต์ละ 1 วิดีโอ)
    public function video()
    {
        return $this->hasOne(PostVideo::class);
    }

    // จำนวนครั้งที่ถูกแชร์ (ทุกช่องทาง)
    public function shares()
    {
        return $this->hasMany(Interaction::class)->where('type', Interaction::SHARE);
    }

    public function family()
    {
        return $this->belongsTo(Family::class);
    }

    public function comments()
    {
        return $this->hasMany(Comment::class)->oldest();
    }

    public function reports()
    {
        return $this->hasMany(PostReport::class);
    }

    public function likes()
    {
        return $this->hasMany(PostLike::class);
    }

    public function images()
    {
        return $this->hasMany(PostImage::class)->orderBy('sort');
    }

    // แฮชแท็กในข้อความ (#ทำอาหาร)
    public function hashtags()
    {
        return $this->belongsToMany(Hashtag::class);
    }

    public function syncHashtags(): void
    {
        $ids = collect(Hashtag::extract((string) $this->content))
            ->map(fn (string $name) => Hashtag::firstOrCreate(['name' => $name])->id);

        $this->hashtags()->sync($ids);
    }

    // ลบไฟล์รูปใน storage เมื่อโพสต์ถูกลบด้วย $post->delete()
    // (API ลบโพสต์ และปุ่มลบในหน้า Admin)
    //
    // โหลดรายการรูปไว้ก่อนลบ เพราะแถวใน post_images
    // จะถูกลบตามไปด้วย cascade และลบไฟล์หลัง Transaction สำเร็จ
    protected static function booted(): void
    {
        // สร้าง/แก้ข้อความ → ดึงแฮชแท็กใหม่
        static::saved(function (Post $post) {
            if ($post->wasRecentlyCreated || $post->wasChanged('content')) {
                $post->syncHashtags();
            }
        });

        static::deleting(function (Post $post) {
            $post->loadMissing(['images', 'video', 'comments']);
        });

        static::deleted(function (Post $post) {
            $paths = [
                ...$post->images->pluck('path')->all(),
                ...($post->video?->filePaths() ?? []),
                ...$post->comments->flatMap->mediaPaths()->all(),
            ];

            DB::afterCommit(fn () => MediaStorage::delete($paths));
        });
    }

    // ไฟล์ทั้งหมดของโพสต์ที่จะถูกลบแบบ cascade (ลบครอบครัว / ลบบัญชี)
    // รูป วิดีโอ และไฟล์แนบในความคิดเห็น — เก็บไว้ลบหลังลบข้อมูลสำเร็จ
    public static function mediaPathsOf($postIds): array
    {
        return [
            ...PostImage::whereIn('post_id', $postIds)->pluck('path')->all(),
            ...PostVideo::whereIn('post_id', $postIds)->get()
                ->flatMap(fn (PostVideo $video) => $video->filePaths())->all(),
            ...Comment::whereIn('post_id', $postIds)->whereNotNull('media_path')->get()
                ->flatMap(fn (Comment $comment) => $comment->mediaPaths())->all(),
        ];
    }

    // โพสต์ที่ผู้ใช้ทุกคนในแอปเห็นได้
    public function isCommunity(): bool
    {
        return $this->visibility === 'community';
    }

    // โพสต์ชุมชนที่ $viewer เห็นได้
    // ไม่ถูกซ่อน, $viewer ยังไม่ได้รายงาน และไม่ใช่ของคนที่ $viewer บล็อก
    public function scopeVisibleInCommunityTo($query, User $viewer, $blockedIds = null)
    {
        $blockedIds ??= $viewer->blockedUsers()->pluck('users.id');

        return $query->where('visibility', 'community')
            ->whereNull('hidden_at')
            ->whereDoesntHave('reports', function ($reports) use ($viewer) {
                $reports->where('user_id', $viewer->id);
            })
            ->whereNotIn('user_id', $blockedIds);
    }

    // โพสต์ที่ $viewer เห็นได้ในหน้าโปรไฟล์ของคนอื่น
    // โพสต์ชุมชนที่ $viewer เห็นได้ + โพสต์ครอบครัวในครอบครัวของ $viewer
    public function scopeVisibleOnProfileTo($query, User $viewer, ?int $viewerFamilyId, $blockedIds = null)
    {
        return $query->where(function ($posts) use ($viewer, $viewerFamilyId, $blockedIds) {
            $posts->where(function ($community) use ($viewer, $blockedIds) {
                $community->visibleInCommunityTo($viewer, $blockedIds);
            });

            if ($viewerFamilyId) {
                $posts->orWhere(function ($family) use ($viewerFamilyId) {
                    $family->where('visibility', 'family')
                        ->where('family_id', $viewerFamilyId);
                });
            }
        });
    }
}
