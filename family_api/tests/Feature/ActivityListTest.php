<?php

namespace Tests\Feature;

use App\Models\Activity;
use App\Models\FamilyMember;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// กิจกรรม: เวลาตามนาฬิกาผู้ใช้ / ตัวกรองและแบ่งหน้าบนเซิร์ฟเวอร์ / แก้ไขโดยเจ้าของ
class ActivityListTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private const NOW = '2026-11-09T12:00:00';

    private function activity(User $user, array $fields = []): Activity
    {
        return Activity::create([
            'user_id' => $user->id,
            'family_id' => null,
            'visibility' => 'private',
            'title' => 'งาน',
            ...$fields,
        ]);
    }

    public function test_activity_time_comes_back_as_the_user_picked_it(): void
    {
        Sanctum::actingAs(User::factory()->create());

        // แอปส่งเวลาตามนาฬิกาเครื่อง (ไม่มีเขตเวลา) → ได้กลับมาเหมือนเดิม ไม่มี Z (แอปไม่บวกเวลาเพิ่ม)
        $this->postJson('/api/activities', [
            'title' => 'ไปตลาด',
            'activity_date' => '2026-11-09T14:30:00.000',
            'visibility' => 'private',
        ])->assertCreated()->assertJsonPath('activity.activity_date', '2026-11-09T14:30:00');

        $this->getJson('/api/activities')->assertJsonPath('activities.0.activity_date', '2026-11-09T14:30:00');
    }

    public function test_filters_and_counts_cover_all_activities_by_the_users_clock(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);

        $this->activity($mom, ['title' => 'เช้านี้', 'activity_date' => '2026-11-09 09:00:00']);
        $this->activity($mom, ['title' => 'เย็นนี้', 'activity_date' => '2026-11-09 18:00:00']);
        $this->activity($mom, ['title' => 'เมื่อวาน', 'activity_date' => '2026-11-08 10:00:00']);
        $this->activity($mom, ['title' => 'เสร็จแล้ว', 'activity_date' => '2026-11-08 08:00:00', 'is_completed' => true]);
        $this->activity($mom, ['title' => 'พรุ่งนี้', 'activity_date' => '2026-11-10 08:00:00']);
        $this->activity($mom, ['title' => 'ไม่กำหนดวัน']);
        $this->activity($son, ['title' => 'ของลูก (กลุ่ม)', 'visibility' => 'family', 'family_id' => $family->id, 'activity_date' => '2026-11-07 10:00:00']);
        $this->activity($son, ['title' => 'ของลูก (ส่วนตัว)', 'activity_date' => '2026-11-09 10:00:00']);

        Sanctum::actingAs($mom);

        $titles = fn (string $filter) => collect(
            $this->getJson('/api/activities?filter=' . $filter . '&now=' . self::NOW)->assertOk()->json('activities')
        )->pluck('title')->all();

        // "เช้านี้" เลยเวลาแล้วแต่ยังไม่เสร็จ → อยู่ทั้งวันนี้และเกินกำหนด
        $this->assertEqualsCanonicalizing(['เช้านี้', 'เย็นนี้'], $titles('today'));
        $this->assertEqualsCanonicalizing(['เช้านี้', 'เมื่อวาน', 'ของลูก (กลุ่ม)'], $titles('overdue'));
        $this->assertEqualsCanonicalizing(['เสร็จแล้ว'], $titles('completed'));
        $this->assertEqualsCanonicalizing(['ของลูก (กลุ่ม)'], $titles('family'));
        $this->assertCount(6, $titles('mine'));
        $this->assertCount(7, $titles('all'));
        $this->assertNotContains('ของลูก (ส่วนตัว)', $titles('all'));

        $this->getJson('/api/activities?filter=today&now=' . self::NOW)
            ->assertJsonPath('counts.all', 7)
            ->assertJsonPath('counts.today', 2)
            ->assertJsonPath('counts.overdue', 3)
            ->assertJsonPath('counts.completed', 1)
            ->assertJsonPath('counts.family', 1)
            ->assertJsonPath('counts.mine', 6);

        // อีกเขตเวลา: นาฬิกาเครื่องเป็นวันที่ 10 แล้ว → "พรุ่งนี้" กลายเป็นวันนี้
        $this->assertEqualsCanonicalizing(['พรุ่งนี้'], collect(
            $this->getJson('/api/activities?filter=today&now=2026-11-10T07:00:00')->json('activities')
        )->pluck('title')->all());

        $this->getJson('/api/activities?filter=soon')->assertUnprocessable();
    }

    public function test_pages_of_twenty_and_old_apps_still_get_everything(): void
    {
        $user = User::factory()->create();

        for ($i = 1; $i <= 25; $i++) {
            $this->activity($user, ['title' => "งาน {$i}", 'activity_date' => sprintf('2026-12-%02d 09:00:00', $i)]);
        }

        Sanctum::actingAs($user);

        $first = $this->getJson('/api/activities?page=1')->assertOk()
            ->assertJsonPath('has_more', true)
            ->assertJsonPath('counts.all', 25);

        $this->assertCount(20, $first->json('activities'));
        $this->assertSame('งาน 1', $first->json('activities.0.title'));

        $second = $this->getJson('/api/activities?page=2')->assertJsonPath('has_more', false);

        $this->assertCount(5, $second->json('activities'));
        $this->assertSame('งาน 21', $second->json('activities.0.title'));

        // แอปเวอร์ชันเก่า (ไม่ส่ง page)
        $this->assertCount(25, $this->getJson('/api/activities')->json('activities'));
    }

    public function test_only_the_owner_edits_title_details_and_time(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $stranger = User::factory()->create();
        $family = $this->createFamily($mom, [$son]);

        $shared = $this->activity($mom, ['title' => 'ไปตลาด', 'visibility' => 'family', 'family_id' => $family->id]);
        $private = $this->activity($mom, ['title' => 'ของขวัญลับ']);

        Sanctum::actingAs($mom);

        $this->patchJson("/api/activities/{$shared->id}", [
            'title' => '  ไปตลาดนัด  ',
            'description' => 'ซื้อผัก',
            'activity_date' => '2026-11-10T07:30:00.000',
        ])
            ->assertOk()
            ->assertJsonPath('activity.title', 'ไปตลาดนัด')
            ->assertJsonPath('activity.description', 'ซื้อผัก')
            ->assertJsonPath('activity.activity_date', '2026-11-10T07:30:00')
            ->assertJsonPath('activity.can_manage', true);

        $this->patchJson("/api/activities/{$shared->id}", ['title' => ''])
            ->assertUnprocessable()
            ->assertJsonPath('errors.title.0', 'กรุณาใส่ชื่อกิจกรรม');

        // ล้างวันเวลาได้
        $this->patchJson("/api/activities/{$private->id}", ['title' => 'ของขวัญลับ', 'activity_date' => null])
            ->assertOk()
            ->assertJsonPath('activity.activity_date', null);

        // สมาชิกคนอื่น: เห็นแต่แก้ไม่ได้ / กิจกรรมส่วนตัวของคนอื่น: เหมือนไม่มี
        Sanctum::actingAs($son);
        $this->patchJson("/api/activities/{$shared->id}", ['title' => 'แก้'])->assertForbidden();
        $this->patchJson("/api/activities/{$private->id}", ['title' => 'แก้'])->assertNotFound();

        Sanctum::actingAs($stranger);
        $this->patchJson("/api/activities/{$shared->id}", ['title' => 'แก้'])->assertNotFound();

        // เจ้าของออกจากกลุ่มแล้ว → แก้กิจกรรมที่แชร์ในกลุ่มเดิมไม่ได้
        FamilyMember::where('user_id', $mom->id)->delete();

        Sanctum::actingAs($mom);
        $this->patchJson("/api/activities/{$shared->id}", ['title' => 'แก้'])->assertForbidden();

        $this->assertSame('ไปตลาดนัด', $shared->refresh()->title);
    }
}
