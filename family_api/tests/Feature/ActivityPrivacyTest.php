<?php

namespace Tests\Feature;

use App\Models\Activity;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// กิจกรรม: สมาชิกเห็นแค่ชื่อและรูปของผู้สร้าง (ไม่เห็นอีเมล) และไม่เห็นกิจกรรมส่วนตัวของคนอื่น
class ActivityPrivacyTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    public function test_family_members_see_creator_name_and_photo_but_not_email(): void
    {
        $mom = User::factory()->create(['name' => 'Mom', 'email' => 'mom-private@example.com']);
        $son = User::factory()->create(['name' => 'Son']);

        $this->createFamily($mom, [$son]);

        Sanctum::actingAs($mom);

        $created = $this->postJson('/api/activities', ['title' => 'ไปตลาด', 'visibility' => 'family'])
            ->assertCreated();

        $this->assertStringNotContainsString('mom-private@example.com', $created->getContent());

        Sanctum::actingAs($son);

        $list = $this->getJson('/api/activities')->assertOk();

        $creator = $list->json('activities.0.user');

        $this->assertSame(['id', 'name', 'profile_image_url', 'profile_photo_url'], array_keys($creator));
        $this->assertSame('Mom', $creator['name']);
        $this->assertStringNotContainsString('mom-private@example.com', $list->getContent());

        // เจ้าของบัญชียังเห็นอีเมลตัวเองในหน้าข้อมูลบัญชี
        Sanctum::actingAs($mom);

        $this->getJson('/api/profile')->assertOk()->assertJsonPath('user.email', 'mom-private@example.com');
    }

    public function test_private_activities_stay_private(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $stranger = User::factory()->create();

        $family = $this->createFamily($mom, [$son]);

        $private = Activity::create([
            'user_id' => $mom->id,
            'family_id' => null,
            'title' => 'ซื้อของขวัญวันเกิดลูก',
            'visibility' => 'private',
        ]);

        $shared = Activity::create([
            'user_id' => $mom->id,
            'family_id' => $family->id,
            'title' => 'ไปตลาด',
            'visibility' => 'family',
        ]);

        // สมาชิกในกลุ่ม: เห็นแค่ที่แชร์ แก้ไข/ลบไม่ได้
        Sanctum::actingAs($son);

        $titles = collect($this->getJson('/api/activities')->json('activities'))->pluck('title');

        $this->assertTrue($titles->contains('ไปตลาด'));
        $this->assertFalse($titles->contains('ซื้อของขวัญวันเกิดลูก'));

        $this->patchJson("/api/activities/{$shared->id}/toggle")->assertForbidden();

        // กิจกรรมส่วนตัวของคนอื่น → ตอบเหมือนไม่มี (ไม่บอกว่ามีอยู่)
        $this->patchJson("/api/activities/{$private->id}/toggle")->assertNotFound();
        $this->patchJson("/api/activities/{$private->id}/visibility", ['visibility' => 'family'])->assertNotFound();
        $this->deleteJson("/api/activities/{$private->id}")->assertNotFound();

        // คนนอกกลุ่ม: ไม่เห็นทั้งสองอย่าง
        Sanctum::actingAs($stranger);

        $this->assertSame([], $this->getJson('/api/activities')->json('activities'));
        $this->deleteJson("/api/activities/{$shared->id}")->assertNotFound();

        $this->assertDatabaseHas('activities', ['id' => $private->id, 'is_completed' => false]);
        $this->assertDatabaseHas('activities', ['id' => $shared->id]);
    }
}
