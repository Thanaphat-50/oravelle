<?php

// แจ้งเตือนกิจกรรมล่วงหน้า (App\Models\ActivityReminder / activities:send-reminders)
$every = max(1, (int) env('ACTIVITY_REMINDER_EVERY_MINUTES', 5));

return [
    // Scheduler รันส่งทุกกี่นาที (ยิ่งถี่ยิ่งตรงเวลา แต่แอปที่ Scale to zero จะถูกปลุกบ่อย → ค่าเครื่องเพิ่ม)
    'every_minutes' => $every,

    // ช้ากว่ากำหนดได้ไม่เกินเท่านี้ เกินแล้วไม่ส่ง (ต้องมากกว่ารอบส่ง)
    'grace_minutes' => max(15, $every * 2),
];
