<?php

namespace App\Filament\Resources\SupportTickets\Pages;

use App\Filament\Resources\SupportTickets\SupportTicketResource;
use App\Models\SupportTicket;
use App\Services\SupportDesk;
use App\Services\SupportTicketClosed;
use Filament\Actions\Action;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\Textarea;
use Filament\Notifications\Notification;
use Filament\Resources\Pages\ViewRecord;
use Filament\Support\Icons\Heroicon;
use Illuminate\Support\Facades\Auth;

// =======================================================
// ดูคำร้อง + ดำเนินการ
// - ตอบผู้ใช้: ผู้ใช้เห็น + ได้แจ้งเตือน (เปลี่ยนสถานะพร้อมกันได้)
// - บันทึกภายใน: เฉพาะทีมงาน ผู้ใช้ไม่เห็น ไม่แจ้งเตือน
// - เปลี่ยนสถานะ / ปิดเรื่อง (ต้องสรุปผลการดำเนินการ)
// ทุกการกระทำบันทึกในประวัติ (ผู้ดำเนินการ + สถานะเดิม/ใหม่)
// =======================================================

class ViewSupportTicket extends ViewRecord
{
    protected static string $resource = SupportTicketResource::class;

    protected function getHeaderActions(): array
    {
        $open = fn (SupportTicket $record) => !$record->isClosed();

        $statusOptions = collect(SupportTicket::STATUS_LABELS)->except(SupportTicket::STATUS_CLOSED)->all();

        return [
            Action::make('reply')
                ->label('ตอบผู้ใช้')
                ->icon(Heroicon::OutlinedChatBubbleLeftRight)
                ->color('primary')
                ->visible($open)
                ->modalHeading('ตอบผู้ใช้ (ผู้ใช้จะเห็นข้อความนี้และได้รับแจ้งเตือน)')
                ->schema([
                    Textarea::make('body')
                        ->label('ข้อความถึงผู้ใช้')
                        ->helperText('ห้ามใส่ข้อมูลภายในทีมงาน ใช้ "บันทึกภายใน" แทน')
                        ->required()
                        ->rows(5)
                        ->maxLength(3000),
                    Select::make('status')
                        ->label('เปลี่ยนสถานะพร้อมกัน')
                        ->options($statusOptions)
                        ->placeholder('ไม่เปลี่ยน'),
                ])
                ->action(fn (SupportTicket $record, array $data) => $this->run(
                    fn () => app(SupportDesk::class)->reply($record, Auth::user(), $data['body'], $data['status'] ?? null),
                    'ส่งคำตอบถึงผู้ใช้แล้ว'
                )),

            Action::make('note')
                ->label('บันทึกภายใน')
                ->icon(Heroicon::OutlinedLockClosed)
                ->color('gray')
                ->modalHeading('บันทึกภายในทีมงาน (ผู้ใช้ไม่เห็น)')
                ->schema([
                    Textarea::make('body')
                        ->label('บันทึก')
                        ->required()
                        ->rows(4)
                        ->maxLength(3000),
                ])
                ->action(fn (SupportTicket $record, array $data) => $this->run(
                    fn () => app(SupportDesk::class)->note($record, Auth::user(), $data['body']),
                    'บันทึกภายในแล้ว'
                )),

            Action::make('status')
                ->label('เปลี่ยนสถานะ')
                ->icon(Heroicon::OutlinedArrowPath)
                ->color('gray')
                ->visible($open)
                ->schema([
                    Select::make('status')
                        ->label('สถานะใหม่')
                        ->options($statusOptions)
                        ->required(),
                    Textarea::make('note')
                        ->label('เหตุผล (บันทึกในประวัติ ผู้ใช้ไม่เห็น)')
                        ->rows(2)
                        ->maxLength(300),
                ])
                ->action(fn (SupportTicket $record, array $data) => $this->run(
                    fn () => app(SupportDesk::class)->changeStatus($record, Auth::user(), $data['status'], $data['note'] ?? null),
                    'เปลี่ยนสถานะแล้ว'
                )),

            Action::make('close')
                ->label('ปิดเรื่อง')
                ->icon(Heroicon::OutlinedCheckCircle)
                ->color('success')
                ->visible($open)
                ->modalHeading('ปิดเรื่อง')
                ->modalDescription('ผู้ใช้จะเห็นสรุปผล และส่งข้อความเพิ่มในเรื่องนี้ไม่ได้ (สร้างเรื่องใหม่โดยอ้างอิงเรื่องนี้ได้)')
                ->schema([
                    Textarea::make('resolution')
                        ->label('สรุปผลการดำเนินการ (ผู้ใช้เห็น)')
                        ->required()
                        ->rows(4)
                        ->maxLength(2000),
                    Textarea::make('message')
                        ->label('ข้อความถึงผู้ใช้ (ไม่บังคับ)')
                        ->rows(3)
                        ->maxLength(3000),
                ])
                ->action(fn (SupportTicket $record, array $data) => $this->run(
                    fn () => app(SupportDesk::class)->close($record, Auth::user(), $data['resolution'], $data['message'] ?? null),
                    'ปิดเรื่องแล้ว'
                )),
        ];
    }

    private function run(callable $work, string $done): void
    {
        try {
            $work();
        } catch (SupportTicketClosed $e) {
            Notification::make()->danger()->title('ทำไม่ได้')->body($e->getMessage())->send();

            return;
        }

        $this->record->refresh();

        Notification::make()->success()->title($done)->send();
    }
}
