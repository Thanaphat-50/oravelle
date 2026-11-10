<?php

namespace Tests\Feature;

use App\Models\FamilyMember;
use App\Models\Post;
use App\Models\SavedPost;
use App\Models\User;
use App\Models\UserBlock;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// บันทึกโพสต์: ส่งซ้ำได้ไม่ซ้ำ / ส่วนตัว / สิทธิ์ตอนบันทึก-แสดงรายการ-เปิดโพสต์ / กรองก่อนแบ่งหน้า
// / ลบโพสต์-ลบบัญชี — ฐานข้อมูลทดสอบแยก (RefreshDatabase)
class SavedPostTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private function makePost(User $user, string $content, array $fields = []): Post
    {
        return Post::forceCreate([
            'user_id' => $user->id,
            'family_id' => FamilyMember::where('user_id', $user->id)->value('family_id') ?? $this->createFamily($user)->id,
            'visibility' => 'community',
            'content' => $content,
            ...$fields,
        ]);
    }

    private function save(User $user, Post $post)
    {
        Sanctum::actingAs($user);

        return $this->putJson("/api/posts/{$post->id}/save");
    }

    private function savedContents(User $user): array
    {
        Sanctum::actingAs($user);

        return collect($this->getJson('/api/saved-posts')->assertOk()->json('posts'))->pluck('content')->all();
    }

    public function test_save_and_unsave_are_idempotent_and_show_in_feed_flags(): void
    {
        $author = User::factory()->create();
        $reader = User::factory()->create();
        $post = $this->makePost($author, 'สูตรขนม');

        $this->save($reader, $post)->assertOk()->assertJsonPath('saved', true);
        $this->save($reader, $post)->assertOk()->assertJsonPath('saved', true);
        $this->assertSame(1, SavedPost::count());

        $this->getJson("/api/posts/{$post->id}")->assertJsonPath('post.saved_by_me', true);
        $this->getJson('/api/search/posts?q=' . urlencode('ขนม'))->assertJsonPath('posts.0.saved_by_me', true);

        $this->deleteJson("/api/posts/{$post->id}/save")->assertOk()->assertJsonPath('saved', false);
        $this->deleteJson("/api/posts/{$post->id}/save")->assertOk()->assertJsonPath('saved', false);
        $this->assertSame(0, SavedPost::count());
        $this->getJson("/api/posts/{$post->id}")->assertJsonPath('post.saved_by_me', false);
    }

    public function test_saved_list_is_private_and_not_visible_to_the_author(): void
    {
        $author = User::factory()->create();
        $reader = User::factory()->create();
        $post = $this->makePost($author, 'ของลับ');

        $this->save($reader, $post)->assertOk();

        $this->assertSame(['ของลับ'], $this->savedContents($reader));
        $this->assertSame([], $this->savedContents($author));

        // เจ้าของโพสต์ไม่เห็นว่าใครบันทึก
        Sanctum::actingAs($author);
        $response = $this->getJson("/api/posts/{$post->id}")->assertOk()->assertJsonPath('post.saved_by_me', false);
        $this->assertStringNotContainsString('"saves"', $response->getContent());
    }

    public function test_can_save_community_and_own_group_posts_only(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $stranger = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $group = $this->makePost($mom, 'ในกลุ่ม', ['visibility' => 'family']);
        $hidden = $this->makePost($mom, 'ถูกซ่อน', ['hidden_at' => now()]);

        $this->save($son, $group)->assertOk();
        $this->save($stranger, $group)->assertNotFound();
        $this->save($stranger, $hidden)->assertNotFound();
        $this->assertSame(1, SavedPost::count());
    }

    public function test_lost_access_is_filtered_before_pagination(): void
    {
        $mom = User::factory()->create();
        $son = User::factory()->create();
        $author = User::factory()->create();
        $this->createFamily($mom, [$son]);

        $posts = collect(range(1, 25))->map(fn ($i) => $this->makePost($author, "โพสต์ {$i}"));
        $group = $this->makePost($mom, 'ในกลุ่ม', ['visibility' => 'family']);

        foreach ($posts as $post) {
            $this->save($son, $post)->assertOk();
        }
        $this->save($son, $group)->assertOk();

        // หมดสิทธิ์หลายแบบ: ซ่อน / ลบ / บล็อกผู้เขียน (บางโพสต์) / ออกจากกลุ่ม
        $posts[24]->forceFill(['hidden_at' => now()])->save();
        $posts[23]->delete();
        $blocked = $this->makePost($mom, 'ของแม่');
        $this->save($son, $blocked)->assertOk();
        UserBlock::create(['user_id' => $son->id, 'blocked_user_id' => $mom->id]);

        Sanctum::actingAs($son);
        $this->postJson('/api/families/leave')->assertOk();

        $first = $this->getJson('/api/saved-posts')->assertOk();
        $this->assertCount(20, $first->json('posts'));
        $this->assertTrue($first->json('has_more'));
        $this->assertSame('โพสต์ 23', $first->json('posts.0.content'));

        $second = $this->getJson('/api/saved-posts?cursor=' . $first->json('next_cursor'))->assertOk();
        $this->assertCount(3, $second->json('posts'));
        $this->assertFalse($second->json('has_more'));

        $contents = collect([...$first->json('posts'), ...$second->json('posts')])->pluck('content');
        $this->assertCount(23, $contents->unique());
        $this->assertNotContains('ในกลุ่ม', $contents);
        $this->assertNotContains('ของแม่', $contents);
        $this->assertNotContains('โพสต์ 25', $contents);

        // เปิดโพสต์ที่หมดสิทธิ์ก็ไม่ได้
        $this->getJson("/api/posts/{$group->id}")->assertForbidden();
        $this->getJson("/api/posts/{$posts[24]->id}")->assertNotFound();
    }

    public function test_shared_original_without_access_is_not_leaked(): void
    {
        $author = User::factory()->create();
        $sharer = User::factory()->create();
        $reader = User::factory()->create();

        $original = $this->makePost($author, 'ต้นฉบับ');
        $share = $this->makePost($sharer, 'แชร์ต่อ', ['shared_post_id' => $original->id]);

        $this->save($reader, $share)->assertOk();

        $original->forceFill(['hidden_at' => now()])->save();

        Sanctum::actingAs($reader);
        $this->getJson('/api/saved-posts')->assertOk()
            ->assertJsonPath('posts.0.content', 'แชร์ต่อ')
            ->assertJsonPath('posts.0.shared_post', null)
            ->assertJsonPath('posts.0.shared_post_unavailable', true);
    }

    public function test_latest_saved_first_and_resave_moves_to_top(): void
    {
        $author = User::factory()->create();
        $reader = User::factory()->create();

        $a = $this->makePost($author, 'A');
        $b = $this->makePost($author, 'B');

        $this->save($reader, $a);
        $this->save($reader, $b);
        $this->assertSame(['B', 'A'], $this->savedContents($reader));

        $this->deleteJson("/api/posts/{$a->id}/save");
        $this->save($reader, $a);
        $this->assertSame(['A', 'B'], $this->savedContents($reader));
    }

    public function test_deleting_post_or_account_removes_saved_rows(): void
    {
        $author = User::factory()->create();
        $reader = User::factory()->create();

        $post = $this->makePost($author, 'จะถูกลบ');
        $other = $this->makePost($author, 'ยังอยู่');
        $this->save($reader, $post);
        $this->save($reader, $other);

        $post->delete();
        $this->assertSame(1, SavedPost::count());

        $reader->delete();
        $this->assertSame(0, SavedPost::count());
    }

    public function test_requires_login(): void
    {
        $post = $this->makePost(User::factory()->create(), 'x');

        $this->getJson('/api/saved-posts')->assertUnauthorized();
        $this->putJson("/api/posts/{$post->id}/save")->assertUnauthorized();
    }
}
