<?php

namespace App\Http\Controllers;

use App\Models\Family;
use App\Models\FamilyMember;
use App\Models\GroupChat;
use App\Models\GroupChatMember;
use App\Models\GroupChatMessage;
use App\Models\User;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Throwable;

use function Illuminate\Support\defer;

// =======================================================
// แชทกลุ่มครอบครัว
//
// POST /api/group-chat/open                         ห้องของกลุ่มที่อยู่ตอนนี้ (ยังไม่มี → สร้าง)
// GET  /api/group-chats/{chat}/messages             ข้อความ (?before_id= เก่ากว่า / ?after_id= ใหม่กว่า)
// GET  /api/group-chats/{chat}/messages/{message}   ข้อความเดียว (ลิงก์รูปใหม่เมื่อลิงก์เดิมหมดอายุ)
// POST /api/group-chats/{chat}/messages             ส่งข้อความ/รูป {body, image, client_id}
// POST /api/group-chats/{chat}/read {message_id}    อ่านถึงข้อความนี้ (ไม่ถอยหลัง)
// PUT  /api/group-chats/{chat}/mute {muted}         ปิดเสียงห้อง (ของตัวเอง)
// GET  /api/group-chat-images/{message}             รูป (ลิงก์ลงลายเซ็น + ตรวจสิทธิ์ทุกครั้ง)
//
// ทุก endpoint ตรวจว่าเป็นสมาชิกปัจจุบันของกลุ่มนี้ และเห็นเฉพาะข้อความหลังเข้ากลุ่มรอบนี้
// =======================================================

class GroupChatController extends Controller
{
    private const PAGE_SIZE = 30;

    // ดึงข้อความใหม่ได้สูงสุดต่อครั้ง (มีมากกว่านี้ → has_newer แล้วดึงต่อ)
    private const NEWER_LIMIT = 100;

    public const MAX_BODY = 2000;

    public const MAX_IMAGE_KB = 4096;

    public function open(Request $request)
    {
        $me = $request->user();

        $membership = FamilyMember::where('user_id', $me->id)->first();

        if (!$membership) {
            return $this->noAccess('คุณยังไม่ได้อยู่ในกลุ่ม เข้าร่วมหรือสร้างกลุ่มก่อนจึงจะใช้แชทกลุ่มได้');
        }

        $chat = GroupChat::forFamily($membership->family_id);
        $access = $chat->accessFor($me);

        if (!$access) {
            return $this->noAccess();
        }

        return response()->json([
            'status' => true,
            'room' => $this->roomPayload($chat, $access),
        ]);
    }

    public function messages(Request $request, GroupChat $chat)
    {
        $data = $request->validate([
            'before_id' => 'nullable|integer|min:1',
            'after_id' => 'nullable|integer|min:0',
        ]);

        $me = $request->user();
        $access = $chat->accessFor($me);

        if (!$access) {
            return $this->noAccess();
        }

        $query = $access->visibleMessages()->with('sender:id,name,profile_photo');

        $hasMore = false;
        $hasNewer = false;

        if (isset($data['after_id'])) {
            // ข้อความใหม่หลังข้อความล่าสุดที่แอปมี (polling) — เฉพาะข้อมูลใหม่
            $items = $query->where('id', '>', $data['after_id'])
                ->orderBy('id')
                ->limit(self::NEWER_LIMIT + 1)
                ->get();

            $hasNewer = $items->count() > self::NEWER_LIMIT;
            $items = $items->take(self::NEWER_LIMIT);
        } else {
            $items = $query
                ->when($data['before_id'] ?? null, fn ($messages, $before) => $messages->where('id', '<', $before))
                ->orderByDesc('id')
                ->limit(self::PAGE_SIZE + 1)
                ->get();

            $hasMore = $items->count() > self::PAGE_SIZE;
            $items = $items->take(self::PAGE_SIZE)->reverse();
        }

        return response()->json([
            'status' => true,
            'room' => $this->roomPayload($chat, $access),
            'messages' => $items->map(fn (GroupChatMessage $message) => $this->messagePayload($message, $me))->values(),
            'has_more' => $hasMore,
            'has_newer' => $hasNewer,
        ]);
    }

    public function show(Request $request, GroupChat $chat, GroupChatMessage $message)
    {
        $me = $request->user();
        $access = $chat->accessFor($me);

        if (!$access || !$this->canSee($access, $message)) {
            return $this->noAccess('ไม่พบข้อความนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว');
        }

        return response()->json([
            'status' => true,
            'message' => $this->messagePayload($message->load('sender:id,name,profile_photo'), $me),
        ]);
    }

