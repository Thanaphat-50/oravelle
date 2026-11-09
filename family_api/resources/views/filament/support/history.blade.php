{{-- ประวัติคำร้อง: ผู้ดำเนินการ / การเปลี่ยนสถานะ (ทีมงานเห็นเท่านั้น) --}}
@php
    /** @var \App\Models\SupportTicket $record */
    $record = $getRecord();
    $events = $record->events()->with('actor:id,name')->get();
    $label = fn (?string $status) => $status ? (\App\Models\SupportTicket::STATUS_LABELS[$status] ?? $status) : null;
@endphp

<table style="width:100%;font-size:13px;border-collapse:collapse">
    <thead>
        <tr style="text-align:left;color:#6b7280">
            <th style="padding:6px">เวลา</th>
            <th style="padding:6px">ผู้ดำเนินการ</th>
            <th style="padding:6px">การกระทำ</th>
            <th style="padding:6px">สถานะ</th>
            <th style="padding:6px">หมายเหตุ</th>
        </tr>
    </thead>
    <tbody>
        @foreach ($events as $event)
            <tr style="border-top:1px solid #e5e7eb">
                <td style="padding:6px;white-space:nowrap">{{ $event->created_at?->timezone('Asia/Bangkok')->format('d/m/Y H:i') }}</td>
                <td style="padding:6px">
                    {{ match ($event->actor_role) { 'staff' => 'ทีมงาน', 'system' => 'ระบบ', default => 'ผู้ใช้' } }}
                    @if ($event->actor) · {{ $event->actor->name }} @endif
                </td>
                <td style="padding:6px">{{ \App\Models\SupportTicketEvent::TYPE_LABELS[$event->type] ?? $event->type }}</td>
                <td style="padding:6px">
                    @if ($event->to_status)
                        {{ $label($event->from_status) ?? '-' }} → {{ $label($event->to_status) }}
                    @endif
                </td>
                <td style="padding:6px">{{ $event->note }}</td>
            </tr>
        @endforeach
    </tbody>
</table>
