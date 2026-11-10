<?php

namespace App\Http\Controllers;

use App\Models\Activity;
use App\Models\ActivityReminder;
use App\Models\AppNotification;
use App\Models\Family;
use App\Models\FamilyInvitation;
use App\Models\FamilyMember;
use App\Models\Post;
use App\Models\User;
use App\Models\UserLocation;
use App\Support\MediaStorage;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

class FamilyController extends Controller
{
    // ข้อมูลสมาชิกที่คนในกลุ่มเห็นกันได้
    private const MEMBER_FIELDS = ['id', 'name', 'profile_image_url', 'profile_photo_url'];

    // =====================================================
    // สร้างครอบครัว
    // =====================================================

    public function create(Request $request)
    {
        $request->validate([
            'name' => 'required|string|max:255',
        ]);

        $user = $request->user();

        $alreadyMember = FamilyMember::where(
            'user_id',
            $user->id
        )->exists();

        if ($alreadyMember) {
            return response()->json([
                'status' => false,
                'message' => 'คุณมีกลุ่มอยู่แล้ว',
            ], 409);
        }

        $family = DB::transaction(function () use (
            $request,
            $user
        ) {
            do {
                $inviteCode =
                    strtoupper(
                        Str::random(8)
                    );
            } while (
                Family::where(
                    'invite_code',
                    $inviteCode
                )->exists()
            );

            $family = Family::create([
                'name' =>
                    $request->name,

                'invite_code' =>
                    $inviteCode,

                'owner_id' =>
                    $user->id,
            ]);

            FamilyMember::create([
                'family_id' =>
                    $family->id,

                'user_id' =>
                    $user->id,

                'role' =>
                    'owner',
            ]);

            // มีครอบครัวแล้ว → คำเชิญ/คำขอที่ค้างอยู่ไม่ใช้แล้ว
            FamilyInvitation::closePendingFor($user);

            return $family;
        });

        return response()->json([
            'status' => true,

            'message' =>
                'สร้างกลุ่มสำเร็จ',

            'family' =>
                $family,
        ], 201);
    }

    // =====================================================
    // เข้าร่วมครอบครัว
    // =====================================================

    public function join(Request $request)
    {
        $request->validate([
            'invite_code' =>
                'required|string',
        ]);

        $user =
            $request->user();

        $alreadyMember =
            FamilyMember::where(
                'user_id',
                $user->id
            )->exists();

        if ($alreadyMember) {
            return response()->json([
                'status' => false,

                'message' =>
                    'คุณมีกลุ่มอยู่แล้ว',
            ], 409);
        }

        $family =
            Family::where(
                'invite_code',
                strtoupper(
                    $request->invite_code
                )
            )->first();

        if (!$family) {
            return response()->json([
                'status' => false,

                'message' =>
                    'ไม่พบรหัสกลุ่มนี้',
            ], 404);
        }

        DB::transaction(function () use (
            $family,
            $user
        ) {
            FamilyMember::create([
                'family_id' =>
                    $family->id,

                'user_id' =>
                    $user->id,

                'role' =>
                    'member',
            ]);

            // เข้าด้วยรหัสแล้ว → คำเชิญ/คำขอที่ค้างอยู่ไม่ใช้แล้ว
            FamilyInvitation::closePendingFor($user);

            // ---------------------------------------------
            // แจ้ง Owner เมื่อมีสมาชิกใหม่
            // ---------------------------------------------

            if (
                $family->owner_id
                !== $user->id
            ) {
                AppNotification::create([
                    'user_id' =>
                        $family->owner_id,

                    'family_id' =>
                        $family->id,

                    'type' =>
                        'member_joined',

                    'title' =>
                        'สมาชิกใหม่',

                    'message' =>
                        $user->name .
                        ' เข้าร่วมกลุ่มแล้ว',

                    'data' => [
                        'user_id' =>
                            $user->id,
                    ],

                    'is_read' =>
                        false,
                ]);
            }
        });

        return response()->json([
            'status' => true,

            'message' =>
                'เข้าร่วมกลุ่มสำเร็จ',

            'family' =>
                $family,
        ]);
    }

