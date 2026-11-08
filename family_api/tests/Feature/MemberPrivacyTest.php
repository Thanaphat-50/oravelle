<?php

namespace Tests\Feature;

use App\Models\User;
use App\Models\UserLocation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// สมาชิกในกลุ่มเห็นกันแค่ id ชื่อ รูป — ไม่เห็นอีเมลของกันและกัน (หน้ากลุ่ม / แผนที่)
class MemberPrivacyTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    public function test_group_page_does_not_send_member_emails(): void
    {
        $mom = User::factory()->create(['name' => 'Mom', 'email' => 'mom-secret@example.com']);
        $son = User::factory()->create(['name' => 'Son', 'email' => 'son-secret@example.com']);

        $this->createFamily($mom, [$son]);

        Sanctum::actingAs($son);

        $response = $this->getJson('/api/families/current')
            ->assertOk()
            ->assertJsonPath('has_family', true)
            ->assertJsonPath('family.owner.name', 'Mom');

        $this->assertStringNotContainsString('mom-secret@example.com', $response->getContent());
        $this->assertStringNotContainsString('son-secret@example.com', $response->getContent());

        $member = collect($response->json('family.members'))->firstWhere('name', 'Mom');

        $this->assertSame(['id', 'name', 'profile_image_url', 'profile_photo_url', 'pivot'], array_keys($member));
        $this->assertArrayHasKey('role', $member['pivot']);
    }

    public function test_map_does_not_send_member_emails(): void
    {
        $mom = User::factory()->create(['name' => 'Mom', 'email' => 'mom-secret@example.com']);
        $son = User::factory()->create(['name' => 'Son']);

        $this->createFamily($mom, [$son]);

        UserLocation::create([
            'user_id' => $mom->id,
            'latitude' => 13.75,
            'longitude' => 100.5,
            'last_seen_at' => now(),
        ]);

        Sanctum::actingAs($son);

        $response = $this->getJson('/api/family/locations')->assertOk();

        $this->assertSame('Mom', $response->json('locations.0.user.name'));
        $this->assertStringNotContainsString('mom-secret@example.com', $response->getContent());
    }
}
