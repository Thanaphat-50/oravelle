<?php

namespace Tests\Feature;

use App\Models\FamilyMember;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\Facades\Storage;
use Illuminate\Support\Facades\URL;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// ไฟล์แนบ + ข้อความเสียงในแชท: ชนิดจริงของไฟล์ / ขนาด / สิทธิ์ดาวน์โหลด / รอบสมาชิกกลุ่ม / ส่งซ้ำ
class ChatAttachmentTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Http::preventStrayRequests();
        $this->withoutDefer();
        Storage::fake('local');
    }

    private function privateRoom(User $a, User $b): int
    {
        Sanctum::actingAs($a);

        return $this->postJson('/api/chats', ['user_id' => $b->id])->assertSuccessful()->json('conversation.id');
    }

    private function groupRoom(User $user): int
    {
        Sanctum::actingAs($user);

        return $this->postJson('/api/group-chat/open')->assertOk()->json('room.id');
    }

    private function upload(User $user, string $url, array $fields)
    {
        Sanctum::actingAs($user);

        return $this->post($url, ['client_id' => uniqid('a', true), ...$fields], ['Accept' => 'application/json']);
    }

    private function pdf(string $name = 'รายงาน.pdf'): UploadedFile
    {
        return UploadedFile::fake()->createWithContent($name, "%PDF-1.4\n1 0 obj << >> endobj\n%%EOF\n");
    }

    private function docx(string $name, string $extra = ''): UploadedFile
    {
        return UploadedFile::fake()->createWithContent(
            $name,
            "PK\x03\x04" . str_repeat("\0", 26) . '[Content_Types].xml' . 'word/document.xml' . $extra
        );
    }

    // ไฟล์ M4A ขนาดเล็ก: ftyp + moov/mvhd (timescale 1000)
    private function m4a(int $durationMs): UploadedFile
    {
        $ftyp = pack('N', 20) . 'ftyp' . 'M4A ' . pack('N', 0) . 'isom';
        $mvhd = pack('N', 108) . 'mvhd' . "\0\0\0\0" . pack('N', 0) . pack('N', 0)
            . pack('N', 1000) . pack('N', $durationMs) . str_repeat("\0", 80);

        return UploadedFile::fake()->createWithContent(
            'voice.m4a',
            $ftyp . pack('N', 8 + strlen($mvhd)) . 'moov' . $mvhd
        );
    }

    private function storedFiles(): array
    {
        return array_values(array_filter(
            Storage::disk('local')->allFiles(),
            fn ($path) => str_contains($path, 'chat_files/')
        ));
    }

    // =====================================================
    // แชทส่วนตัว
    // =====================================================

    public function test_private_file_is_private_and_opened_only_by_room_members(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $outsider = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);

        $sent = $this->upload($mom, "/api/chats/{$room}/messages", [
            'body' => 'สรุปงาน',
            'file' => $this->pdf(),
        ])->assertCreated()
            ->assertJsonPath('message.attachment.kind', 'file')
            ->assertJsonPath('message.attachment.name', 'รายงาน.pdf')
            ->assertJsonPath('message.attachment.mime', 'application/pdf')
            ->assertJsonPath('message.body', 'สรุปงาน');

        // เก็บด้วยชื่อสุ่มใน disk ส่วนตัว (ไม่ใช้ชื่อจากผู้ใช้)
        $files = $this->storedFiles();
        $this->assertCount(1, $files);
        $this->assertStringNotContainsString('.pdf', $files[0]);

        // ลูกเปิดได้ (ลิงก์ของตัวเอง)
        Sanctum::actingAs($son);
        $url = $this->getJson("/api/chats/{$room}/messages")->json('messages.0.attachment.url');
        $download = $this->get($url)->assertOk();
        $this->assertStringContainsString('attachment', (string) $download->headers->get('content-disposition'));
        $this->assertSame('nosniff', $download->headers->get('x-content-type-options'));

        // ปลอมผู้ดูในลิงก์ → ลายเซ็นไม่ตรง / คนนอกห้องที่ได้ลิงก์ของตัวเอง → ตรวจสิทธิ์ไม่ผ่าน
        $this->get(str_replace("viewer={$son->id}", "viewer={$outsider->id}", $url))->assertForbidden();
        $this->get(URL::temporarySignedRoute('chat.file', now()->addMinutes(10), [
            'message' => $sent->json('message.id'),
            'viewer' => $outsider->id,
        ]))->assertForbidden();

        // ลิงก์หมดอายุใน 10 นาที → ขอลิงก์ใหม่จากข้อความเดียว
        $this->travel(11)->minutes();
        $this->get($url)->assertForbidden();

        Sanctum::actingAs($son);
        $fresh = $this->getJson("/api/chats/{$room}/messages/" . $sent->json('message.id'))
            ->assertOk()->json('message.attachment.url');
        $this->get($fresh)->assertOk();

        // คนนอกห้องขอข้อความเดียวไม่ได้
        Sanctum::actingAs($outsider);
        $this->getJson("/api/chats/{$room}/messages/" . $sent->json('message.id'))->assertNotFound();
    }

    public function test_file_type_comes_from_content_and_bad_files_leave_nothing_behind(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);
        $url = "/api/chats/{$room}/messages";

        // โปรแกรมเปลี่ยนชื่อเป็น .pdf / นามสกุลที่ไม่รองรับ / ข้อความที่มี NUL / เอกสารที่มีมาโคร / เกินขนาด
        $this->upload($mom, $url, ['file' => UploadedFile::fake()->createWithContent('invoice.pdf', "MZ\x90\x00 program")])
            ->assertStatus(422)->assertJsonPath('errors.file.0', 'ไฟล์นี้ไม่ตรงกับชนิดที่แจ้ง หรือเป็นชนิดที่ไม่รองรับ');
        $this->upload($mom, $url, ['file' => UploadedFile::fake()->createWithContent('setup.exe', "MZ\x90\x00")])
            ->assertStatus(422)->assertJsonPath('errors.file.0', 'รองรับเฉพาะไฟล์ PDF, TXT, DOCX, XLSX และ PPTX');
        $this->upload($mom, $url, ['file' => UploadedFile::fake()->createWithContent('note.txt', "abc\0def")])
            ->assertStatus(422);
        $this->upload($mom, $url, ['file' => $this->docx('macro.docx', 'word/vbaProject.bin')])
            ->assertStatus(422);
        $this->upload($mom, $url, ['file' => UploadedFile::fake()->create('big.pdf', 10241)])
            ->assertStatus(422)->assertJsonPath('errors.file.0', 'ไฟล์ต้องมีขนาดไม่เกิน 10 MB');

        $this->assertSame([], $this->storedFiles());

        // ชื่อที่แสดงตัดเส้นทางและตัวกลับทิศออก / ข้อความภาษาไทยรับได้
        $this->upload($mom, $url, ['file' => $this->docx("../../evil\u{202E}xcod.docx")])
            ->assertCreated()->assertJsonPath('message.attachment.name', 'evilxcod.docx');
        $this->upload($mom, $url, ['file' => UploadedFile::fake()->createWithContent('บันทึก.txt', 'สวัสดีครับ')])
            ->assertCreated()->assertJsonPath('message.attachment.mime', 'text/plain');

        $this->assertCount(2, $this->storedFiles());
    }

    public function test_voice_length_is_read_from_the_file_and_limited(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);
        $url = "/api/chats/{$room}/messages";

        // ความยาวที่แอปส่งมาไม่ถูกใช้ ใช้ค่าจากไฟล์ / ข้อความเสียงไม่มีคำบรรยาย
        $sent = $this->upload($mom, $url, [
            'voice' => $this->m4a(5000),
            'voice_duration_ms' => 90000,
            'body' => 'ไม่ควรติดไปด้วย',
        ])->assertCreated()
            ->assertJsonPath('message.attachment.kind', 'voice')
            ->assertJsonPath('message.attachment.duration_ms', 5000)
            ->assertJsonPath('message.body', null);

        $play = $this->get($sent->json('message.attachment.url'))->assertOk();
        $this->assertSame('audio/mp4', $play->headers->get('content-type'));

        $this->upload($mom, $url, ['voice' => $this->m4a(200000)])
            ->assertStatus(422)->assertJsonPath('errors.voice.0', 'ข้อความเสียงยาวได้ไม่เกิน 3 นาที');
        $this->upload($mom, $url, ['voice' => UploadedFile::fake()->createWithContent('voice.m4a', 'not audio at all')])
            ->assertStatus(422);
        $this->upload($mom, $url, ['voice' => $this->m4a(3000), 'file' => $this->pdf()])
            ->assertStatus(422);

        $this->assertCount(1, $this->storedFiles());
    }

    public function test_retry_with_same_client_id_keeps_one_message_and_one_file(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);

        Sanctum::actingAs($mom);
        $fields = ['client_id' => 'retry-1', 'file' => $this->pdf()];
        $first = $this->post("/api/chats/{$room}/messages", $fields, ['Accept' => 'application/json'])->assertCreated();
        $again = $this->post("/api/chats/{$room}/messages", ['client_id' => 'retry-1', 'file' => $this->pdf()], ['Accept' => 'application/json'])
            ->assertOk();

        $this->assertSame($first->json('message.id'), $again->json('message.id'));
        $this->assertCount(1, $this->storedFiles());
    }

    public function test_uploads_are_rate_limited_per_user(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);
        $room = $this->privateRoom($mom, $son);

        for ($i = 0; $i < 20; $i++) {
            RateLimiter::hit('chat-upload:' . $mom->id, 60);
        }

        $this->upload($mom, "/api/chats/{$room}/messages", ['file' => $this->pdf()])
            ->assertStatus(429)->assertJsonPath('message', 'ส่งไฟล์ถี่เกินไป กรุณารอสักครู่แล้วลองใหม่');

        $this->assertSame([], $this->storedFiles());
    }

    // =====================================================
    // แชทกลุ่ม: รอบสมาชิก
    // =====================================================

    public function test_group_files_follow_membership_rounds_and_replies_hide_file_details(): void
    {
        $mom = User::factory()->create();
        $dad = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$dad]);
        $chat = $this->groupRoom($mom);
        $url = "/api/group-chats/{$chat}/messages";

        $old = $this->upload($mom, $url, ['file' => $this->pdf('ก่อนลูกเข้า.pdf')])->assertCreated()->json('message.id');

        FamilyMember::create(['family_id' => $family->id, 'user_id' => $son->id, 'role' => 'member']);

        // ลูก (สมาชิกใหม่) ไม่เห็นและเปิดไฟล์รอบก่อนไม่ได้ แม้มีลิงก์ลงลายเซ็นของตัวเอง
        Sanctum::actingAs($son);
        $this->assertStringNotContainsString('ก่อนลูกเข้า', $this->getJson("/api/group-chats/{$chat}/messages")->getContent());
        $this->get(URL::temporarySignedRoute('group-chat.file', now()->addMinutes(10), [
            'message' => $old,
            'viewer' => $son->id,
        ]))->assertForbidden();

        // ไฟล์หลังเข้ากลุ่มเปิดได้
        $this->upload($mom, $url, ['file' => $this->pdf('หลังลูกเข้า.pdf')])->assertCreated();
        Sanctum::actingAs($son);
        $link = $this->getJson("/api/group-chats/{$chat}/messages")->json('messages.0.attachment.url');
        $this->get($link)->assertOk();

        // พ่อตอบไฟล์เก่า: ลูกเห็นกรอบ "ไม่พร้อมใช้งาน" / พ่อเห็นแค่ชนิด ไม่มีชื่อไฟล์หรือลิงก์
        $reply = $this->upload($dad, $url, ['body' => 'รับทราบ', 'reply_to_id' => $old])->assertCreated();
        $reply->assertJsonPath('message.reply_to.attachment_kind', 'file');
        $this->assertArrayNotHasKey('url', $reply->json('message.reply_to'));
        $this->assertStringNotContainsString('ก่อนลูกเข้า', json_encode($reply->json('message.reply_to'), JSON_UNESCAPED_UNICODE));

        // ลูกออกจากกลุ่ม → ลิงก์ที่เคยได้เปิดไม่ได้ทันที
        FamilyMember::where('family_id', $family->id)->where('user_id', $son->id)->delete();
        $this->get($link)->assertForbidden();
    }
}
