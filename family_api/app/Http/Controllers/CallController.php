<?php

namespace App\Http\Controllers;

use App\Models\Call;
use App\Models\Conversation;
use App\Models\User;
use App\Support\AppSessions;
use App\Support\CallSignals;
use App\Support\ChatAccess;
use App\Support\LiveKit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Laravel\Sanctum\PersonalAccessToken;

use function Illuminate\Support\defer;

// =======================================================
// โทรเสียง / วิดีโอคอล 1 ต่อ 1 (แชทส่วนตัว / ร้านค้า)
// - Laravel ทำแค่สถานะสาย + ตรวจสิทธิ์ + ออก token อายุสั้น / เสียงและวิดีโอวิ่งผ่าน LiveKit
// - ตรวจสิทธิ์ห้องแชทเดิม (บล็อก / อยู่กลุ่มเดียวกัน / ลูกค้า-ร้าน) และเซสชัน ตอนเริ่ม รับ และระหว่างสาย
// - คนละ 1 สายพร้อมกัน: ผู้รับมีสายอยู่ → busy / ผู้โทรมีสายอยู่ → 409
// - รับสายพร้อมกันหลายเครื่อง: อัปเดตแบบมีเงื่อนไข เครื่องเดียวสำเร็จ ที่เหลือได้ 409
// - ระหว่างสายแอปส่ง heartbeat ทุก ~15 วินาที: หมดสิทธิ์/เซสชันถูกเพิกถอน → จบสาย + ลบห้อง LiveKit
// - LiveKit ยังไม่ได้ตั้งค่า → 503 (แอปไม่แสดงปุ่มโทร)
// =======================================================

class CallController extends Controller
{
    public function start(Request $request)
    {
        $data = $request->validate([
            'conversation_id' => 'required|integer|min:1',
            'type' => 'required|in:audio,video',
        ]);

        $me = $request->user();

        if (!LiveKit::configured()) {
            return response()->json([
                'status' => false,
                'code' => 'calls_unavailable',
                'message' => 'ระบบโทรยังไม่พร้อมใช้งาน',
            ], 503);
        }

        $conversation = Conversation::with('shop')->find($data['conversation_id']);

        if (!$conversation || !$conversation->hasMember($me->id)) {
            return $this->notFound();
        }

        $otherId = $conversation->otherUserId($me->id);

        if (!ChatAccess::canSend($me, $otherId, $conversation)) {
            return response()->json([
                'status' => false,
                'code' => 'not_allowed',
                'message' => 'โทรหาคนนี้ไม่ได้',
            ], 403);
        }

        $call = DB::transaction(function () use ($me, $otherId, $conversation, $data) {
            // ล็อกผู้ใช้ทั้งสองตามลำดับ id: โทรหากันพร้อมกันสองฝั่ง → ทำทีละคำขอ
            User::whereIn('id', [$me->id, $otherId])->orderBy('id')->lockForUpdate()->get(['id']);

            $active = Call::whereIn('status', Call::ACTIVE)
                ->where(fn ($calls) => $calls
                    ->whereIn('caller_id', [$me->id, $otherId])
                    ->orWhereIn('callee_id', [$me->id, $otherId]))
                ->get()
                ->each(fn (Call $call) => $call->settle())
                ->filter(fn (Call $call) => $call->isActive());

            if ($active->contains(fn (Call $call) => $call->isParticipant((int) $me->id))) {
                return null;
            }

            $busy = $active->contains(fn (Call $call) => $call->isParticipant($otherId));

            return Call::create([
                'conversation_id' => $conversation->id,
                'caller_id' => $me->id,
                'callee_id' => $otherId,
                'type' => $data['type'],
                'status' => $busy ? 'busy' : 'ringing',
                'end_reason' => $busy ? 'busy' : null,
                'ended_at' => $busy ? now() : null,
                'room' => 'call_' . Str::lower(Str::random(32)),
                'caller_token_id' => AppSessions::currentId($me),
                'ring_expires_at' => now()->addSeconds(Call::RING_SECONDS),
            ]);
        });

        if (!$call) {
            return response()->json([
                'status' => false,
                'code' => 'already_in_call',
                'message' => 'คุณมีสายที่กำลังใช้งานอยู่',
            ], 409);
        }

        // สายไม่ว่าง: ไม่เรียกเข้า ไม่ออก token
        if ($call->status === 'busy') {
            return response()->json(['status' => true, 'call' => $this->payload($call, $me)], 201);
        }

        $callId = $call->id;
        defer(fn () => CallSignals::incoming($callId));

        // ผู้โทรเข้าห้องรอได้เลย (เวลาสายเริ่มนับเมื่ออีกฝ่ายเชื่อมต่อจริง)
        return response()->json([
            'status' => true,
            'call' => $this->payload($call, $me),
            'livekit' => $this->joinInfo($call, $me),
        ], 201);
    }

