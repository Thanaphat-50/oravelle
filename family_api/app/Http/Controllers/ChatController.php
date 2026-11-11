<?php

namespace App\Http\Controllers;

use App\Models\AppNotification;
use App\Models\ChatMessage;
use App\Models\ChatMessageReaction;
use App\Models\Conversation;
use App\Models\Family;
use App\Models\FamilyMember;
use App\Models\GroupChat;
use App\Models\Order;
use App\Models\Shop;
use App\Models\User;
use App\Models\UserBlock;
use App\Services\PushNotifications;
use App\Support\ChatAttachment;
use App\Support\ChatExtras;
use App\Support\MediaStorage;
use Illuminate\Support\Collection;
use Illuminate\Validation\Rule;
use Illuminate\Database\UniqueConstraintViolationException;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Throwable;

use function Illuminate\Support\defer;

// =======================================================
// แชทส่วนตัว (คนในกลุ่มเดียวกัน หรือลูกค้ากับร้านที่ทักจากหน้าสินค้า/ร้าน)
// - ส่งข้อความ / รูปได้ ยกเลิกการส่งข้อความของตัวเองได้
// - ออกจากครอบครัวแล้ว: อ่านแชทเก่าได้ แต่ส่งต่อไม่ได้
// - แอปดึงข้อความใหม่เป็นระยะขณะเปิดห้องแชท + แจ้งเตือนเด้ง
// =======================================================

class ChatController extends Controller
{
    private const PAGE_SIZE = 30;

    private const MAX_IMAGE_KB = 4096;

    // =====================================================
    // GET /api/chats
    // ห้องแชทของเรา + รายชื่อคนในครอบครัว (เริ่มแชทใหม่)
    // =====================================================

    public function index(Request $request)
    {
        $me = $request->user();

        $familyIds = $this->familyMemberIds($me);

        $conversations = Conversation::of($me->id)
            ->with('shop:id,user_id,name,logo_path')
            ->whereNotNull('last_message_at')
            ->orderByDesc('last_message_at')
            ->get();

        // toBase(): ยังไม่มีห้องเลย → Eloquent Collection ว่าง merge ตัวเลขไม่ได้
        $otherIds = $conversations->toBase()
            ->map(fn (Conversation $conversation) => $conversation->otherUserId($me->id))
            ->merge($familyIds)
            ->unique()
            ->values();

        $users = User::whereIn('id', $otherIds)
            ->get(['id', 'name', 'profile_photo'])
            ->keyBy('id');

        $lastMessages = ChatMessage::whereIn(
            'id',
            ChatMessage::whereIn('conversation_id', $conversations->pluck('id'))
                ->selectRaw('max(id)')
                ->groupBy('conversation_id')
        )->get()->keyBy('conversation_id');

        $blockedIds = $this->blockedEitherWay($me);

        $rooms = $conversations->map(function (Conversation $conversation) use ($me, $users, $lastMessages, $familyIds, $blockedIds) {
            $otherId = $conversation->otherUserId($me->id);

            $last = $lastMessages->get($conversation->id);

            return [
                'id' => $conversation->id,
                'user' => $this->roomUserPayload($conversation, $me, $users->get($otherId), $otherId),
                'shop' => $this->shopPayload($conversation, $me),
                'last_message' => $last ? [
                    'body' => $last->body ? Str::limit($last->body, 80) : null,
                    'has_image' => $last->image_path !== null,
                    'attachment_kind' => $last->attachment_kind,
                    'is_mine' => (int) $last->sender_id === (int) $me->id,
                    'created_at' => $last->created_at?->toIso8601String(),
                ] : null,
                'unread_count' => $conversation->unreadCountFor($me->id),
                'can_send' => !$blockedIds->contains($otherId)
                    && ($familyIds->contains($otherId) || $conversation->isShopChatWith($me->id, $otherId)),
            ];
        })->values();

        $roomByUser = $conversations->mapWithKeys(
            fn (Conversation $conversation) => [$conversation->otherUserId($me->id) => $conversation->id]
        );

        $contacts = $familyIds
            ->map(fn ($id) => [
                ...$this->userPayload($users->get($id), (int) $id),
                'conversation_id' => $roomByUser->get($id),
            ])
            ->values();

        return response()->json([
            'status' => true,
            'conversations' => $rooms,
            'contacts' => $contacts,
            // แชทกลุ่มครอบครัว (ดูรายการเฉย ๆ ไม่สร้างห้อง และไม่ทำให้อ่านแล้ว)
            'group_chat' => $this->groupChatSummary($me),
        ]);
    }

