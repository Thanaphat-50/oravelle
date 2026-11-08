<?php

namespace App\Http\Controllers;

use App\Models\Activity;
use App\Models\AppNotification;
use App\Models\FamilyMember;
use Illuminate\Http\Request;

class ActivityController extends Controller
{
    // =====================================================
    // GET /api/activities
    //
    // เห็น:
    // - private ของตัวเอง
    // - family ของ Family ที่ตัวเองอยู่
    // =====================================================

    public function index(Request $request)
    {
        $user = $request->user();

        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        $query = Activity::query()
            ->with([
                'user:id,name,profile_photo',
            ])
            ->where(function ($query) use (
                $user,
                $membership
            ) {
                // -----------------------------------------
                // Private ของตัวเอง
                // -----------------------------------------

                $query->where(function ($privateQuery) use ($user) {
                    $privateQuery
                        ->where(
                            'user_id',
                            $user->id
                        )
                        ->where(
                            'visibility',
                            'private'
                        );
                });

                // -----------------------------------------
                // Family activity
                // -----------------------------------------

                if ($membership) {
                    $query->orWhere(function ($familyQuery) use ($membership) {
                        $familyQuery
                            ->where(
                                'family_id',
                                $membership->family_id
                            )
                            ->where(
                                'visibility',
                                'family'
                            );
                    });
                }
            })
            ->orderBy('is_completed')
            ->orderByRaw('activity_date IS NULL')
            ->orderBy('activity_date')
            ->orderByDesc('created_at');

        $activities = $query
            ->get()
            ->map(function ($activity) use (
                $user,
                $membership
            ) {
                $isMine =
                    $activity->user_id === $user->id;

                $canManage =
                    $isMine;

                // Family activity ต้องยังอยู่ใน Family เดิม
                if (
                    $activity->visibility === 'family'
                    && (
                        !$membership
                        || $membership->family_id
                            !== $activity->family_id
                    )
                ) {
                    $canManage = false;
                }

                $activity->setAttribute(
                    'is_mine',
                    $isMine
                );

                $activity->setAttribute(
                    'can_manage',
                    $canManage
                );

                return $activity;
            });

        return response()->json([
            'status' => true,

            'activities' => $activities,

            'family' => [
                'has_family' =>
                    $membership !== null,

                'id' =>
                    $membership
                        ? $membership->family_id
                        : null,
            ],
        ]);
    }

    // =====================================================
    // POST /api/activities
    // =====================================================

    public function store(Request $request)
    {
        $user = $request->user();

        $validated = $request->validate([
            'title' => [
                'required',
                'string',
                'max:255',
            ],

            'description' => [
                'nullable',
                'string',
                'max:2000',
            ],

            'activity_date' => [
                'nullable',
                'date',
            ],

            'visibility' => [
                'required',
                'in:private,family',
            ],
        ]);

        $familyId = null;

        // ---------------------------------------------
        // ถ้าแชร์กับ Family
        // ---------------------------------------------

        if ($validated['visibility'] === 'family') {
            $membership = FamilyMember::where(
                'user_id',
                $user->id
            )->first();

            if (!$membership) {
                return response()->json([
                    'status' => false,

                    'message' =>
                        'คุณต้องมีกลุ่มก่อนจึงจะแชร์กิจกรรมได้',
                ], 403);
            }

            $familyId =
                $membership->family_id;
        }

        // ---------------------------------------------
        // CREATE
        // ---------------------------------------------

        $activity = Activity::create([
            'user_id' =>
                $user->id,

            'family_id' =>
                $familyId,

            'visibility' =>
                $validated['visibility'],

            'title' =>
                $validated['title'],

            'description' =>
                $validated['description']
                    ?? null,

            'activity_date' =>
                $validated['activity_date']
                    ?? null,

            'is_completed' =>
                false,
        ]);

        // ---------------------------------------------
        // Notification
        // ถ้าเป็น Family activity
        // ---------------------------------------------

        if (
            $validated['visibility'] === 'family'
            && $familyId !== null
        ) {
            $members = FamilyMember::where(
                'family_id',
                $familyId
            )
                ->where(
                    'user_id',
                    '!=',
                    $user->id
                )
                ->get();

            foreach ($members as $member) {
                AppNotification::create([
                    'user_id' =>
                        $member->user_id,

                    'family_id' =>
                        $familyId,

                    'type' =>
                        'new_activity',

                    'title' =>
                        'กิจกรรมใหม่ในกลุ่ม',

                    'message' =>
                        $user->name .
                        ' เพิ่มกิจกรรม “' .
                        $activity->title .
                        '”',

                    'data' => [
                        'activity_id' =>
                            $activity->id,
                    ],

                    'is_read' =>
                        false,
                ]);
            }
        }

        $activity->load([
            'user:id,name,profile_photo',
        ]);

        $activity->setAttribute(
            'is_mine',
            true
        );

        $activity->setAttribute(
            'can_manage',
            true
        );

        return response()->json([
            'status' => true,

            'message' =>
                $validated['visibility'] === 'family'
                    ? 'สร้างและแชร์กิจกรรมกับกลุ่มแล้ว'
                    : 'สร้างกิจกรรมส่วนตัวแล้ว',

            'activity' =>
                $activity,
        ], 201);
    }