    // สายที่กำลังเรียกเข้าหาเรา (เปิดแอปจากแจ้งเตือน / กลับเข้าแอป)
    public function active(Request $request)
    {
        $me = $request->user();

        $call = Call::with('conversation.shop')
            ->where('callee_id', $me->id)
            ->where('status', 'ringing')
            ->latest('id')
            ->first()
            ?->settle();

        return response()->json([
            'status' => true,
            'call' => $call && $call->status === 'ringing' ? $this->payload($call, $me) : null,
        ]);
    }

    public function show(Request $request, Call $call)
    {
        $me = $request->user();

        if (!$call->isParticipant((int) $me->id)) {
            return $this->notFound();
        }

        $call->settle();

        return response()->json(['status' => true, 'call' => $this->payload($call, $me)]);
    }

    public function accept(Request $request, Call $call)
    {
        $me = $request->user();

        if ((int) $call->callee_id !== (int) $me->id) {
            return $this->notFound();
        }

        $call->settle();

        // หมดสิทธิ์ระหว่างเรียกเข้า (บล็อก / ออกจากกลุ่ม / เซสชันผู้โทรถูกเพิกถอน)
        if ($call->status === 'ringing' && ($reason = $this->deniedReason($call))) {
            $call->finish('failed', $reason);
        }

        $accepted = Call::whereKey($call->id)
            ->where('status', 'ringing')
            ->where('ring_expires_at', '>', now())
            ->update([
                'status' => 'accepted',
                'accepted_at' => now(),
                'last_seen_at' => now(),
                'callee_token_id' => AppSessions::currentId($me),
                'updated_at' => now(),
            ]) > 0;

        $call->refresh();

        if (!$accepted) {
            return $this->conflict($call, $me);
        }

        $callId = $call->id;
        defer(fn () => CallSignals::answered($callId));

        return response()->json([
            'status' => true,
            'call' => $this->payload($call, $me),
            'livekit' => $this->joinInfo($call, $me),
        ]);
    }

    public function decline(Request $request, Call $call)
    {
        $me = $request->user();

        if ((int) $call->callee_id !== (int) $me->id) {
            return $this->notFound();
        }

        $call->settle();

        if ($call->status === 'ringing') {
            $call->finish('declined', 'declined');
        }

        return response()->json(['status' => true, 'call' => $this->payload($call, $me)]);
    }

    // วางสาย: ผู้โทรระหว่างเรียก = ยกเลิก / ผู้รับระหว่างเรียก = ปฏิเสธ / ระหว่างคุย = จบสาย (ส่งซ้ำได้)
    public function hangup(Request $request, Call $call)
    {
        $me = $request->user();

        if (!$call->isParticipant((int) $me->id)) {
            return $this->notFound();
        }

        $call->settle();

        if ($call->status === 'ringing') {
            (int) $call->caller_id === (int) $me->id
                ? $call->finish('cancelled', 'caller_cancelled')
                : $call->finish('declined', 'declined');
        } elseif ($call->status === 'accepted') {
            $call->finish('ended', 'hangup');
        }

        return response()->json(['status' => true, 'call' => $this->payload($call, $me)]);
    }