    public function send(Request $request, GroupChat $chat)
    {
        $me = $request->user();

        if (!$chat->accessFor($me)) {
            return $this->noAccess();
        }

        $data = $request->validate([
            'body' => 'required_without:image|nullable|string|max:' . self::MAX_BODY,
            'image' => 'nullable|image|mimes:jpg,jpeg,png,webp|max:' . self::MAX_IMAGE_KB,
            'client_id' => 'required|string|max:64',
        ], [
            'body.required_without' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
            'body.max' => 'ข้อความยาวได้ไม่เกิน 2,000 ตัวอักษร',
            'image.image' => 'รองรับเฉพาะรูป JPG, PNG หรือ WEBP',
            'image.mimes' => 'รองรับเฉพาะรูป JPG, PNG หรือ WEBP',
            'image.max' => 'รูปต้องมีขนาดไม่เกิน 4 MB',
            'client_id.required' => 'กรุณาอัปเดตแอปแล้วลองใหม่',
        ]);

        $body = isset($data['body']) ? trim($data['body']) : '';

        // ส่งซ้ำ (หมดเวลารอแต่เซิร์ฟเวอร์บันทึกแล้ว / กดส่งใหม่) → ข้อความเดิม
        if ($sent = $this->sentBefore($chat, $me, $data['client_id'])) {
            return $this->sentResponse($sent, $me, 200);
        }

        if ($body === '' && !$request->hasFile('image')) {
            return response()->json([
                'status' => false,
                'message' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
            ], 422);
        }

        $imagePath = $request->hasFile('image')
            ? $request->file('image')->store('group_chat_images', GroupChatMessage::disk())
            : null;

        try {
            $message = DB::transaction(function () use ($chat, $me, $body, $imagePath, $data) {
                // ล็อกแถวสมาชิกรอบนี้: ถูกนำออกพร้อมกัน → ฝั่งที่ลบรอ หรือเราเห็นว่าหมดสิทธิ์แล้ว
                // (ไม่รับข้อความหลังหมดสิทธิ์ตามลำดับธุรกรรม)
                $membership = FamilyMember::where('user_id', $me->id)
                    ->where('family_id', $chat->family_id)
                    ->lockForUpdate()
                    ->first();

                $access = $membership
                    ? GroupChatMember::where('family_member_id', $membership->id)->first()
                    : null;

                if (!$access) {
                    return null;
                }

                $message = GroupChatMessage::create([
                    'group_chat_id' => $chat->id,
                    'sender_id' => $me->id,
                    'client_id' => $data['client_id'],
                    'body' => $body === '' ? null : $body,
                    'image_path' => $imagePath,
                ]);

                $chat->forceFill(['last_message_at' => $message->created_at])->save();

                // ข้อความของเราเอง = อ่านแล้ว
                $access->markReadUpTo($message->id);

                return $message;
            });
        } catch (UniqueConstraintViolationException $e) {
            // ส่งซ้ำเข้ามาพร้อมกัน: อีกคำขอบันทึกไปก่อน → ใช้ข้อความนั้น
            GroupChatMessage::deleteFiles([$imagePath]);

            $sent = $this->sentBefore($chat, $me, $data['client_id']);

            if (!$sent) {
                throw $e;
            }

            return $this->sentResponse($sent, $me, 200);
        } catch (Throwable $e) {
            GroupChatMessage::deleteFiles([$imagePath]);

            throw $e;
        }

        if (!$message) {
            GroupChatMessage::deleteFiles([$imagePath]);

            return $this->noAccess();
        }

        // แจ้งเตือนหลังตอบแอปแล้ว (ตรวจสิทธิ์ผู้รับใหม่ตอนส่งจริง)
        $messageId = $message->id;
        defer(fn () => GroupChat::notifyNewMessage($messageId));

        return $this->sentResponse($message->load('sender:id,name,profile_photo'), $me, 201);
    }

    public function read(Request $request, GroupChat $chat)
    {
        $data = $request->validate(['message_id' => 'required|integer|min:1']);

        $access = $chat->accessFor($request->user());

        if (!$access) {
            return $this->noAccess();
        }

        // ไม่เกินข้อความล่าสุดที่มีอยู่จริง
        $access->markReadUpTo(min((int) $data['message_id'], $chat->latestMessageId()));

        return response()->json([
            'status' => true,
            'unread_count' => $access->unreadCount(),
            'last_read_id' => $access->last_read_id,
        ]);
    }