    // =====================================================
    // ดูครอบครัวปัจจุบัน
    // =====================================================

    public function current(
        Request $request
    ) {
        $membership =
            FamilyMember::where(
                'user_id',
                $request->user()->id
            )->first();

        if (!$membership) {
            return response()->json([
                'status' =>
                    true,

                'has_family' =>
                    false,

                'family' =>
                    null,
            ]);
        }

        $family =
            Family::with([
                'owner:id,name,profile_photo',

                'members:id,name,profile_photo',
            ])->find(
                $membership->family_id
            );

        // สมาชิกเห็นกันแค่ id ชื่อ รูป (และบทบาทใน pivot) — ไม่ส่งอีเมลของคนอื่น
        // อีเมลของตัวเองดูได้ที่ /api/profile
        $family?->owner?->setVisible(self::MEMBER_FIELDS);
        $family?->members->each(fn (User $member) => $member->setVisible([...self::MEMBER_FIELDS, 'pivot']));

        if (!$family) {
            return response()->json([
                'status' =>
                    true,

                'has_family' =>
                    false,

                'family' =>
                    null,
            ]);
        }

        return response()->json([
            'status' =>
                true,

            'has_family' =>
                true,

            'role' =>
                $membership->role,

            'family' =>
                $family,
        ]);
    }

    // =====================================================
    // Owner เปลี่ยนชื่อครอบครัว
    // =====================================================

