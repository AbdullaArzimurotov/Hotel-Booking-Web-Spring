\set ON_ERROR_STOP on
-- Полный цикл в транзакции. ROLLBACK сохраняет исходные демонстрационные записи.
BEGIN;
DO $$
DECLARE guest bigint; cleaner bigint; physical_room bigint; booking bigint; stay bigint;
BEGIN
    SELECT id INTO STRICT guest FROM users WHERE email='demo.guest@example.invalid';
    SELECT id INTO STRICT cleaner FROM users WHERE email='demo.cleaner@example.invalid';
    SELECT r.id INTO physical_room
    FROM find_available_rooms(hotel_today(),hotel_today()+3,1) a
    JOIN rooms r ON r.id=a.room_id WHERE r.cleaning_state='CLEAN'
    ORDER BY r.number LIMIT 1 FOR UPDATE OF r;
    IF physical_room IS NULL THEN
        RAISE EXCEPTION 'Нет чистого свободного номера для примера';
    END IF;
    INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count)
    VALUES (guest,physical_room,hotel_today(),hotel_today()+2,1)
    RETURNING id INTO booking;
    RAISE NOTICE 'Бронь создана, id=%',booking;
    INSERT INTO stays(booking_id,room_id) VALUES (booking,physical_room) RETURNING id INTO stay;
    RAISE NOTICE 'Заселение выполнено';
    UPDATE bookings SET check_out=check_out+1 WHERE id=booking;
    RAISE NOTICE 'Проживание продлено на ночь';
    UPDATE stays SET check_out_date=hotel_today() WHERE id=stay;
    RAISE NOTICE 'Выезд выполнен, создано задание на уборку';
    UPDATE cleaning_tasks SET assignee_id=cleaner,status='DONE' WHERE stay_id=stay;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE id=physical_room AND cleaning_state='CLEAN') THEN
        RAISE EXCEPTION 'Номер не подготовлен';
    END IF;
    RAISE NOTICE 'Уборка завершена; очередь писем сформирована, отправка не выполнялась';
END $$;
SELECT 'Полный цикл выполнен; изменения ниже откатываются' AS result;
ROLLBACK;
