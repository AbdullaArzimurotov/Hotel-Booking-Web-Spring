\set ON_ERROR_STOP on
-- Начальная миграция v1. Запускается только внутри отдельной базы проекта.
DO $$ BEGIN
    IF current_database() <> 'hotel_booking_web' AND
       current_database() !~ '^hotel_booking_web_test_[0-9a-f]{8}$' THEN
        RAISE EXCEPTION 'Схема предназначена только для базы hotel_booking_web';
    END IF;
    IF current_setting('server_version_num')::integer < 180000 THEN
        RAISE EXCEPTION 'Требуется PostgreSQL 18 или новее';
    END IF;
END $$;
SELECT COALESCE(obj_description('public'::regnamespace, 'pg_namespace') =
    'hotel_booking_web:schema:v1', false) AS initialized \gset
\if :initialized
    \echo 'Схема v1 уже установлена; данные сохранены.'
\else
BEGIN;
SET LOCAL search_path = public, pg_catalog;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Календарь одной гостиницы; не зависит от часового пояса клиентского сеанса.
CREATE FUNCTION hotel_today() RETURNS date LANGUAGE sql STABLE AS $$
    SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Europe/Moscow')::date
$$;

CREATE TABLE roles (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code varchar(30) NOT NULL UNIQUE,
    name varchar(120) NOT NULL CHECK (btrim(name) <> ''),
    CONSTRAINT roles_code_check CHECK (code IN
        ('ADMIN', 'RECEPTIONIST', 'GUEST', 'CLEANER', 'MANAGER'))
);
CREATE TABLE users (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_id bigint NOT NULL REFERENCES roles(id) ON DELETE RESTRICT,
    full_name varchar(160) NOT NULL CHECK (btrim(full_name) <> ''),
    email varchar(254) NOT NULL CHECK
        (email = btrim(email) AND email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'),
    password_hash varchar(60) NOT NULL CHECK
        (password_hash ~ '^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'),
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX users_email_ci_key ON users(lower(email));
CREATE INDEX users_role_idx ON users(role_id);

CREATE TABLE room_types (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code varchar(30) NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    name varchar(120) NOT NULL CHECK (btrim(name) <> ''),
    capacity smallint NOT NULL CHECK (capacity > 0),
    base_price numeric(12,2) NOT NULL CHECK (base_price > 0),
    description text NOT NULL DEFAULT ''
);
CREATE TABLE amenities (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code varchar(40) NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    name varchar(120) NOT NULL CHECK (btrim(name) <> '')
);
CREATE TABLE room_type_amenities (
    room_type_id bigint NOT NULL REFERENCES room_types(id) ON DELETE RESTRICT,
    amenity_id bigint NOT NULL REFERENCES amenities(id) ON DELETE RESTRICT,
    PRIMARY KEY (room_type_id, amenity_id)
);
CREATE INDEX room_type_amenities_amenity_idx ON room_type_amenities(amenity_id);
CREATE TABLE rooms (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    number varchar(12) NOT NULL UNIQUE CHECK (btrim(number) <> ''),
    room_type_id bigint NOT NULL REFERENCES room_types(id) ON DELETE RESTRICT,
    in_service_from date NOT NULL DEFAULT hotel_today(),
    operational_status varchar(20) NOT NULL DEFAULT 'AVAILABLE'
        CHECK (operational_status IN ('AVAILABLE', 'MAINTENANCE')),
    cleaning_state varchar(10) NOT NULL DEFAULT 'CLEAN'
        CHECK (cleaning_state IN ('CLEAN', 'DIRTY')),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX rooms_type_idx ON rooms(room_type_id);

CREATE TABLE bookings (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference varchar(40) NOT NULL UNIQUE DEFAULT
        ('B-' || replace(gen_random_uuid()::text, '-', '')),
    guest_id bigint NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    room_id bigint NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
    check_in date NOT NULL,
    check_out date NOT NULL,
    guest_count smallint NOT NULL CHECK (guest_count > 0),
    nightly_price numeric(12,2) NOT NULL CHECK (nightly_price > 0),
    currency char(3) NOT NULL DEFAULT 'RUB' CHECK (currency = 'RUB'),
    status varchar(15) NOT NULL DEFAULT 'CONFIRMED' CHECK
        (status IN ('CONFIRMED', 'CHECKED_IN', 'COMPLETED', 'CANCELLED')),
    period daterange GENERATED ALWAYS AS (daterange(check_in, check_out, '[)')) STORED,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT bookings_dates_check CHECK (check_out > check_in),
    -- Составной ключ позволяет проверить совпадение номера в проживании.
    CONSTRAINT bookings_id_room_key UNIQUE (id, room_id),
    -- Ограничение действует и для конкурирующих транзакций, а не только поиска.
    CONSTRAINT bookings_no_overlap EXCLUDE USING gist
        (room_id WITH =, period WITH &&)
        WHERE (status IN ('CONFIRMED', 'CHECKED_IN'))
);
CREATE INDEX bookings_guest_idx ON bookings(guest_id);
CREATE INDEX bookings_room_idx ON bookings(room_id);

CREATE TABLE stays (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id bigint NOT NULL UNIQUE,
    room_id bigint NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
    check_in_date date NOT NULL DEFAULT hotel_today(),
    check_out_date date,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    closed_at timestamptz,
    CONSTRAINT stays_booking_room_fk FOREIGN KEY (booking_id, room_id)
        REFERENCES bookings(id, room_id) ON DELETE RESTRICT,
    CONSTRAINT stays_dates_check CHECK
        (check_out_date IS NULL OR check_out_date >= check_in_date),
    CONSTRAINT stays_closed_at_check CHECK
        ((check_out_date IS NULL) = (closed_at IS NULL))
);
-- Незавершенное проживание удерживает физический номер даже после срока брони.
CREATE UNIQUE INDEX stays_one_active_room ON stays(room_id)
    WHERE check_out_date IS NULL;

CREATE TABLE cleaning_tasks (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    stay_id bigint NOT NULL UNIQUE REFERENCES stays(id) ON DELETE RESTRICT,
    room_id bigint NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
    assignee_id bigint REFERENCES users(id) ON DELETE RESTRICT,
    status varchar(10) NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING', 'DONE')),
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamptz,
    CONSTRAINT cleaning_completion_check CHECK
        ((status = 'PENDING' AND completed_at IS NULL)
         OR (status = 'DONE' AND completed_at IS NOT NULL AND assignee_id IS NOT NULL))
);
CREATE UNIQUE INDEX cleaning_one_pending_room ON cleaning_tasks(room_id)
    WHERE status = 'PENDING';
CREATE INDEX cleaning_assignee_idx ON cleaning_tasks(assignee_id);

CREATE TABLE email_notifications (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_id bigint NOT NULL REFERENCES bookings(id) ON DELETE RESTRICT,
    recipient_email varchar(254) NOT NULL,
    event_code varchar(30) NOT NULL CHECK
        (event_code IN ('BOOKING_CONFIRMED', 'BOOKING_CANCELLED', 'BOOKING_CHANGED')),
    event_key varchar(160) NOT NULL UNIQUE,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(payload) = 'object'),
    status varchar(10) NOT NULL DEFAULT 'PENDING' CHECK
        (status IN ('PENDING', 'SENT', 'FAILED')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    last_error text,
    created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
    sent_at timestamptz,
    CONSTRAINT email_sent_at_check CHECK ((status = 'SENT') = (sent_at IS NOT NULL))
);
CREATE INDEX email_pending_idx ON email_notifications(created_at)
    WHERE status IN ('PENDING', 'FAILED');
CREATE INDEX email_booking_idx ON email_notifications(booking_id);

CREATE FUNCTION guard_booking() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE r rooms%ROWTYPE; t room_types%ROWTYPE;
BEGIN
    SELECT * INTO r FROM rooms WHERE id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Номер не существует' USING ERRCODE = '23503';
    END IF;
    SELECT * INTO t FROM room_types WHERE id = r.room_type_id;
    IF NEW.check_out <= NEW.check_in THEN
        RAISE EXCEPTION 'Выезд должен быть позднее заезда' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'CONFIRMED' OR NEW.check_in < hotel_today()
           OR NEW.check_in < r.in_service_from THEN
            RAISE EXCEPTION 'Недопустимое начальное состояние или дата брони'
                USING ERRCODE = '23514';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM users u JOIN roles ro ON ro.id = u.role_id
                       WHERE u.id = NEW.guest_id AND u.enabled AND ro.code = 'GUEST') THEN
            RAISE EXCEPTION 'Бронь оформляется для действующего гостя'
                USING ERRCODE = '23514';
        END IF;
        IF r.operational_status <> 'AVAILABLE' OR EXISTS
           (SELECT 1 FROM stays st JOIN bookings bo ON bo.id = st.booking_id
            WHERE st.room_id = r.id AND st.check_out_date IS NULL AND bo.check_out <= hotel_today()) THEN
            RAISE EXCEPTION 'Номер заблокирован' USING ERRCODE = '23514';
        END IF;
        -- Клиент не может подставить свою цену вместо действующего тарифа.
        NEW.nightly_price := t.base_price;
    ELSE
        IF NEW IS NOT DISTINCT FROM OLD THEN RETURN NEW; END IF;
        IF (NEW.guest_id, NEW.room_id, NEW.nightly_price, NEW.currency,
            NEW.reference, NEW.created_at, NEW.id)
           IS DISTINCT FROM
           (OLD.guest_id, OLD.room_id, OLD.nightly_price, OLD.currency,
            OLD.reference, OLD.created_at, OLD.id) THEN
            RAISE EXCEPTION 'Владелец, номер и сохраненные условия неизменяемы'
                USING ERRCODE = '23514';
        END IF;
        IF OLD.status IN ('COMPLETED', 'CANCELLED') THEN
            RAISE EXCEPTION 'Завершенная или отмененная бронь неизменяема'
                USING ERRCODE = '23514';
        END IF;
        IF OLD.status = 'CHECKED_IN' AND
           (NEW.check_in <> OLD.check_in OR NEW.guest_count <> OLD.guest_count
            OR NEW.check_out < OLD.check_out) THEN
            RAISE EXCEPTION 'После заселения разрешено только продление срока'
                USING ERRCODE = '23514';
        END IF;
        IF (NEW.check_in, NEW.check_out, NEW.guest_count) IS DISTINCT FROM
           (OLD.check_in, OLD.check_out, OLD.guest_count) THEN
            IF NEW.status <> OLD.status OR r.operational_status <> 'AVAILABLE'
               OR (OLD.status = 'CONFIRMED' AND NEW.check_in < hotel_today())
               OR NEW.check_in < r.in_service_from THEN
                RAISE EXCEPTION 'Невозможно изменить условия брони' USING ERRCODE = '23514';
            END IF;
        END IF;
        IF NEW.status <> OLD.status THEN
            IF (NEW.check_in, NEW.check_out, NEW.guest_count) IS DISTINCT FROM
               (OLD.check_in, OLD.check_out, OLD.guest_count) THEN
                RAISE EXCEPTION 'Изменение срока и статуса выполняется раздельно'
                    USING ERRCODE = '23514';
            END IF;
            IF NOT (
                (OLD.status = 'CONFIRMED' AND NEW.status = 'CANCELLED') OR
                (OLD.status = 'CONFIRMED' AND NEW.status = 'CHECKED_IN' AND
                 EXISTS (SELECT 1 FROM stays WHERE booking_id = OLD.id AND check_out_date IS NULL)) OR
                (OLD.status = 'CHECKED_IN' AND NEW.status = 'COMPLETED' AND
                 EXISTS (SELECT 1 FROM stays WHERE booking_id = OLD.id AND check_out_date IS NOT NULL))
            ) THEN
                RAISE EXCEPTION 'Недопустимый переход состояния брони' USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;
    IF NEW.status IN ('CONFIRMED', 'CHECKED_IN') AND NEW.guest_count > t.capacity THEN
        RAISE EXCEPTION 'Число гостей превышает вместимость' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER bookings_guard BEFORE INSERT OR UPDATE ON bookings
    FOR EACH ROW EXECUTE FUNCTION guard_booking();

CREATE FUNCTION guard_stay() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE b bookings%ROWTYPE; r rooms%ROWTYPE;
BEGIN
    -- Один порядок блокировок: бронь, затем физический номер.
    SELECT * INTO b FROM bookings WHERE id = NEW.booking_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Бронь не найдена' USING ERRCODE = '23503'; END IF;
    SELECT * INTO r FROM rooms WHERE id = b.room_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF NEW.room_id <> b.room_id THEN
            RAISE EXCEPTION 'Номер проживания не совпадает с бронью' USING ERRCODE = '23503';
        END IF;
        IF b.status <> 'CONFIRMED' OR b.check_in <> hotel_today()
           OR NEW.check_in_date <> b.check_in OR NEW.check_out_date IS NOT NULL THEN
            RAISE EXCEPTION 'Заселение возможно по подтвержденной брони в дату заезда'
                USING ERRCODE = '23514';
        END IF;
        IF r.operational_status <> 'AVAILABLE' OR r.cleaning_state <> 'CLEAN' THEN
            RAISE EXCEPTION 'Номер не готов к заселению' USING ERRCODE = '23514';
        END IF;
        IF EXISTS (SELECT 1 FROM stays WHERE room_id = r.id AND check_out_date IS NULL) THEN
            RAISE EXCEPTION 'Номер фактически занят' USING ERRCODE = '23505';
        END IF;
        NEW.closed_at := NULL;
    ELSE
        IF NEW IS NOT DISTINCT FROM OLD THEN RETURN NEW; END IF;
        IF (NEW.id, NEW.booking_id, NEW.room_id, NEW.check_in_date, NEW.created_at)
            IS DISTINCT FROM (OLD.id, OLD.booking_id, OLD.room_id, OLD.check_in_date, OLD.created_at)
           OR OLD.check_out_date IS NOT NULL OR NEW.check_out_date IS NULL
           OR NEW.check_out_date < OLD.check_in_date OR NEW.check_out_date > hotel_today() THEN
            RAISE EXCEPTION 'Недопустимое изменение проживания' USING ERRCODE = '23514';
        END IF;
        NEW.closed_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER stays_guard BEFORE INSERT OR UPDATE ON stays
    FOR EACH ROW EXECUTE FUNCTION guard_stay();

CREATE FUNCTION sync_stay() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE bookings SET status = 'CHECKED_IN' WHERE id = NEW.booking_id;
    ELSIF OLD.check_out_date IS NULL AND NEW.check_out_date IS NOT NULL THEN
        UPDATE bookings SET status = 'COMPLETED' WHERE id = NEW.booking_id;
        UPDATE rooms SET cleaning_state = 'DIRTY' WHERE id = NEW.room_id;
        INSERT INTO cleaning_tasks(stay_id, room_id) VALUES (NEW.id, NEW.room_id);
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER stays_sync AFTER INSERT OR UPDATE ON stays
    FOR EACH ROW EXECUTE FUNCTION sync_stay();

CREATE FUNCTION guard_cleaning() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE s stays%ROWTYPE;
BEGIN
    SELECT * INTO s FROM stays WHERE id = NEW.stay_id;
    IF NOT FOUND OR s.room_id <> NEW.room_id OR s.check_out_date IS NULL THEN
        RAISE EXCEPTION 'Уборка должна относиться к выезду из этого номера' USING ERRCODE = '23514';
    END IF;
    PERFORM 1 FROM rooms WHERE id = NEW.room_id FOR UPDATE;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status <> 'PENDING' THEN
            RAISE EXCEPTION 'Новое задание должно ожидать выполнения' USING ERRCODE = '23514';
        END IF;
    ELSE
        IF NEW IS NOT DISTINCT FROM OLD THEN RETURN NEW; END IF;
        IF (NEW.id, NEW.stay_id, NEW.room_id, NEW.created_at) IS DISTINCT FROM
           (OLD.id, OLD.stay_id, OLD.room_id, OLD.created_at) OR OLD.status = 'DONE' THEN
            RAISE EXCEPTION 'История уборки неизменяема' USING ERRCODE = '23514';
        END IF;
    END IF;
    IF NEW.assignee_id IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM users u JOIN roles r ON r.id = u.role_id
         WHERE u.id = NEW.assignee_id AND u.enabled AND r.code = 'CLEANER') THEN
        RAISE EXCEPTION 'Исполнитель должен быть действующим сотрудником уборки'
            USING ERRCODE = '23514';
    END IF;
    IF NEW.status = 'DONE' THEN
        IF NEW.assignee_id IS NULL OR EXISTS
            (SELECT 1 FROM stays WHERE room_id = NEW.room_id AND check_out_date IS NULL) THEN
            RAISE EXCEPTION 'Невозможно завершить уборку' USING ERRCODE = '23514';
        END IF;
        NEW.completed_at := CURRENT_TIMESTAMP;
    ELSE
        NEW.completed_at := NULL;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER cleaning_guard BEFORE INSERT OR UPDATE ON cleaning_tasks
    FOR EACH ROW EXECUTE FUNCTION guard_cleaning();
CREATE FUNCTION sync_cleaning() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status = 'PENDING' AND NEW.status = 'DONE' THEN
        UPDATE rooms SET cleaning_state = 'CLEAN' WHERE id = NEW.room_id;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER cleaning_sync AFTER UPDATE ON cleaning_tasks
    FOR EACH ROW EXECUTE FUNCTION sync_cleaning();

CREATE FUNCTION guard_room() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE capacity_limit smallint;
BEGIN
    IF NEW.in_service_from <> OLD.in_service_from AND
       EXISTS (SELECT 1 FROM bookings WHERE room_id = OLD.id) THEN
        RAISE EXCEPTION 'Дата учета номера с историей неизменяема' USING ERRCODE = '23514';
    END IF;
    SELECT capacity INTO capacity_limit FROM room_types WHERE id = NEW.room_type_id;
    IF EXISTS (SELECT 1 FROM bookings WHERE room_id = OLD.id
               AND status IN ('CONFIRMED', 'CHECKED_IN') AND guest_count > capacity_limit) THEN
        RAISE EXCEPTION 'Новый тип не вмещает гостей действующей брони' USING ERRCODE = '23514';
    END IF;
    IF NEW.operational_status = 'MAINTENANCE' AND EXISTS
        (SELECT 1 FROM stays WHERE room_id = OLD.id AND check_out_date IS NULL) THEN
        RAISE EXCEPTION 'Сначала необходимо завершить проживание' USING ERRCODE = '23514';
    END IF;
    IF NEW.cleaning_state = 'CLEAN' AND EXISTS
        (SELECT 1 FROM cleaning_tasks WHERE room_id = OLD.id AND status = 'PENDING') THEN
        RAISE EXCEPTION 'Сначала необходимо выполнить задание на уборку' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER rooms_guard BEFORE UPDATE ON rooms
    FOR EACH ROW EXECUTE FUNCTION guard_room();
CREATE FUNCTION guard_type_capacity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- Изменение вместимости сериализуется с созданием броней по тем же номерам.
    PERFORM id FROM rooms WHERE room_type_id = NEW.id ORDER BY id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM bookings b JOIN rooms r ON r.id = b.room_id
               WHERE r.room_type_id = NEW.id AND b.status IN ('CONFIRMED', 'CHECKED_IN')
                 AND b.guest_count > NEW.capacity) THEN
        RAISE EXCEPTION 'Вместимость противоречит действующим броням' USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER room_types_capacity AFTER UPDATE OF capacity ON room_types
    FOR EACH ROW WHEN (OLD.capacity IS DISTINCT FROM NEW.capacity)
    EXECUTE FUNCTION guard_type_capacity();

