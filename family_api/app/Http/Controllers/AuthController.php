<?php

namespace App\Http\Controllers;

use App\Models\User;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Hash;
use Illuminate\Validation\ValidationException;

class AuthController extends Controller
{
    public function register(Request $request)
    {
        $data = $request->validate([
            'name' => 'required|string|max:255',
            'email' => 'required|email|unique:users,email',
            'password' => 'required|string|min:8|confirmed',
        ], [
            'name.required' => 'กรุณาใส่ชื่อ',
            'name.max' => 'ชื่อยาวได้ไม่เกิน 255 ตัวอักษร',
            'email.required' => 'กรุณาใส่อีเมล',
            'email.email' => 'รูปแบบอีเมลไม่ถูกต้อง',
            'email.unique' => 'อีเมลนี้มีบัญชีอยู่แล้ว กรุณาเข้าสู่ระบบ หรือใช้อีเมลอื่น',
            'password.required' => 'กรุณาตั้งรหัสผ่าน',
            'password.min' => 'รหัสผ่านต้องมีอย่างน้อย 8 ตัวอักษร',
            'password.confirmed' => 'ยืนยันรหัสผ่านไม่ตรงกัน',
        ]);

        $user = User::create([
            'name' => $data['name'],
            'email' => $data['email'],
            'password' => Hash::make($data['password']),
        ]);

        $token = $user->createToken('family-app')->plainTextToken;

        return response()->json([
            'status' => true,
            'message' => 'สมัครสมาชิกสำเร็จ',
            'user' => $user,
            'token' => $token,
        ], 201);
    }

    public function login(Request $request)
    {
        $data = $request->validate([
            'email' => 'required|email',
            'password' => 'required',
        ], [
            'email.required' => 'กรุณาใส่อีเมล',
            'email.email' => 'รูปแบบอีเมลไม่ถูกต้อง',
            'password.required' => 'กรุณาใส่รหัสผ่าน',
        ]);

        $user = User::where('email', $data['email'])->first();

        if (!$user || !Hash::check($data['password'], $user->password)) {
            throw ValidationException::withMessages([
                'email' => ['อีเมลหรือรหัสผ่านไม่ถูกต้อง'],
            ]);
        }

        $token = $user->createToken('family-app')->plainTextToken;

        return response()->json([
            'status' => true,
            'message' => 'เข้าสู่ระบบสำเร็จ',
            'user' => $user,
            'token' => $token,
        ]);
    }

    public function logout(Request $request)
    {
        $request->user()->currentAccessToken()->delete();

        return response()->json([
            'status' => true,
            'message' => 'ออกจากระบบแล้ว',
        ]);
    }
}