    // =====================================================
    // GET /api/chats/unread-count (ตัวเลขบนไอคอนแชท)
    // =====================================================

    public function unreadCount(Request $request)
    {
        $me = $request->user();

        $count = ChatMessage::query()
            ->join('conversations', 'conversations.id', '=', 'chat_messages.conversation_id')
            ->where('chat_messages.sender_id', '!=', $me->id)
            ->where(function ($rooms) use ($me) {
                $rooms->where(function ($one) use ($me) {
                    $one->where('conversations.user_one_id', $me->id)
                        ->whereRaw('chat_messages.id > coalesce(conversations.user_one_read_id, 0)');
                })->orWhere(function ($two) use ($me) {
                    $two->where('conversations.user_two_id', $me->id)
                        ->whereRaw('chat_messages.id > coalesce(conversations.user_two_read_id, 0)');
                });
            })
            ->count();

        // + แชทกลุ่ม (นับเฉพาะข้อความของคนอื่นที่เห็นได้ หลังตำแหน่งอ่านของเรา)
        $group = $this->groupChatSummary($me);
        $groupUnread = $group['unread_count'] ?? 0;

        return response()->json([
            'status' => true,
            'unread_count' => $count + $groupUnread,
            'group_unread_count' => $groupUnread,
        ]);
    }

    // =====================================================
    // POST /api/chats {user_id} → เปิดห้องแชทกับคนในกลุ่ม
    // POST /api/chats {shop_id} → ทักร้าน (ใครก็ทักร้านที่เปิดขายได้)
    // =====================================================

    public function open(Request $request)
    {
        $data = $request->validate([
            'user_id' => 'required_without_all:shop_id,order_id|nullable|integer',
            'shop_id' => 'nullable|integer',
            'order_id' => 'nullable|integer',
        ]);

        $me = $request->user();

        if (isset($data['order_id'])) {
            return $this->openOrderChat($me, (int) $data['order_id']);
        }

        if (isset($data['shop_id'])) {
            return $this->openShopChat($me, (int) $data['shop_id']);
        }

        $otherId = (int) $data['user_id'];

        if ($otherId === (int) $me->id) {
            return response()->json([
                'status' => false,
                'message' => 'แชทกับตัวเองไม่ได้',
            ], 422);
        }

        if (!$this->familyMemberIds($me)->contains($otherId)) {
            return $this->onlyFamily();
        }

        $conversation = Conversation::between($me->id, $otherId);

        return response()->json([
            'status' => true,
            'conversation' => $this->conversationPayload($conversation, $me),
        ]);
    }

    // =====================================================
    // GET /api/chats/{conversation}/messages
    // ?after_id=N  ข้อความใหม่กว่า N (ดึงเป็นระยะ)
    // ?before_id=N ข้อความเก่ากว่า N (เลื่อนดูย้อนหลัง)
    // ไม่ส่ง = ข้อความล่าสุด
    // =====================================================

