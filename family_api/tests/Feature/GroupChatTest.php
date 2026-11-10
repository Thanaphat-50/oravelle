<?php

namespace Tests\Feature;

use App\Models\Conversation;
use App\Models\DeviceToken;
use App\Models\FamilyMember;
use App\Models\GroupChat;
use App\Models\GroupChatMember;
use App\Models\GroupChatMessage;
use App\Models\User;
use App\Models\UserBlock;
use App\Services\AccountDeletionService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request as HttpRequest;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Storage;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// แชทกลุ่มครอบครัว: ห้องเดียวต่อกลุ่ม / สิทธิ์ตามรอบสมาชิก / รูปแนบตรวจสิทธิ์ / ส่งซ้ำไม่ซ้ำ
// / ยังไม่อ่านแยกคน / ปิดเสียง / Push ตรวจสิทธิ์ตอนส่ง / ลบกลุ่ม-ลบบัญชี
// ฐานข้อมูลทดสอบแยก (RefreshDatabase) + Push ปลอม (Http::fake) + ไฟล์ปลอม (Storage::fake)
class GroupChatTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private const FCM_URL = 'https://fcm.googleapis.com/v1/projects/test-project/messages:send';

    protected function setUp(): void
    {
        parent::setUp();

        Storage::fake('local');
        Http::preventStrayRequests();
        $this->withoutDefer();
    }

    private function open(User $user): int
    {
        Sanctum::actingAs($user);

        return $this->postJson('/api/group-chat/open')->assertOk()->json('room.id');
    }

    private function say(User $user, int $chatId, string $body, ?string $clientId = null)
    {
        Sanctum::actingAs($user);

        return $this->postJson("/api/group-chats/{$chatId}/messages", [
            'body' => $body,
            'client_id' => $clientId ?? uniqid('c', true),
        ]);
    }

    private function bodies(User $user, int $chatId, array $query = []): array
    {
        Sanctum::actingAs($user);

        return collect($this->getJson("/api/group-chats/{$chatId}/messages?" . http_build_query($query))->assertOk()->json('messages'))
            ->pluck('body')->all();
    }

    private function join(User $user, int $familyId): FamilyMember
    {
        // ทุกทางเข้ากลุ่มในระบบสร้างแถว family_members ด้วย FamilyMember::create
        return FamilyMember::create(['family_id' => $familyId, 'user_id' => $user->id, 'role' => 'member']);
    }

    private function configurePush(): void
    {
        config(['services.fcm.credentials' => base64_encode(json_encode([
            'type' => 'service_account',
            'project_id' => 'test-project',
            'client_email' => 'push@test-project.iam.gserviceaccount.com',
            'private_key' => 'unused-in-this-test',
        ]))]);
        Cache::put('fcm.access_token.test-project', 'cached-access-token', 600);
        Http::fake([self::FCM_URL => Http::response(['name' => 'projects/test-project/messages/1'])]);
    }

    private function device(User $user, string $fid): void
    {
        DeviceToken::create([
            'user_id' => $user->id,
            'access_token_id' => $user->createToken('family-app')->accessToken->id,
            'token' => $fid,
        ]);
    }

    private function pushedTo(): array
    {
        return collect(Http::recorded())
            ->map(fn ($pair) => $pair[0]['message']['fid'] ?? null)
            ->filter()
            ->values()
            ->all();
    }

    // =====================================================
    // ห้อง
    // =====================================================

    public function test_one_room_per_group_even_when_opened_together(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);

        $first = $this->open($mom);
        $second = $this->open($son);

        $this->assertSame($first, $second);
        $this->assertSame($first, GroupChat::forFamily($family->id)->id);
        $this->assertSame(1, GroupChat::count());
        $this->assertSame(2, GroupChatMember::count());
    }

    public function test_room_name_follows_the_group_and_list_does_not_create_or_read(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);

        // ดูรายการแชทเฉย ๆ → ยังไม่มีห้อง ไม่สร้างห้อง
        Sanctum::actingAs($son);
        $this->getJson('/api/chats')->assertOk()
            ->assertJsonPath('group_chat.id', null)
            ->assertJsonPath('group_chat.name', $family->name)
            ->assertJsonPath('group_chat.members_count', 2);
        $this->assertSame(0, GroupChat::count());

        $chatId = $this->open($mom);
        $this->say($mom, $chatId, 'สวัสดีทุกคน')->assertCreated();

        Sanctum::actingAs($mom);
        $this->putJson("/api/families/{$family->id}", ['name' => 'บ้านใหม่'])->assertOk();
        $this->getJson("/api/group-chats/{$chatId}/messages")->assertJsonPath('room.name', 'บ้านใหม่');

        // เปิดรายการ → ยังไม่อ่าน
        Sanctum::actingAs($son);
        $this->getJson('/api/chats')->assertJsonPath('group_chat.unread_count', 1)
            ->assertJsonPath('group_chat.name', 'บ้านใหม่')
            ->assertJsonPath('group_chat.last_message.body', 'สวัสดีทุกคน');
        $this->getJson('/api/chats')->assertJsonPath('group_chat.unread_count', 1);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('unread_count', 1)
            ->assertJsonPath('group_unread_count', 1);
    }

    public function test_outsiders_cannot_use_the_room_even_through_the_api(): void
    {
        $mom = User::factory()->create();
        $stranger = User::factory()->create();
        $otherOwner = User::factory()->create();
        $this->createFamily($mom);
        $this->createFamily($otherOwner);

        $chatId = $this->open($mom);
        $messageId = $this->say($mom, $chatId, 'เรื่องในบ้าน')->json('message.id');

        foreach ([$stranger, $otherOwner] as $outsider) {
            Sanctum::actingAs($outsider);
            $this->getJson("/api/group-chats/{$chatId}/messages")->assertForbidden()->assertJsonPath('code', 'not_member');
            $this->getJson("/api/group-chats/{$chatId}/messages/{$messageId}")->assertForbidden();
            $this->postJson("/api/group-chats/{$chatId}/messages", ['body' => 'แอบส่ง', 'client_id' => 'x'])->assertForbidden();
            $this->postJson("/api/group-chats/{$chatId}/read", ['message_id' => $messageId])->assertForbidden();
            $this->putJson("/api/group-chats/{$chatId}/mute", ['muted' => true])->assertForbidden();
        }

        Sanctum::actingAs($stranger);
        $this->postJson('/api/group-chat/open')->assertForbidden();
        $this->assertSame(1, GroupChatMessage::count());
    }

    // =====================================================
    // ข้อความย้อนหลังตามรอบสมาชิก
    // =====================================================

    public function test_new_member_only_sees_messages_after_joining(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom);

        $chatId = $this->open($mom);
        $this->say($mom, $chatId, 'ก่อนลูกเข้า')->assertCreated();

        $this->join($son, $family->id);
        $this->say($mom, $chatId, 'หลังลูกเข้า')->assertCreated();

        $this->assertSame(['หลังลูกเข้า'], $this->bodies($son, $chatId));
        // หน้าเก่ากว่าก็ไม่มีข้อความก่อนเข้ากลุ่ม
        $this->assertSame(['หลังลูกเข้า'], $this->bodies($son, $chatId, ['before_id' => 999999]));
        $this->assertSame(['ก่อนลูกเข้า', 'หลังลูกเข้า'], $this->bodies($mom, $chatId));

        Sanctum::actingAs($son);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('group_unread_count', 1);

        // ข้อความก่อนเข้าเปิดตรง ๆ ไม่ได้
        $before = GroupChatMessage::where('body', 'ก่อนลูกเข้า')->first();
        $this->getJson("/api/group-chats/{$chatId}/messages/{$before->id}")->assertForbidden();
    }

    public function test_existing_members_start_when_the_room_opens_without_old_private_chats(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        // แชทส่วนตัวเดิมไม่ถูกดึงมา
        Conversation::create(['user_one_id' => min($mom->id, $son->id), 'user_two_id' => max($mom->id, $son->id)]);

        $chatId = $this->open($son);
        $this->say($mom, $chatId, 'ข้อความแรกของห้อง')->assertCreated();

        $this->assertSame(['ข้อความแรกของห้อง'], $this->bodies($son, $chatId));
        $this->assertSame(0, GroupChatMember::where('user_id', $son->id)->value('visible_after_id'));
    }

    public function test_leaving_and_rejoining_does_not_restore_old_history(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);

        $chatId = $this->open($mom);
        $this->say($mom, $chatId, 'รอบแรก')->assertCreated();
        $this->assertSame(['รอบแรก'], $this->bodies($son, $chatId));

        Sanctum::actingAs($son);
        $this->postJson('/api/families/leave')->assertOk();
        $this->getJson("/api/group-chats/{$chatId}/messages")->assertForbidden();

        $this->say($mom, $chatId, 'ตอนลูกไม่อยู่')->assertCreated();

        $this->join($son, $family->id);
        $this->say($mom, $chatId, 'รอบใหม่')->assertCreated();

        $this->assertSame(['รอบใหม่'], $this->bodies($son, $chatId));
        $this->assertSame(1, GroupChatMember::where('user_id', $son->id)->count());
    }

    public function test_removed_member_cannot_read_send_page_or_open_images(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $chatId = $this->open($mom);

        Sanctum::actingAs($mom);
        $photo = $this->post("/api/group-chats/{$chatId}/messages", [
            'client_id' => 'photo-1',
            'image' => UploadedFile::fake()->create('cake.jpg', 120, 'image/jpeg'),
        ], ['Accept' => 'application/json'])->assertCreated();

        // ลูกได้ลิงก์รูปตอนยังเป็นสมาชิก
        Sanctum::actingAs($son);
        $url = $this->getJson("/api/group-chats/{$chatId}/messages")->json('messages.0.image_url');
        $this->assertNotNull($url);
        app('auth')->forgetGuards();
        $this->get($url)->assertOk();

        Sanctum::actingAs($mom);
        $this->deleteJson("/api/families/members/{$son->id}")->assertOk();

        Sanctum::actingAs($son);
        $this->getJson("/api/group-chats/{$chatId}/messages")->assertForbidden();
        $this->getJson("/api/group-chats/{$chatId}/messages?before_id=99999")->assertForbidden();
        $this->getJson("/api/group-chats/{$chatId}/messages?after_id=0")->assertForbidden();
        $this->getJson("/api/group-chats/{$chatId}/messages/" . $photo->json('message.id'))->assertForbidden();
        $this->say($son, $chatId, 'หลังถูกนำออก')->assertForbidden();
        $this->getJson('/api/chats')->assertJsonPath('group_chat', null);

        // ลิงก์เดิมยังไม่หมดอายุ แต่หมดสิทธิ์แล้ว → เปิดไม่ได้
        app('auth')->forgetGuards();
        $this->get($url)->assertForbidden();
        $this->assertSame(0, GroupChatMessage::where('body', 'หลังถูกนำออก')->count());
    }

    public function test_images_are_private_validated_and_need_a_valid_signature(): void
    {
        $mom = User::factory()->create();
        $this->createFamily($mom);
        $chatId = $this->open($mom);

        Sanctum::actingAs($mom);
        $this->post("/api/group-chats/{$chatId}/messages", [
            'client_id' => 'pdf',
            'image' => UploadedFile::fake()->create('doc.pdf', 50, 'application/pdf'),
        ], ['Accept' => 'application/json'])->assertStatus(422);
        $this->post("/api/group-chats/{$chatId}/messages", [
            'client_id' => 'big',
            'image' => UploadedFile::fake()->create('big.jpg', 5000, 'image/jpeg'),
        ], ['Accept' => 'application/json'])->assertStatus(422);

        $sent = $this->post("/api/group-chats/{$chatId}/messages", [
            'client_id' => 'ok',
            'image' => UploadedFile::fake()->create('ok.png', 100, 'image/png'),
        ], ['Accept' => 'application/json'])->assertCreated();

        $message = GroupChatMessage::find($sent->json('message.id'));
        Storage::disk('local')->assertExists($message->image_path);
        $this->assertStringNotContainsString($message->image_path, $sent->getContent());

        // ไม่มีลายเซ็น / แก้ผู้ดู → เปิดไม่ได้
        app('auth')->forgetGuards();
        $this->get("/api/group-chat-images/{$message->id}?viewer={$mom->id}")->assertForbidden();
        $tampered = str_replace("viewer={$mom->id}", 'viewer=999', $sent->json('message.image_url'));
        $this->get($tampered)->assertForbidden();
    }

    // =====================================================
    // ส่งข้อความ
    // =====================================================

    public function test_retry_with_the_same_client_id_does_not_duplicate(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $chatId = $this->open($mom);

        $first = $this->say($mom, $chatId, 'นัดกินข้าว', 'client-1')->assertCreated();
        $retry = $this->say($mom, $chatId, 'นัดกินข้าว', 'client-1')->assertOk();
        $this->say($son, $chatId, 'โอเค', 'client-1')->assertCreated();

        $this->assertSame($first->json('message.id'), $retry->json('message.id'));
        $this->assertSame('client-1', $retry->json('message.client_id'));
        $this->assertSame(2, GroupChatMessage::count());

        // ข้อมูลผู้ส่งไม่มีอีเมล / client_id ของคนอื่นไม่ถูกส่ง
        Sanctum::actingAs($son);
        $response = $this->getJson("/api/group-chats/{$chatId}/messages")->assertOk()
            ->assertJsonPath('messages.0.client_id', null)
            ->assertJsonPath('messages.0.sender.name', $mom->name);
        $this->assertSame(['id', 'name', 'profile_image_url'], array_keys($response->json('messages.0.sender')));
        $this->assertStringNotContainsString($mom->email, $response->getContent());

        $this->say($mom, $chatId, '')->assertStatus(422);
        $this->say($mom, $chatId, str_repeat('ก', 2001))->assertStatus(422);
    }

    public function test_paging_older_and_newer_messages(): void
    {
        $mom = User::factory()->create();
        $this->createFamily($mom);
        $chatId = $this->open($mom);

        // สร้างตรง ๆ (ส่งผ่าน API ถูกจำกัด 30 ข้อความ/นาที)
        foreach (range(1, 35) as $i) {
            GroupChatMessage::create(['group_chat_id' => $chatId, 'sender_id' => $mom->id, 'client_id' => "m{$i}", 'body' => "ข้อความ {$i}"]);
        }

        Sanctum::actingAs($mom);
        $latest = $this->getJson("/api/group-chats/{$chatId}/messages")->assertOk();
        $this->assertCount(30, $latest->json('messages'));
        $this->assertTrue($latest->json('has_more'));
        $this->assertSame('ข้อความ 6', $latest->json('messages.0.body'));
        $this->assertSame('ข้อความ 35', $latest->json('messages.29.body'));

        $older = $this->getJson("/api/group-chats/{$chatId}/messages?before_id=" . $latest->json('messages.0.id'))->assertOk();
        $this->assertSame(['ข้อความ 1', 'ข้อความ 2', 'ข้อความ 3', 'ข้อความ 4', 'ข้อความ 5'], collect($older->json('messages'))->pluck('body')->all());
        $this->assertFalse($older->json('has_more'));

        $this->say($mom, $chatId, 'ใหม่ล่าสุด')->assertCreated();
        Sanctum::actingAs($mom);
        $newer = $this->getJson("/api/group-chats/{$chatId}/messages?after_id=" . $latest->json('messages.29.id'))->assertOk();
        $this->assertSame(['ใหม่ล่าสุด'], collect($newer->json('messages'))->pluck('body')->all());
    }

    // =====================================================
    // ยังไม่อ่าน
    // =====================================================

    public function test_unread_is_per_member_and_never_moves_back_across_devices(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $dad = User::factory()->create();
        $this->createFamily($mom, [$son, $dad]);
        $chatId = $this->open($mom);

        $ids = collect(['หนึ่ง', 'สอง', 'สาม'])->map(fn ($text) => $this->say($mom, $chatId, $text)->json('message.id'));
        $this->say($son, $chatId, 'ของลูกเอง')->assertCreated();

        // ลูก: ข้อความของตัวเองไม่นับ / ส่งแล้วถือว่าอ่านถึงข้อความของตัวเอง
        Sanctum::actingAs($son);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('group_unread_count', 0);

        // พ่อ: เครื่อง A อ่านถึงข้อความที่ 3 / เครื่อง B ส่งตำแหน่งเก่า (ข้อความที่ 1) → ไม่ถอยกลับ
        Sanctum::actingAs($dad);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('group_unread_count', 4);
        $this->postJson("/api/group-chats/{$chatId}/read", ['message_id' => $ids[2]])->assertOk()->assertJsonPath('unread_count', 1);
        $this->postJson("/api/group-chats/{$chatId}/read", ['message_id' => $ids[0]])->assertOk()->assertJsonPath('unread_count', 1);
        $this->postJson("/api/group-chats/{$chatId}/read", ['message_id' => 999999])->assertOk()->assertJsonPath('unread_count', 0);

        // แม่ยังไม่ได้อ่านข้อความลูก (แยกต่อคน)
        Sanctum::actingAs($mom);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('group_unread_count', 1);
    }

    // =====================================================
    // แจ้งเตือน
    // =====================================================

    public function test_push_skips_sender_muted_members_blockers_and_chat_setting_off(): void
    {
        $this->configurePush();

        $mom = User::factory()->create();
        $son = User::factory()->create();
        $dad = User::factory()->create();
        $aunt = User::factory()->create();
        $grandma = User::factory()->create(['notification_settings' => ['new_message' => false]]);
        $this->createFamily($mom, [$son, $dad, $aunt, $grandma]);

        foreach ([$mom, $son, $dad, $aunt, $grandma] as $user) {
            $this->device($user, 'fid-' . $user->id);
        }
        // ลูกมี 2 เครื่อง → Push 2 เครื่อง แต่ไม่มีรายการแจ้งเตือนซ้ำ
        $this->device($son, 'fid-son-tablet');

        $chatId = $this->open($mom);

        Sanctum::actingAs($dad);
        $this->putJson("/api/group-chats/{$chatId}/mute", ['muted' => true])->assertOk()->assertJsonPath('muted', true);
        UserBlock::create(['user_id' => $aunt->id, 'blocked_user_id' => $mom->id]);

        $this->say($mom, $chatId, 'ความลับในบ้าน')->assertCreated();

        $this->assertEqualsCanonicalizing(['fid-' . $son->id, 'fid-son-tablet'], $this->pushedTo());
        Http::assertSent(fn (HttpRequest $request) => $request['message']['notification']['body'] === 'มีข้อความใหม่ในกลุ่ม'
            && $request['message']['data']['type'] === 'group_message'
            && !str_contains(json_encode($request->data(), JSON_UNESCAPED_UNICODE), 'ความลับ'));
        $this->assertSame(0, \App\Models\AppNotification::count());

        // ปิดเสียงแล้วยังรับข้อความและนับยังไม่อ่าน / คนที่บล็อกก็ยังเห็นข้อความ
        Sanctum::actingAs($dad);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('group_unread_count', 1);
        $this->assertSame(['ความลับในบ้าน'], $this->bodies($aunt, $chatId));
    }

    public function test_queued_push_rechecks_membership_before_sending(): void
    {
        $this->configurePush();

        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $this->device($son, 'fid-son');

        $chatId = $this->open($mom);

        $message = GroupChatMessage::create([
            'group_chat_id' => $chatId,
            'sender_id' => $mom->id,
            'client_id' => 'queued',
            'body' => 'รอส่ง',
        ]);

        // ลูกถูกนำออกก่อนงานส่ง Push ทำงาน
        Sanctum::actingAs($mom);
        $this->deleteJson("/api/families/members/{$son->id}")->assertOk();

        GroupChat::notifyNewMessage($message->id);

        $this->assertSame([], $this->pushedTo());
    }

    // =====================================================
    // ลบกลุ่ม / ลบบัญชี / ย้ายเจ้าของ
    // =====================================================

    public function test_deleting_the_group_removes_room_messages_and_images(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $chatId = $this->open($mom);

        Sanctum::actingAs($son);
        $sent = $this->post("/api/group-chats/{$chatId}/messages", [
            'client_id' => 'pic',
            'image' => UploadedFile::fake()->create('pic.jpg', 80, 'image/jpeg'),
        ], ['Accept' => 'application/json'])->assertCreated();
        $path = GroupChatMessage::find($sent->json('message.id'))->image_path;

        Sanctum::actingAs($mom);
        $this->deleteJson('/api/families/current')->assertOk();

        $this->assertSame(0, GroupChat::count());
        $this->assertSame(0, GroupChatMessage::count());
        $this->assertSame(0, GroupChatMember::count());
        Storage::disk('local')->assertMissing($path);

        Sanctum::actingAs($son);
        $this->getJson("/api/group-chats/{$chatId}/messages")->assertNotFound();
    }

    public function test_deleting_an_account_removes_its_messages_and_images_only(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $chatId = $this->open($mom);

        $this->say($mom, $chatId, 'ของแม่')->assertCreated();

        Sanctum::actingAs($son);
        $sent = $this->post("/api/group-chats/{$chatId}/messages", [
            'body' => 'ของลูก',
            'client_id' => 'son-pic',
            'image' => UploadedFile::fake()->create('son.jpg', 80, 'image/jpeg'),
        ], ['Accept' => 'application/json'])->assertCreated();
        $path = GroupChatMessage::find($sent->json('message.id'))->image_path;

        app(AccountDeletionService::class)->delete($son->fresh());

        Storage::disk('local')->assertMissing($path);
        $this->assertSame(['ของแม่'], $this->bodies($mom, $chatId));
    }

    public function test_transferring_ownership_keeps_everyones_history(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $chatId = $this->open($mom);
        $this->say($mom, $chatId, 'ก่อนโอน')->assertCreated();

        Sanctum::actingAs($mom);
        $this->postJson("/api/families/transfer-owner/{$son->id}")->assertOk();

        $this->assertSame(['ก่อนโอน'], $this->bodies($son, $chatId));
        $this->assertSame(['ก่อนโอน'], $this->bodies($mom, $chatId));
    }

    public function test_private_and_shop_chat_counts_still_work(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        Sanctum::actingAs($mom);
        $conversationId = $this->postJson('/api/chats', ['user_id' => $son->id])->assertSuccessful()->json('conversation.id');
        $this->postJson("/api/chats/{$conversationId}/messages", ['body' => 'ส่วนตัว'])->assertCreated();

        $chatId = $this->open($mom);
        $this->say($mom, $chatId, 'กลุ่ม')->assertCreated();

        Sanctum::actingAs($son);
        $this->getJson('/api/chats/unread-count')->assertJsonPath('unread_count', 2)->assertJsonPath('group_unread_count', 1);
        $this->getJson("/api/chats/{$conversationId}/messages")->assertOk()->assertJsonPath('messages.0.body', 'ส่วนตัว');
    }
}
