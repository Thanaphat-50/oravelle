<?php

namespace Tests\Feature;

use App\Models\Comment;
use App\Models\FamilyMember;
use App\Models\Hashtag;
use App\Models\Post;
use App\Models\PostLike;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;
use Laravel\Sanctum\Sanctum;
use Tests\Concerns\CreatesFamilies;
use Tests\TestCase;

// แก้ไขข้อความโพสต์: เจ้าของเท่านั้น / ข้อมูลอื่นคงเดิม / แฮชแท็กและค้นหาอัปเดต / ข้อความเดิมไม่นับแก้
// / แก้ชนกัน / โพสต์ถูกซ่อน-ถูกลบ / โพสต์แชร์ — ฐานข้อมูลทดสอบแยก (RefreshDatabase)
class PostEditTest extends TestCase
{
    use CreatesFamilies, RefreshDatabase;

    private function makePost(User $user, ?string $content, array $fields = []): Post
    {
        return Post::forceCreate([
            'user_id' => $user->id,
            'family_id' => FamilyMember::where('user_id', $user->id)->value('family_id') ?? $this->createFamily($user)->id,
            'visibility' => 'community',
            'content' => $content,
            ...$fields,
        ]);
    }

    private function edit(User $user, Post $post, ?string $content, ?int $version = null)
    {
        Sanctum::actingAs($user);

        return $this->patchJson("/api/posts/{$post->id}", [
            'content' => $content,
            'version' => $version ?? $post->fresh()?->edit_version ?? 0,
        ]);
    }

    public function test_owner_edits_text_and_everything_else_stays(): void
    {
        $this->travelTo(Carbon::parse('2026-11-10 09:00:00'));

        $owner = User::factory()->create();
        $fan = User::factory()->create();

        $post = $this->makePost($owner, 'เที่ยวทะเล #ทะเล #วันหยุด');
        PostLike::create(['post_id' => $post->id, 'user_id' => $fan->id]);
        Comment::create(['post_id' => $post->id, 'user_id' => $fan->id, 'content' => 'สวยมาก']);
        $createdAt = $post->created_at->toIso8601String();

        $this->travelTo(Carbon::parse('2026-11-10 10:30:00'));

        $this->edit($owner, $post, '  เที่ยวภูเขา #ภูเขา #วันหยุด  ')->assertOk()
            ->assertJsonPath('changed', true)
            ->assertJsonPath('post.id', $post->id)
            ->assertJsonPath('post.content', 'เที่ยวภูเขา #ภูเขา #วันหยุด')
            ->assertJsonPath('post.edit_version', 1)
            ->assertJsonPath('post.likes_count', 1)
            ->assertJsonCount(1, 'post.comments');

        $fresh = $post->fresh();
        $this->assertSame('2026-11-10 10:30:00', $fresh->edited_at->format('Y-m-d H:i:s'));
        $this->assertSame($createdAt, $fresh->created_at->toIso8601String());
        $this->assertSame(1, PostLike::where('post_id', $post->id)->count());
        $this->assertSame(1, Comment::where('post_id', $post->id)->count());

        // แฮชแท็ก: ที่เอาออกหายไป ที่เพิ่มเข้ามามี
        $this->assertEqualsCanonicalizing(['ภูเขา', 'วันหยุด'], $fresh->hashtags()->pluck('name')->all());

        // ค้นหาเจอข้อความใหม่ ไม่เจอข้อความเก่า
        Sanctum::actingAs($fan);
        $this->getJson('/api/search/posts?q=' . urlencode('ภูเขา'))->assertJsonCount(1, 'posts');
        $this->getJson('/api/search/posts?q=' . urlencode('ทะเล'))->assertJsonCount(0, 'posts');
        $this->getJson('/api/posts?scope=community&hashtag=' . urlencode('ทะเล'))->assertJsonCount(0, 'posts');
    }

    public function test_saving_the_same_text_is_not_an_edit_and_does_not_double_count_tags(): void
    {
        $owner = User::factory()->create();
        $post = $this->makePost($owner, 'ทำอาหาร #สูตรเด็ด');

        foreach (['ทำอาหาร #สูตรเด็ด', '  ทำอาหาร #สูตรเด็ด '] as $same) {
            $this->edit($owner, $post, $same)->assertOk()->assertJsonPath('changed', false);
        }

        $fresh = $post->fresh();
        $this->assertNull($fresh->edited_at);
        $this->assertSame(0, $fresh->edit_version);

        // แก้จริงหลายครั้ง แท็กเดิมยังนับ 1 โพสต์
        $this->edit($owner, $post, 'ทำอาหารเย็น #สูตรเด็ด')->assertOk();
        $this->edit($owner, $post, 'ทำอาหารเช้า #สูตรเด็ด')->assertOk();

        $this->assertSame(1, DB::table('hashtag_post')->where('post_id', $post->id)->count());
        $this->assertSame(1, Hashtag::where('name', 'สูตรเด็ด')->first()->posts()->count());
    }