CREATE FUNCTION enqueue_booking_notification() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE event_name text; key_suffix text; recipient text;
BEGIN
    IF TG_OP = 'INSERT' THEN
        event_name := 'BOOKING_CONFIRMED'; key_suffix := 'confirmed';
    ELSIF NEW.status = 'CANCELLED' AND OLD.status <> 'CANCELLED' THEN
        event_name := 'BOOKING_CANCELLED'; key_suffix := 'cancelled';
    ELSIF (NEW.check_in, NEW.check_out, NEW.guest_count) IS DISTINCT FROM
          (OLD.check_in, OLD.check_out, OLD.guest_count) THEN
        event_name := 'BOOKING_CHANGED';
        -- Каждое изменение имеет свой ключ, даже при возврате к прежним датам.
        key_suffix := 'changed:' || gen_random_uuid()::text;
    ELSE RETURN NULL;
    END IF;
    SELECT email INTO recipient FROM users WHERE id = NEW.guest_id;
    INSERT INTO email_notifications(booking_id, recipient_email, event_code, event_key, payload)
    VALUES (NEW.id, recipient, event_name, NEW.id::text || ':' || key_suffix,
            jsonb_build_object('reference', NEW.reference, 'check_in', NEW.check_in,
               'check_out', NEW.check_out, 'nightly_price', NEW.nightly_price, 'currency', NEW.currency));
    RETURN NULL;
