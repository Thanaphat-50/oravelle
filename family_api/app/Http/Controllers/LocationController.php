<?php

namespace App\Http\Controllers;

use App\Models\FamilyMember;
use App\Models\Post;
use App\Models\User;
use App\Models\UserLocation;
use App\Services\PlaceFinder;
use App\Services\RouteFinder;
use Illuminate\Http\Request;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use RuntimeException;

class LocationController extends Controller
{
    // =====================================================
    // อัปเดตตำแหน่งของตัวเอง
    // =====================================================

    public function update(Request $request)
    {
        $user = $request->user();

        // ต้องอยู่ใน Family ก่อน
        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        if (!$membership) {
            return response()->json([
                'status' => false,
                'message' =>
                    'คุณต้องอยู่ในกลุ่มก่อนจึงจะอัปเดตตำแหน่งได้',
            ], 403);
        }

        $data = $request->validate([
            'latitude' =>
                'required|numeric|between:-90,90',

            'longitude' =>
                'required|numeric|between:-180,180',

            'accuracy' =>
                'nullable|numeric|min:0',
        ]);

        // ปิดการแชร์ตำแหน่งอยู่ → ไม่เก็บตำแหน่ง
        // (กันแอปเวอร์ชันเก่าที่ยังส่งตำแหน่งมา)
        if ($user->location_sharing === false) {
            return response()->json([
                'status' => true,
                'shared' => false,
                'message' =>
                    'คุณปิดการแชร์ตำแหน่งอยู่ ตำแหน่งจึงไม่ถูกบันทึก',
            ]);
        }

        $location = UserLocation::updateOrCreate(
            [
                'user_id' => $user->id,
            ],
            [
                'latitude' =>
                    $data['latitude'],

                'longitude' =>
                    $data['longitude'],

                'accuracy' =>
                    $data['accuracy'] ?? null,

                'last_seen_at' => now(),
            ]
        );

        return response()->json([
            'status' => true,
            'message' =>
                'อัปเดตตำแหน่งสำเร็จ',
            'location' => $location,
        ]);
    }

    // =====================================================
    // ดูตำแหน่งสมาชิกใน Family เดียวกัน
    // =====================================================

    public function familyLocations(
        Request $request
    ) {
        $user = $request->user();

        // หาว่า User อยู่ Family ไหน
        $membership = FamilyMember::where(
            'user_id',
            $user->id
        )->first();

        if (!$membership) {
            return response()->json([
                'status' => false,
                'message' =>
                    'คุณยังไม่ได้อยู่ในกลุ่ม',
                'locations' => [],
            ], 403);
        }

        // เอาเฉพาะ User ID ที่ยังเป็นสมาชิก Family นี้จริง ๆ
        $memberIds = FamilyMember::where(
            'family_id',
            $membership->family_id
        )
            ->pluck('user_id');

        // สมาชิกที่ปิดการแชร์ตำแหน่ง (รวมตัวเราเอง)
        $pausedIds = User::whereIn('id', $memberIds)
            ->where('location_sharing', false)
            ->pluck('id');

        // ชื่อคนอื่นที่ปิดแชร์ (ให้ครอบครัวรู้ว่าทำไมไม่เห็นตำแหน่ง)
        // สถานะของตัวเองดูได้จาก /api/settings
        $paused = User::whereIn('id', $pausedIds)
            ->where('id', '!=', $user->id)
            ->get(['id', 'name']);

        // ดึง Location เฉพาะสมาชิกปัจจุบันที่เปิดแชร์อยู่เท่านั้น
        $locations = UserLocation::whereIn(
            'user_id',
            $memberIds->diff($pausedIds)
        )
            ->with([
                'user:id,name,profile_photo'
            ])
            ->get()
            // ไม่ส่งอีเมลของสมาชิกไปกับตำแหน่ง (แผนที่ใช้แค่ชื่อและรูป)
            ->each(fn (UserLocation $location) => $location->user?->setVisible([
                'id', 'name', 'profile_image_url', 'profile_photo_url',
            ]))
            // is_me → แอปรู้ว่าจุดไหนคือเรา (ไม่ต้องคิดระยะทาง/นำทางไปหาตัวเอง)
            ->each(fn (UserLocation $location) => $location->setAttribute(
                'is_me',
                (int) $location->user_id === (int) $user->id
            ))
            ->sortByDesc('is_me')
            ->values();

        // ข้อความบนแผนที่ของแต่ละคน (โพสต์ครอบครัวนี้ล่าสุดที่ยังไม่หมดเวลา)
        $statuses = Post::onMap()
            ->where('family_id', $membership->family_id)
            ->whereIn('user_id', $locations->pluck('user_id'))
            ->orderByDesc('id')
            ->get(['id', 'user_id', 'content', 'created_at', 'map_status_until'])
            ->unique('user_id')
            ->keyBy('user_id');

        $locations->each(function (UserLocation $location) use ($statuses) {
            $post = $statuses->get($location->user_id);

            $location->setAttribute('status', $post ? [
                'post_id' => $post->id,
                'text' => Str::limit(trim($post->content), 120),
                'created_at' => $post->created_at?->toIso8601String(),
                'until' => $post->map_status_until?->toIso8601String(),
            ] : null);
        });

        return response()->json([
            'status' => true,
            'locations' => $locations,
            'paused' => $paused,
        ]);
    }