    public function test_only_the_owner_can_edit_even_through_the_api(): void
    {
        $owner = User::factory()->create();
        $other = User::factory()->create();
        $this->createFamily($owner, [$other]);

        $community = $this->makePost($owner, 'ของชุมชน');
        $family = $this->makePost($owner, 'ของกลุ่ม', ['visibility' => 'family']);

        $this->edit($other, $community, 'แก้แทน')->assertForbidden();
        $this->edit($other, $family, 'แก้แทน')->assertForbidden()
            ->assertJsonPath('message', 'คุณแก้ไขได้เฉพาะโพสต์ของตัวเอง');

        $this->assertSame('ของชุมชน', $community->fresh()->content);
        $this->assertSame('ของกลุ่ม', $family->fresh()->content);

        app('auth')->forgetGuards();
        $this->patchJson("/api/posts/{$community->id}", ['content' => 'x', 'version' => 0])->assertUnauthorized();
    }

    public function test_group_post_needs_current_membership(): void
    {
        $owner = User::factory()->create();
        $mom = User::factory()->create();
        $this->createFamily($mom, [$owner]);

        $post = $this->makePost($owner, 'ในกลุ่ม', ['visibility' => 'family']);

        Sanctum::actingAs($owner);
        $this->postJson('/api/families/leave')->assertOk();

        $this->edit($owner, $post, 'แก้หลังออกกลุ่ม')->assertForbidden()
            ->assertJsonPath('message', 'คุณไม่ได้อยู่ในกลุ่มของโพสต์นี้แล้ว');
    }

    public function test_hidden_or_deleted_post_cannot_be_edited(): void
    {
        $owner = User::factory()->create();

        $hidden = $this->makePost($owner, 'ถูกรายงาน', ['hidden_at' => now()]);
        $this->edit($owner, $hidden, 'หลบการตรวจ')->assertForbidden()->assertJsonPath('code', 'post_hidden');
        $this->assertSame('ถูกรายงาน', $hidden->fresh()->content);

        $gone = $this->makePost($owner, 'จะลบ');
        $version = 0;
        $gone->delete();

        $this->edit($owner, $gone, 'แก้หลังลบ', $version)->assertNotFound();
    }

    public function test_text_only_post_cannot_become_empty_but_media_and_shares_can(): void
    {
        $owner = User::factory()->create();
        $author = User::factory()->create();

        $text = $this->makePost($owner, 'มีแต่ข้อความ');
        $this->edit($owner, $text, '   ')->assertStatus(422)->assertJsonPath('code', 'content_required');
        $this->assertSame('มีแต่ข้อความ', $text->fresh()->content);

        $photo = $this->makePost($owner, 'มีรูป');
        $photo->images()->create(['path' => 'post_images/a.jpg']);
        $this->edit($owner, $photo, '')->assertOk()->assertJsonPath('post.content', '');

        $original = $this->makePost($author, 'ต้นฉบับของคนอื่น');
        $share = $this->makePost($owner, 'แชร์ต่อ', ['shared_post_id' => $original->id]);

        $this->edit($owner, $share, 'คำบรรยายใหม่')->assertOk()
            ->assertJsonPath('post.content', 'คำบรรยายใหม่')
            ->assertJsonPath('post.shared_post.content', 'ต้นฉบับของคนอื่น');
        $this->edit($owner, $share, '')->assertOk();

        $this->assertSame('ต้นฉบับของคนอื่น', $original->fresh()->content);
        $this->assertNull($original->fresh()->edited_at);

        $this->edit($owner, $text, str_repeat('ก', 5001))->assertStatus(422)->assertJsonValidationErrors('content');
    }

    public function test_edits_from_two_devices_do_not_silently_overwrite(): void
    {
        $owner = User::factory()->create();
        $post = $this->makePost($owner, 'ร่างแรก');

        // ทั้งสองเครื่องเปิดฟอร์มตอน version 0
        $this->edit($owner, $post, 'จากมือถือ', 0)->assertOk()->assertJsonPath('post.edit_version', 1);

        $this->edit($owner, $post, 'จากแท็บเล็ต', 0)->assertStatus(409)
            ->assertJsonPath('code', 'edit_conflict')
            ->assertJsonPath('post.content', 'จากมือถือ')
            ->assertJsonPath('post.edit_version', 1);

        $this->assertSame('จากมือถือ', $post->fresh()->content);

        // ดูข้อความล่าสุดแล้วยืนยัน → บันทึกได้
        $this->edit($owner, $post, 'จากแท็บเล็ต', 1)->assertOk()->assertJsonPath('post.edit_version', 2);
    }

    public function test_edited_original_shows_in_shares_and_detail(): void
    {
        $author = User::factory()->create();
        $sharer = User::factory()->create();
        $viewer = User::factory()->create();

        $original = $this->makePost($author, 'ข่าวเดิม');
        $share = $this->makePost($sharer, '', ['shared_post_id' => $original->id]);

        $this->edit($author, $original, 'ข่าวแก้แล้ว')->assertOk();

        Sanctum::actingAs($viewer);
        $this->getJson("/api/posts/{$share->id}")->assertOk()
            ->assertJsonPath('post.shared_post.content', 'ข่าวแก้แล้ว');
        $this->getJson("/api/posts/{$original->id}")->assertOk()
            ->assertJsonPath('post.content', 'ข่าวแก้แล้ว')
            ->assertJsonPath('post.edit_version', 1);
        $this->assertNotNull($this->getJson("/api/posts/{$original->id}")->json('post.edited_at'));
    }
}