    // =====================================================
    // PATCH /api/activities/{activity}/toggle
    // =====================================================

    public function toggle(
        Request $request,
        Activity $activity
    ) {
        $user = $request->user();

        // กิจกรรมส่วนตัวของคนอื่น / กลุ่มอื่น → ตอบเหมือนไม่มี (ไม่บอกว่ามีอยู่)
        if (!$this->canSee($activity, $user)) {
            return $this->notFound();
        }

        if ($activity->user_id !== $user->id) {
            return response()->json([
                'status' => false,

                'message' =>
                    'เฉพาะผู้สร้างกิจกรรมเท่านั้นที่เปลี่ยนสถานะได้',
            ], 403);
        }

        // ถ้าเป็น Family activity
        // ต้องยังอยู่ Family เดิม
        if ($activity->visibility === 'family') {
            $membership = FamilyMember::where(
                'user_id',
                $user->id
            )
                ->where(
                    'family_id',
                    $activity->family_id
                )
                ->first();

            if (!$membership) {
                return response()->json([
                    'status' => false,

                    'message' =>
                        'คุณไม่ได้อยู่ในกลุ่มของกิจกรรมนี้แล้ว',
                ], 403);
            }
        }

        $activity->update([
            'is_completed' =>
                !$activity->is_completed,
        ]);

        $activity->load([
            'user:id,name,profile_photo',
        ]);

        $activity->setAttribute(
            'is_mine',
            true
        );

        $activity->setAttribute(
            'can_manage',
            true
        );

        return response()->json([
            'status' => true,

            'message' =>
                $activity->is_completed
                    ? 'ทำกิจกรรมสำเร็จแล้ว'
                    : 'เปลี่ยนกลับเป็นยังไม่เสร็จ',

            'activity' =>
                $activity,
        ]);
    }

    // =====================================================
    // PATCH /api/activities/{activity}/visibility
    //
    // private <-> family
    // =====================================================

