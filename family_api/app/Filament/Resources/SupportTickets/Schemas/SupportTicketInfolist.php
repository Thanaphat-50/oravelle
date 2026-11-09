<?php

namespace App\Filament\Resources\SupportTickets\Schemas;

use App\Models\SupportTicket;
use Filament\Infolists\Components\TextEntry;
use Filament\Infolists\Components\ViewEntry;
use Filament\Schemas\Components\Section;
use Filament\Schemas\Schema;

class SupportTicketInfolist
{
    public static function configure(Schema $schema): Schema
    {
        return $schema
            ->columns(1)
            ->components([
                Section::make('คำร้อง')
                    ->columns(3)
                    ->schema([
                        TextEntry::make('code')->label('เลขคำร้อง')->copyable(),
                        TextEntry::make('status')
                            ->label('สถานะ')
                            ->badge()
                            ->formatStateUsing(fn (string $state) => SupportTicket::STATUS_LABELS[$state] ?? $state),
                        TextEntry::make('category')
                            ->label('ประเภท')
                            ->formatStateUsing(fn (string $state) => SupportTicket::CATEGORY_LABELS[$state] ?? $state),
                        TextEntry::make('subject')->label('หัวข้อ')->columnSpanFull(),
                        TextEntry::make('user.name')
                            ->label('ผู้ใช้')
                            ->formatStateUsing(fn ($state, SupportTicket $record) => $state . ' (ID ' . $record->user_id . ')'),
                        TextEntry::make('user.email')->label('อีเมล')->copyable(),
                        TextEntry::make('order_code')
                            ->label('คำสั่งซื้อ')
                            ->placeholder('-')
                            ->url(fn (SupportTicket $record) => $record->order_code
                                ? route('filament.admin.resources.orders.index', ['tableSearch' => $record->order_code])
                                : null),
                        TextEntry::make('previousTicket.code')->label('อ้างอิงเรื่องเดิม')->placeholder('-'),
                        TextEntry::make('created_at')->label('สร้างเมื่อ')->dateTime(),
                        TextEntry::make('last_activity_at')->label('อัปเดตล่าสุด')->since(),
                        TextEntry::make('resolution')
                            ->label('สรุปผล (ผู้ใช้เห็น)')
                            ->placeholder('ยังไม่ปิดเรื่อง')
                            ->columnSpanFull(),
                    ]),

                // ข้อความทั้งหมดตามเวลา: ผู้ใช้ / ทีมงาน / บันทึกภายใน (แยกสีชัดเจน) + รูปแนบ
                Section::make('ข้อความ')
                    ->schema([
                        ViewEntry::make('messages')
                            ->hiddenLabel()
                            ->view('filament.support.conversation'),
                    ]),

                Section::make('ประวัติการดำเนินการ')
                    ->collapsed()
                    ->schema([
                        ViewEntry::make('events')
                            ->hiddenLabel()
                            ->view('filament.support.history'),
                    ]),
            ]);
    }
}
