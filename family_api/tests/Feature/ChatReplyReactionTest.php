<?php

namespace Tests\Feature;

use App\Models\ChatMessageReaction;
use App\Models\FamilyMember;
use App\Models\GroupChatMessageReaction;
use App\Models\Shop;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// Reply / Reaction / สถานะอ่าน — แชทส่วนตัว และแชทกลุ่ม (ขอบเขตรอบสมาชิก)
// ฐานข้อมูลทดสอบแยก (RefreshDatabase) / ไม่มี Push ออกไปจริง (preventStrayRequests)
class ChatReplyReactionTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Http::preventStrayRequests();
        $this->withoutDefer();
    }

    private function privateRoom(User $a, User $b): int
    {
        Sanctum::actingAs($a);

        return $this->postJson('/api/chats', ['user_id' => $b->id])->assertSuccessful()->json('conversation.id');
    }

    private function sendPrivate(User $user, int $room, string $body, ?int $replyTo = null)
    {
        Sanctum::actingAs($user);

        return $this->postJson("/api/chats/{$room}/messages", array_filter([
            'body' => $body,
            'client_id' => uniqid('p', true),
            'reply_to_id' => $replyTo,
        ]));
    }

    private function groupRoom(User $user): int
    {
        Sanctum::actingAs($user);

        return $this->postJson('/api/group-chat/open')->assertOk()->json('room.id');
    }

    private function sendGroup(User $user, int $chat, string $body, ?int $replyTo = null)
    {
        Sanctum::actingAs($user);

        return $this->postJson("/api/group-chats/{$chat}/messages", array_filter([
            'body' => $body,
            'client_id' => uniqid('g', true),
            'reply_to_id' => $replyTo,
        ]));
    }

    // =====================================================
    // แชทส่วนตัว: อ่านแล้วเมื่อแสดงจริง
    // =====================================================

    public function test_private_read_happens_when_shown_and_never_moves_back(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);

        $first = $this->sendPrivate($mom, $room, 'หนึ่ง')->json('message.id');
        $second = $this->sendPrivate($mom, $room, 'สอง')->json('message.id');

        // แอปใหม่ดึงข้อความ (mark_read=0) → ยังไม่อ่าน
        Sanctum::actingAs($son);
        $this->getJson("/api/chats/{$room}/messages?mark_read=0")->assertOk()->assertJsonPath('conversation.my_read_id', 0);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('unread_count', 2);

        // แสดงถึงข้อความที่ 2 แล้ว / อีกเครื่องส่งตำแหน่งเก่า → ไม่ถอยหลัง
        $this->postJson("/api/chats/{$room}/read", ['message_id' => $second])->assertOk()->assertJsonPath('unread_count', 0);
        $this->postJson("/api/chats/{$room}/read", ['message_id' => $first])->assertOk()->assertJsonPath('unread_count', 0);

        Sanctum::actingAs($mom);
        $this->getJson("/api/chats/{$room}/messages?mark_read=0")->assertJsonPath('conversation.other_read_id', $second);

        // แอปเวอร์ชันเก่า (ไม่ส่ง mark_read) → อ่านเมื่อดึงข้อความเหมือนเดิม
        $this->sendPrivate($son, $room, 'ตอบแม่');
        Sanctum::actingAs($mom);
        $this->getJson("/api/chats/{$room}/messages")->assertOk();
        $this->getJson('/api/chats/unread-count')->assertJsonPath('unread_count', 0);
    }

    // =====================================================
    // Reply
    // =====================================================

    public function test_private_reply_is_same_room_only_and_hides_deleted_sources(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $dad = User::factory()->create();
        $this->createFamily($mom, [$son, $dad]);
        $room = $this->privateRoom($mom, $son);
        $otherRoom = $this->privateRoom($mom, $dad);

        $source = $this->sendPrivate($mom, $room, 'ซื้อนมด้วยนะ')->json('message.id');
        $elsewhere = $this->sendPrivate($mom, $otherRoom, 'เรื่องของพ่อ')->json('message.id');

        $this->sendPrivate($son, $room, 'ได้เลย', $source)->assertCreated()
            ->assertJsonPath('message.reply_to.available', true)
            ->assertJsonPath('message.reply_to.body', 'ซื้อนมด้วยนะ')
            ->assertJsonPath('message.reply_to.sender_name', $mom->name);

        // อ้างข้อความห้องอื่น → ไม่ได้
        $this->sendPrivate($son, $room, 'แอบอ้าง', $elsewhere)->assertStatus(422)->assertJsonPath('code', 'reply_unavailable');

        // ต้นทางถูกยกเลิกการส่ง → ไม่พร้อมใช้งาน ไม่เผยเนื้อหา
        Sanctum::actingAs($mom);
        $this->deleteJson("/api/chats/{$room}/messages/{$source}")->assertOk();

        Sanctum::actingAs($son);
        $response = $this->getJson("/api/chats/{$room}/messages?mark_read=0")->assertOk();
        $reply = collect($response->json('messages'))->firstWhere('body', 'ได้เลย');
        $this->assertSame(['available' => false], $reply['reply_to']);
        $this->assertStringNotContainsString('ซื้อนมด้วยนะ', $response->getContent());
    }

    public function test_shop_reply_preview_shows_shop_name_not_owners_name_to_customer(): void
    {
        $owner = User::factory()->create(['name' => 'ชื่อจริงเจ้าของร้าน']);
        $customer = User::factory()->create();
        $shop = Shop::create([
            'user_id' => $owner->id,
            'name' => 'ร้านป้าแดง',
            'category' => 'clothing',
            'phone' => '0812345678',
            'province' => 'เชียงใหม่',
            'status' => Shop::STATUS_ACTIVE,
            'delivery_methods' => ['shipping'],
            'payment_methods' => ['cod'],
        ]);

        Sanctum::actingAs($customer);
        $room = $this->postJson('/api/chats', ['shop_id' => $shop->id])->assertSuccessful()->json('conversation.id');

        $source = $this->sendPrivate($owner, $room, 'สวัสดีค่ะ')->assertCreated()->json('message.id');
        $reply = $this->sendPrivate($customer, $room, 'ขอดูสินค้าค่ะ', $source)->assertCreated();

        $reply->assertJsonPath('message.reply_to.sender_name', 'ร้านป้าแดง');
        $this->assertStringNotContainsString('ชื่อจริงเจ้าของร้าน', $reply->getContent());

        // เจ้าของร้านเห็นชื่อลูกค้าตามปกติ
        $back = $this->sendPrivate($owner, $room, 'ได้เลยค่ะ', $reply->json('message.id'))->assertCreated();
        $back->assertJsonPath('message.reply_to.sender_name', $customer->name);
    }

    public function test_group_reply_respects_each_viewers_history(): void
    {
        $mom = User::factory()->create();
        $dad = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$dad]);
        $chat = $this->groupRoom($mom);

        $old = $this->sendGroup($mom, $chat, 'ความลับก่อนลูกเข้า')->json('message.id');

        FamilyMember::create(['family_id' => $family->id, 'user_id' => $son->id, 'role' => 'member']);

        // ลูกตอบข้อความก่อนตัวเองเข้ากลุ่มไม่ได้
        $this->sendGroup($son, $chat, 'ขอดู', $old)->assertStatus(422)->assertJsonPath('code', 'reply_unavailable');

        // พ่อตอบข้อความเก่าได้ / ลูกเห็นกรอบอ้างอิงเป็น "ไม่พร้อมใช้งาน" ไม่เห็นเนื้อหา
        $this->sendGroup($dad, $chat, 'รับทราบ', $old)->assertCreated()
            ->assertJsonPath('message.reply_to.body', 'ความลับก่อนลูกเข้า');

        Sanctum::actingAs($son);
        $response = $this->getJson("/api/group-chats/{$chat}/messages")->assertOk();
        $this->assertSame(['available' => false], $response->json('messages.0.reply_to'));
        $this->assertStringNotContainsString('ความลับก่อนลูกเข้า', $response->getContent());

        Sanctum::actingAs($dad);
        $this->getJson("/api/group-chats/{$chat}/messages")->assertJsonPath('messages.1.reply_to.available', true);
    }

    // =====================================================
    // Reaction
    // =====================================================

    public function test_reactions_set_change_remove_and_retry_keep_counts_right(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $dad = User::factory()->create();
        $this->createFamily($mom, [$son, $dad]);
        $room = $this->privateRoom($mom, $son);
        $message = $this->sendPrivate($mom, $room, 'กินข้าวยัง')->json('message.id');

        Sanctum::actingAs($son);
        $url = "/api/chats/{$room}/messages/{$message}/reaction";
        $this->putJson($url, ['emoji' => '👍'])->assertOk()->assertJsonPath('reactions.0.count', 1)->assertJsonPath('reactions.0.mine', true);
        $this->putJson($url, ['emoji' => '👍'])->assertOk()->assertJsonPath('reactions.0.count', 1);
        $this->putJson($url, ['emoji' => '❤️'])->assertOk()->assertJsonPath('reactions.0.emoji', '❤️');
        $this->assertSame(1, ChatMessageReaction::count());
        $this->putJson($url, ['emoji' => '🔥'])->assertStatus(422);

        Sanctum::actingAs($mom);
        $this->putJson($url, ['emoji' => '❤️'])->assertOk()->assertJsonPath('reactions.0.count', 2);

        Sanctum::actingAs($son);
        $this->deleteJson($url)->assertOk()->assertJsonPath('reactions.0.count', 1)->assertJsonPath('reactions.0.mine', false);
        $this->deleteJson($url)->assertOk()->assertJsonPath('reactions.0.count', 1);

        // ไม่ใช่สมาชิกห้อง → ไม่ได้ / Reaction ไม่ทำให้มีข้อความยังไม่อ่าน
        Sanctum::actingAs($dad);
        $this->putJson($url, ['emoji' => '😂'])->assertNotFound();

        Sanctum::actingAs($son);
        $this->getJson("/api/chats/{$room}/messages")->assertOk();
        Sanctum::actingAs($mom);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('unread_count', 0);
    }

    public function test_group_reactions_need_current_access_to_that_message(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $late = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);
        $chat = $this->groupRoom($mom);

        $message = $this->sendGroup($mom, $chat, 'ไปเที่ยวกัน')->json('message.id');
        FamilyMember::create(['family_id' => $family->id, 'user_id' => $late->id, 'role' => 'member']);

        $url = "/api/group-chats/{$chat}/messages/{$message}/reaction";

        Sanctum::actingAs($son);
        $this->putJson($url, ['emoji' => '😂'])->assertOk()->assertJsonPath('reactions.0.count', 1);

        // เข้าทีหลัง → ข้อความก่อนเข้า Reaction ไม่ได้
        Sanctum::actingAs($late);
        $this->putJson($url, ['emoji' => '😂'])->assertForbidden();

        // ออกจากกลุ่มแล้ว → Reaction / ตอบกลับ ไม่ได้
        Sanctum::actingAs($son);
        $this->postJson('/api/families/leave')->assertOk();
        $this->putJson($url, ['emoji' => '👍'])->assertForbidden();
        $this->deleteJson($url)->assertForbidden();
        $this->sendGroup($son, $chat, 'ตอบหลังออก', $message)->assertForbidden();

        $this->assertSame(1, GroupChatMessageReaction::count());
    }

    // =====================================================
    // อ่านแล้ว X คน + สถานะของข้อความที่โหลดไว้แล้ว
    // =====================================================

    public function test_group_read_count_uses_current_rounds_only_and_states_refresh(): void
    {
        $mom = User::factory()->create();
        $dad = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$dad, $son]);
        $chat = $this->groupRoom($mom);

        $message = $this->sendGroup($mom, $chat, 'ประชุมบ้าน 2 ทุ่ม')->assertCreated();
        $id = $message->json('message.id');
        $this->assertSame(0, $message->json('message.read_count'));

        Sanctum::actingAs($dad);
        $this->postJson("/api/group-chats/{$chat}/read", ['message_id' => $id])->assertOk();
        Sanctum::actingAs($son);
        $this->postJson("/api/group-chats/{$chat}/read", ['message_id' => $id])->assertOk();

        // ดึงข้อความใหม่พร้อมสถานะของข้อความที่โหลดไว้แล้ว
        Sanctum::actingAs($dad);
        $this->putJson("/api/group-chats/{$chat}/messages/{$id}/reaction", ['emoji' => '👍'])->assertOk();

        Sanctum::actingAs($mom);
        $states = $this->getJson("/api/group-chats/{$chat}/messages?after_id={$id}&states_from={$id}")->assertOk();
        $this->assertSame([], $states->json('messages'));
        $this->assertSame(2, $states->json('states.0.read_count'));
        $this->assertSame('👍', $states->json('states.0.reactions.0.emoji'));

        // ลูกออก → ไม่นับ / กลับเข้ามาใหม่ (รอบใหม่เห็นไม่ได้) → ไม่นับ
        Sanctum::actingAs($son);
        $this->postJson('/api/families/leave')->assertOk();
        FamilyMember::create(['family_id' => $family->id, 'user_id' => $son->id, 'role' => 'member']);

        Sanctum::actingAs($mom);
        $this->getJson("/api/group-chats/{$chat}/messages")->assertJsonPath('messages.0.read_count', 1);

        // ข้อความของคนอื่นไม่มีตัวเลขผู้อ่าน
        Sanctum::actingAs($dad);
        $this->getJson("/api/group-chats/{$chat}/messages")->assertJsonPath('messages.0.read_count', null);
    }
}
