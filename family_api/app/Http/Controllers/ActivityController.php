<?php

namespace App\Http\Controllers;

use App\Models\Activity;
use App\Models\AppNotification;
use App\Models\FamilyMember;
use Illuminate\Http\Request;
use Illuminate\Support\Carbon;

class ActivityController extends Controller
{
    // =====================================================
    // GET /api/activities?page=&filter=&now=
    //
    // filter: all | mine | family | today | overdue | completed (ทำงานกับข้อมูลทั้งหมดบนเซิร์ฟเวอร์)
    // now:    เวลาปัจจุบันในเครื่องผู้ใช้ (เวลาท้องถิ่น ไม่มีเขตเวลา เช่น 2026-11-09T14:30:00)
    //         ใช้ตัดสิน "วันนี้" / "เกินกำหนด" — ไม่ส่งมา = เวลาไทย
    // page:   แบ่งหน้าละ 20 รายการ (แอปเวอร์ชันเก่าไม่ส่ง page → ได้ทั้งหมดเหมือนเดิม)
    // counts: จำนวนของทุกตัวกรอง (นับจากข้อมูลทั้งหมด ไม่ใช่เฉพาะหน้าที่โหลด)
    //
    // activity_date = วันเวลาตามนาฬิกาในเครื่องผู้ใช้ (ไม่มีเขตเวลา) ส่งกลับรูปแบบเดียวกัน
    // =====================================================

    public const FILTERS = ['all', 'mine', 'family', 'today', 'overdue', 'completed'];

    private const PAGE_SIZE = 20;

    public function index(Request $request)
    {
        $data = $request->validate([
            'filter' => ['nullable', 'in:' . implode(',', self::FILTERS)],
            'page' => 'nullable|integer|min:1',
            'now' => 'nullable|date',
        ]);

        $user = $request->user();

        $membership = FamilyMember::where('user_id', $user->id)->first();

        $now = $this->localNow($data['now'] ?? null);

        $visible = fn () => $this->visibleTo($user, $membership);

        $query = $this->applyFilter($visible(), $data['filter'] ?? 'all', $user, $now)
            ->with(['user:id,name,profile_photo'])
            ->orderBy('is_completed')
            ->orderByRaw('activity_date IS NULL')
            ->orderBy('activity_date')
            ->orderByDesc('created_at')
            ->orderByDesc('id');

        $paged = isset($data['page']);

        if ($paged) {
            $paginator = $query->simplePaginate(self::PAGE_SIZE, ['*'], 'page', (int) $data['page']);
            $items = collect($paginator->items());
        } else {
            $items = $query->get();
        }

        $activities = $items->map(fn (Activity $activity) => $this->withFlags($activity, $user, $membership))->values();

        return response()->json([
            'status' => true,

            'activities' => $activities,

            'page' => $paged ? $paginator->currentPage() : 1,
            'has_more' => $paged && $paginator->hasMorePages(),

            'counts' => collect(self::FILTERS)
                ->mapWithKeys(fn (string $filter) => [
                    $filter => $this->applyFilter($visible(), $filter, $user, $now)->count(),
                ]),

            'family' => [
                'has_family' => $membership !== null,
                'id' => $membership?->family_id,
            ],
        ]);
    }

    // กิจกรรมที่ผู้ใช้เห็นได้: ส่วนตัวของตัวเอง + ที่แชร์ในกลุ่มที่อยู่ตอนนี้
    private function visibleTo($user, ?FamilyMember $membership)
    {
        return Activity::query()->where(function ($query) use ($user, $membership) {
            $query->where(fn ($private) => $private
                ->where('user_id', $user->id)
                ->where('visibility', 'private'));

            if ($membership) {
                $query->orWhere(fn ($family) => $family
                    ->where('family_id', $membership->family_id)
                    ->where('visibility', 'family'));
            }
        });
    }

    private function applyFilter($query, string $filter, $user, Carbon $now)
    {
        return match ($filter) {
            'mine' => $query->where('user_id', $user->id),
            'family' => $query->where('visibility', 'family'),
            'today' => $query->whereBetween('activity_date', [
                $now->copy()->startOfDay(),
                $now->copy()->endOfDay(),
            ]),
            'overdue' => $query->where('is_completed', false)
                ->whereNotNull('activity_date')
                ->where('activity_date', '<', $now),
            'completed' => $query->where('is_completed', true),
            default => $query,
        };
    }

    // เวลาตามนาฬิกาผู้ใช้ เก็บแบบไม่มีเขตเวลา (เทียบกับ activity_date ตรง ๆ)
    private function localNow(?string $now): Carbon
    {
        $wallClock = $now !== null
            ? Carbon::parse($now)->format('Y-m-d H:i:s')
            : now('Asia/Bangkok')->format('Y-m-d H:i:s');

        return Carbon::createFromFormat('Y-m-d H:i:s', $wallClock, config('app.timezone'));
    }

    private function withFlags(Activity $activity, $user, ?FamilyMember $membership): Activity
    {
        $isMine = (int) $activity->user_id === (int) $user->id;

        // กิจกรรมกลุ่ม: จัดการได้เมื่อยังอยู่กลุ่มเดิม
        $canManage = $isMine && (
            $activity->visibility !== 'family'
            || ($membership && (int) $membership->family_id === (int) $activity->family_id)
        );

        $activity->setAttribute('is_mine', $isMine);
        $activity->setAttribute('can_manage', $canManage);

        return $activity;
    }

    // =====================================================
    // PATCH /api/activities/{activity} {title, description, activity_date}
    // แก้ไขได้เฉพาะเจ้าของ (กิจกรรมกลุ่ม: ต้องยังอยู่กลุ่มเดิม)
    // การมองเห็น (ส่วนตัว/กลุ่ม) เปลี่ยนที่ /visibility
    // =====================================================

    public function update(Request $request, Activity $activity)
    {
        $user = $request->user();

        if (!$this->canSee($activity, $user)) {
            return $this->notFound();
        }

        if ((int) $activity->user_id !== (int) $user->id) {
            return response()->json([
                'status' => false,
                'message' => 'เฉพาะผู้สร้างกิจกรรมเท่านั้นที่แก้ไขได้',
            ], 403);
        }

        $membership = FamilyMember::where('user_id', $user->id)->first();

        if ($activity->visibility === 'family'
            && (!$membership || (int) $membership->family_id !== (int) $activity->family_id)) {
            return response()->json([
                'status' => false,
                'message' => 'คุณไม่ได้อยู่ในกลุ่มของกิจกรรมนี้แล้ว',
            ], 403);
        }

        $validated = $request->validate([
            'title' => 'required|string|max:255',
            'description' => 'nullable|string|max:2000',
            'activity_date' => 'nullable|date',
        ], [
            'title.required' => 'กรุณาใส่ชื่อกิจกรรม',
            'title.max' => 'ชื่อกิจกรรมยาวได้ไม่เกิน 255 ตัวอักษร',
            'description.max' => 'รายละเอียดยาวได้ไม่เกิน 2000 ตัวอักษร',
            'activity_date.date' => 'วันเวลาไม่ถูกต้อง',
        ]);

        $activity->update([
            'title' => trim($validated['title']),
            'description' => filled($validated['description'] ?? null) ? trim($validated['description']) : null,
            'activity_date' => $validated['activity_date'] ?? null,
        ]);

        $activity->load(['user:id,name,profile_photo']);

        return response()->json([
            'status' => true,
            'message' => 'บันทึกการแก้ไขแล้ว',
            'activity' => $this->withFlags($activity, $user, $membership),
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