    public function mute(Request $request, GroupChat $chat)
    {
        $data = $request->validate(['muted' => 'required|boolean']);

        $access = $chat->accessFor($request->user());

        if (!$access) {
            return $this->noAccess();
        }

        $access->forceFill(['muted' => (bool) $data['muted']])->save();

        return response()->json([
            'status' => true,
            'muted' => $access->muted,
            'message' => $access->muted
                ? 'ปิดเสียงแจ้งเตือนห้องนี้แล้ว ยังรับข้อความตามปกติ'
                : 'เปิดเสียงแจ้งเตือนห้องนี้แล้ว',
        ]);
    }

    // รูปในห้อง: ลิงก์ลงลายเซ็น (สร้างให้เฉพาะผู้มีสิทธิ์) + ตรวจสิทธิ์ของผู้ดูซ้ำทุกครั้ง
    public function image(Request $request, GroupChatMessage $message)
    {
        $viewer = User::find((int) $request->query('viewer'));
        $chat = $message->chat;
        $access = $viewer && $chat ? $chat->accessFor($viewer) : null;

        if (!$access || !$this->canSee($access, $message) || !$message->image_path) {
            return response()->json([
                'status' => false,
                'message' => 'คุณไม่มีสิทธิ์ดูรูปนี้แล้ว',
            ], 403);
        }

        $disk = Storage::disk(GroupChatMessage::disk());

        if (!$disk->exists($message->image_path)) {
            return response()->json(['status' => false, 'message' => 'ไม่พบรูปนี้'], 404);
        }

        return $disk->response($message->image_path, null, [
            'Cache-Control' => 'private, max-age=300',
            'X-Content-Type-Options' => 'nosniff',
        ]);
    }

    // =====================================================
    // Helpers
    // =====================================================

    private function canSee(GroupChatMember $access, GroupChatMessage $message): bool
    {
        return (int) $message->group_chat_id === (int) $access->group_chat_id
            && $message->id > $access->visible_after_id;
    }

    private function sentBefore(GroupChat $chat, User $me, string $clientId): ?GroupChatMessage
    {
        return GroupChatMessage::where('group_chat_id', $chat->id)
            ->where('sender_id', $me->id)
            ->where('client_id', $clientId)
            ->with('sender:id,name,profile_photo')
            ->first();
    }

    private function sentResponse(GroupChatMessage $message, User $me, int $status)
    {
        return response()->json([
            'status' => true,
            'message' => $this->messagePayload($message, $me),
        ], $status);
    }

    private function roomPayload(GroupChat $chat, GroupChatMember $access): array
    {
        return [
            'id' => $chat->id,
            'family_id' => $chat->family_id,
            // ชื่อกลุ่มล่าสุดเสมอ (เปลี่ยนชื่อกลุ่ม → ชื่อห้องเปลี่ยนตาม)
            'name' => Family::whereKey($chat->family_id)->value('name') ?? 'แชทกลุ่ม',
            'members_count' => FamilyMember::where('family_id', $chat->family_id)->count(),
            'muted' => $access->muted,
            'last_read_id' => $access->last_read_id,
            'unread_count' => $access->unreadCount(),
        ];
    }

    // ผู้ส่ง: id ชื่อ รูป เท่านั้น (ไม่มีอีเมล เบอร์โทร หรือข้อมูลบัญชี)
    private function messagePayload(GroupChatMessage $message, User $me): array
    {
        $mine = (int) $message->sender_id === (int) $me->id;
        $sender = $message->sender;

        return [
            'id' => $message->id,
            'sender' => [
                'id' => $message->sender_id,
                'name' => $sender?->name ?? 'สมาชิก',
                'profile_image_url' => $sender?->profile_image_url,
            ],
            'is_mine' => $mine,
            // รหัสจากแอปของผู้ส่ง (จับคู่ข้อความที่กำลังส่ง) — ส่งให้ผู้ส่งเท่านั้น
            'client_id' => $mine ? $message->client_id : null,
            'body' => $message->body,
            'image_url' => $message->imageUrlFor($me),
            'created_at' => $message->created_at?->toIso8601String(),
        ];
    }

    private function noAccess(?string $message = null)
    {
        return response()->json([
            'status' => false,
            'code' => 'not_member',
            'message' => $message ?? 'คุณไม่ได้อยู่ในกลุ่มนี้แล้ว จึงเปิดหรือส่งข้อความในแชทกลุ่มไม่ได้',
        ], 403);
    }
}
