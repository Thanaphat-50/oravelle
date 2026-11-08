<?php

namespace App\Http\Controllers;

use App\Models\AppNotification;
use App\Models\ChatMessage;
use App\Models\Conversation;
use App\Models\FamilyMember;
use App\Models\Order;
use App\Models\Shop;
use App\Models\User;
use App\Models\UserBlock;
use App\Services\PushNotifications;
use App\Support\MediaStorage;
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

        return response()->json([
            'status' => true,
            'unread_count' => $count,
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

        // เปิดดูห้องอยู่ → นับว่าอ่านถึงข้อความล่าสุดแล้ว
        if (!isset($data['before_id'])) {
            $latestId = (int) $conversation->messages()->max('id');

            if ($latestId > $conversation->lastReadId($me->id)) {
                $conversation->forceFill([$conversation->readColumn($me->id) => $latestId])->save();
            }
        }

        return response()->json([
            'status' => true,
            'conversation' => $this->conversationPayload($conversation, $me),
            'messages' => $messages->map(fn (ChatMessage $message) => $this->messagePayload($message, $me))->values(),
            'has_more' => $hasMore,
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
            'body' => 'required_without:image|nullable|string|max:2000',
            'image' => 'nullable|image|mimes:jpg,jpeg,png,webp|max:' . self::MAX_IMAGE_KB,
            'client_id' => 'nullable|string|max:64',
        ], [
            'body.required_without' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
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

        // ส่งซ้ำ (หมดเวลารอแต่เซิร์ฟเวอร์บันทึกแล้ว / กดส่งใหม่) → ข้อความเดิม
        if ($sent = $this->sentBefore($conversation, $me, $clientId)) {
            return $this->sentResponse($sent, $me, 200);
        }

        if (($body === null || $body === '') && !$request->hasFile('image')) {
            return response()->json([
                'status' => false,
                'message' => 'กรุณาพิมพ์ข้อความหรือแนบรูป',
            ], 422);
        }

        $imagePath = $request->hasFile('image')
            ? MediaStorage::storeAll([$request->file('image')], 'chat_images')[0]
            : null;

        try {
            $message = DB::transaction(function () use ($conversation, $me, $body, $imagePath, $clientId) {
                $message = ChatMessage::create([
                    'conversation_id' => $conversation->id,
                    'sender_id' => $me->id,
                    'client_id' => $clientId,
                    'body' => $body === '' ? null : $body,
                    'image_path' => $imagePath,
                ]);

                // ข้อความของเราเอง = อ่านแล้ว
                $conversation->forceFill([
                    'last_message_at' => $message->created_at,
                    $conversation->readColumn($me->id) => $message->id,
                ])->save();

                return $message;
            });
        } catch (UniqueConstraintViolationException $e) {
            // ส่งซ้ำเข้ามาพร้อมกัน: อีกคำขอบันทึกไปก่อน → ใช้ข้อความนั้น
            MediaStorage::delete([$imagePath]);

            $sent = $this->sentBefore($conversation, $me, $clientId);

            if (!$sent) {
                throw $e;
            }

            return $this->sentResponse($sent, $me, 200);
        } catch (Throwable $e) {
            MediaStorage::delete([$imagePath]);

            throw $e;
        }

        $this->notifyRecipient($me, $otherId, $conversation, $message);

        return $this->sentResponse($message, $me, 201);
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
        ];
    }

    private function messagePayload(ChatMessage $message, User $me): array
    {
        return [
            'id' => $message->id,
            'sender_id' => $message->sender_id,
            'is_mine' => (int) $message->sender_id === (int) $me->id,
            // รหัสจากแอปของผู้ส่ง (จับคู่ข้อความที่กำลังส่งกับข้อความจากเซิร์ฟเวอร์) — ส่งให้ผู้ส่งเท่านั้น
            'client_id' => (int) $message->sender_id === (int) $me->id ? $message->client_id : null,
            'body' => $message->body,
            'image_url' => $message->image_url,
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
            : '📷 ส่งรูปภาพ';

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