    public function messages(Request $request, Conversation $conversation)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id)) {
            return $this->notFound();
        }

        $data = $request->validate([
            'after_id' => 'nullable|integer',
            'before_id' => 'nullable|integer',
            // แอปใหม่ส่ง 0: บอกอ่านแล้วเองตอนข้อความแสดงจริง (POST /read) / แอปเก่าไม่ส่ง = แบบเดิม
            'mark_read' => 'nullable|boolean',
            // สถานะ Reaction ของข้อความที่โหลดไว้แล้ว (id >= ค่านี้ ถึง after_id) ไม่เกิน 100 ข้อความ
            'states_from' => 'nullable|integer|min:1',
        ]);

        $query = $conversation->messages();

        $hasMore = false;

        if (isset($data['after_id'])) {
            $messages = $query->where('id', '>', $data['after_id'])
                ->orderBy('id')
                ->limit(100)
                ->get();
        } else {
            $messages = $query
                ->when(isset($data['before_id']), fn ($older) => $older->where('id', '<', $data['before_id']))
                ->orderByDesc('id')
                ->limit(self::PAGE_SIZE + 1)
                ->get();

            $hasMore = $messages->count() > self::PAGE_SIZE;

            $messages = $messages->take(self::PAGE_SIZE)->reverse()->values();
        }

        $extras = $this->extrasFor($messages, $conversation, $me);

        // แอปเวอร์ชันเก่า: เปิดดูห้องอยู่ → นับว่าอ่านถึงข้อความล่าสุดแล้ว
        if (!isset($data['before_id']) && ($data['mark_read'] ?? true)) {
            $latestId = (int) $conversation->messages()->max('id');

            if ($latestId > $conversation->lastReadId($me->id)) {
                $conversation->forceFill([$conversation->readColumn($me->id) => $latestId])->save();
            }
        }

        return response()->json([
            'status' => true,
            'conversation' => $this->conversationPayload($conversation, $me),
            'messages' => $messages->map(fn (ChatMessage $message) => $this->messagePayload($message, $me, $extras))->values(),
            'has_more' => $hasMore,
            'states' => $this->states($conversation, $me, $data),
        ]);
    }

    // =====================================================
    // POST /api/chats/{conversation}/read {message_id}
    // แอปบอกว่าแสดงข้อความถึงอันนี้แล้ว (หน้าห้องอยู่ด้านหน้า) — ไม่ถอยหลัง (หลายเครื่อง)
    // =====================================================

    public function read(Request $request, Conversation $conversation)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id)) {
            return $this->notFound();
        }

        $data = $request->validate(['message_id' => 'required|integer|min:1']);

        $target = min((int) $data['message_id'], (int) $conversation->messages()->max('id'));
        $column = $conversation->readColumn($me->id);

        Conversation::whereKey($conversation->id)
            ->where(fn ($rooms) => $rooms->whereNull($column)->orWhere($column, '<', $target))
            ->update([$column => $target]);

        return response()->json([
            'status' => true,
            'unread_count' => $conversation->fresh()->unreadCountFor($me->id),
        ]);
    }

    // =====================================================
    // POST /api/chats/{conversation}/messages
    // body (ข้อความ) และ/หรือ image (รูป 1 รูป แบบ multipart)
    // client_id (รหัสที่แอปสร้าง): ส่งซ้ำด้วยรหัสเดิม → ได้ข้อความเดิม (200) ไม่สร้างซ้ำ/ไม่แจ้งเตือนซ้ำ
    // =====================================================

    public function send(Request $request, Conversation $conversation)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id)) {
            return $this->notFound();
        }

        $data = $request->validate([
            'body' => 'required_without_all:image,file,voice|nullable|string|max:2000',
            'image' => 'nullable|image|mimes:jpg,jpeg,png,webp|max:' . self::MAX_IMAGE_KB,
            'client_id' => 'nullable|string|max:64',
            'reply_to_id' => 'nullable|integer|min:1',
            ...ChatAttachment::rules(),
        ], [
            ...ChatAttachment::messages(),
            'body.required_without_all' => 'กรุณาพิมพ์ข้อความหรือแนบไฟล์',
            'image.image' => 'รองรับเฉพาะรูป JPG, PNG หรือ WEBP',
            'image.mimes' => 'รองรับเฉพาะรูป JPG, PNG หรือ WEBP',
            'image.max' => 'รูปต้องมีขนาดไม่เกิน 4 MB',
        ]);

        $otherId = $conversation->otherUserId($me->id);

        if (!$this->canSend($me, $otherId, $conversation)) {
            return $this->onlyFamily();
        }

        $body = isset($data['body']) ? trim($data['body']) : null;

        $clientId = filled($data['client_id'] ?? null) ? $data['client_id'] : null;

        // ตอบกลับได้เฉพาะข้อความในห้องเดียวกัน
        $replyTo = isset($data['reply_to_id'])
            ? ChatMessage::where('conversation_id', $conversation->id)->whereKey($data['reply_to_id'])->first()
            : null;

        if (isset($data['reply_to_id']) && !$replyTo && !$this->sentBefore($conversation, $me, $clientId)) {
            return $this->replyUnavailable();
        }

        // ส่งซ้ำ (หมดเวลารอแต่เซิร์ฟเวอร์บันทึกแล้ว / กดส่งใหม่) → ข้อความเดิม
        if ($sent = $this->sentBefore($conversation, $me, $clientId)) {
            return $this->sentResponse($sent, $me, 200);
        }

        // ไฟล์/เสียง: ตรวจชนิดจากเนื้อไฟล์จริง + จำกัดความถี่ (ไม่ผ่าน → 422/429)
        $attachment = ChatAttachment::inspect($request, $me->id);

        // ข้อความเสียงไม่มีคำบรรยาย
        if (($attachment['kind'] ?? null) === 'voice') {
            $body = null;
        }

        if (($body === null || $body === '') && !$request->hasFile('image') && !$attachment) {
            return response()->json([
                'status' => false,
                'message' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
            ], 422);
        }

        $imagePath = $request->hasFile('image')
            ? MediaStorage::storeAll([$request->file('image')], 'chat_images')[0]
            : null;

        $attachmentPath = $attachment ? ChatAttachment::store($attachment, 'chat_files') : null;

        try {
            $message = DB::transaction(function () use ($conversation, $me, $body, $imagePath, $clientId, $replyTo, $attachment, $attachmentPath) {
                $message = ChatMessage::create([
                    'conversation_id' => $conversation->id,
                    'sender_id' => $me->id,
                    'client_id' => $clientId,
                    'body' => $body === '' ? null : $body,
                    'image_path' => $imagePath,
                    'reply_to_id' => $replyTo?->id,
                    'is_reply' => $replyTo !== null,
                    ...ChatAttachment::columns($attachment, $attachmentPath),
                ]);

                // ข้อความของเราเอง = อ่านแล้ว
                $conversation->forceFill([
                    'last_message_at' => $message->created_at,
                    $conversation->readColumn($me->id) => $message->id,
                ])->save();

                return $message;
            });
        } catch (UniqueConstraintViolationException $e) {
            // ส่งซ้ำเข้ามาพร้อมกัน: อีกคำขอบันทึกไปก่อน → ใช้ข้อความนั้น (ไม่เหลือไฟล์กำพร้า)
            MediaStorage::delete([$imagePath]);
            ChatAttachment::deleteFiles([$attachmentPath]);

            $sent = $this->sentBefore($conversation, $me, $clientId);

            if (!$sent) {
                throw $e;
            }

            return $this->sentResponse($sent, $me, 200);
        } catch (Throwable $e) {
            MediaStorage::delete([$imagePath]);
            ChatAttachment::deleteFiles([$attachmentPath]);

            throw $e;
        }

        $this->notifyRecipient($me, $otherId, $conversation, $message);

        return $this->sentResponse($message, $me, 201);
    }

    // =====================================================
    // GET /api/chats/{conversation}/messages/{message}
    // ข้อความเดียว (ลิงก์ไฟล์/เสียงใหม่เมื่อลิงก์เดิมหมดอายุ)
    // =====================================================

    public function show(Request $request, Conversation $conversation, ChatMessage $message)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id) || (int) $message->conversation_id !== (int) $conversation->id) {
            return $this->notFound();
        }

        return response()->json([
            'status' => true,
            'message' => $this->messagePayload($message, $me),
        ]);
    }

    // =====================================================
    // GET /api/chat-files/{message}?viewer=&signature= (ลิงก์ลงลายเซ็น อายุสั้น)
    // ไฟล์แนบ/ข้อความเสียง: ตรวจว่าผู้ดูยังเป็นสมาชิกห้องทุกครั้งที่เปิด
    // =====================================================

    public function file(Request $request, ChatMessage $message)
    {
        $viewerId = (int) $request->query('viewer');
        $conversation = $message->conversation;

        if (!$conversation
            || !$message->attachment_path
            || !$conversation->hasMember($viewerId)
            || !User::whereKey($viewerId)->exists()) {
            return response()->json([
                'status' => false,
                'message' => 'คุณไม่มีสิทธิ์เปิดไฟล์นี้แล้ว',
            ], 403);
        }

        return ChatAttachment::respond($message);
    }

    private function sentBefore(Conversation $conversation, User $me, ?string $clientId): ?ChatMessage
    {
        return $clientId === null ? null : ChatMessage::where('conversation_id', $conversation->id)
            ->where('sender_id', $me->id)
            ->where('client_id', $clientId)
            ->first();
    }

    private function sentResponse(ChatMessage $message, User $me, int $status)
    {
        return response()->json([
            'status' => true,
            'message' => $this->messagePayload($message, $me),
        ], $status);
    }

    // =====================================================
    // DELETE /api/chats/{conversation}/messages/{message}
    // ยกเลิกการส่ง (เฉพาะข้อความของตัวเอง)
    // =====================================================

    public function destroy(Request $request, Conversation $conversation, ChatMessage $message)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id) || (int) $message->conversation_id !== (int) $conversation->id) {
            return $this->notFound();
        }

        if ((int) $message->sender_id !== (int) $me->id) {
            return response()->json([
                'status' => false,
                'message' => 'ยกเลิกได้เฉพาะข้อความของคุณ',
            ], 403);
        }

        $message->delete();

        return response()->json([
            'status' => true,
        ]);
    }

    // =====================================================
    // Helpers
    // =====================================================

    // ห้องแชทกลุ่มของกลุ่มที่อยู่ตอนนี้ (null = ยังไม่มีกลุ่ม / id null = ยังไม่มีใครเปิดห้อง)
    private function groupChatSummary(User $me): ?array
    {
        $membership = FamilyMember::where('user_id', $me->id)->first();

        if (!$membership) {
            return null;
        }

        $chat = GroupChat::where('family_id', $membership->family_id)->first();
        $access = $chat?->accessFor($me);

        $last = $access
            ? $access->visibleMessages()->with('sender:id,name')->orderByDesc('id')->first()
            : null;

        return [
            'id' => $chat?->id,
            'name' => Family::whereKey($membership->family_id)->value('name') ?? 'แชทกลุ่ม',
            'members_count' => FamilyMember::where('family_id', $membership->family_id)->count(),
            'unread_count' => $access?->unreadCount() ?? 0,
            'muted' => $access?->muted ?? false,
            'last_message' => $last ? [
                'body' => $last->body ? Str::limit($last->body, 80) : null,
                'has_image' => $last->image_path !== null,
                'attachment_kind' => $last->attachment_kind,
                'is_mine' => (int) $last->sender_id === (int) $me->id,
                'sender_name' => $last->sender?->name,
                'created_at' => $last->created_at?->toIso8601String(),
            ] : null,
        ];
    }

    // คนในครอบครัวเดียวกับเรา (ไม่รวมตัวเอง)
    private function familyMemberIds(User $me)
    {
        $familyId = FamilyMember::where('user_id', $me->id)->value('family_id');

        if (!$familyId) {
            return collect();
        }

        return FamilyMember::where('family_id', $familyId)
            ->where('user_id', '!=', $me->id)
            ->pluck('user_id')
            ->map(fn ($id) => (int) $id);
    }

    // คนที่เราบล็อก หรือบล็อกเรา
    private function blockedEitherWay(User $me)
    {
        return UserBlock::where('user_id', $me->id)->pluck('blocked_user_id')
            ->merge(UserBlock::where('blocked_user_id', $me->id)->pluck('user_id'))
            ->map(fn ($id) => (int) $id)
            ->unique();
    }

    // คนในกลุ่มเดียวกัน หรือห้องลูกค้า-ร้าน และไม่ได้บล็อกกัน
    private function canSend(User $me, int $otherId, ?Conversation $conversation = null): bool
    {
        if ($this->blockedEitherWay($me)->contains($otherId)) {
            return false;
        }

        return $this->familyMemberIds($me)->contains($otherId)
            || ($conversation?->isShopChatWith($me->id, $otherId) ?? false);
    }

    // แชทจากหน้าคำสั่งซื้อ: ผู้ซื้อ → ร้าน / ร้าน → ลูกค้า (เช่น ถามบัญชีเพื่อคืนเงิน)
    private function openOrderChat(User $me, int $orderId)
    {
        $order = Order::with('shop')->find($orderId);

        if (!$order || !$order->shop || (!$order->isBuyer($me) && !$order->isSeller($me))) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบคำสั่งซื้อนี้',
            ], 404);
        }

        if ($order->isBuyer($me)) {
            return $this->openShopChat($me, (int) $order->shop_id);
        }

        $buyerId = (int) $order->buyer_id;

        if ($this->blockedEitherWay($me)->contains($buyerId)) {
            return response()->json([
                'status' => false,
                'message' => 'คุณแชทกับลูกค้าคนนี้ไม่ได้',
            ], 403);
        }

        $conversation = Conversation::between($me->id, $buyerId);

        if ($conversation->shop_id === null) {
            $conversation->forceFill(['shop_id' => $order->shop_id])->save();
        }

        return response()->json([
            'status' => true,
            'conversation' => $this->conversationPayload($conversation->load('shop'), $me),
        ]);
    }

    private function openShopChat(User $me, int $shopId)
    {
        $shop = Shop::find($shopId);

        // ร้านปิด → ทักได้เฉพาะคนที่เคยสั่งซื้อ (คุยเรื่องคำสั่งซื้อเดิม)
        $allowed = $shop && ($shop->isActive()
            || Order::where('shop_id', $shop->id)->where('buyer_id', $me->id)->exists());

        if (!$allowed) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบร้านนี้ หรือร้านปิดอยู่',
            ], 404);
        }

        $ownerId = (int) $shop->user_id;

        if ($ownerId === (int) $me->id) {
            return response()->json([
                'status' => false,
                'message' => 'นี่คือร้านของคุณ',
            ], 422);
        }

        if ($this->blockedEitherWay($me)->contains($ownerId)) {
            return response()->json([
                'status' => false,
                'message' => 'คุณแชทกับร้านนี้ไม่ได้',
            ], 403);
        }

        $conversation = Conversation::between($me->id, $ownerId);

        // ห้องเดิม (เช่น อยู่กลุ่มเดียวกัน) → ผูกกับร้านนี้ด้วย
        if ($conversation->shop_id === null) {
            $conversation->forceFill(['shop_id' => $shop->id])->save();
        }

        return response()->json([
            'status' => true,
            'conversation' => $this->conversationPayload($conversation->load('shop'), $me),
        ]);
    }

    private function userPayload(?User $user, int $id): array
    {
        return [
            'id' => $id,
            'name' => $user?->name ?? 'ผู้ใช้',
            'profile_image_url' => $user?->profile_image_url,
        ];
    }

    // ลูกค้าเห็นห้องแชทร้านเป็นชื่อ/โลโก้ร้าน (เจ้าของร้านเห็นชื่อลูกค้าตามปกติ)
    private function roomUserPayload(Conversation $conversation, User $me, ?User $other, int $otherId): array
    {
        $shop = $conversation->shop;

        if ($shop && (int) $shop->user_id === $otherId) {
            return [
                'id' => $otherId,
                'name' => $shop->name,
                'profile_image_url' => $shop->logo_url,
            ];
        }

        return $this->userPayload($other, $otherId);
    }

    private function shopPayload(Conversation $conversation, User $me): ?array
    {
        $shop = $conversation->shop;

        return $shop ? [
            'id' => $shop->id,
            'name' => $shop->name,
            'logo_url' => $shop->logo_url,
            'is_mine' => (int) $shop->user_id === (int) $me->id,
        ] : null;
    }

    private function conversationPayload(Conversation $conversation, User $me): array
    {
        $otherId = $conversation->otherUserId($me->id);

        $conversation->loadMissing('shop');

        return [
            'id' => $conversation->id,
            'user' => $this->roomUserPayload(
                $conversation,
                $me,
                User::find($otherId, ['id', 'name', 'profile_photo']),
                $otherId
            ),
            'shop' => $this->shopPayload($conversation, $me),
            'can_send' => $this->canSend($me, $otherId, $conversation),
            // อีกฝ่ายอ่านถึงข้อความไหนแล้ว (แสดง "อ่านแล้ว")
            'other_read_id' => $conversation->lastReadId($otherId),
            // เราอ่านถึงไหน (เส้น "ข้อความที่ยังไม่ได้อ่าน" ตอนเปิดห้อง)
            'my_read_id' => $conversation->lastReadId($me->id),
        ];
    }

    // Reply + Reaction ของข้อความชุดนี้ (โหลดรวดเดียว) — ต้นทางต้องอยู่ห้องเดียวกัน
    private function extrasFor(Collection $messages, Conversation $conversation, User $me): array
    {
        $conversationId = (int) $conversation->id;

        $extras = ChatExtras::prepare(
            $messages,
            ChatMessage::class,
            ChatMessageReaction::class,
            'chat_message_id',
            $me,
            fn (ChatMessage $source) => (int) $source->conversation_id === $conversationId
        );

        // ลูกค้าเห็นเจ้าของร้านเป็นชื่อร้านเหมือนหัวห้อง (ข้อความอ้างอิงไม่เผยชื่อส่วนตัว)
        $shop = $conversation->shop;

        if ($shop && (int) $shop->user_id !== (int) $me->id) {
            $extras['names'][(int) $shop->user_id] = $shop->name;
        }

        return $extras;
    }

    // Reaction ของข้อความที่แอปโหลดไว้แล้ว (ตอนดึงข้อความใหม่) — ชุดเดียว ไม่ยิงทีละข้อความ
    private function states(Conversation $conversation, User $me, array $data): array
    {
        if (!isset($data['states_from'], $data['after_id'])) {
            return [];
        }

        $ids = $conversation->messages()
            ->where('id', '>=', $data['states_from'])
            ->where('id', '<=', $data['after_id'])
            ->orderByDesc('id')
            ->limit(100)
            ->pluck('id');

        $rows = ChatMessageReaction::whereIn('chat_message_id', $ids)->get(['chat_message_id', 'user_id', 'emoji'])->groupBy('chat_message_id');

        return $ids->map(fn ($id) => [
            'id' => $id,
            'reactions' => ChatExtras::summarize($rows[$id] ?? collect(), $me),
        ])->values()->all();
    }

    // =====================================================
    // PUT    /api/chats/{conversation}/messages/{message}/reaction {emoji}  ตั้ง (ส่งซ้ำได้)
    // DELETE /api/chats/{conversation}/messages/{message}/reaction          ถอน (ส่งซ้ำได้)
    // ไม่นับ unread / ไม่ส่งแจ้งเตือน
    // =====================================================

    public function react(Request $request, Conversation $conversation, ChatMessage $message)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id) || (int) $message->conversation_id !== (int) $conversation->id) {
            return $this->notFound();
        }

        $data = $request->validate(['emoji' => ['required', Rule::in(ChatExtras::EMOJIS)]]);

        if (!$this->canSend($me, $conversation->otherUserId($me->id), $conversation)) {
            return $this->onlyFamily();
        }

        try {
            ChatMessageReaction::updateOrCreate(
                ['chat_message_id' => $message->id, 'user_id' => $me->id],
                ['emoji' => $data['emoji']]
            );
        } catch (UniqueConstraintViolationException) {
            ChatMessageReaction::where('chat_message_id', $message->id)->where('user_id', $me->id)->update(['emoji' => $data['emoji']]);
        }

        return $this->reactionsResponse($message, $me);
    }

    public function unreact(Request $request, Conversation $conversation, ChatMessage $message)
    {
        $me = $request->user();

        if (!$conversation->hasMember($me->id) || (int) $message->conversation_id !== (int) $conversation->id) {
            return $this->notFound();
        }

        ChatMessageReaction::where('chat_message_id', $message->id)->where('user_id', $me->id)->delete();

        return $this->reactionsResponse($message, $me);
    }

    private function reactionsResponse(ChatMessage $message, User $me)
    {
        return response()->json([
            'status' => true,
            'message_id' => $message->id,
            'reactions' => ChatExtras::summarize(ChatMessageReaction::where('chat_message_id', $message->id)->get(['user_id', 'emoji']), $me),
        ]);
    }

    private function replyUnavailable()
    {
        return response()->json([
            'status' => false,
            'code' => 'reply_unavailable',
            'message' => 'ข้อความที่ต้องการตอบกลับไม่พร้อมใช้งานแล้ว',
            'errors' => ['reply_to_id' => ['ข้อความที่ต้องการตอบกลับไม่พร้อมใช้งานแล้ว']],
        ], 422);
    }

    private function messagePayload(ChatMessage $message, User $me, ?array $extras = null): array
    {
        $extras ??= $this->extrasFor(collect([$message]), $message->conversation, $me);

        return [
            'reply_to' => ChatExtras::replyPayload($message, $extras),
            'reactions' => ChatExtras::reactionsPayload($message, $extras),
            'id' => $message->id,
            'sender_id' => $message->sender_id,
            'is_mine' => (int) $message->sender_id === (int) $me->id,
            // รหัสจากแอปของผู้ส่ง (จับคู่ข้อความที่กำลังส่งกับข้อความจากเซิร์ฟเวอร์) — ส่งให้ผู้ส่งเท่านั้น
            'client_id' => (int) $message->sender_id === (int) $me->id ? $message->client_id : null,
            'body' => $message->body,
            'image_url' => $message->image_url,
            // ไฟล์/เสียง: ลิงก์ชั่วคราวผูกกับผู้ดู (ผู้ดูเป็นสมาชิกห้องแล้ว)
            'attachment' => ChatAttachment::payload($message, 'chat.file', (int) $me->id),
            'created_at' => $message->created_at?->toIso8601String(),
        ];
    }

    // แจ้งเตือนเด้งหาอีกฝ่าย (ไม่บันทึกในหน้าแจ้งเตือน) หลังตอบแอปไปแล้ว
    private function notifyRecipient(User $me, int $otherId, Conversation $conversation, ChatMessage $message): void
    {
        $recipient = User::find($otherId, ['id', 'notification_settings']);

        if (!$recipient || !$recipient->wantsNotification(AppNotification::TYPE_NEW_MESSAGE)) {
            return;
        }

        // เจ้าของร้านตอบลูกค้า → แสดงเป็นชื่อร้าน
        $shop = $conversation->shop;

        $title = $shop && (int) $shop->user_id === (int) $me->id ? $shop->name : $me->name;

        $body = $message->body
            ? Str::limit($message->body, 100)
            : match ($message->attachment_kind) {
                'file' => '📎 ส่งไฟล์',
                'voice' => '🎤 ส่งข้อความเสียง',
                default => '📷 ส่งรูปภาพ',
            };

        $conversationId = $conversation->id;

        defer(fn () => app(PushNotifications::class)->sendToUser(
            $otherId,
            $title,
            $body,
            [
                'type' => AppNotification::TYPE_NEW_MESSAGE,
                'conversation_id' => $conversationId,
            ],
            'chat-' . $conversationId
        ));
    }

    private function onlyFamily()
    {
        return response()->json([
            'status' => false,
            'message' => 'แชทได้เฉพาะสมาชิกในกลุ่มเดียวกัน หรือร้านที่คุณทักไว้',
        ], 403);
    }

    private function notFound()
    {
        return response()->json([
            'status' => false,
            'message' => 'ไม่พบห้องแชทนี้',
        ], 404);
    }
}
