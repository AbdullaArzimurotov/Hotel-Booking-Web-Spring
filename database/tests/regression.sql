\set ON_ERROR_STOP on
-- Запускается только тестовым исполнителем в одноразовой базе.
DO $$ BEGIN
    IF current_database() !~ '^hotel_booking_web_test_[0-9a-f]{8}$' THEN
        RAISE EXCEPTION 'Регрессионные тесты разрешены только во временной тестовой базе';
    END IF;
END $$;
BEGIN;
CREATE TEMP TABLE test_results(name text PRIMARY KEY, result text NOT NULL);
CREATE FUNCTION pg_temp.ok(condition boolean, label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION 'Проверка не пройдена: %',label; END IF;
    INSERT INTO test_results VALUES (label,'ПРОЙДЕНО');
END $$;
CREATE FUNCTION pg_temp.rejects(command text, expected_state text, label text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE observed text; rejected boolean := false;
BEGIN
    BEGIN
        EXECUTE command;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS observed = RETURNED_SQLSTATE;
        IF observed <> expected_state THEN
            RAISE EXCEPTION 'Проверка %: ожидался SQLSTATE %, получен %: %',label,expected_state,observed,SQLERRM;
        END IF;
        rejected := true;
    END;
    PERFORM pg_temp.ok(rejected,label);
END $$;

DO $$
DECLARE guest bigint; cleaner bigint; role_guest bigint; hash text; typ bigint;
        room_a bigint; room_b bigint; room_single bigint; room_blocked bigint;
        b1 bigint; b2 bigint; bs bigint; active_stay bigint; task bigint;
        original_calendar text; initial_day date; notices bigint; final_cost numeric;
BEGIN
    SELECT id,role_id,password_hash INTO STRICT guest,role_guest,hash
    FROM users WHERE email='demo.guest@example.invalid';
    SELECT id INTO STRICT cleaner FROM users WHERE email='demo.cleaner@example.invalid';
    initial_day := hotel_today();
    SELECT pg_get_functiondef('hotel_today()'::regprocedure) INTO original_calendar;

    PERFORM pg_temp.ok((SELECT count(*)=10 FROM information_schema.tables
        WHERE table_schema='public' AND table_type='BASE TABLE'),'01. Установлено 10 таблиц');
    PERFORM pg_temp.ok((SELECT count(*)=5 FROM roles),'02. Пять ролей');
    PERFORM pg_temp.rejects(format('INSERT INTO users(role_id,full_name,email,password_hash) VALUES (%s,%L,%L,%L)',
        role_guest,'Проверка','DEMO.GUEST@EXAMPLE.INVALID',hash),'23505','03. Email уникален без учета регистра');
    PERFORM pg_temp.rejects(format('INSERT INTO users(role_id,full_name,email,password_hash) VALUES (-1,%L,%L,%L)',
        'Проверка','fk@example.invalid',hash),'23503','04. Внешний ключ роли');
    PERFORM pg_temp.rejects(format('INSERT INTO users(role_id,full_name,email,password_hash) VALUES (%s,NULL,%L,%L)',
        role_guest,'null@example.invalid',hash),'23502','05. Обязательное имя');
    PERFORM pg_temp.rejects('INSERT INTO room_types(code,name,capacity,base_price) VALUES (''TEST_BAD'',''Тест'',0,100)',
        '23514','06. Положительная вместимость');
    PERFORM pg_temp.rejects('INSERT INTO room_types(code,name,capacity,base_price) VALUES (''TEST_BAD'',''Тест'',1,-1)',
        '23514','07. Положительный тариф');

    INSERT INTO room_types(code,name,capacity,base_price) VALUES ('TEST_DOUBLE','Тестовый',2,4000) RETURNING id INTO typ;
    INSERT INTO rooms(number,room_type_id) VALUES ('TEST-A',typ) RETURNING id INTO room_a;
    INSERT INTO rooms(number,room_type_id) VALUES ('TEST-B',typ) RETURNING id INTO room_b;
    INSERT INTO rooms(number,room_type_id,operational_status) VALUES ('TEST-BLOCK',typ,'MAINTENANCE')
        RETURNING id INTO room_blocked;
    SELECT r.id INTO room_single FROM rooms r JOIN room_types t ON t.id=r.room_type_id WHERE r.number='201';
    PERFORM pg_temp.rejects(format('INSERT INTO rooms(number,room_type_id) VALUES (''TEST-A'',%s)',typ),
        '23505','08. Уникальный номер комнаты');
    PERFORM pg_temp.rejects(format('INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count) VALUES (%s,%s,hotel_today(),hotel_today(),1)',guest,room_a),
        '23514','09. Выезд позднее заезда');
    PERFORM pg_temp.rejects(format('INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count) VALUES (%s,%s,hotel_today()-1,hotel_today()+1,1)',guest,room_a),
        '23514','10. Нет брони в прошлом');
    PERFORM pg_temp.rejects(format('INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count) VALUES (%s,%s,hotel_today()+30,hotel_today()+31,2)',guest,room_single),
        '23514','11. Вместимость проверяется по типу');
    PERFORM pg_temp.rejects(format('INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count) VALUES (%s,%s,hotel_today()+30,hotel_today()+31,1)',guest,room_blocked),
        '23514','12. Блокировка номера');

    INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count,nightly_price)
    VALUES (guest,room_a,initial_day+30,initial_day+33,2,1) RETURNING id INTO b1;
    PERFORM pg_temp.ok((SELECT nightly_price=4000 FROM bookings WHERE id=b1),'13. Тариф назначает сервер базы');
    PERFORM pg_temp.rejects(format('INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count) VALUES (%s,%s,hotel_today()+31,hotel_today()+34,1)',guest,room_a),
        '23P01','14. Пересекающаяся бронь отклоняется');
    INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count)
    VALUES (guest,room_a,initial_day+33,initial_day+35,1) RETURNING id INTO b2;
    PERFORM pg_temp.ok(b2 IS NOT NULL,'15. Соседние брони разрешены');
    UPDATE room_types SET base_price=5000 WHERE id=typ;
    PERFORM pg_temp.ok((SELECT nightly_price=4000 FROM bookings WHERE id=b1),'16. Изменение тарифа не меняет бронь');
    PERFORM pg_temp.rejects(format('UPDATE room_types SET capacity=1 WHERE id=%s',typ),
        '23514','17. Уменьшение вместимости не нарушает бронь');
    PERFORM pg_temp.rejects(format('UPDATE bookings SET check_out=check_out+1 WHERE id=%s',b1),
        '23P01','18. Конфликтующее продление запрещено');
    PERFORM pg_temp.ok((SELECT check_out=initial_day+33 FROM bookings WHERE id=b1),'19. Отказ не изменяет срок');
    UPDATE bookings SET status='CANCELLED' WHERE id=b2;
    UPDATE bookings SET check_out=initial_day+34 WHERE id=b1;
    PERFORM pg_temp.ok((SELECT check_out=initial_day+34 FROM bookings WHERE id=b1),'20. Отмена освобождает даты');
    PERFORM pg_temp.rejects(format('UPDATE bookings SET nightly_price=1 WHERE id=%s',b1),
        '23514','21. Снимок цены неизменяем');
    PERFORM pg_temp.rejects(format('UPDATE bookings SET status=''CHECKED_IN'' WHERE id=%s',b1),
        '23514','22. Статус не заменяет реальное заселение');
    PERFORM pg_temp.rejects(format('DELETE FROM bookings WHERE id=%s',b1),
        '23514','23. История не удаляется');

    INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count)
    VALUES (guest,room_b,initial_day,initial_day+2,2) RETURNING id INTO bs;
    UPDATE rooms SET cleaning_state='DIRTY' WHERE id=room_b;
    PERFORM pg_temp.rejects(format('INSERT INTO stays(booking_id,room_id) VALUES (%s,%s)',bs,room_b),
        '23514','24. В грязный номер не заселяют');
    UPDATE rooms SET cleaning_state='CLEAN',operational_status='MAINTENANCE' WHERE id=room_b;
    PERFORM pg_temp.rejects(format('INSERT INTO stays(booking_id,room_id) VALUES (%s,%s)',bs,room_b),
        '23514','25. Заселение в заблокированный номер запрещено');
    UPDATE rooms SET operational_status='AVAILABLE' WHERE id=room_b;
    PERFORM pg_temp.rejects(format('INSERT INTO stays(booking_id,room_id) VALUES (%s,%s)',bs,room_a),
        '23503','26. Номер проживания согласован с бронью');
    INSERT INTO stays(booking_id,room_id) VALUES (bs,room_b) RETURNING id INTO active_stay;
    PERFORM pg_temp.ok((SELECT status='CHECKED_IN' FROM bookings WHERE id=bs),'27. Заселение меняет состояние брони');
    PERFORM pg_temp.rejects(format('INSERT INTO stays(booking_id,room_id) VALUES (%s,%s)',bs,room_b),
        '23514','28. Повторное активное проживание запрещено');
    PERFORM pg_temp.rejects(format('UPDATE rooms SET operational_status=''MAINTENANCE'' WHERE id=%s',room_b),
        '23514','29. Занятый номер не блокируется под ремонт');

    -- Моделирование времени изолировано одноразовой БД и откатывается транзакцией.
    EXECUTE format('CREATE OR REPLACE FUNCTION hotel_today() RETURNS date LANGUAGE sql STABLE AS %L',
        'SELECT DATE ' || quote_literal(initial_day::text) || ' + 3');
    PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM find_available_rooms(hotel_today()+1,hotel_today()+2,1)
                                  WHERE room_id=room_b),'30. Просроченный выезд удерживает физический номер');
    PERFORM pg_temp.rejects(format('INSERT INTO bookings(guest_id,room_id,check_in,check_out,guest_count) VALUES (%s,%s,hotel_today()+1,hotel_today()+2,1)',guest,room_b),
        '23514','31. Повторная проверка учитывает просроченный выезд');
    UPDATE stays SET check_out_date=hotel_today() WHERE id=active_stay;
    SELECT final_amount INTO final_cost FROM v_stay_history WHERE id=active_stay;
    PERFORM pg_temp.ok(final_cost=15000,'32. Три фактические ночи по сохраненному тарифу');
    PERFORM pg_temp.ok((SELECT status='COMPLETED' FROM bookings WHERE id=bs),'33. Выезд завершает бронь');
    PERFORM pg_temp.ok((SELECT cleaning_state='DIRTY' FROM rooms WHERE id=room_b),'34. Выезд требует уборки');
    SELECT id INTO STRICT task FROM cleaning_tasks WHERE stay_id=active_stay;
    UPDATE stays SET check_out_date=hotel_today() WHERE id=active_stay;
    PERFORM pg_temp.ok((SELECT count(*)=1 FROM cleaning_tasks WHERE stay_id=active_stay),'35. Повтор выезда не дублирует задание');
    PERFORM pg_temp.rejects(format('INSERT INTO cleaning_tasks(stay_id,room_id) VALUES (%s,%s)',active_stay,room_b),
        '23505','36. На выезд только одно задание');
    PERFORM pg_temp.rejects(format('UPDATE rooms SET cleaning_state=''CLEAN'' WHERE id=%s',room_b),
        '23514','37. Нельзя обойти незавершенную уборку');
    PERFORM pg_temp.rejects(format('UPDATE cleaning_tasks SET status=''DONE'',assignee_id=%s WHERE id=%s',guest,task),
        '23514','38. Гость не исполнитель уборки');
    UPDATE rooms SET operational_status='MAINTENANCE' WHERE id=room_b;
    UPDATE cleaning_tasks SET status='DONE',assignee_id=cleaner WHERE id=task;
    PERFORM pg_temp.ok((SELECT cleaning_state='CLEAN' AND operational_status='MAINTENANCE' FROM rooms WHERE id=room_b),
        '39. Уборка не снимает эксплуатационную блокировку');
    PERFORM pg_temp.ok(NOT EXISTS (SELECT 1 FROM v_cleaning_queue WHERE id=task),'40. Выполненное задание уходит из очереди');
    PERFORM pg_temp.ok((SELECT status='COMPLETED' FROM v_stay_history WHERE id=active_stay),'41. История содержит завершенное проживание');
    PERFORM pg_temp.ok((SELECT count(*)=1 FROM email_notifications WHERE booking_id=bs AND event_code='BOOKING_CONFIRMED'),
        '42. Подтверждение создает одно уведомление');
    PERFORM pg_temp.ok((SELECT count(*)=1 FROM email_notifications WHERE booking_id=b2 AND event_code='BOOKING_CANCELLED'),
        '43. Отмена создает уведомление');
    SELECT count(*) INTO notices FROM email_notifications WHERE booking_id=b1;
    UPDATE bookings SET guest_count=guest_count WHERE id=b1;
    PERFORM pg_temp.ok((SELECT count(*)=notices FROM email_notifications WHERE booking_id=b1),'44. Повтор без изменений не дублирует письмо');
    PERFORM pg_temp.rejects(format('UPDATE email_notifications SET status=''SENT'' WHERE booking_id=%s',bs),
        '23514','45. Отправка требует отметки времени');
    PERFORM pg_temp.ok((SELECT sum(finalized_revenue_rub)=19000 FROM hotel_report(initial_day,initial_day+3)),
        '46. Три ночи и минимальное начисление отражены в отчете');
    PERFORM pg_temp.ok((SELECT sum(occupied_nights)=6 FROM hotel_report(initial_day,initial_day+3)),
        '47. Два проживания по три ночи дают шесть номеро-ночей');
    PERFORM pg_temp.ok((SELECT sum(finalized_revenue_rub)=10000 FROM hotel_report(initial_day+1,initial_day+3)),
        '48. Граница отчета включает только две ночи');
    PERFORM pg_temp.ok((SELECT occupancy_percent IS NULL FROM hotel_report(initial_day-1,initial_day)),
        '49. При нулевой емкости нет деления на ноль');
    PERFORM pg_temp.rejects('SELECT * FROM hotel_report(hotel_today()+2,hotel_today()+3)',
        '23514','50. Фактический отчет не приписывает данные будущему');
    EXECUTE original_calendar;
    PERFORM pg_temp.ok(hotel_today()=initial_day,'51. Календарь восстановлен');
END $$;
SELECT name,result FROM test_results ORDER BY name;
SELECT count(*) AS successful_checks FROM test_results;
ROLLBACK;
