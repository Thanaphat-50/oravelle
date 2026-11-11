<?php

namespace App\Http\Controllers;

use App\Models\Family;
use App\Models\FamilyMember;
use App\Models\GroupChat;
use App\Models\GroupChatMember;
use App\Models\GroupChatMessage;
use App\Models\GroupChatMessageReaction;
use App\Models\User;
use App\Support\ChatAttachment;
use App\Support\ChatExtras;
use Illuminate\Support\Collection;
use Illuminate\Validation\Rule;
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
            // สถานะ (Reaction / อ่านแล้ว X คน) ของข้อความที่โหลดไว้แล้ว id >= ค่านี้ ถึง after_id (ไม่เกิน 100)
            'states_from' => 'nullable|integer|min:1',
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

        $extras = $this->extrasFor($items, $access, $me);

        return response()->json([
            'status' => true,
            'room' => $this->roomPayload($chat, $access),
            'messages' => $items->map(fn (GroupChatMessage $message) => $this->messagePayload($message, $me, $extras))->values(),
            'has_more' => $hasMore,
            'has_newer' => $hasNewer,
            'states' => $this->states($chat, $access, $me, $data),
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
            'message' => $this->messagePayload(
                $message->load('sender:id,name,profile_photo'),
                $me,
                $this->extrasFor(collect([$message]), $access, $me)
            ),
        ]);
    }

    public function send(Request $request, GroupChat $chat)
    {
        $me = $request->user();

        if (!$chat->accessFor($me)) {
            return $this->noAccess();
        }

        $data = $request->validate([
            'body' => 'required_without_all:image,file,voice|nullable|string|max:' . self::MAX_BODY,
            'image' => 'nullable|image|mimes:jpg,jpeg,png,webp|max:' . self::MAX_IMAGE_KB,
            'client_id' => 'required|string|max:64',
            'reply_to_id' => 'nullable|integer|min:1',
            ...ChatAttachment::rules(),
        ], [
            ...ChatAttachment::messages(),
            'body.required_without_all' => 'กรุณาพิมพ์ข้อความหรือแนบไฟล์',
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

        // ตอบกลับได้เฉพาะข้อความในห้องเดียวกันที่ผู้ส่งเห็นได้ (ขอบเขตรอบสมาชิกของผู้ส่ง)
        $replyTo = null;

        if (isset($data['reply_to_id'])) {
            $senderAccess = $chat->accessFor($me);
            $replyTo = GroupChatMessage::where('group_chat_id', $chat->id)->whereKey($data['reply_to_id'])->first();

            if (!$replyTo || !$senderAccess || !$this->canSee($senderAccess, $replyTo)) {
                return response()->json([
                    'status' => false,
                    'code' => 'reply_unavailable',
                    'message' => 'ข้อความที่ต้องการตอบกลับไม่พร้อมใช้งานแล้ว',
                    'errors' => ['reply_to_id' => ['ข้อความที่ต้องการตอบกลับไม่พร้อมใช้งานแล้ว']],
                ], 422);
            }
        }

        // ไฟล์/เสียง: ตรวจชนิดจากเนื้อไฟล์จริง + จำกัดความถี่ (ไม่ผ่าน → 422/429)
        $attachment = ChatAttachment::inspect($request, $me->id);

        if (($attachment['kind'] ?? null) === 'voice') {
            $body = '';
        }

        if ($body === '' && !$request->hasFile('image') && !$attachment) {
            return response()->json([
                'status' => false,
                'message' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
            ], 422);
        }

        $imagePath = $request->hasFile('image')
            ? $request->file('image')->store('group_chat_images', GroupChatMessage::disk())
            : null;

        $attachmentPath = $attachment ? ChatAttachment::store($attachment, 'group_chat_files') : null;

        try {
            $message = DB::transaction(function () use ($chat, $me, $body, $imagePath, $data, $replyTo, $attachment, $attachmentPath) {
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
                    'reply_to_id' => $replyTo?->id,
                    'is_reply' => $replyTo !== null,
                    ...ChatAttachment::columns($attachment, $attachmentPath),
                ]);

                $chat->forceFill(['last_message_at' => $message->created_at])->save();

                // ข้อความของเราเอง = อ่านแล้ว
                $access->markReadUpTo($message->id);

                return $message;
            });
        } catch (UniqueConstraintViolationException $e) {
            // ส่งซ้ำเข้ามาพร้อมกัน: อีกคำขอบันทึกไปก่อน → ใช้ข้อความนั้น (ไม่เหลือไฟล์กำพร้า)
            GroupChatMessage::deleteFiles([$imagePath, $attachmentPath]);

            $sent = $this->sentBefore($chat, $me, $data['client_id']);

            if (!$sent) {
                throw $e;
            }

            return $this->sentResponse($sent, $me, 200);
        } catch (Throwable $e) {
            GroupChatMessage::deleteFiles([$imagePath, $attachmentPath]);

            throw $e;
        }

        if (!$message) {
            GroupChatMessage::deleteFiles([$imagePath, $attachmentPath]);

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

    // ไฟล์แนบ/ข้อความเสียง: ลิงก์ลงลายเซ็น (สร้างให้เฉพาะผู้มีสิทธิ์) + ตรวจสิทธิ์ของผู้ดูซ้ำทุกครั้ง
    // สมาชิกใหม่/กลับเข้ากลุ่มรอบใหม่ เปิดไฟล์ของรอบเก่าไม่ได้ / ออกจากกลุ่มแล้วเปิดไม่ได้
    public function file(Request $request, GroupChatMessage $message)
    {
        $viewer = User::find((int) $request->query('viewer'));
        $chat = $message->chat;
        $access = $viewer && $chat ? $chat->accessFor($viewer) : null;

        if (!$access || !$this->canSee($access, $message) || !$message->attachment_path) {
            return response()->json([
                'status' => false,
                'message' => 'คุณไม่มีสิทธิ์เปิดไฟล์นี้แล้ว',
            ], 403);
        }

        return ChatAttachment::respond($message);
    }

    // =====================================================
    // PUT    /api/group-chats/{chat}/messages/{message}/reaction {emoji}  ตั้ง (ส่งซ้ำได้)
    // DELETE /api/group-chats/{chat}/messages/{message}/reaction          ถอน (ส่งซ้ำได้)
    // สมาชิกปัจจุบันที่เห็นข้อความนั้นเท่านั้น / ไม่นับ unread / ไม่ส่งแจ้งเตือน
    // =====================================================

    public function react(Request $request, GroupChat $chat, GroupChatMessage $message)
    {
        $me = $request->user();
        $access = $chat->accessFor($me);

        if (!$access || !$this->canSee($access, $message)) {
            return $this->noAccess('ไม่พบข้อความนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว');
        }

        $data = $request->validate(['emoji' => ['required', Rule::in(ChatExtras::EMOJIS)]]);

        try {
            GroupChatMessageReaction::updateOrCreate(
                ['group_chat_message_id' => $message->id, 'user_id' => $me->id],
                ['emoji' => $data['emoji']]
            );
        } catch (UniqueConstraintViolationException) {
            GroupChatMessageReaction::where('group_chat_message_id', $message->id)->where('user_id', $me->id)->update(['emoji' => $data['emoji']]);
        }

        return $this->reactionsResponse($message, $me);
    }

    public function unreact(Request $request, GroupChat $chat, GroupChatMessage $message)
    {
        $me = $request->user();
        $access = $chat->accessFor($me);

        if (!$access || !$this->canSee($access, $message)) {
            return $this->noAccess('ไม่พบข้อความนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว');
        }

        GroupChatMessageReaction::where('group_chat_message_id', $message->id)->where('user_id', $me->id)->delete();

        return $this->reactionsResponse($message, $me);
    }

    private function reactionsResponse(GroupChatMessage $message, User $me)
    {
        return response()->json([
            'status' => true,
            'message_id' => $message->id,
            'reactions' => ChatExtras::summarize(
                GroupChatMessageReaction::where('group_chat_message_id', $message->id)->get(['user_id', 'emoji']),
                $me
            ),
        ]);
    }

    // =====================================================
    // Helpers
    // =====================================================

    // Reply / Reaction / ผู้อ่าน ของข้อความชุดนี้ (โหลดรวดเดียว)
    // ต้นทางของ Reply: ผู้ชมต้องเห็นได้ (ห้องเดียวกัน + หลังเข้ากลุ่มรอบนี้) ไม่งั้น "ไม่พร้อมใช้งาน"
    private function extrasFor(Collection $messages, ?GroupChatMember $access, User $me): array
    {
        $extras = ChatExtras::prepare(
            $messages,
            GroupChatMessage::class,
            GroupChatMessageReaction::class,
            'group_chat_message_id',
            $me,
            fn (GroupChatMessage $source) => $access !== null && $this->canSee($access, $source)
        );

        // สมาชิกรอบปัจจุบันเท่านั้น (ออก/ถูกนำออก → แถวถูกลบ ไม่ถูกนับ)
        $extras['members'] = $access && $messages->contains(fn ($message) => (int) $message->sender_id === (int) $me->id)
            ? GroupChatMember::where('group_chat_id', $access->group_chat_id)->get(['user_id', 'last_read_id', 'visible_after_id'])
            : collect();

        return $extras;
    }

    // อ่านแล้ว X คน: สมาชิกปัจจุบัน (ไม่นับผู้ส่ง) ที่เห็นข้อความนี้ได้ และอ่านถึงข้อความนี้แล้ว
    private function readCount(GroupChatMessage $message, Collection $members): int
    {
        return $members
            ->filter(fn (GroupChatMember $member) => (int) $member->user_id !== (int) $message->sender_id
                && $member->visible_after_id < $message->id
                && $member->last_read_id >= $message->id)
            ->count();
    }

    // สถานะของข้อความที่โหลดไว้แล้ว (ตอนดึงข้อความใหม่) — ชุดเดียว ไม่ยิงทีละข้อความ
    private function states(GroupChat $chat, GroupChatMember $access, User $me, array $data): array
    {
        if (!isset($data['states_from'], $data['after_id'])) {
            return [];
        }

        $messages = $access->visibleMessages()
            ->where('id', '>=', $data['states_from'])
            ->where('id', '<=', $data['after_id'])
            ->orderByDesc('id')
            ->limit(100)
            ->get(['id', 'group_chat_id', 'sender_id']);

        $extras = $this->extrasFor($messages, $access, $me);

        return $messages->map(fn (GroupChatMessage $message) => [
            'id' => $message->id,
            'reactions' => ChatExtras::reactionsPayload($message, $extras),
            'read_count' => (int) $message->sender_id === (int) $me->id ? $this->readCount($message, $extras['members']) : null,
        ])->values()->all();
    }

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
    private function messagePayload(GroupChatMessage $message, User $me, ?array $extras = null): array
    {
        $mine = (int) $message->sender_id === (int) $me->id;
        $sender = $message->sender;

        $extras ??= $this->extrasFor(collect([$message]), $message->chat?->accessFor($me), $me);

        return [
            'reply_to' => ChatExtras::replyPayload($message, $extras),
            'reactions' => ChatExtras::reactionsPayload($message, $extras),
            // ส่งแล้ว (บันทึกบนเซิร์ฟเวอร์) + อ่านแล้ว X คน — เฉพาะข้อความของเรา
            'read_count' => $mine ? $this->readCount($message, $extras['members']) : null,
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
            'attachment' => ChatAttachment::payload($message, 'group-chat.file', (int) $me->id),
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
