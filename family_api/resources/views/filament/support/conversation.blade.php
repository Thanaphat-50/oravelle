{{-- ข้อความในคำร้อง (หลังบ้าน): ผู้ใช้ / ทีมงาน / บันทึกภายใน + รูปแนบ (ลิงก์ชั่วคราว) --}}
@php
    /** @var \App\Models\SupportTicket $record */
    $record = $getRecord();
    $messages = $record->messages()->with(['attachments', 'author:id,name'])->get();
@endphp

<div style="display:flex;flex-direction:column;gap:12px">
    @forelse ($messages as $message)
        @php
            $style = match (true) {
                $message->is_internal => 'background:#fef3c7;border:1px dashed #d97706',
                $message->is_staff => 'background:#eef2ff;border:1px solid #c7d2fe',
                default => 'background:#f9fafb;border:1px solid #e5e7eb',
            };
            $who = match (true) {
                $message->is_internal => '🔒 บันทึกภายใน (ผู้ใช้ไม่เห็น) · ' . ($message->author?->name ?? 'ทีมงาน'),
                $message->is_staff => 'ตอบผู้ใช้ · ' . ($message->author?->name ?? 'ทีมงาน'),
                default => 'ผู้ใช้ · ' . ($message->author?->name ?? 'ผู้ใช้'),
            };
        @endphp

        <div style="{{ $style }};border-radius:12px;padding:12px;color:#111827">
            <div style="font-size:12px;color:#6b7280;margin-bottom:6px">
                {{ $who }} · {{ $message->created_at?->timezone('Asia/Bangkok')->format('d/m/Y H:i') }}
            </div>

            @if (filled($message->body))
                <div style="white-space:pre-wrap;font-size:14px">{{ $message->body }}</div>
            @endif

            @if ($message->attachments->isNotEmpty())
                <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:8px">
                    @foreach ($message->attachments as $attachment)
                        <a href="{{ $attachment->signedUrl() }}" target="_blank" rel="noopener">
                            <img src="{{ $attachment->signedUrl() }}" alt="รูปแนบ"
                                 style="width:120px;height:120px;object-fit:cover;border-radius:8px;border:1px solid #e5e7eb">
                        </a>
                    @endforeach
                </div>
            @endif
        </div>
    @empty
        <div style="color:#6b7280">ยังไม่มีข้อความ</div>
    @endforelse
</div>
