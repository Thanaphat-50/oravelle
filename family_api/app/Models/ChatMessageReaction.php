<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

// Reaction ของข้อความ (1 คน 1 Reaction ต่อข้อความ — unique)
class ChatMessageReaction extends Model
{
    protected $table = 'chat_message_reactions';

    protected $fillable = [
        'chat_message_id',
        'user_id',
        'emoji',
    ];

    public function message()
    {
        return $this->belongsTo(ChatMessage::class, 'chat_message_id');
    }
}