    // ระหว่างสาย (และผู้โทรระหว่างรอ): ตรวจสิทธิ์/เซสชันซ้ำ + token ใหม่สำหรับเชื่อมต่อใหม่
    public function heartbeat(Request $request, Call $call)
    {
        $me = $request->user();

        if (!$call->isParticipant((int) $me->id)) {
            return $this->notFound();
        }

        $call->settle();

        if ($call->isActive() && ($reason = $this->deniedReason($call))) {
            $call->finish('failed', $reason);

            return response()->json([
                'status' => false,
                'code' => $reason,
                'message' => $reason === 'session_revoked'
                    ? 'สายถูกตัด เพราะมีการออกจากระบบของอุปกรณ์ที่ใช้โทร'
                    : 'สายถูกตัด เพราะไม่มีสิทธิ์คุยกันแล้ว',
                'call' => $this->payload($call, $me),
            ], 403);
        }

        $joinable = $call->status === 'accepted'
            || ($call->status === 'ringing' && (int) $call->caller_id === (int) $me->id);

        if ($call->status === 'accepted') {
            Call::whereKey($call->id)->update(['last_seen_at' => now()]);
        }

        return response()->json([
            'status' => true,
            'call' => $this->payload($call, $me),
            ...($joinable ? ['livekit' => $this->joinInfo($call, $me)] : []),
        ]);
    }

    // =====================================================
    // Helpers
    // =====================================================

    // ยังคุยกันได้ไหม: สิทธิ์ห้องแชทเดิม + เซสชันที่ใช้เริ่ม/รับสายยังไม่ถูกเพิกถอน
    private function deniedReason(Call $call): ?string
    {
        $caller = User::find($call->caller_id);
        $conversation = $call->conversation;

        if (!$caller || !$conversation || !User::whereKey($call->callee_id)->exists()
            || !ChatAccess::canSend($caller, (int) $call->callee_id, $conversation)) {
            return 'not_allowed';
        }

        foreach ([$call->caller_token_id, $call->callee_token_id] as $tokenId) {
            if ($tokenId !== null && !PersonalAccessToken::whereKey($tokenId)->exists()) {
                return 'session_revoked';
            }
        }

        return null;
    }

    private function joinInfo(Call $call, User $me): array
    {
        $other = $call->otherId((int) $me->id);

        return [
            'url' => LiveKit::clientUrl(),
            'token' => LiveKit::joinToken(
                (string) $call->room,
                'u' . $me->id,
                CallSignals::nameFor($call, (int) $me->id, $other),
                $call->type === 'video'
            ),
            'expires_in' => LiveKit::TOKEN_TTL,
        ];
    }

    private function payload(Call $call, User $viewer): array
    {
        $otherId = $call->otherId((int) $viewer->id);
        $shop = $call->conversation?->shop;
        $asShop = $shop && (int) $shop->user_id === $otherId;
        $other = User::find($otherId, ['id', 'name', 'profile_photo']);

        return [
            'id' => $call->id,
            'conversation_id' => $call->conversation_id,
            'type' => $call->type,
            'status' => $call->status,
            'role' => (int) $call->caller_id === (int) $viewer->id ? 'caller' : 'callee',
            'other' => [
                'id' => $otherId,
                'name' => $asShop ? $shop->name : ($other?->name ?? 'ผู้ใช้'),
                'profile_image_url' => $asShop ? $shop->logo_url : $other?->profile_image_url,
            ],
            'ring_expires_at' => $call->ring_expires_at?->toIso8601String(),
            'accepted_at' => $call->accepted_at?->toIso8601String(),
            'ended_at' => $call->ended_at?->toIso8601String(),
            'end_reason' => $call->end_reason,
            'server_time' => now()->toIso8601String(),
        ];
    }

    private function conflict(Call $call, User $me)
    {
        return response()->json([
            'status' => false,
            'code' => 'call_' . $call->status,
            'message' => match ($call->status) {
                'accepted' => 'รับสายที่อุปกรณ์อื่นแล้ว',
                'cancelled' => 'ผู้โทรยกเลิกสายแล้ว',
                'missed' => 'สายนี้หมดเวลาแล้ว',
                'declined' => 'ปฏิเสธสายนี้แล้ว',
                'ended' => 'สายนี้จบแล้ว',
                default => 'สายนี้ใช้งานไม่ได้แล้ว',
            },
            'call' => $this->payload($call, $me),
        ], 409);
    }

    private function notFound()
    {
        return response()->json(['status' => false, 'message' => 'ไม่พบสายนี้'], 404);
    }
}
