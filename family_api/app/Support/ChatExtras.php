<?php

namespace App\Support;

use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Collection;
use Illuminate\Support\Str;

// =======================================================
// Reply + Reaction ของข้อความแชท (ใช้ร่วมกัน: แชทส่วนตัว/ร้านค้า และแชทกลุ่ม)
// - โหลดเป็นชุดต่อหน้า (ไม่ query ทีละข้อความ)
// - ตัวอย่างข้อความต้นทางคำนวณตามสิทธิ์ของ "ผู้ชม" ทุกครั้ง (ไม่ใช้สำเนา)
//   ผู้ชมไม่มีสิทธิ์เห็นต้นทาง / ต้นทางถูกลบ → available: false (ไม่มีข้อความ รูป หรือผู้ส่ง)
// =======================================================

class ChatExtras
{
    public const EMOJIS = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

    /**
     * @param  Collection<int, Model>  $messages
     * @param  class-string<Model>  $messageClass
     * @param  callable(Model): bool  $canSee  ผู้ชมเห็นข้อความต้นทางนี้ได้ไหม
     */
    public static function prepare(Collection $messages, string $messageClass, string $reactionClass, string $reactionKey, User $viewer, callable $canSee): array
    {
        $sourceIds = $messages->pluck('reply_to_id')->filter()->unique()->values();

        $sources = $sourceIds->isEmpty()
            ? collect()
            : $messageClass::whereIn('id', $sourceIds)->get()->keyBy('id');

        $names = $sources->isEmpty()
            ? collect()
            : User::whereIn('id', $sources->pluck('sender_id')->unique())->pluck('name', 'id');

        $rows = $messages->isEmpty()
            ? collect()
            : $reactionClass::whereIn($reactionKey, $messages->pluck('id'))->get([$reactionKey, 'user_id', 'emoji']);

        return [
            'viewer' => $viewer,
            'sources' => $sources,
            'names' => $names,
            'can_see' => $canSee,
            'reactions' => $rows->groupBy($reactionKey),
        ];
    }

    public static function replyPayload(Model $message, array $extras): ?array
    {
        if (!$message->is_reply) {
            return null;
        }

        $source = $message->reply_to_id ? ($extras['sources'][$message->reply_to_id] ?? null) : null;

        if (!$source || !($extras['can_see'])($source)) {
            return ['available' => false];
        }

        return [
            'available' => true,
            'id' => $source->id,
            'sender_name' => $extras['names'][$source->sender_id] ?? 'สมาชิก',
            'is_mine' => (int) $source->sender_id === (int) $extras['viewer']->id,
            'body' => $source->body ? Str::limit($source->body, 100) : null,
            'has_image' => $source->image_path !== null,
        ];
    }

    // [{emoji, count, mine}] เรียงตามลำดับอีโมจิที่รองรับ
    public static function reactionsPayload(Model $message, array $extras): array
    {
        return self::summarize($extras['reactions'][$message->id] ?? collect(), $extras['viewer']);
    }

    public static function summarize(Collection $rows, User $viewer): array
    {
        return collect(self::EMOJIS)
            ->map(fn (string $emoji) => [
                'emoji' => $emoji,
                'count' => $rows->where('emoji', $emoji)->count(),
                'mine' => $rows->where('emoji', $emoji)->contains(fn ($row) => (int) $row->user_id === (int) $viewer->id),
            ])
            ->filter(fn (array $item) => $item['count'] > 0)
            ->values()
            ->all();
    }
}
