<?php

namespace Tests\Feature;

use App\Models\Activity;
use App\Models\ActivityReminder;
use App\Models\AppNotification;
use App\Models\DeviceToken;
use App\Models\FamilyMember;
use App\Models\User;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Http\Client\Request as HttpRequest;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Http;
use Laravel\Sanctum\Sanctum;
use ReflectionMethod;
use RuntimeException;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// แจ้งเตือนกิจกรรมล่วงหน้า: ตั้งเตือนของแต่ละคน / เวลา UTC + เขตเวลา / ยกเลิกเมื่อเปลี่ยนแปลง / ส่งครั้งเดียว
// เวลาปลอม (travelTo) + Push ปลอม (Http::fake) + ฐานข้อมูลทดสอบแยก (RefreshDatabase)
class ActivityReminderTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private const FCM_URL = 'https://fcm.googleapis.com/v1/projects/test-project/messages:send';

    protected function setUp(): void
    {
        parent::setUp();

        $this->withoutDefer();
        Http::preventStrayRequests();

        // 08:00 เวลาไทย
        $this->travelTo(Carbon::parse('2026-11-20 01:00:00', 'UTC'));
    }

    // กิจกรรม 10:00 เวลาไทย = 03:00 UTC
    private function create(User $user, array $fields = [])
    {
        Sanctum::actingAs($user);

        return $this->postJson('/api/activities', [
            'title' => 'ประชุมผู้ปกครอง',
            'visibility' => 'private',
            'starts_at' => '2026-11-20T10:00:00+07:00',
            'timezone' => 'Asia/Bangkok',
            ...$fields,
        ]);
    }

    private function remind(User $user, Activity $activity, ?int $offset)
    {
        Sanctum::actingAs($user);

        return $this->putJson("/api/activities/{$activity->id}/reminder", ['offset' => $offset]);
    }

    private function at(string $utc): array
    {
        return ActivityReminder::sendDue(Carbon::parse($utc, 'UTC'));
    }

    private function reminders(User $user): int
    {
        return AppNotification::where('user_id', $user->id)->where('type', 'activity_reminder')->count();
    }

    // =====================================================
    // ตั้งเตือน + เวลา
    // =====================================================

    public function test_creator_sets_reminder_on_create_and_sees_the_reminder_time(): void
    {
        $mom = User::factory()->create();

        $response = $this->create($mom, ['reminder_offset' => 30])->assertCreated()
            ->assertJsonPath('activity.activity_date', '2026-11-20T10:00:00')
            ->assertJsonPath('activity.timezone', 'Asia/Bangkok')
            ->assertJsonPath('activity.can_remind', true)
            ->assertJsonPath('activity.needs_time_confirmation', false)
            ->assertJsonPath('activity.my_reminder.offset_minutes', 30)
            ->assertJsonPath('activity.my_reminder.label', 'ก่อน 30 นาที')
            ->assertJsonPath('activity.my_reminder.remind_at', '2026-11-20T02:30:00+00:00')
            ->assertJsonPath('activity.my_reminder.status', 'pending');

        $this->assertSame('2026-11-20T03:00:00+00:00', Carbon::parse($response->json('activity.starts_at'))->toIso8601String());

        // ค่าเริ่มต้น = ไม่เตือน
        $this->create($mom)->assertCreated()->assertJsonPath('activity.my_reminder', null);
    }

    public function test_reminder_is_sent_at_time_and_before_time_once(): void
    {
        $mom = User::factory()->create();
        $dad = User::factory()->create();

        $before = Activity::find($this->create($mom, ['reminder_offset' => 15])->json('activity.id'));
        $onTime = Activity::find($this->create($dad, ['reminder_offset' => 0])->json('activity.id'));

        $this->assertSame(['sent' => 0, 'expired' => 0, 'cancelled' => 0], $this->at('2026-11-20 02:44:59'));

        $this->assertSame(1, $this->at('2026-11-20 02:45:00')['sent']);
        $this->assertSame(1, $this->reminders($mom));
        $this->assertSame(0, $this->reminders($dad));

        $this->assertSame(1, $this->at('2026-11-20 03:00:00')['sent']);
        $this->assertSame(1, $this->reminders($dad));

        // รันซ้ำ → ไม่ส่งซ้ำ
        $this->assertSame(0, $this->at('2026-11-20 03:05:00')['sent']);
        $this->assertSame(1, $this->reminders($mom));

        $notification = AppNotification::where('user_id', $mom->id)->first();
        $this->assertSame('เตือนกิจกรรม', $notification->title);
        $this->assertSame('กิจกรรมของคุณจะเริ่มในอีก 15 นาที · แตะเพื่อดูรายละเอียด', $notification->message);
        $this->assertStringNotContainsString('ประชุม', $notification->message);
        $this->assertSame(['activity_id' => $before->id], $notification->data);
        $this->assertSame('sent', $onTime->reminders()->first()->status);
    }

    public function test_two_members_have_their_own_reminders_on_a_shared_activity(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $activity = Activity::find($this->create($mom, ['visibility' => 'family', 'reminder_offset' => 15])->json('activity.id'));

        // ลูกไม่มีสิทธิ์แก้ไขกิจกรรม แต่ตั้งเตือนของตัวเองได้
        Sanctum::actingAs($son);
        $this->patchJson("/api/activities/{$activity->id}", ['title' => 'แก้'])->assertForbidden();

        $this->remind($son, $activity, 30)->assertOk()
            ->assertJsonPath('reminder.offset_minutes', 30)
            ->assertJsonPath('reminder.remind_at', '2026-11-20T02:30:00+00:00');

        // แต่ละคนเห็นค่าของตัวเอง
        Sanctum::actingAs($son);
        $this->getJson("/api/activities/{$activity->id}")->assertOk()->assertJsonPath('activity.my_reminder.offset_minutes', 30);
        $this->getJson('/api/activities')->assertJsonPath('activities.0.my_reminder.offset_minutes', 30);

        Sanctum::actingAs($mom);
        $this->getJson('/api/activities')->assertJsonPath('activities.0.my_reminder.offset_minutes', 15)
            ->assertJsonMissingPath('activities.0.reminders');

        // ลูก 02:30 / แม่ 02:45 (UTC) — ต่างคนต่างได้ของตัวเอง
        $this->assertSame(1, $this->at('2026-11-20 02:30:00')['sent']);
        $this->assertSame(1, $this->reminders($son));
        $this->assertSame(0, $this->reminders($mom));

        $this->assertSame(1, $this->at('2026-11-20 02:45:00')['sent']);
        $this->assertSame(1, $this->reminders($mom));
        $this->assertSame(1, $this->reminders($son));
    }

    public function test_reminder_time_in_the_past_is_refused_and_not_sent_late(): void
    {
        $mom = User::factory()->create();

        // 10:00 วันนี้ ก่อน 1 วัน = เมื่อวาน → ให้เลือกใหม่ (ไม่สร้างกิจกรรมแบบเงียบ ๆ)
        $this->create($mom, ['reminder_offset' => 1440])->assertStatus(422)
            ->assertJsonPath('code', 'reminder_past')
            ->assertJsonPath('message', 'เวลาเตือนที่เลือกผ่านไปแล้ว กรุณาเลือกใหม่');
        $this->assertSame(0, Activity::count());

        $activity = Activity::find($this->create($mom)->json('activity.id'));

        $this->remind($mom, $activity, 1440)->assertStatus(422)->assertJsonPath('code', 'reminder_past');
        $this->remind($mom, $activity, 30)->assertOk();
    }

    public function test_activity_without_date_cannot_have_a_reminder(): void
    {
        $mom = User::factory()->create();

        $this->create($mom, ['starts_at' => null, 'timezone' => null, 'reminder_offset' => 0])
            ->assertStatus(422)->assertJsonPath('code', 'no_time');

        $activity = Activity::find($this->create($mom, ['starts_at' => null, 'timezone' => null])->json('activity.id'));

        $this->remind($mom, $activity, 15)->assertStatus(422)
            ->assertJsonPath('message', 'ตั้งวันและเวลาของกิจกรรมก่อน จึงจะตั้งเตือนได้');

        Sanctum::actingAs($mom);
        $this->getJson("/api/activities/{$activity->id}")->assertJsonPath('activity.can_remind', false)
            ->assertJsonPath('activity.needs_time_confirmation', false);
    }

    public function test_start_time_without_timezone_is_refused(): void
    {
        $this->create(User::factory()->create(), ['starts_at' => '2026-11-20T10:00:00'])->assertStatus(422)
            ->assertJsonValidationErrors('starts_at');

        $this->create(User::factory()->create(), ['timezone' => 'Mars/Base'])->assertStatus(422)
            ->assertJsonValidationErrors('timezone');
    }

    // =====================================================
    // ข้อมูลเก่า / แอปเวอร์ชันเก่า
    // =====================================================

    public function test_legacy_activity_is_not_shifted_and_needs_owner_confirmation(): void
    {
        $mom = User::factory()->create();

        // กิจกรรมก่อนมีระบบเตือน: นาฬิกาผู้ใช้ ไม่ทราบเขตเวลา
        $legacy = Activity::create([
            'user_id' => $mom->id,
            'visibility' => 'private',
            'title' => 'งานเก่า',
            'activity_date' => '2026-11-21 09:00:00',
        ]);

        Sanctum::actingAs($mom);
        $this->getJson('/api/activities')
            ->assertJsonPath('activities.0.activity_date', '2026-11-21T09:00:00')
            ->assertJsonPath('activities.0.starts_at', null)
            ->assertJsonPath('activities.0.can_remind', false)
            ->assertJsonPath('activities.0.needs_time_confirmation', true);

        $this->remind($mom, $legacy, 15)->assertStatus(422)->assertJsonPath('code', 'time_unconfirmed');

        $this->assertSame('2026-11-21 09:00:00', DB::table('activities')->where('id', $legacy->id)->value('activity_date'));
        $this->assertNull(DB::table('activities')->where('id', $legacy->id)->value('starts_at'));

        // เจ้าของยืนยันวันเวลา (แอปใหม่ส่งเวลาพร้อมเขตเวลา) → ตั้งเตือนได้
        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$legacy->id}", [
            'title' => 'งานเก่า',
            'starts_at' => '2026-11-21T09:00:00+07:00',
            'timezone' => 'Asia/Bangkok',
            'reminder_offset' => 15,
        ])->assertOk()
            ->assertJsonPath('activity.activity_date', '2026-11-21T09:00:00')
            ->assertJsonPath('activity.needs_time_confirmation', false)
            ->assertJsonPath('activity.my_reminder.remind_at', '2026-11-21T01:45:00+00:00');
    }

    public function test_old_app_edit_keeps_or_pauses_the_real_time(): void
    {
        $mom = User::factory()->create();
        $activity = Activity::find($this->create($mom, ['reminder_offset' => 30])->json('activity.id'));

        // แอปเก่าแก้ชื่อ ส่งวันเวลาเดิม (ไม่มี starts_at) → คงเวลาจริงและการเตือน
        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$activity->id}", [
            'title' => 'ชื่อใหม่',
            'activity_date' => '2026-11-20T10:00:00.000',
        ])->assertOk()->assertJsonPath('activity.my_reminder.status', 'pending');

        $this->assertNotNull($activity->fresh()->starts_at);

        // แอปเก่าเปลี่ยนวันเวลา → ไม่ทราบเขตเวลา → พักการเตือน รอเจ้าของยืนยันในแอปใหม่
        $this->patchJson("/api/activities/{$activity->id}", [
            'title' => 'ชื่อใหม่',
            'activity_date' => '2026-11-20T11:00:00.000',
        ])->assertOk()
            ->assertJsonPath('activity.activity_date', '2026-11-20T11:00:00')
            ->assertJsonPath('activity.needs_time_confirmation', true)
            ->assertJsonPath('activity.my_reminder.status', 'paused');

        $this->assertSame(0, $this->at('2026-11-20 03:30:00')['sent']);
    }

    // =====================================================
    // เปลี่ยนแปลง → ยกเลิก / คำนวณใหม่
    // =====================================================

    public function test_time_change_recomputes_every_reminder_and_old_schedule_is_not_sent(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $activity = Activity::find($this->create($mom, ['visibility' => 'family', 'reminder_offset' => 15])->json('activity.id'));
        $this->remind($son, $activity, 0)->assertOk();

        $oldVersion = ActivityReminder::where('user_id', $son->id)->value('version');

        // เลื่อนไป 12:00 เวลาไทย
        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$activity->id}", [
            'title' => 'ประชุมผู้ปกครอง',
            'starts_at' => '2026-11-20T05:00:00Z',
            'timezone' => 'Asia/Bangkok',
        ])->assertOk()->assertJsonPath('activity.activity_date', '2026-11-20T12:00:00');

        $this->assertSame('2026-11-20 04:45:00', ActivityReminder::where('user_id', $mom->id)->first()->remind_at->format('Y-m-d H:i:s'));
        $this->assertSame('2026-11-20 05:00:00', ActivityReminder::where('user_id', $son->id)->first()->remind_at->format('Y-m-d H:i:s'));

        // เวลาเดิม → ไม่มีอะไรส่ง / งานส่งที่ค้างของกำหนดเดิม (version เก่า) → ไม่ส่ง
        $this->assertSame(0, $this->at('2026-11-20 03:00:00')['sent']);
        $sendOne = new ReflectionMethod(ActivityReminder::class, 'sendOne');
        $this->assertNull($sendOne->invoke(null, ActivityReminder::where('user_id', $son->id)->value('id'), $oldVersion, Carbon::parse('2026-11-20 05:00:00', 'UTC')));

        $this->assertSame(2, $this->at('2026-11-20 05:00:00')['sent']);
        $this->assertSame(1, $this->reminders($mom));
        $this->assertSame(1, $this->reminders($son));
    }

    public function test_changing_or_turning_off_my_reminder_cancels_the_old_one(): void
    {
        $mom = User::factory()->create();
        $activity = Activity::find($this->create($mom, ['reminder_offset' => 30])->json('activity.id'));

        $this->remind($mom, $activity, 15)->assertOk();
        $this->assertSame(0, $this->at('2026-11-20 02:30:00')['sent']);

        $this->remind($mom, $activity, null)->assertOk()->assertJsonPath('reminder', null)->assertJsonPath('message', 'ปิดการเตือนแล้ว');
        $this->assertSame(0, $this->at('2026-11-20 02:45:00')['sent']);
        $this->assertSame(0, $this->reminders($mom));

        Sanctum::actingAs($mom);
        $this->getJson("/api/activities/{$activity->id}")->assertJsonPath('activity.my_reminder', null);
    }

    public function test_complete_pauses_and_uncomplete_only_reschedules_future_without_resending(): void
    {
        $mom = User::factory()->create();
        $activity = Activity::find($this->create($mom, ['reminder_offset' => 30])->json('activity.id'));

        // เสร็จก่อนถึงเวลาเตือน → ไม่ส่ง
        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$activity->id}/toggle")->assertOk()->assertJsonPath('activity.my_reminder.status', 'paused');
        $this->assertSame(0, $this->at('2026-11-20 02:30:00')['sent']);

        // กลับเป็นยังไม่เสร็จ ตอนเวลาเตือนยังไม่ถึง → ตั้งใหม่
        $this->patchJson("/api/activities/{$activity->id}/toggle")->assertOk()->assertJsonPath('activity.my_reminder.status', 'pending');
        $this->assertSame(1, $this->at('2026-11-20 02:30:00')['sent']);

        // ส่งแล้ว → เสร็จ → กลับเป็นยังไม่เสร็จ → ไม่ส่งรอบเดิมซ้ำ
        $this->travelTo(Carbon::parse('2026-11-20 02:40:00', 'UTC'));
        $this->patchJson("/api/activities/{$activity->id}/toggle")->assertOk();
        $this->patchJson("/api/activities/{$activity->id}/toggle")->assertOk()->assertJsonPath('activity.my_reminder.status', 'sent');
        $this->assertSame(0, $this->at('2026-11-20 02:41:00')['sent']);
        $this->assertSame(1, $this->reminders($mom));
    }

    public function test_uncomplete_after_reminder_time_does_not_send_late(): void
    {
        $mom = User::factory()->create();
        $activity = Activity::find($this->create($mom, ['reminder_offset' => 30])->json('activity.id'));

        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$activity->id}/toggle")->assertOk();

        $this->travelTo(Carbon::parse('2026-11-20 02:35:00', 'UTC'));
        $this->patchJson("/api/activities/{$activity->id}/toggle")->assertOk()->assertJsonPath('activity.my_reminder.status', 'expired');

        $this->assertSame(0, $this->at('2026-11-20 02:36:00')['sent']);
        $this->assertSame(0, $this->reminders($mom));
    }

    public function test_deleted_activity_cancels_reminders_and_detail_says_not_found(): void
    {
        $mom = User::factory()->create();
        $activity = Activity::find($this->create($mom, ['reminder_offset' => 30])->json('activity.id'));

        Sanctum::actingAs($mom);
        $this->deleteJson("/api/activities/{$activity->id}")->assertOk();

        $this->assertSame(0, ActivityReminder::count());
        $this->assertSame(0, $this->at('2026-11-20 02:30:00')['sent']);

        $this->getJson("/api/activities/{$activity->id}")->assertNotFound();
    }

    public function test_private_activity_is_owner_only_and_making_private_cancels_others(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $private = Activity::find($this->create($mom)->json('activity.id'));
        $this->remind($son, $private, 15)->assertNotFound();

        Sanctum::actingAs($son);
        $this->getJson("/api/activities/{$private->id}")->assertNotFound()
            ->assertJsonPath('message', 'ไม่พบกิจกรรมนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว');

        $shared = Activity::find($this->create($mom, ['visibility' => 'family', 'reminder_offset' => 30])->json('activity.id'));
        $this->remind($son, $shared, 15)->assertOk();

        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$shared->id}/visibility", ['visibility' => 'private'])->assertOk();

        $this->assertSame('cancelled', ActivityReminder::where('user_id', $son->id)->value('status'));
        $this->assertSame('pending', ActivityReminder::where('user_id', $mom->id)->value('status'));

        $this->at('2026-11-20 02:45:00');
        $this->assertSame(1, $this->reminders($mom));
        $this->assertSame(0, $this->reminders($son));
    }

    public function test_leaving_or_being_removed_from_group_cancels_reminders(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $daughter = User::factory()->create();
        $this->createFamily($mom, [$son, $daughter]);

        $shared = Activity::find($this->create($mom, ['visibility' => 'family'])->json('activity.id'));
        $this->remind($son, $shared, 15)->assertOk();
        $this->remind($daughter, $shared, 15)->assertOk();

        Sanctum::actingAs($son);
        $this->postJson('/api/families/leave')->assertOk();
        $this->assertSame('cancelled', ActivityReminder::where('user_id', $son->id)->value('status'));

        Sanctum::actingAs($mom);
        $this->deleteJson("/api/families/members/{$daughter->id}")->assertOk();
        $this->assertSame('cancelled', ActivityReminder::where('user_id', $daughter->id)->value('status'));

        $this->assertSame(0, $this->at('2026-11-20 02:45:00')['sent']);
    }

    public function test_permission_is_checked_again_right_before_sending(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $shared = Activity::find($this->create($mom, ['visibility' => 'family'])->json('activity.id'));
        $this->remind($son, $shared, 15)->assertOk();

        // หมดสิทธิ์ทางอื่น (ไม่ผ่านหน้าออกจากกลุ่ม)
        FamilyMember::where('user_id', $son->id)->delete();

        $this->assertSame(['sent' => 0, 'expired' => 0, 'cancelled' => 1], $this->at('2026-11-20 02:45:00'));
        $this->assertSame(0, $this->reminders($son));
    }

    // =====================================================
    // ส่ง: ซ้อน / ลองใหม่ / ระยะผ่อนผัน
    // =====================================================

    public function test_overlapping_runs_and_retry_never_duplicate_notifications(): void
    {
        $mom = User::factory()->create();
        $activity = Activity::find($this->create($mom, ['reminder_offset' => 15])->json('activity.id'));
        $reminder = ActivityReminder::first();

        // ล้มกลางทาง (สร้างรายการแจ้งเตือนไม่สำเร็จ) → ย้อนทั้งหมด ยังเป็น pending
        $fail = true;
        Event::listen('eloquent.creating: ' . AppNotification::class, function () use (&$fail) {
            if ($fail) {
                $fail = false;

                throw new RuntimeException('database hiccup');
            }
        });

        $this->assertSame(0, $this->at('2026-11-20 02:45:00')['sent']);
        $this->assertSame('pending', $reminder->fresh()->status);
        $this->assertSame(0, $this->reminders($mom));

        // รอบถัดไปลองใหม่ → ส่ง / สองรอบซ้อนกัน (เห็นรายการเดียวกัน) → ส่งครั้งเดียว
        $sendOne = new ReflectionMethod(ActivityReminder::class, 'sendOne');
        $now = Carbon::parse('2026-11-20 02:50:00', 'UTC');

        $this->assertSame('sent', $sendOne->invoke(null, $reminder->id, $reminder->version, $now));
        $this->assertNull($sendOne->invoke(null, $reminder->id, $reminder->version, $now));
        $this->assertSame(0, $this->at('2026-11-20 02:50:00')['sent']);

        $this->assertSame(1, $this->reminders($mom));
        $this->assertSame($activity->id, AppNotification::where('user_id', $mom->id)->first()->data['activity_id']);
    }

    public function test_downtime_does_not_flood_old_reminders(): void
    {
        $mom = User::factory()->create();
        $this->create($mom, ['reminder_offset' => 30])->assertCreated();
        $this->create($mom, ['reminder_offset' => 15])->assertCreated();

        config(['reminders.grace_minutes' => 15]);

        // Scheduler หยุดไป กลับมาตอน 03:01 → 02:30 ช้าเกิน 15 นาที (ไม่ส่ง) / 02:45 ช้า 16 นาที (ไม่ส่ง)
        $this->assertSame(['sent' => 0, 'expired' => 2, 'cancelled' => 0], $this->at('2026-11-20 03:01:00'));
        $this->assertSame(0, $this->reminders($mom));
    }

    public function test_late_run_within_grace_still_sends(): void
    {
        $mom = User::factory()->create();
        $this->create($mom, ['reminder_offset' => 30])->assertCreated();

        config(['reminders.grace_minutes' => 15]);

        $this->assertSame(1, $this->at('2026-11-20 02:44:00')['sent']);
    }

    // =====================================================
    // เขตเวลา / ข้ามวัน / DST
    // =====================================================

    public function test_cross_day_reminder_and_member_in_other_timezone_share_the_same_instant(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        // 00:15 วันที่ 21 เวลาไทย ก่อน 30 นาที = 23:45 วันที่ 20 เวลาไทย = 16:45 UTC
        $id = $this->create($mom, [
            'visibility' => 'family',
            'starts_at' => '2026-11-21T00:15:00+07:00',
            'reminder_offset' => 30,
        ])->assertCreated()
            ->assertJsonPath('activity.activity_date', '2026-11-21T00:15:00')
            ->assertJsonPath('activity.my_reminder.remind_at', '2026-11-20T16:45:00+00:00')
            ->json('activity.id');

        // ลูกอยู่โตเกียว: ได้ starts_at (UTC) เดียวกัน → แอปแสดง 02:15 วันที่ 21 ตามเครื่อง
        Sanctum::actingAs($son);
        $startsAt = Carbon::parse($this->getJson("/api/activities/{$id}")->json('activity.starts_at'));
        $this->assertSame('2026-11-21 02:15', $startsAt->setTimezone('Asia/Tokyo')->format('Y-m-d H:i'));

        $this->assertSame(0, $this->at('2026-11-20 16:44:00')['sent']);
        $this->assertSame(1, $this->at('2026-11-20 16:45:00')['sent']);
    }

    public function test_daylight_saving_change_uses_the_real_instant(): void
    {
        $this->travelTo(Carbon::parse('2026-10-30 12:00:00', 'UTC'));

        $mom = User::factory()->create();

        // นิวยอร์กเปลี่ยนเวลา 1 พ.ย. 2026 (EDT -4 → EST -5)
        // 09:00 EST วันที่ 1 = 14:00 UTC / ก่อน 1 วัน = 24 ชั่วโมงจริง = 14:00 UTC วันที่ 31 (10:00 EDT)
        $this->create($mom, [
            'starts_at' => '2026-11-01T09:00:00-05:00',
            'timezone' => 'America/New_York',
            'reminder_offset' => 1440,
        ])->assertCreated()
            ->assertJsonPath('activity.activity_date', '2026-11-01T09:00:00')
            ->assertJsonPath('activity.my_reminder.remind_at', '2026-10-31T14:00:00+00:00');

        $this->create($mom, [
            'starts_at' => '2026-11-01T09:00:00-05:00',
            'timezone' => 'America/New_York',
            'reminder_offset' => 15,
        ])->assertJsonPath('activity.my_reminder.remind_at', '2026-11-01T13:45:00+00:00');
    }

    // =====================================================
    // Push: หลายเครื่อง / Token ใช้ไม่ได้
    // =====================================================

    public function test_one_in_app_notification_pushed_to_every_device_and_invalid_token_removed(): void
    {
        config(['services.fcm.credentials' => base64_encode(json_encode([
            'type' => 'service_account',
            'project_id' => 'test-project',
            'client_email' => 'push@test-project.iam.gserviceaccount.com',
            'private_key' => 'unused-in-this-test',
        ]))]);
        Cache::put('fcm.access_token.test-project', 'cached-access-token', 600);

        Http::fake([self::FCM_URL => fn (HttpRequest $request) => $request['message']['fid'] === 'old-phone'
            ? Http::response(['error' => ['code' => 404, 'status' => 'NOT_FOUND', 'details' => [[
                '@type' => 'type.googleapis.com/google.firebase.fcm.v1.FcmError',
                'errorCode' => 'UNREGISTERED',
            ]]]], 404)
            : Http::response(['name' => 'projects/test-project/messages/1'])]);

        $mom = User::factory()->create();
        foreach (['phone', 'tablet', 'old-phone'] as $token) {
            DeviceToken::create(['user_id' => $mom->id, 'access_token_id' => $mom->createToken('app')->accessToken->id, 'token' => $token]);
        }

        $this->create($mom, ['reminder_offset' => 0])->assertCreated();
        $this->at('2026-11-20 03:00:00');

        $this->assertSame(1, $this->reminders($mom));
        Http::assertSentCount(3);
        Http::assertSent(fn (HttpRequest $request) => $request['message']['notification']['body'] === 'กิจกรรมของคุณถึงเวลาแล้ว · แตะเพื่อดูรายละเอียด'
            && $request['message']['data']['type'] === 'activity_reminder'
            && !str_contains(json_encode($request->data(), JSON_UNESCAPED_UNICODE), 'ประชุม'));
        $this->assertEqualsCanonicalizing(['phone', 'tablet'], DeviceToken::pluck('token')->all());
    }

    // =====================================================
    // คำสั่ง + ตารางเวลา
    // =====================================================

    public function test_command_sends_and_schedule_keeps_hourly_order_job(): void
    {
        $mom = User::factory()->create();
        $this->create($mom, ['reminder_offset' => 30])->assertCreated();

        $this->travelTo(Carbon::parse('2026-11-20 02:31:00', 'UTC'));
        $this->artisan('activities:send-reminders')->assertSuccessful();
        $this->assertSame(1, $this->reminders($mom));

        $events = collect(app(Schedule::class)->events());
        $find = fn (string $command) => $events->first(fn ($event) => str_contains($event->command ?? '', $command));

        $this->assertSame('*/5 * * * *', $find('activities:send-reminders')->expression);
        $this->assertSame('0 * * * *', $find('orders:expire')->expression);
    }
}