    // =====================================================
    // เส้นทางตามถนนจากเราไปหาสมาชิก
    // GET /api/family/members/{user}/route?from_lat=&from_lng=&mode=drive
    // =====================================================

    public function route(Request $request, User $user, RouteFinder $routes)
    {
        $data = $request->validate([
            'from_lat' => 'required|numeric|between:-90,90',
            'from_lng' => 'required|numeric|between:-180,180',
            'mode' => ['nullable', Rule::in(array_keys(RouteFinder::MODES))],
        ]);

        $location = $this->sharedLocationOf($request, $user);

        if (!$location) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบตำแหน่งของสมาชิกคนนี้',
            ], 404);
        }

        // แอปใช้ 4xx (5xx แอปถือเป็น Server ล่ม) → แสดงระยะทางเส้นตรงแทน
        if (!$routes->enabled()) {
            return response()->json([
                'status' => false,
                'code' => 'routes_disabled',
                'message' => 'ยังไม่ได้เปิดใช้การคำนวณเส้นทาง',
            ], 409);
        }

        $mode = $data['mode'] ?? 'drive';

        try {
            $route = $routes->route(
                (float) $data['from_lat'],
                (float) $data['from_lng'],
                (float) $location->latitude,
                (float) $location->longitude,
                $mode
            );
        } catch (RuntimeException) {
            return response()->json([
                'status' => false,
                'code' => 'route_failed',
                'message' => 'คำนวณเส้นทางไม่สำเร็จ กรุณาลองใหม่',
            ], 424);
        }

        if (!$route) {
            return response()->json([
                'status' => false,
                'code' => 'no_route',
                'message' => 'ไม่พบเส้นทางสำหรับการเดินทางแบบนี้',
            ], 404);
        }

        return response()->json([
            'status' => true,
            'mode' => $mode,
            ...$route,
        ]);
    }

    // =====================================================
    // รายละเอียดของตำแหน่งสมาชิก
    // GET /api/family/members/{user}/place
    // - area:   หมู่บ้าน/ชุมชน ตำบล อำเภอ จังหวัด (null = หาไม่ได้)
    // - places: สถานที่ใกล้เคียง (null = ยังไม่ได้เปิด Google Places)
    // =====================================================

    public function place(Request $request, User $user, PlaceFinder $places)
    {
        $location = $this->sharedLocationOf($request, $user);

        if (!$location) {
            return response()->json([
                'status' => false,
                'message' => 'ไม่พบตำแหน่งของสมาชิกคนนี้',
            ], 404);
        }

        $latitude = (float) $location->latitude;
        $longitude = (float) $location->longitude;

        return response()->json([
            'status' => true,
            'latitude' => $latitude,
            'longitude' => $longitude,
            'area' => $places->area($latitude, $longitude),
            'places' => $places->nearby($latitude, $longitude),
        ]);
    }

    // ตำแหน่งล่าสุดของสมาชิกครอบครัวเดียวกันที่เปิดแชร์ตำแหน่งอยู่ (null = ดูไม่ได้)
    private function sharedLocationOf(Request $request, User $user): ?UserLocation
    {
        $familyId = FamilyMember::where('user_id', $request->user()->id)
            ->value('family_id');

        $sameFamily = $familyId !== null
            && FamilyMember::where('family_id', $familyId)
                ->where('user_id', $user->id)
                ->exists();

        if (!$sameFamily || $user->location_sharing === false) {
            return null;
        }

        return UserLocation::where('user_id', $user->id)->first();
    }
}