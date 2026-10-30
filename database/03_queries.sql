\set ON_ERROR_STOP on
-- Примеры чтения не изменяют базу. Параметры функций можно заменить своими.
SELECT current_database() AS database_name, hotel_today() AS hotel_date;

-- Предварительно доступные номера на три ночи через месяц, для двух гостей.
SELECT * FROM find_available_rooms(hotel_today()+30, hotel_today()+33, 2);

-- Список броней и плановая стоимость по сохраненному тарифу.
SELECT reference, room_number, check_in, check_out, status, planned_amount, currency
FROM v_booking_details ORDER BY id;

-- История только выбранного гостя: приложение обязано подставлять id из сеанса.
SELECT h.reference, h.room_number, h.check_in_date, h.check_out_date,
       h.status, h.final_amount, h.preliminary_amount, h.currency
FROM v_stay_history h JOIN users u ON u.id = h.guest_id
WHERE u.email = 'demo.guest@example.invalid' ORDER BY h.id;

SELECT * FROM v_cleaning_queue ORDER BY created_at, id;

-- Очередь уведомлений: на втором этапе SMTP-отправка еще не реализована.
SELECT event_code, status, count(*) AS quantity
FROM email_notifications GROUP BY event_code,status ORDER BY event_code,status;
