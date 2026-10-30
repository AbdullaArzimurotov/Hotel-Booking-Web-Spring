\set ON_ERROR_STOP on
-- Данные вымышлены. Повторный запуск не перезаписывает измененные записи.
BEGIN;
INSERT INTO roles(code, name) VALUES
 ('ADMIN','Администратор'), ('RECEPTIONIST','Сотрудник приема и размещения'),
 ('GUEST','Гость'), ('CLEANER','Сотрудник уборки'), ('MANAGER','Руководитель')
ON CONFLICT (code) DO NOTHING;

-- Случайные исходные значения паролей нигде не сохраняются.
-- Эти записи предназначены для проверки данных, а не для входа в будущую программу.
INSERT INTO users(role_id, full_name, email, password_hash)
SELECT r.id, d.name, d.email, crypt(gen_random_uuid()::text, gen_salt('bf', 10))
FROM (VALUES
 ('ADMIN','Демонстрационный администратор','demo.admin@example.invalid'),
 ('RECEPTIONIST','Демонстрационный сотрудник приема','demo.reception@example.invalid'),
 ('GUEST','Демонстрационный гость','demo.guest@example.invalid'),
 ('CLEANER','Демонстрационный сотрудник уборки','demo.cleaner@example.invalid'),
 ('MANAGER','Демонстрационный руководитель','demo.manager@example.invalid')
) AS d(code,name,email) JOIN roles r ON r.code = d.code
WHERE NOT EXISTS (SELECT 1 FROM users u WHERE lower(u.email) = lower(d.email));

INSERT INTO room_types(code,name,capacity,base_price,description) VALUES
 ('SINGLE','Одноместный',1,2500.00,'Один гость'),
 ('DOUBLE','Двухместный',2,4000.00,'До двух гостей'),
 ('SUITE','Семейный',4,7000.00,'До четырех гостей')
ON CONFLICT (code) DO NOTHING;
INSERT INTO amenities(code,name) VALUES
 ('WIFI','Беспроводной интернет'),('BATHROOM','Собственная ванная'),
 ('AIR_CONDITIONER','Кондиционер'),('DESK','Рабочий стол')
ON CONFLICT (code) DO NOTHING;
INSERT INTO room_type_amenities(room_type_id,amenity_id)
SELECT t.id,a.id FROM room_types t CROSS JOIN amenities a
WHERE a.code IN ('WIFI','BATHROOM') OR t.code = 'SUITE'
ON CONFLICT DO NOTHING;
INSERT INTO rooms(number,room_type_id,in_service_from)
SELECT d.number,t.id,hotel_today() FROM
 (VALUES ('101','DOUBLE'),('102','DOUBLE'),('201','SINGLE'),
         ('202','SINGLE'),('301','SUITE'),('302','SUITE')) d(number,code)
 JOIN room_types t ON t.code = d.code
ON CONFLICT (number) DO NOTHING;

DO $$ DECLARE guest bigint; b bigint; physical_room bigint; s bigint; BEGIN
    SELECT id INTO STRICT guest FROM users WHERE email = 'demo.guest@example.invalid';
    -- Сценарий выезда в день заезда: минимальная стоимость одной ночи, требуется уборка.
    IF NOT EXISTS (SELECT 1 FROM bookings WHERE reference = 'DEMO-CLOSED-001') THEN
        SELECT id INTO STRICT physical_room FROM rooms WHERE number = '101';
        INSERT INTO bookings(reference,guest_id,room_id,check_in,check_out,guest_count)
        VALUES ('DEMO-CLOSED-001',guest,physical_room,hotel_today(),hotel_today()+1,2)
        RETURNING id INTO b;
        INSERT INTO stays(booking_id,room_id) VALUES (b,physical_room) RETURNING id INTO s;
        UPDATE stays SET check_out_date = hotel_today() WHERE id = s;
    END IF;
    -- Действующее проживание; номер нельзя повторно заселить.
    IF NOT EXISTS (SELECT 1 FROM bookings WHERE reference = 'DEMO-ACTIVE-001') THEN
        SELECT id INTO STRICT physical_room FROM rooms WHERE number = '102';
        INSERT INTO bookings(reference,guest_id,room_id,check_in,check_out,guest_count)
        VALUES ('DEMO-ACTIVE-001',guest,physical_room,hotel_today(),hotel_today()+2,1)
        RETURNING id INTO b;
        INSERT INTO stays(booking_id,room_id) VALUES (b,physical_room);
    END IF;
    -- Будущая бронь, не являющаяся фактическим проживанием.
    IF NOT EXISTS (SELECT 1 FROM bookings WHERE reference = 'DEMO-FUTURE-001') THEN
        SELECT id INTO STRICT physical_room FROM rooms WHERE number = '301';
        INSERT INTO bookings(reference,guest_id,room_id,check_in,check_out,guest_count)
        VALUES ('DEMO-FUTURE-001',guest,physical_room,hotel_today()+7,hotel_today()+10,3);
    END IF;
END $$;
COMMIT;