END $$;
CREATE TRIGGER bookings_notification AFTER INSERT OR UPDATE ON bookings
    FOR EACH ROW EXECUTE FUNCTION enqueue_booking_notification();

CREATE FUNCTION protect_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'История сохраняется: используйте изменение состояния вместо удаления'
        USING ERRCODE = '23514';
END $$;
CREATE TRIGGER bookings_history BEFORE DELETE ON bookings
    FOR EACH ROW EXECUTE FUNCTION protect_history();
CREATE TRIGGER stays_history BEFORE DELETE ON stays
    FOR EACH ROW EXECUTE FUNCTION protect_history();
CREATE TRIGGER cleaning_history BEFORE DELETE ON cleaning_tasks
    FOR EACH ROW EXECUTE FUNCTION protect_history();

CREATE VIEW v_booking_details AS
SELECT b.id, b.reference, b.guest_id, u.full_name AS guest_name, b.room_id,
       r.number AS room_number, t.name AS room_type, b.check_in, b.check_out,
       b.guest_count, b.status, b.nightly_price, b.currency,
       (b.check_out - b.check_in) * b.nightly_price AS planned_amount
FROM bookings b JOIN users u ON u.id = b.guest_id
JOIN rooms r ON r.id = b.room_id JOIN room_types t ON t.id = r.room_type_id;
CREATE VIEW v_stay_history AS
SELECT s.id, s.booking_id, b.reference, b.guest_id, s.room_id, r.number AS room_number,
       s.check_in_date, s.check_out_date, b.nightly_price, b.currency,
       CASE WHEN s.check_out_date IS NULL THEN 'ACTIVE' ELSE 'COMPLETED' END AS status,
       CASE WHEN s.check_out_date IS NOT NULL
            THEN GREATEST(s.check_out_date - s.check_in_date, 1) * b.nightly_price END AS final_amount,
       CASE WHEN s.check_out_date IS NULL
            THEN GREATEST(hotel_today() - s.check_in_date, 0) * b.nightly_price END AS preliminary_amount
