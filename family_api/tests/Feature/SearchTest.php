<?php

namespace Tests\Feature;

use App\Models\Comment;
use App\Models\FamilyMember;
use App\Models\Post;
use App\Models\PostReport;
use App\Models\User;
use App\Models\UserBlock;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// ค้นหาโพสต์และผู้ใช้: ค้นทั้งหมดบนเซิร์ฟเวอร์ตามสิทธิ์ / กลุ่มแยกกัน / บล็อก / ซ่อน / อักขระพิเศษ / แบ่งหน้า
// ฐานข้อมูลทดสอบแยก (RefreshDatabase)
class SearchTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private function communityPost(User $user, string $content, array $fields = []): Post
    {
        // forceCreate: ตั้ง hidden_at ได้ (ไม่อยู่ใน fillable)
        return Post::forceCreate([
            'user_id' => $user->id,
            // posts.family_id ต้องมีค่า (ผู้โพสต์ในการทดสอบมีกลุ่มของตัวเอง)
            'family_id' => FamilyMember::where('user_id', $user->id)->value('family_id') ?? $this->createFamily($user)->id,
            'visibility' => 'community',
            'content' => $content,
            ...$fields,
        ]);
    }

    private function familyPost(User $user, string $content): Post
    {
        return $this->communityPost($user, $content, ['visibility' => 'family']);
    }

    private function searchPosts(User $viewer, string $q, array $params = [])
    {
        Sanctum::actingAs($viewer);

        return $this->getJson('/api/search/posts?' . http_build_query(['q' => $q, ...$params]));
    }

    private function postContents(User $viewer, string $q, array $params = []): array
    {
        return collect($this->searchPosts($viewer, $q, $params)->assertOk()->json('posts'))->pluck('content')->all();
    }

    private function userNames(User $viewer, string $q): array
    {
        Sanctum::actingAs($viewer);

        return collect($this->getJson('/api/search/users?' . http_build_query(['q' => $q]))->assertOk()->json('users'))
            ->pluck('name')->all();
    }

    // =====================================================
    // คำค้น
    // =====================================================

    public function test_thai_english_and_spaced_queries_match_community_posts(): void
    {
        $author = User::factory()->create();
        $viewer = User::factory()->create();

        $this->communityPost($author, 'วันนี้ไปตลาดน้ำอัมพวา อากาศดีมาก');
        $this->communityPost($author, 'Garden Day with butterflies');
        $this->communityPost($author, 'ทำแกงเขียวหวาน สูตรคุณยาย');
        $this->communityPost($author, 'ไม่เกี่ยวข้อง');

        $this->assertSame(['วันนี้ไปตลาดน้ำอัมพวา อากาศดีมาก'], $this->postContents($viewer, 'ตลาดน้ำ'));
        $this->assertSame(['Garden Day with butterflies'], $this->postContents($viewer, 'garden'));
        $this->assertSame(['Garden Day with butterflies'], $this->postContents($viewer, 'BUTTERFLIES'));

        // หลายคำ (คั่นด้วยช่องว่าง) → ต้องมีทุกคำ ลำดับไหนก็ได้ / ช่องว่างหัวท้ายและซ้ำถูกตัด
        $this->assertSame(['ทำแกงเขียวหวาน สูตรคุณยาย'], $this->postContents($viewer, '  คุณยาย   แกงเขียว  '));
        $this->assertSame([], $this->postContents($viewer, 'แกงเขียว garden'));
    }

    public function test_percent_and_underscore_are_literal_not_wildcards(): void
    {
        $author = User::factory()->create();
        $viewer = User::factory()->create();

        $this->communityPost($author, 'ลดราคา 50% ทั้งร้าน');
        $this->communityPost($author, 'ลดราคา 500 บาท');
        $this->communityPost($author, 'file_name.txt');
        $this->communityPost($author, 'filename.txt');
        $this->communityPost($author, 'สุดคุ้ม! ห้ามพลาด');

        $this->assertSame(['ลดราคา 50% ทั้งร้าน'], $this->postContents($viewer, '50%'));
        $this->assertSame(['file_name.txt'], $this->postContents($viewer, 'file_name'));
        $this->assertSame(['สุดคุ้ม! ห้ามพลาด'], $this->postContents($viewer, 'คุ้ม!'));
        $this->assertSame(['ลดราคา 50% ทั้งร้าน'], $this->postContents($viewer, '%'));
        $this->assertSame(['file_name.txt'], $this->postContents($viewer, '_'));
        $this->assertSame([], $this->postContents($viewer, "' OR 1=1 --"));
    }

    public function test_query_is_required_and_limited_to_max_length(): void
    {
        Sanctum::actingAs(User::factory()->create());

        $this->getJson('/api/search/posts?q=')->assertStatus(422)->assertJsonPath('message', 'กรุณาพิมพ์คำค้นหา');
        $this->getJson('/api/search/posts?q=' . urlencode('   '))->assertStatus(422);
        $this->getJson('/api/search/users?q=' . str_repeat('ก', 101))->assertStatus(422)
            ->assertJsonPath('message', 'คำค้นหายาวได้ไม่เกิน 100 ตัวอักษร');
        $this->getJson('/api/search/posts?q=' . urlencode(str_repeat('ก', 100)))->assertOk();
    }

    // =====================================================
    // สิทธิ์: ชุมชน / ในกลุ่ม
    // =====================================================

    public function test_community_search_excludes_family_posts_hidden_and_reported(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $viewer = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $this->communityPost($mom, 'ทริปทะเล ชุมชน');
        $this->familyPost($mom, 'ทริปทะเล ในกลุ่ม');
        $this->communityPost($mom, 'ทริปทะเล ถูกซ่อน', ['hidden_at' => now()]);
        $reported = $this->communityPost($son, 'ทริปทะเล ที่รายงานแล้ว');
        PostReport::create(['post_id' => $reported->id, 'user_id' => $viewer->id, 'reason' => 'spam']);

        $this->assertSame(['ทริปทะเล ชุมชน'], $this->postContents($viewer, 'ทริปทะเล'));

        // คนในกลุ่มค้นในชุมชนก็ไม่เห็นโพสต์กลุ่มปนมา / คนที่ไม่ได้รายงานยังเห็น
        $this->assertEqualsCanonicalizing(['ทริปทะเล ชุมชน', 'ทริปทะเล ที่รายงานแล้ว'], $this->postContents($son, 'ทริปทะเล'));
    }

    public function test_family_search_only_covers_current_group_from_the_server(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $other = User::factory()->create();
        $mine = $this->createFamily($mom, [$son]);
        $theirs = $this->createFamily($other);

        $this->familyPost($mom, 'นัดกินข้าว กลุ่มเรา');
        $this->communityPost($mom, 'นัดกินข้าว ชุมชน');
        $this->familyPost($other, 'นัดกินข้าว กลุ่มอื่น');

        $this->assertSame(['นัดกินข้าว กลุ่มเรา'], $this->postContents($son, 'นัดกินข้าว', ['scope' => 'family']));
        $this->assertSame(['นัดกินข้าว กลุ่มอื่น'], $this->postContents($other, 'นัดกินข้าว', ['scope' => 'family']));

        // ส่ง family_id ของกลุ่มอื่นมา → ไม่สนใจ ใช้กลุ่มของผู้ใช้ที่เข้าสู่ระบบ
        $this->assertSame(['นัดกินข้าว กลุ่มเรา'], $this->postContents($son, 'นัดกินข้าว', ['scope' => 'family', 'family_id' => $theirs->id]));
        $this->assertNotSame($mine->id, $theirs->id);
    }

    public function test_user_without_group_or_after_leaving_cannot_search_or_open_group_posts(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $post = $this->familyPost($mom, 'รูปงานวันเกิด');

        $this->assertSame(['รูปงานวันเกิด'], $this->postContents($son, 'วันเกิด', ['scope' => 'family']));

        Sanctum::actingAs($son);
        $this->postJson('/api/families/leave')->assertOk();

        $this->searchPosts($son, 'วันเกิด', ['scope' => 'family'])->assertForbidden()
            ->assertJsonPath('code', 'no_family')
            ->assertJsonMissingPath('posts');

        // เปิดผลเดิม → ตรวจสิทธิ์ใหม่
        $this->getJson("/api/posts/{$post->id}")->assertForbidden();
    }

    public function test_post_hidden_or_deleted_after_search_cannot_be_opened(): void
    {
        $author = User::factory()->create();
        $viewer = User::factory()->create();

        $hidden = $this->communityPost($author, 'ขายของมือสอง');
        $deleted = $this->communityPost($author, 'ขายของมือสอง ด่วน');

        $this->assertCount(2, $this->postContents($viewer, 'มือสอง'));

        $hidden->forceFill(['hidden_at' => now()])->save();
        $deleted->delete();

        Sanctum::actingAs($viewer);
        $this->getJson("/api/posts/{$hidden->id}")->assertNotFound();
        $this->getJson("/api/posts/{$deleted->id}")->assertNotFound();
        $this->assertSame([], $this->postContents($viewer, 'มือสอง'));
    }

    // =====================================================
    // บล็อก (กติกาเดิม)
    // =====================================================

    public function test_blocking_follows_existing_rules(): void
    {
        $alice = User::factory()->create(['name' => 'Alice Searchable']);
        $bob = User::factory()->create(['name' => 'Bob Searchable']);

        $this->communityPost($alice, 'alice กาแฟดริป');
        $this->communityPost($bob, 'bob กาแฟดริป');

        UserBlock::create(['user_id' => $alice->id, 'blocked_user_id' => $bob->id]);

        // โพสต์: เหมือนฟีดชุมชน → ไม่เห็นโพสต์ของคนที่เราบล็อก
        $this->assertSame(['alice กาแฟดริป'], $this->postContents($alice, 'กาแฟดริป'));

        // ผู้ใช้: เหมือนรายการแนะนำ/ผู้ติดตาม → บล็อกกันทางไหนก็ไม่เห็นกัน
        $this->assertSame(['Alice Searchable'], $this->userNames($alice, 'Searchable'));
        $this->assertSame(['Bob Searchable'], $this->userNames($bob, 'Searchable'));
    }

    // =====================================================
    // ผู้ใช้
    // =====================================================

    public function test_user_search_by_display_name_only_without_private_data(): void
    {
        $viewer = User::factory()->create();
        $somchai = User::factory()->create(['name' => 'สมชาย ใจดี', 'email' => 'secret-somchai@example.com']);
        $this->communityPost($somchai, 'สวัสดีชุมชน');

        // ไม่ค้นจากอีเมล
        $this->assertSame([], $this->userNames($viewer, 'secret-somchai'));
        $this->assertSame([], $this->userNames($viewer, 'example.com'));

        Sanctum::actingAs($viewer);
        $response = $this->getJson('/api/search/users?q=' . urlencode('ใจดี'))->assertOk();

        $this->assertSame(['id', 'name', 'profile_image_url', 'is_me', 'is_family'], array_keys($response->json('users.0')));
        $this->assertStringNotContainsString('secret-somchai', $response->getContent());
        $this->assertStringNotContainsString('email', $response->getContent());
    }

    public function test_only_people_with_a_community_profile_or_same_group_are_found(): void
    {
        $viewer = User::factory()->create(['name' => 'ผู้ค้น ทดสอบ']);
        $poster = User::factory()->create(['name' => 'คุณโพสต์ ทดสอบ']);
        $commenter = User::factory()->create(['name' => 'คุณคอมเมนต์ ทดสอบ']);
        $quiet = User::factory()->create(['name' => 'คุณเงียบ ทดสอบ']);
        $relative = User::factory()->create(['name' => 'ญาติ ทดสอบ']);
        $hiddenOnly = User::factory()->create(['name' => 'ถูกซ่อน ทดสอบ']);

        $this->createFamily($viewer, [$relative]);
        $this->createFamily($quiet);

        $post = $this->communityPost($poster, 'โพสต์ชุมชน');
        Comment::create(['post_id' => $post->id, 'user_id' => $commenter->id, 'content' => 'เห็นด้วย']);
        $this->familyPost($quiet, 'โพสต์ในกลุ่มเท่านั้น');
        $this->communityPost($hiddenOnly, 'ถูกซ่อน', ['hidden_at' => now()]);

        $names = $this->userNames($viewer, 'ทดสอบ');

        $this->assertEqualsCanonicalizing(['ผู้ค้น ทดสอบ', 'คุณโพสต์ ทดสอบ', 'คุณคอมเมนต์ ทดสอบ', 'ญาติ ทดสอบ'], $names);

        // ทุกคนที่ค้นเจอเปิดโปรไฟล์ได้จริง (กติกาเดียวกัน)
        foreach ([$poster, $commenter, $relative] as $user) {
            $this->getJson("/api/users/{$user->id}/profile")->assertOk();
        }
        $this->getJson("/api/users/{$quiet->id}/profile")->assertNotFound();
    }

    public function test_users_are_sorted_by_name_then_id_and_paginated_without_repeats(): void
    {
        $viewer = User::factory()->create();

        foreach (range(1, 23) as $i) {
            $user = User::factory()->create(['name' => 'สมาชิก ' . ($i % 2 === 0 ? 'ข' : 'ก')]);
            $this->communityPost($user, 'hello');
        }

        Sanctum::actingAs($viewer);
        $first = $this->getJson('/api/search/users?q=' . urlencode('สมาชิก'))->assertOk();
        $this->assertTrue($first->json('has_more'));
        $this->assertCount(20, $first->json('users'));

        $second = $this->getJson('/api/search/users?' . http_build_query(['q' => 'สมาชิก', 'cursor' => $first->json('next_cursor')]))->assertOk();
        $this->assertFalse($second->json('has_more'));

        $all = collect([...$first->json('users'), ...$second->json('users')]);
        $this->assertCount(23, $all->pluck('id')->unique());

        $expected = $all->sortBy([['name', 'asc'], ['id', 'asc']])->pluck('id')->values()->all();
        $this->assertSame($expected, $all->pluck('id')->all());
    }

    // =====================================================
    // แบ่งหน้า / ลำดับ
    // =====================================================

    public function test_posts_newest_first_with_cursor_and_no_repeats_when_new_posts_arrive(): void
    {
        $author = User::factory()->create();
        $viewer = User::factory()->create();

        // เวลาเท่ากันทั้งหมด → ใช้ id ตัดสิน
        $this->travelTo(Carbon::parse('2026-11-10 10:00:00'));
        foreach (range(1, 25) as $i) {
            $this->communityPost($author, "เมนูอาหาร #{$i}");
        }

        $first = $this->searchPosts($viewer, 'เมนูอาหาร')->assertOk();
        $this->assertCount(20, $first->json('posts'));
        $this->assertTrue($first->json('has_more'));
        $this->assertSame('เมนูอาหาร #25', $first->json('posts.0.content'));
        $this->assertArrayNotHasKey('total', $first->json());

        // มีโพสต์ใหม่ระหว่างเลื่อน → หน้าถัดไปไม่ซ้ำและไม่ข้าม
        $this->travelTo(Carbon::parse('2026-11-10 10:05:00'));
        $this->communityPost($author, 'เมนูอาหาร ใหม่');

        $second = $this->searchPosts($viewer, 'เมนูอาหาร', ['cursor' => $first->json('next_cursor')])->assertOk();
        $this->assertFalse($second->json('has_more'));

        $ids = collect([...$first->json('posts'), ...$second->json('posts')])->pluck('id');
        $this->assertCount(25, $ids->unique());
        $this->assertSame('เมนูอาหาร #1', $second->json('posts.4.content'));
    }

    public function test_search_payload_matches_feed_and_avoids_per_row_queries(): void
    {
        $author = User::factory()->create();
        $viewer = User::factory()->create();

        foreach (range(1, 15) as $i) {
            $post = $this->communityPost($author, "ปลูกผัก {$i}");
            Comment::create(['post_id' => $post->id, 'user_id' => $author->id, 'content' => 'ดีมาก']);
        }

        Sanctum::actingAs($viewer);

        DB::enableQueryLog();
        $response = $this->getJson('/api/search/posts?q=' . urlencode('ปลูกผัก'))->assertOk();
        $queries = count(DB::getQueryLog());
        DB::disableQueryLog();

        // จำนวนคำสั่งไม่เพิ่มตามจำนวนโพสต์ (โหลดความสัมพันธ์รวดเดียว)
        $this->assertLessThan(15, $queries);

        $response->assertJsonPath('posts.0.user.name', $author->name)
            ->assertJsonPath('posts.0.is_mine', false)
            ->assertJsonPath('posts.0.likes_count', 0)
            ->assertJsonPath('posts.0.liked_by_me', false)
            ->assertJsonCount(1, 'posts.0.comments');
        $this->assertArrayNotHasKey('email', $response->json('posts.0.user'));
    }

    public function test_search_is_rate_limited_and_requires_login(): void
    {
        $this->getJson('/api/search/posts?q=abc')->assertUnauthorized();

        Sanctum::actingAs(User::factory()->create());

        foreach (range(1, 60) as $i) {
            $this->getJson('/api/search/users?q=a' . $i)->assertOk();
        }

        $this->getJson('/api/search/posts?q=abc')->assertStatus(429);
    }
}
