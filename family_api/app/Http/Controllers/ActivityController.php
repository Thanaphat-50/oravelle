<?php

namespace App\Http\Controllers;

use App\Models\Activity;
use App\Models\AppNotification;
use App\Models\FamilyMember;
use App\Models\ActivityReminder;
use Illuminate\Http\JsonResponse;
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
            ->with([
                'user:id,name,profile_photo',
                'reminders' => fn ($reminders) => $reminders->where('user_id', $user->id),
            ])
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

        return $this->withReminder($activity, $user);
    }

    // การเตือนของผู้ใช้คนนี้ (คนอื่นไม่เห็นค่าของกันและกัน)
    // can_remind: รู้ช่วงเวลาจริงและยังไม่เสร็จ
    // needs_time_confirmation: กิจกรรมเดิมก่อนมีระบบเตือน (มีวันเวลาแต่ไม่ทราบเขตเวลา) → เจ้าของต้องยืนยันวันเวลา
    private function withReminder(Activity $activity, $user): Activity
    {
        $reminder = $activity->relationLoaded('reminders')
            ? $activity->reminders->firstWhere('user_id', $user->id)
            : $activity->reminders()->where('user_id', $user->id)->first();

        $activity->unsetRelation('reminders');

        $activity->setAttribute('my_reminder', $reminder && $reminder->status !== ActivityReminder::STATUS_CANCELLED
            ? $reminder->payload()
            : null);
        $activity->setAttribute('can_remind', $activity->canRemind());
        $activity->setAttribute('needs_time_confirmation', $activity->starts_at === null && $activity->getRawOriginal('activity_date') !== null);

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
            // แอปใหม่: ช่วงเวลาจริง + เขตเวลา IANA / แอปเก่า: activity_date (ไม่ทราบเขตเวลา)
            // ต้องมีเขตเวลาในค่า (Z หรือ +07:00) — ไม่เดาเขตเวลาให้
            'starts_at' => ['nullable', 'date', 'regex:/(Z|[+-]\d{2}:?\d{2})$/i'],
            'timezone' => 'required_with:starts_at|nullable|timezone:all_with_bc',
            'reminder_offset' => 'nullable|in:0,15,30,1440',
        ], [
            'title.required' => 'กรุณาใส่ชื่อกิจกรรม',
            'title.max' => 'ชื่อกิจกรรมยาวได้ไม่เกิน 255 ตัวอักษร',
            'description.max' => 'รายละเอียดยาวได้ไม่เกิน 2000 ตัวอักษร',
            'activity_date.date' => 'วันเวลาไม่ถูกต้อง',
            'starts_at.date' => 'วันเวลาไม่ถูกต้อง',
            'starts_at.regex' => 'วันเวลาต้องระบุเขตเวลา',
            'timezone.*' => 'เขตเวลาไม่ถูกต้อง',
            'reminder_offset.in' => 'ตัวเลือกการเตือนไม่ถูกต้อง',
        ]);

        $time = $this->timeFields($request, $validated, $activity);

        // ตั้งเตือนพร้อมบันทึก → ตรวจก่อนบันทึก (เวลาเตือนต้องอยู่ในอนาคต)
        if ($request->exists('reminder_offset')
            && ($error = $this->reminderError(
                array_key_exists('starts_at', $time) ? $time['starts_at'] : $activity->starts_at,
                (bool) $activity->is_completed,
                array_key_exists('activity_date', $time) ? $time['activity_date'] : $activity->getRawOriginal('activity_date'),
                $this->offset($validated)
            ))) {
            return $error;
        }

        $before = $activity->starts_at?->toIso8601String();

        $activity->update([
            'title' => trim($validated['title']),
            'description' => filled($validated['description'] ?? null) ? trim($validated['description']) : null,
            ...$time,
        ]);

        // เวลาเปลี่ยน → คำนวณเวลาเตือนของทุกคนใหม่ (กำหนดเก่าไม่ส่ง)
        if ($before !== $activity->starts_at?->toIso8601String()) {
            ActivityReminder::reschedule($activity, true);
        }

        if ($request->exists('reminder_offset')) {
            ActivityReminder::setFor($activity, $user, $this->offset($validated));
        }

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
            // แอปใหม่: ช่วงเวลาจริง + เขตเวลา IANA / แอปเก่า: activity_date (ไม่ทราบเขตเวลา)
            // ต้องมีเขตเวลาในค่า (Z หรือ +07:00) — ไม่เดาเขตเวลาให้
            'starts_at' => ['nullable', 'date', 'regex:/(Z|[+-]\d{2}:?\d{2})$/i'],
            'timezone' => 'required_with:starts_at|nullable|timezone:all_with_bc',
            'reminder_offset' => 'nullable|in:0,15,30,1440',

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

        $time = $this->timeFields($request, $validated);

        if ($request->exists('reminder_offset')
            && ($error = $this->reminderError($time['starts_at'], false, $time['activity_date'], $this->offset($validated)))) {
            return $error;
        }

        $activity = Activity::create([
            ...$time,

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

            'is_completed' =>
                false,
        ]);

        if ($request->exists('reminder_offset')) {
            ActivityReminder::setFor($activity, $user, $this->offset($validated));
        }

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
                $this->withReminder($activity, $user),
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

        // เสร็จ → พักการเตือนที่ยังไม่ส่ง / กลับเป็นยังไม่เสร็จ → ตั้งใหม่เฉพาะที่ยังอยู่ในอนาคต
        ActivityReminder::reschedule($activity, false);

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
                $this->withReminder($activity, $user),
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

            // สมาชิกคนอื่นหมดสิทธิ์เห็น → ยกเลิกการเตือนของเขา
            ActivityReminder::revokeLostAccess();

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
                    $this->withReminder($activity, $user),
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
                $this->withReminder($activity, $user),
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

    // =====================================================
    // GET /api/activities/{activity}  (เปิดจากแจ้งเตือน)
    // ไม่มีสิทธิ์ / ถูกลบ → 404 ไม่ส่งข้อมูลเก่า
    // =====================================================

    public function show(Request $request, Activity $activity)
    {
        $user = $request->user();

        if (!$this->canSee($activity, $user)) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบกิจกรรมนี้ หรือคุณไม่มีสิทธิ์ดูแล้ว',
            ], 404);
        }

        $membership = FamilyMember::where('user_id', $user->id)->first();

        $activity->load(['user:id,name,profile_photo']);

        return response()->json([
            'status' => true,
            'activity' => $this->withFlags($activity, $user, $membership),
        ]);
    }

    // =====================================================
    // PUT /api/activities/{activity}/reminder {offset: null|0|15|30|1440}
    // ตั้งเตือนของตัวเอง: เจ้าของ หรือสมาชิกที่เห็นกิจกรรมกลุ่ม (ไม่ต้องมีสิทธิ์แก้ไข)
    // =====================================================

    public function reminder(Request $request, Activity $activity)
    {
        $user = $request->user();

        if (!$this->canSee($activity, $user)) {
            return $this->notFound();
        }

        $validated = $request->validate(
            ['offset' => 'nullable|in:0,15,30,1440'],
            ['offset.in' => 'ตัวเลือกการเตือนไม่ถูกต้อง']
        );

        $offset = isset($validated['offset']) ? (int) $validated['offset'] : null;

        if ($error = $this->reminderError($activity->starts_at, (bool) $activity->is_completed, $activity->getRawOriginal('activity_date'), $offset)) {
            return $error;
        }

        $reminder = ActivityReminder::setFor($activity, $user, $offset);

        return response()->json([
            'status' => true,
            'message' => $reminder ? 'ตั้งเตือนแล้ว: ' . ActivityReminder::OFFSETS[$offset] : 'ปิดการเตือนแล้ว',
            'reminder' => $reminder?->payload(),
        ]);
    }

    // เวลาแบบใหม่ (starts_at + timezone) → activity_date = นาฬิกาในเขตเวลานั้น (ให้แอปเก่า/ตัวกรอง)
    // แอปเก่าส่ง activity_date อย่างเดียว → ไม่ทราบเขตเวลา (starts_at = NULL ตั้งเตือนไม่ได้)
    private function timeFields(Request $request, array $validated, ?Activity $current = null): array
    {
        // แอปเก่าแก้ไขชื่อ/รายละเอียด แล้วส่งวันเวลาเดิมกลับมา → คงช่วงเวลาจริงและการเตือนไว้
        if (!$request->exists('starts_at')
            && $current?->starts_at !== null
            && filled($validated['activity_date'] ?? null)
            && Carbon::parse($validated['activity_date'])->format('Y-m-d H:i') === $current->activity_date?->format('Y-m-d H:i')) {
            return [];
        }

        if (filled($validated['starts_at'] ?? null)) {
            $start = Carbon::parse($validated['starts_at'])->utc()->startOfSecond();

            return [
                'starts_at' => $start,
                'timezone' => $validated['timezone'],
                'activity_date' => $start->copy()->setTimezone($validated['timezone'])->format('Y-m-d H:i:s'),
            ];
        }

        return [
            'starts_at' => null,
            'timezone' => null,
            'activity_date' => $request->exists('starts_at') ? null : ($validated['activity_date'] ?? null),
        ];
    }

    private function offset(array $validated): ?int
    {
        return isset($validated['reminder_offset']) ? (int) $validated['reminder_offset'] : null;
    }

    private function reminderError(?Carbon $startsAt, bool $completed, ?string $legacyDate, ?int $offset): ?JsonResponse
    {
        if ($offset === null) {
            return null;
        }

        $error = fn (string $code, string $message) => response()->json([
            'status' => false,
            'code' => $code,
            'message' => $message,
            'errors' => ['reminder_offset' => [$message]],
        ], 422);

        if ($startsAt === null) {
            return $legacyDate !== null
                ? $error('time_unconfirmed', 'กิจกรรมนี้สร้างก่อนมีระบบเตือน กรุณายืนยันวันเวลา (แก้ไขกิจกรรมแล้วบันทึก) ก่อนตั้งเตือน')
                : $error('no_time', 'ตั้งวันและเวลาของกิจกรรมก่อน จึงจะตั้งเตือนได้');
        }

        if ($completed) {
            return $error('completed', 'กิจกรรมนี้ทำเสร็จแล้ว ตั้งเตือนไม่ได้');
        }

        if (!$startsAt->copy()->subMinutes($offset)->isFuture()) {
            return $error('reminder_past', 'เวลาเตือนที่เลือกผ่านไปแล้ว กรุณาเลือกใหม่');
        }

        return null;
    }
}