FROM stays s JOIN bookings b ON b.id = s.booking_id JOIN rooms r ON r.id = s.room_id;
CREATE VIEW v_cleaning_queue AS
SELECT c.id, c.stay_id, c.room_id, r.number AS room_number, c.assignee_id,
       c.created_at, r.operational_status
FROM cleaning_tasks c JOIN rooms r ON r.id = c.room_id WHERE c.status = 'PENDING';

CREATE FUNCTION find_available_rooms(p_in date, p_out date, p_guests integer)
RETURNS TABLE(room_id bigint, room_number varchar, type_name varchar,
              capacity smallint, price numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_in IS NULL OR p_out IS NULL OR p_guests IS NULL OR p_guests <= 0
       OR p_in < hotel_today() OR p_out <= p_in THEN
        RAISE EXCEPTION 'Неверные даты или число гостей' USING ERRCODE = '23514';
    END IF;
    RETURN QUERY
    SELECT r.id, r.number, t.name, t.capacity, t.base_price
    FROM rooms r JOIN room_types t ON t.id = r.room_type_id
    WHERE r.operational_status = 'AVAILABLE' AND r.in_service_from <= p_in
      AND t.capacity >= p_guests
      AND NOT EXISTS (SELECT 1 FROM bookings b WHERE b.room_id = r.id
          AND b.status IN ('CONFIRMED', 'CHECKED_IN') AND b.period && daterange(p_in, p_out, '[)'))
      AND NOT EXISTS (SELECT 1 FROM stays s JOIN bookings b ON b.id = s.booking_id
          WHERE s.room_id = r.id AND s.check_out_date IS NULL AND b.check_out <= hotel_today())
    ORDER BY r.number;
END $$;

-- Суточный управленческий отчет. Выручка здесь означает начисление по закрытым проживаниям.
CREATE FUNCTION hotel_report(p_from date, p_to date)
RETURNS TABLE(day date, room_nights bigint, occupied_nights bigint,
              occupancy_percent numeric, finalized_revenue_rub numeric, provisional_amount_rub numeric)
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from OR p_to > hotel_today()+1 THEN
        RAISE EXCEPTION 'Неверный период фактического отчета' USING ERRCODE = '23514';
    END IF;
    RETURN QUERY
    WITH days AS (
        SELECT generate_series(p_from::timestamp,(p_to-1)::timestamp,interval '1 day')::date AS d
    ), capacity AS (
        SELECT x.d,count(r.id)::bigint AS total
        FROM days x LEFT JOIN rooms r ON r.in_service_from <= x.d GROUP BY x.d
    ), occupied AS (
        SELECT x.d,count(s.id)::bigint AS total
        FROM days x LEFT JOIN stays s ON s.check_in_date <= x.d
            AND x.d < COALESCE(s.check_out_date,hotel_today()) GROUP BY x.d
    ), revenue AS (
        SELECT x.d,COALESCE(sum(b.nightly_price),0) AS amount
        FROM days x LEFT JOIN stays s ON s.check_out_date IS NOT NULL
            AND s.check_in_date <= x.d AND x.d < GREATEST(s.check_out_date,s.check_in_date+1)
        LEFT JOIN bookings b ON b.id = s.booking_id GROUP BY x.d
    ), provisional AS (
        SELECT x.d,COALESCE(sum(b.nightly_price),0) AS amount
        FROM days x LEFT JOIN stays s ON s.check_out_date IS NULL
            AND s.check_in_date <= x.d AND x.d < hotel_today()
        LEFT JOIN bookings b ON b.id = s.booking_id GROUP BY x.d
    )
    SELECT c.d,c.total,o.total,round(100.0*o.total/NULLIF(c.total,0),2),r.amount,p.amount
    FROM capacity c JOIN occupied o USING(d) JOIN revenue r USING(d)
    JOIN provisional p USING(d) ORDER BY c.d;
END $$;

COMMENT ON TABLE roles IS 'Пять ролей приложения; не роли сервера PostgreSQL.';
COMMENT ON TABLE users IS 'Учетные записи; пароль хранится только в виде BCrypt-хеша.';
COMMENT ON TABLE room_types IS 'Типы, вместимость и базовые тарифы в рублях.';
COMMENT ON TABLE amenities IS 'Справочник удобств.';
COMMENT ON TABLE room_type_amenities IS 'Связь типов номеров и удобств многие ко многим.';
COMMENT ON TABLE rooms IS 'Физические помещения; чистота отделена от эксплуатации.';
COMMENT ON TABLE bookings IS 'Брони; даты [заезд, выезд), тариф сохраняется при создании.';
COMMENT ON TABLE stays IS 'Фактическое проживание; room_id дублируется под контролем составного FK.';
COMMENT ON TABLE cleaning_tasks IS 'Одно задание на каждый фактический выезд.';
COMMENT ON TABLE email_notifications IS 'Транзакционная очередь: фактическая SMTP-отправка относится к реализации приложения.';
COMMENT ON COLUMN bookings.period IS 'Вычисляемый диапазон; отдельно приложением не записывается.';
COMMENT ON COLUMN bookings.nightly_price IS 'Снимок тарифа, заполняемый триггером; неизменяем.';
COMMENT ON COLUMN stays.room_id IS 'Согласован с бронью составным FK; нужен для уникальности активного проживания.';
COMMENT ON COLUMN rooms.in_service_from IS 'Сохраняется для расчета исторической емкости фонда.';
COMMENT ON CONSTRAINT bookings_no_overlap ON bookings IS 'Запрет конкурентных пересечений активных броней одного номера.';
COMMENT ON INDEX stays_one_active_room IS 'Не более одного незавершенного проживания в физическом номере.';
COMMENT ON SCHEMA public IS 'hotel_booking_web:schema:v1';
COMMIT;
\endif
-- Проверяем наличие всех объектов даже при повторном запуске.
DO $$ DECLARE actual_count integer; BEGIN
    SELECT count(*) INTO actual_count FROM information_schema.tables
    WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
      AND table_name IN ('roles','users','room_types','amenities','room_type_amenities',
                        'rooms','bookings','stays','cleaning_tasks','email_notifications');
    IF actual_count <> 10 OR NOT EXISTS
       (SELECT 1 FROM pg_constraint WHERE conrelid = 'bookings'::regclass
        AND conname = 'bookings_no_overlap' AND contype = 'x') THEN
        RAISE EXCEPTION 'Установленная схема неполна; автоматическое изменение запрещено';
    END IF;
END $$;