    public function update(
        Request $request,
        Family $family
    ) {
        $user =
            $request->user();

        if (
            $family->owner_id
            !== $user->id
        ) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เฉพาะเจ้าของกลุ่มเท่านั้นที่แก้ไขได้',
            ], 403);
        }

        $data =
            $request->validate([
                'name' =>
                    'required|string|max:255',
            ]);

        $family->name =
            $data['name'];

        $family->save();

        return response()->json([
            'status' =>
                true,

            'message' =>
                'เปลี่ยนชื่อกลุ่มสำเร็จ',

            'family' =>
                $family,
        ]);
    }

    // =====================================================
    // Owner สร้าง Invite Code ใหม่
    // =====================================================

    public function regenerateCode(
        Request $request
    ) {
        $user =
            $request->user();

        $family =
            Family::where(
                'owner_id',
                $user->id
            )->first();

        if (!$family) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เฉพาะเจ้าของกลุ่มเท่านั้นที่สร้างรหัสใหม่ได้',
            ], 403);
        }

        do {
            $newCode =
                strtoupper(
                    Str::random(8)
                );
        } while (
            Family::where(
                'invite_code',
                $newCode
            )->exists()
        );

        $family->invite_code =
            $newCode;

        $family->save();

        return response()->json([
            'status' =>
                true,

            'message' =>
                'สร้าง Invite Code ใหม่สำเร็จ',

            'invite_code' =>
                $newCode,
        ]);
    }

    // =====================================================
    // Owner นำสมาชิกออก
    // =====================================================

    public function removeMember(
        Request $request,
        int $userId
    ) {
        $user =
            $request->user();

        $family =
            Family::where(
                'owner_id',
                $user->id
            )->first();

        if (!$family) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เฉพาะเจ้าของกลุ่มเท่านั้นที่นำสมาชิกออกได้',
            ], 403);
        }

        if (
            $userId ===
            $user->id
        ) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เจ้าของไม่สามารถนำตัวเองออกได้',
            ], 422);
        }

        $member =
            FamilyMember::where(
                'family_id',
                $family->id
            )
                ->where(
                    'user_id',
                    $userId
                )
                ->first();

        if (!$member) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'ไม่พบสมาชิกนี้ในกลุ่ม',
            ], 404);
        }

        if (
            $member->role ===
            'owner'
        ) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'ไม่สามารถนำเจ้าของกลุ่มออกจากกลุ่มได้',
            ], 422);
        }

        DB::transaction(function () use (
            $member,
            $userId,
            $family
        ) {
            // ---------------------------------------------
            // Family Activity ของสมาชิก
            // → กลายเป็น Private
            // ---------------------------------------------

            Activity::where(
                'user_id',
                $userId
            )
                ->where(
                    'family_id',
                    $family->id
                )
                ->where(
                    'visibility',
                    'family'
                )
                ->update([
                    'visibility' =>
                        'private',

                    'family_id' =>
                        null,
                ]);

            // ---------------------------------------------
            // ลบตำแหน่งล่าสุด
            // ---------------------------------------------

            UserLocation::where(
                'user_id',
                $userId
            )->delete();

            // ---------------------------------------------
            // นำสมาชิกออกจาก Family
            // ---------------------------------------------

            $member->delete();
        });

        // หมดสิทธิ์เห็นกิจกรรมกลุ่ม → ยกเลิกการเตือนที่ยังไม่ส่ง (ก่อนส่งจริงก็ตรวจสิทธิ์ซ้ำอีกชั้น)
        ActivityReminder::revokeLostAccess();

        return response()->json([
            'status' =>
                true,

            'message' =>
                'นำสมาชิกออกจากกลุ่มสำเร็จ',
        ]);
    }

    // =====================================================
    // Member ออกจากครอบครัว
    // =====================================================

    public function leave(
        Request $request
    ) {
        $user =
            $request->user();

        $membership =
            FamilyMember::where(
                'user_id',
                $user->id
            )->first();

        if (!$membership) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'คุณยังไม่ได้อยู่ในกลุ่ม',
            ], 404);
        }

        if (
            $membership->role ===
            'owner'
        ) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เจ้าของกลุ่มไม่สามารถออกจากกลุ่มได้ กรุณาโอนสิทธิ์ Owner ก่อน',
            ], 422);
        }

        DB::transaction(function () use (
            $membership,
            $user
        ) {
            // ---------------------------------------------
            // Family Activity ของตัวเอง
            // → Private
            // ---------------------------------------------

            Activity::where(
                'user_id',
                $user->id
            )
                ->where(
                    'family_id',
                    $membership->family_id
                )
                ->where(
                    'visibility',
                    'family'
                )
                ->update([
                    'visibility' =>
                        'private',

                    'family_id' =>
                        null,
                ]);

            // ---------------------------------------------
            // ลบตำแหน่งล่าสุด
            // ---------------------------------------------

            UserLocation::where(
                'user_id',
                $user->id
            )->delete();

            // ---------------------------------------------
            // ออกจาก Family
            // ---------------------------------------------

            $membership->delete();
        });

        // หมดสิทธิ์เห็นกิจกรรมกลุ่ม → ยกเลิกการเตือนที่ยังไม่ส่ง (ก่อนส่งจริงก็ตรวจสิทธิ์ซ้ำอีกชั้น)
        ActivityReminder::revokeLostAccess();

        return response()->json([
            'status' =>
                true,

            'message' =>
                'ออกจากกลุ่มสำเร็จ',
        ]);
    }

    // =====================================================
    // Owner โอนสิทธิ์
    // =====================================================

    public function transferOwner(
        Request $request,
        int $userId
    ) {
        $currentUser =
            $request->user();

        $family =
            Family::where(
                'owner_id',
                $currentUser->id
            )->first();

        if (!$family) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เฉพาะ Owner เท่านั้นที่สามารถโอนสิทธิ์ได้',
            ], 403);
        }

        if (
            $userId ===
            $currentUser->id
        ) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'คุณเป็น Owner อยู่แล้ว',
            ], 422);
        }

        $newOwnerMembership =
            FamilyMember::where(
                'family_id',
                $family->id
            )
                ->where(
                    'user_id',
                    $userId
                )
                ->first();

        if (!$newOwnerMembership) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'ไม่พบสมาชิกนี้ในกลุ่ม',
            ], 404);
        }

        DB::transaction(function () use (
            $family,
            $currentUser,
            $newOwnerMembership,
            $userId
        ) {
            // ---------------------------------------------
            // Owner เดิม → Member
            // ---------------------------------------------

            FamilyMember::where(
                'family_id',
                $family->id
            )
                ->where(
                    'user_id',
                    $currentUser->id
                )
                ->update([
                    'role' =>
                        'member',
                ]);

            // ---------------------------------------------
            // Member ใหม่ → Owner
            // ---------------------------------------------

            $newOwnerMembership->role =
                'owner';

            $newOwnerMembership->save();

            // ---------------------------------------------
            // เปลี่ยน owner_id
            // ---------------------------------------------

            $family->owner_id =
                $userId;

            $family->save();
        });

        return response()->json([
            'status' =>
                true,

            'message' =>
                'โอนสิทธิ์ Owner สำเร็จ',
        ]);
    }

    // =====================================================
    // Owner ลบครอบครัว
    // =====================================================

    public function deleteFamily(
        Request $request
    ) {
        $user =
            $request->user();

        $family =
            Family::where(
                'owner_id',
                $user->id
            )->first();

        if (!$family) {
            return response()->json([
                'status' =>
                    false,

                'message' =>
                    'เฉพาะเจ้าของกลุ่มเท่านั้นที่สามารถลบกลุ่มได้',
            ], 403);
        }

        // เก็บที่อยู่ไฟล์ในโพสต์ของครอบครัว (รูป วิดีโอ ไฟล์ในความคิดเห็น)
        // ไว้ลบหลังลบข้อมูลสำเร็จ
        $imagePaths = Post::mediaPathsOf(
            Post::where('family_id', $family->id)->select('id')
        );

        DB::transaction(function () use (
            $family
        ) {
            // ---------------------------------------------
            // เก็บ ID สมาชิก
            // ---------------------------------------------

            $memberIds =
                DB::table(
                    'family_members'
                )
                    ->where(
                        'family_id',
                        $family->id
                    )
                    ->pluck(
                        'user_id'
                    );

            // ---------------------------------------------
            // Family Activity ทั้งหมด
            // → Private
            //
            // สำคัญ:
            // ต้องทำก่อนลบ Family
            // ---------------------------------------------

            Activity::where(
                'family_id',
                $family->id
            )
                ->update([
                    'visibility' =>
                        'private',

                    'family_id' =>
                        null,
                ]);

            // ---------------------------------------------
            // ลบ Location ของสมาชิกทุกคน
            // ---------------------------------------------

            if (
                $memberIds->isNotEmpty()
            ) {
                DB::table(
                    'user_locations'
                )
                    ->whereIn(
                        'user_id',
                        $memberIds
                    )
                    ->delete();
            }

            // ---------------------------------------------
            // หา Post ทั้งหมด
            // ---------------------------------------------

            $postIds =
                DB::table(
                    'posts'
                )
                    ->where(
                        'family_id',
                        $family->id
                    )
                    ->pluck(
                        'id'
                    );

            // ---------------------------------------------
            // ลบ Comment
            // ---------------------------------------------

            if (
                $postIds->isNotEmpty()
            ) {
                DB::table(
                    'comments'
                )
                    ->whereIn(
                        'post_id',
                        $postIds
                    )
                    ->delete();
            }

            // ---------------------------------------------
            // ลบ Post
            // ---------------------------------------------

            DB::table(
                'posts'
            )
                ->where(
                    'family_id',
                    $family->id
                )
                ->delete();

            // ---------------------------------------------
            // ลบสมาชิก
            // ---------------------------------------------

            DB::table(
                'family_members'
            )
                ->where(
                    'family_id',
                    $family->id
                )
                ->delete();

            // ---------------------------------------------
            // ลบ Family
            // ---------------------------------------------

            $family->delete();
        });

        // หมดสิทธิ์เห็นกิจกรรมกลุ่ม → ยกเลิกการเตือนที่ยังไม่ส่ง (ก่อนส่งจริงก็ตรวจสิทธิ์ซ้ำอีกชั้น)
        ActivityReminder::revokeLostAccess();

        // ลบไฟล์ของโพสต์ที่ถูกลบไปแล้ว
        // (แถวในตารางถูกลบตาม cascade แต่ไฟล์ต้องลบเอง)
        MediaStorage::delete($imagePaths);

        return response()->json([
            'status' =>
                true,

            'message' =>
                'ลบกลุ่มสำเร็จ',
        ]);
    }
}