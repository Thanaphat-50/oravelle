<?php

namespace App\Support;

use App\Models\AppNotification;
use App\Models\Call;
use App\Models\User;
use App\Services\PushNotifications;

use function Illuminate\Support\defer;

// =======================================================
// แจ้งเตือนของสาย + ปิดห้อง LiveKit
// - ข้อความแจ้งเตือนมีแค่ชื่อผู้โทรและชนิดสาย ไม่มีเนื้อหาแชท
// - tag เดียวกันต่อสาย ("call-<id>"): แจ้งเตือนสายเข้าถูกแทนที่ด้วย "รับสายที่อุปกรณ์อื่นแล้ว" /
//   "สายที่ไม่ได้รับ" → เครื่องอื่นหยุดเรียก และแจ้งเตือนช้าไม่ทำให้สายเก่าดังขึ้นใหม่
// - ใช้การตั้งค่าแจ้งเตือน "ข้อความใหม่" ของผู้รับ (ปิด → ไม่เด้งแจ้งเตือน แต่เปิดแอปแล้วยังเห็นสายที่กำลังเรียก)
// - การปิดเสียงแชทกลุ่มไม่เกี่ยวกับสายโทร 1 ต่อ 1
// =======================================================

class CallSignals
{
    public const PUSH_TYPE = 'call';

    // ชื่อของ $userId ที่ $viewerId เห็น (ลูกค้าเห็นเจ้าของร้านเป็นชื่อร้าน เหมือนในแชท)
    public static function nameFor(Call $call, int $userId, int $viewerId): string
    {
        $shop = $call->conversation?->shop;

        if ($shop && (int) $shop->user_id === $userId && $viewerId !== $userId) {
            return $shop->name;
        }

        return User::whereKey($userId)->value('name') ?? 'ผู้ใช้';
    }

    public static function incoming(int $callId): void
    {
        $call = Call::with('conversation.shop', 'callee:id,notification_settings')->find($callId);

        if (!$call || $call->status !== 'ringing' || !self::wants($call)) {
            return;
        }

        $name = self::nameFor($call, (int) $call->caller_id, (int) $call->callee_id);

        app(PushNotifications::class)->sendToUser(
            (int) $call->callee_id,
            $call->type === 'video' ? 'วิดีโอคอลเข้า' : 'สายเรียกเข้า',
            $name . ($call->type === 'video' ? ' วิดีโอคอลหาคุณ' : ' โทรหาคุณ'),
            [
                'type' => self::PUSH_TYPE,
                'call_id' => $call->id,
                'status' => 'ringing',
                'call_type' => $call->type,
                'expires_at' => $call->ring_expires_at->toIso8601String(),
            ],
            'call-' . $call->id
        );
    }

    // รับสายแล้ว → แจ้งเตือนสายเข้าบนเครื่องอื่นของผู้รับถูกแทนที่ (หยุดเรียก)
    public static function answered(int $callId): void
    {
        $call = Call::with('callee:id,notification_settings')->find($callId);

        if (!$call || !self::wants($call)) {
            return;
        }

        app(PushNotifications::class)->sendToUser(
            (int) $call->callee_id,
            'สายเรียกเข้า',
            'รับสายที่อุปกรณ์อื่นแล้ว',
            ['type' => self::PUSH_TYPE, 'call_id' => $call->id, 'status' => 'accepted'],
            'call-' . $call->id
        );
    }

    public static function finished(Call $call): void
    {
        $room = (string) $call->room;
        $callId = (int) $call->id;

        defer(function () use ($room, $callId) {
            LiveKit::deleteRoom($room);
            self::notifyNotAnswered($callId);
        });
    }

    // สายที่ไม่ได้คุย (ยกเลิก / ไม่รับ / ปฏิเสธจากเครื่องอื่น / หมดสิทธิ์) → แทนที่แจ้งเตือนสายเข้า
    private static function notifyNotAnswered(int $callId): void
    {
        $call = Call::with('conversation.shop', 'callee:id,notification_settings')->find($callId);

        if (!$call || $call->accepted_at !== null || $call->status === 'busy' || !self::wants($call)) {
            return;
        }

        $declined = $call->status === 'declined';

        app(PushNotifications::class)->sendToUser(
            (int) $call->callee_id,
            $declined ? 'สายเรียกเข้า' : 'สายที่ไม่ได้รับ',
            $declined
                ? 'ปฏิเสธสายแล้ว'
                : self::nameFor($call, (int) $call->caller_id, (int) $call->callee_id) . ' โทรหาคุณ',
            ['type' => self::PUSH_TYPE, 'call_id' => $call->id, 'status' => $call->status],
            'call-' . $call->id
        );
    }

    private static function wants(Call $call): bool
    {
        return (bool) $call->callee?->wantsNotification(AppNotification::TYPE_NEW_MESSAGE);
    }
}
