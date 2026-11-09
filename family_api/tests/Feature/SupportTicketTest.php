<?php

namespace Tests\Feature;

use App\Filament\Resources\SupportTickets\Pages\ViewSupportTicket;
use App\Models\AppNotification;
use App\Models\Order;
use App\Models\Product;
use App\Models\Shop;
use App\Models\SupportAttachment;
use App\Models\SupportMessage;
use App\Models\SupportTicket;
use App\Models\User;
use App\Services\AccountDeletionService;
use App\Services\SupportDesk;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Storage;
use Laravel\Sanctum\Sanctum;
use Livewire\Livewire;
use Tests\Concerns\FakesImages;
use Tests\TestCase;

// ศูนย์ช่วยเหลือ: สิทธิ์ / บันทึกภายใน / กันส่งซ้ำ / ไฟล์แนบ / สถานะออเดอร์ไม่เปลี่ยน / ลบบัญชี / หลังบ้าน
class SupportTicketTest extends TestCase
{
    use FakesImages, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Storage::fake('local');
        Storage::fake('public');
    }

    private function staff(): User
    {
        $admin = User::factory()->create(['name' => 'เจ้าหน้าที่ A']);
        $admin->is_admin = true;
        $admin->save();

        return $admin;
    }

    private function orderFor(User $buyer): array
    {
        $seller = User::factory()->create();

        $shop = Shop::create([
            'user_id' => $seller->id,
            'name' => 'ร้านทดสอบ',
            'category' => 'produce',
            'phone' => '0812345678',
            'province' => 'เชียงใหม่',
            'status' => Shop::STATUS_ACTIVE,
            'terms_accepted_at' => now(),
            'delivery_methods' => ['storefront'],
            'payment_methods' => ['promptpay'],
            'promptpay_id' => '0899999999',
        ]);

        $product = $shop->products()->create([
            'title' => 'มะม่วง',
            'price' => 100,
            'stock' => 5,
            'category' => 'produce',
            'status' => Product::STATUS_ACTIVE,
        ]);

        $order = DB::transaction(fn () => Order::placeGroup($buyer, $shop, [[
            'product' => $product,
            'variant' => null,
            'quantity' => 1,
            'unit_price' => 100.0,
        ]], [
            'delivery_method' => 'storefront',
            'payment_method' => 'promptpay',
            'recipient_name' => 'คุณแม่',
            'recipient_phone' => '0811112222',
        ]));

        return [$order, $seller];
    }

    private function create(array $fields = [], array $files = [])
    {
        return $this->post('/api/support/tickets', [
            'category' => 'app',
            'subject' => 'เปิดแอปแล้วค้าง',
            'body' => 'เปิดหน้าแชทแล้วค้างทุกครั้ง',
            'client_id' => 'c-' . uniqid(),
            ...$fields,
            ...($files ? ['images' => $files] : []),
        ], ['Accept' => 'application/json']);
    }

    public function test_user_reports_a_problem_with_photos_and_retry_does_not_duplicate(): void
    {
        $user = User::factory()->create();
        Sanctum::actingAs($user);

        $body = ['client_id' => 'same-tap'];

        $first = $this->create($body, [$this->fakePng('a.png')])
            ->assertCreated()
            ->assertJsonPath('ticket.status', SupportTicket::STATUS_SUBMITTED)
            ->assertJsonPath('ticket.status_label', 'ส่งแล้ว')
            ->assertJsonPath('ticket.category_label', 'การใช้งานแอป')
            ->assertJsonPath('ticket.messages.0.from', 'me')
            ->assertJsonPath('limits.max_images', 4);

        $this->assertMatchesRegularExpression('/^HT\d{6}[A-Z2-9]{5}$/', $first->json('ticket.code'));

        // กดซ้ำ / หมดเวลารอแล้วส่งใหม่ → คำร้องเดิม
        $this->create($body, [$this->fakePng('a.png')])
            ->assertOk()
            ->assertJsonPath('ticket.id', $first->json('ticket.id'));

        $this->assertSame(1, SupportTicket::count());
        $this->assertSame(1, SupportAttachment::count());

        // ไฟล์อยู่ใน disk ส่วนตัว ไม่ใช่ public
        $path = SupportAttachment::first()->path;
        Storage::disk('local')->assertExists($path);
        Storage::disk('public')->assertMissing($path);

        // ลิงก์ชั่วคราวเปิดได้ / แก้ลายเซ็นหรือหมดอายุแล้วเปิดไม่ได้
        $url = $first->json('ticket.messages.0.attachments.0.url');

        $this->get($url)->assertOk();
        $this->getJson(preg_replace('/signature=[^&]+/', 'signature=bad', $url))->assertForbidden();
        $this->getJson('/api/support/files/' . SupportAttachment::first()->id)->assertForbidden();

        $this->travel(31)->minutes();
        $this->getJson($url)->assertForbidden();
    }

    public function test_other_users_cannot_see_reply_or_download(): void
    {
        $owner = User::factory()->create();
        $other = User::factory()->create();

        Sanctum::actingAs($owner);
        $ticketId = $this->create([], [$this->fakePng('private.png')])->assertCreated()->json('ticket.id');

        Sanctum::actingAs($other);

        $this->getJson("/api/support/tickets/{$ticketId}")->assertNotFound();
        $this->post("/api/support/tickets/{$ticketId}/messages", ['body' => 'แอบส่ง', 'client_id' => 'x'], ['Accept' => 'application/json'])
            ->assertNotFound();
        $this->assertSame([], $this->getJson('/api/support/tickets')->json('tickets'));

        $this->assertSame(1, SupportMessage::count());
    }

    public function test_internal_notes_never_reach_the_user_and_replies_notify_without_details(): void
    {
        $user = User::factory()->create();
        $staff = $this->staff();

        Sanctum::actingAs($user);
        $ticket = SupportTicket::find($this->create()->json('ticket.id'));

        $desk = app(SupportDesk::class);

        $desk->note($ticket, $staff, 'ลูกค้าเคยแจ้งเรื่องนี้ครั้งก่อน (ลับ)');
        $this->assertSame(0, AppNotification::where('user_id', $user->id)->count());

        $desk->reply($ticket, $staff, 'ขอภาพหน้าจอเพิ่มเติมครับ', SupportTicket::STATUS_WAITING_USER);

        $response = $this->getJson("/api/support/tickets/{$ticket->id}")
            ->assertOk()
            ->assertJsonPath('ticket.status', SupportTicket::STATUS_WAITING_USER)
            ->assertJsonPath('ticket.messages.1.from', 'staff')
            ->assertJsonPath('ticket.messages.1.author', 'ทีมงาน ORAVELLE');

        $this->assertCount(2, $response->json('ticket.messages'));
        $this->assertStringNotContainsString('ลับ', $response->getContent());
        $this->assertStringNotContainsString('เจ้าหน้าที่ A', $response->getContent());

        // แจ้งเตือน 1 ครั้ง ไม่มีเนื้อหาคำตอบ
        $notification = AppNotification::where('user_id', $user->id)->sole();
        $this->assertSame('support_ticket', $notification->type);
        $this->assertSame($ticket->id, (int) $notification->data['ticket_id']);
        $this->assertStringNotContainsString('ภาพหน้าจอ', $notification->message);

        // ผู้ใช้ส่งข้อมูลเพิ่ม (ส่งซ้ำได้ข้อความเดิม) → กลับไปกำลังตรวจสอบ
        foreach ([1, 2] as $_) {
            $this->post("/api/support/tickets/{$ticket->id}/messages", [
                'body' => 'แนบภาพแล้วครับ',
                'client_id' => 'more-1',
                'images' => [$this->fakePng('screen.png')],
            ], ['Accept' => 'application/json'])->assertSuccessful();
        }

        $this->assertSame(2, SupportMessage::where('ticket_id', $ticket->id)->where('is_staff', false)->count());
        $this->assertSame(SupportTicket::STATUS_IN_REVIEW, $ticket->refresh()->status);

        // ปิดเรื่อง → ผู้ใช้เห็นสรุปผล ส่งเพิ่มไม่ได้ อ้างอิงเรื่องเดิมได้
        $desk->close($ticket, $staff, 'แก้ไขในแอปเวอร์ชันใหม่แล้ว');

        $this->getJson("/api/support/tickets/{$ticket->id}")
            ->assertJsonPath('ticket.status_label', 'ปิดเรื่อง')
            ->assertJsonPath('ticket.can_reply', false)
            ->assertJsonPath('ticket.resolution', 'แก้ไขในแอปเวอร์ชันใหม่แล้ว');

        $this->post("/api/support/tickets/{$ticket->id}/messages", ['body' => 'ยังไม่หาย', 'client_id' => 'late'], ['Accept' => 'application/json'])
            ->assertStatus(409)
            ->assertJsonPath('code', 'ticket_closed');

        $this->create(['previous_ticket_id' => $ticket->id])
            ->assertCreated()
            ->assertJsonPath('ticket.previous_ticket.code', $ticket->code);

        // ประวัติ: ผู้ดำเนินการ + สถานะเดิม/ใหม่
        $this->assertTrue($ticket->events()->where('type', 'closed')->where('actor_id', $staff->id)
            ->where('from_status', SupportTicket::STATUS_IN_REVIEW)->exists());

        $this->getJson('/api/support/tickets?filter=closed')->assertJsonCount(1, 'tickets');
        $this->getJson('/api/support/tickets?filter=open')->assertJsonCount(1, 'tickets');
    }

    public function test_order_problem_links_the_order_and_does_not_change_it(): void
    {
        $buyer = User::factory()->create();
        [$order, $seller] = $this->orderFor($buyer);

        $order->forceFill(['status' => Order::STATUS_CANCELLED, 'refund_status' => Order::REFUND_DONE, 'refunded_at' => now()])->save();
        $snapshot = fn () => json_encode($order->refresh()->only(['status', 'refund_status', 'refund_confirmed_at', 'refunded_at', 'updated_at']));
        $before = $snapshot();

        // ร้านไม่เห็นคำร้องของผู้ซื้อ / คนนอกแจ้งปัญหาออเดอร์นี้ไม่ได้
        Sanctum::actingAs(User::factory()->create());
        $this->create(['category' => 'refund', 'order_id' => $order->id])->assertNotFound();

        Sanctum::actingAs($buyer);

        $ticketId = $this->create(['category' => 'refund', 'subject' => 'ยังไม่ได้รับเงินคืน', 'order_id' => $order->id])
            ->assertCreated()
            ->assertJsonPath('ticket.order.code', $order->code)
            ->json('ticket.id');

        $this->assertSame($before, $snapshot());

        // มีเรื่องที่ยังไม่ปิดของออเดอร์ + ประเภทเดียวกัน → เสนอเรื่องเดิม
        $this->getJson("/api/support/tickets/open?order_id={$order->id}&category=refund")
            ->assertJsonPath('ticket.id', $ticketId);

        $this->create(['category' => 'refund', 'order_id' => $order->id])
            ->assertStatus(409)
            ->assertJsonPath('code', 'open_ticket_exists')
            ->assertJsonPath('ticket.id', $ticketId);

        $this->create(['category' => 'refund', 'order_id' => $order->id, 'confirm_new' => 1])->assertCreated();

        Sanctum::actingAs($seller);
        $this->getJson("/api/support/tickets/{$ticketId}")->assertNotFound();

        // ร้านแจ้งปัญหาออเดอร์ของตัวเองได้
        $this->create(['category' => 'order', 'order_id' => $order->id])->assertCreated();
    }

    public function test_wrong_files_and_limits_are_rejected_in_thai(): void
    {
        Sanctum::actingAs(User::factory()->create());

        $this->create([], [UploadedFile::fake()->create('note.pdf', 10, 'application/pdf')])
            ->assertUnprocessable()
            ->assertJsonPath('errors', fn ($errors) => str_contains(json_encode($errors, JSON_UNESCAPED_UNICODE), 'JPG, PNG หรือ WEBP'));

        $this->create([], [UploadedFile::fake()->create('big.jpg', 6000, 'image/jpeg')])
            ->assertUnprocessable()
            ->assertJsonPath('errors', fn ($errors) => str_contains(json_encode($errors, JSON_UNESCAPED_UNICODE), 'ไม่เกิน 5 MB'));

        $this->create([], array_map(fn ($i) => $this->fakePng("p{$i}.png"), range(1, 5)))
            ->assertUnprocessable()
            ->assertJsonPath('errors.images.0', 'แนบรูปได้ไม่เกิน 4 รูป');

        $this->create(['subject' => ''])->assertUnprocessable()->assertJsonPath('errors.subject.0', 'กรุณาใส่หัวข้อ');

        $this->assertSame(0, SupportTicket::count());
    }

    public function test_creating_tickets_is_rate_limited(): void
    {
        Sanctum::actingAs(User::factory()->create());

        for ($i = 0; $i < 10; $i++) {
            $this->create()->assertCreated();
        }

        $this->create()->assertTooManyRequests();
    }

    public function test_deleting_the_account_removes_tickets_and_files(): void
    {
        $user = User::factory()->create();
        Sanctum::actingAs($user);

        $this->create([], [$this->fakePng('a.png')])->assertCreated();
        $path = SupportAttachment::first()->path;

        app(AccountDeletionService::class)->delete($user);

        $this->assertSame(0, SupportTicket::count());
        $this->assertSame(0, SupportAttachment::count());
        Storage::disk('local')->assertMissing($path);
    }

    public function test_only_staff_open_the_back_office_and_can_act(): void
    {
        $user = User::factory()->create();
        Sanctum::actingAs($user);
        $ticket = SupportTicket::find($this->create()->json('ticket.id'));

        // หลังบ้านใช้ guard web (Sanctum::actingAs ตั้ง guard เริ่มต้นเป็น sanctum)
        $this->actingAs($user, 'web')->get('/admin/support-tickets')->assertForbidden();

        $staff = $this->staff();
        $this->actingAs($staff, 'web');

        $this->get('/admin/support-tickets')->assertOk()->assertSee($ticket->code);
        $this->get("/admin/support-tickets/{$ticket->id}")->assertOk()->assertSee('เปิดหน้าแชทแล้วค้างทุกครั้ง');

        Livewire::test(ViewSupportTicket::class, ['record' => $ticket->getRouteKey()])
            ->callAction('note', ['body' => 'ตรวจ log แล้ว'])
            ->callAction('reply', ['body' => 'แก้ไขแล้วครับ', 'status' => SupportTicket::STATUS_IN_REVIEW])
            ->callAction('close', ['resolution' => 'แก้ไขแล้ว'])
            ->assertHasNoActionErrors();

        $ticket->refresh();

        $this->assertSame(SupportTicket::STATUS_CLOSED, $ticket->status);
        $this->assertSame(1, $ticket->messages()->where('is_internal', true)->count());
        $this->assertTrue($ticket->events()->where('actor_id', $staff->id)->where('type', 'internal_note')->exists());
    }
}