    public function updateVisibility(
        Request $request,
        Activity $activity
    ) {
        $user = $request->user();

        // ต้องเป็นเจ้าของ
        // กิจกรรมส่วนตัวของคนอื่น / กลุ่มอื่น → ตอบเหมือนไม่มี (ไม่บอกว่ามีอยู่)
        if (!$this->canSee($activity, $user)) {
            return $this->notFound();
        }

        if ($activity->user_id !== $user->id) {
            return response()->json([
                'status' => false,

                'message' =>
                    'คุณไม่มีสิทธิ์แก้ไขกิจกรรมนี้',
            ], 403);
        }

        $validated = $request->validate([
            'visibility' => [
                'required',
                'in:private,family',
            ],
        ]);

        $newVisibility =
            $validated['visibility'];

        // =================================================
        // FAMILY -> PRIVATE
        // =================================================

        if ($newVisibility === 'private') {
            $activity->update([
                'visibility' =>
                    'private',

                'family_id' =>
                    null,
            ]);

            $activity->load([
                'user:id,name,profile_photo',
            ]);

            $activity->setAttribute(
                'is_mine',
                true
            );

            $activity->setAttribute(
                'can_manage',
                true
            );

            return response()->json([
                'status' => true,

                'message' =>
                    'เปลี่ยนเป็นกิจกรรมส่วนตัวแล้ว',

                'activity' =>
                    $activity,
            ]);
        }

        // =================================================
        // PRIVATE -> FAMILY
        // =================================================

        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        if (!$membership) {
            return response()->json([
                'status' => false,

                'message' =>
                    'คุณต้องมีกลุ่มก่อนจึงจะแชร์กิจกรรมได้',
            ], 403);
        }

        // เช็กว่าแชร์กับ Family นี้อยู่แล้วหรือไม่
        $alreadyShared =
            $activity->visibility === 'family'
            && $activity->family_id
                === $membership->family_id;

        $activity->update([
            'visibility' =>
                'family',

            'family_id' =>
                $membership->family_id,
        ]);

        // ---------------------------------------------
        // แจ้งเตือนเฉพาะตอนเพิ่ง Share
        // ---------------------------------------------

        if (!$alreadyShared) {
            $members = FamilyMember::where(
                'family_id',
                $membership->family_id
            )
                ->where(
                    'user_id',
                    '!=',
                    $user->id
                )
                ->get();

            foreach ($members as $member) {
                AppNotification::create([
                    'user_id' =>
                        $member->user_id,

                    'family_id' =>
                        $membership->family_id,

                    'type' =>
                        'new_activity',

                    'title' =>
                        'กิจกรรมใหม่ในกลุ่ม',

                    'message' =>
                        $user->name .
                        ' แชร์กิจกรรม “' .
                        $activity->title .
                        '”',

                    'data' => [
                        'activity_id' =>
                            $activity->id,
                    ],

                    'is_read' =>
                        false,
                ]);
            }
        }

        $activity->load([
            'user:id,name,profile_photo',
        ]);

        $activity->setAttribute(
            'is_mine',
            true
        );

        $activity->setAttribute(
            'can_manage',
            true
        );

        return response()->json([
            'status' => true,

            'message' =>
                'แชร์กิจกรรมกับกลุ่มแล้ว',

            'activity' =>
                $activity,
        ]);
    }

    // =====================================================
    // DELETE /api/activities/{activity}
    // =====================================================

    public function destroy(
        Request $request,
        Activity $activity
    ) {
        $user = $request->user();

        // กิจกรรมส่วนตัวของคนอื่น / กลุ่มอื่น → ตอบเหมือนไม่มี (ไม่บอกว่ามีอยู่)
        if (!$this->canSee($activity, $user)) {
            return $this->notFound();
        }

        if ($activity->user_id !== $user->id) {
            return response()->json([
                'status' => false,

                'message' =>
                    'เฉพาะผู้สร้างกิจกรรมเท่านั้นที่ลบได้',
            ], 403);
        }

        // Family activity
        if ($activity->visibility === 'family') {
            $membership = FamilyMember::where(
                'user_id',
                $user->id
            )
                ->where(
                    'family_id',
                    $activity->family_id
                )
                ->first();

            if (!$membership) {
                return response()->json([
                    'status' => false,

                    'message' =>
                        'คุณไม่ได้อยู่ในกลุ่มของกิจกรรมนี้แล้ว',
                ], 403);
            }
        }

        $activity->delete();

        return response()->json([
            'status' => true,

            'message' =>
                'ลบกิจกรรมเรียบร้อยแล้ว',
        ]);
    }

    // =====================================================
    // เห็นกิจกรรมนี้ได้ไหม: ของตัวเอง หรือแชร์ในกลุ่มที่เราอยู่
    // =====================================================

    private function canSee(Activity $activity, $user): bool
    {
        if ((int) $activity->user_id === (int) $user->id) {
            return true;
        }

        return $activity->visibility === 'family'
            && $activity->family_id !== null
            && FamilyMember::where('user_id', $user->id)
                ->where('family_id', $activity->family_id)
                ->exists();
    }

    private function notFound()
    {
        return response()->json([
            'status' => false,
            'message' => 'ไม่พบกิจกรรมนี้',
        ], 404);
    }
}
