#!/usr/bin/env python3
"""Проверка установки и конкуренции в одноразовой PostgreSQL-базе; без внешних пакетов."""
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
PG_BIN = Path(os.environ.get('PG_BIN', '/Applications/Postgres.app/Contents/Versions/latest/bin'))
PSQL = str(PG_BIN / 'psql') if (PG_BIN / 'psql').is_file() else shutil.which('psql')
CREATEDB = str(Path(PSQL).with_name('createdb')) if PSQL else None
DROPDB = str(Path(PSQL).with_name('dropdb')) if PSQL else None
if not PSQL:
    raise SystemExit('Не найден psql. Укажите каталог PostgreSQL через PG_BIN или PATH.')
DB = 'hotel_booking_web_test_' + uuid.uuid4().hex[:8]
ENV = os.environ.copy()
ENV.pop('PGOPTIONS', None)
ENV['PGCONNECT_TIMEOUT'] = '10'
ENV['PGAPPNAME'] = 'hotel_model_tests'


def sql(command=None, filename=None):
    """Выполнить SQL с обязательной остановкой при ошибке."""
    args = [PSQL, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB]
    args += ['-f', str(filename)] if filename else ['-c', command]
    return subprocess.check_output(args, env=ENV, text=True, stderr=subprocess.STDOUT)


def snapshot():
    """Контроль строк и рабочего календаря до/после транзакционных проверок."""
    tables = ['roles', 'users', 'room_types', 'amenities', 'room_type_amenities',
              'rooms', 'bookings', 'stays', 'cleaning_tasks', 'email_notifications']
    return sql(' UNION ALL '.join(
        f"SELECT '{name}:' || COALESCE(jsonb_agg(to_jsonb(t) ORDER BY id)::text,'[]') FROM {name} t"
        if name != 'room_type_amenities' else
        "SELECT 'room_type_amenities:' || jsonb_agg(to_jsonb(t) ORDER BY room_type_id,amenity_id)::text FROM room_type_amenities t"
        for name in tables))


created = False
first = second = None
try:
    subprocess.run([CREATEDB, '--template=template0', '--encoding=UTF8', DB], env=ENV, check=True,
                   capture_output=True, text=True)
    created = True
    sql(filename=ROOT / 'database/01_schema.sql')
    sql(filename=ROOT / 'database/02_demo_data.sql')
    original = snapshot()
    output = sql(filename=ROOT / 'database/tests/regression.sql')
    print(output, end='')
    passed_checks = len(re.findall(r'^\d+\. .*\|ПРОЙДЕНО$', output, re.MULTILINE))
    assert passed_checks == 51, f'Неполный набор проверок: {passed_checks}'
    assert snapshot() == original, 'Регрессионные проверки изменили исходные строки'
    assert sql('SELECT hotel_today() = (CURRENT_TIMESTAMP AT TIME ZONE \'Europe/Moscow\')::date').strip() == 't'
    # Повторная установка не сбрасывает строки или демонстрационные пароли.
    sql(filename=ROOT / 'database/01_schema.sql')
    sql(filename=ROOT / 'database/02_demo_data.sql')
    assert snapshot() == original, 'Повтор установки изменил данные'
    print('ПРОЙДЕНО: повтор установки и точное сохранение всех исходных строк')

    ids = sql("SELECT u.id,r.id FROM users u CROSS JOIN rooms r "
              "WHERE u.email='demo.guest@example.invalid' AND r.number='201'").strip().split('|')
    guest, room = map(int, ids)
    prefix = 'RACE-' + uuid.uuid4().hex[:12]
    app = 'hotel_race_first_' + uuid.uuid4().hex[:8]
    command = ("INSERT INTO bookings(reference,guest_id,room_id,check_in,check_out,guest_count) "
               f"VALUES ('{prefix}-{{}}',{guest},{room},hotel_today()+30,hotel_today()+33,1)")
    env_first = dict(ENV, PGAPPNAME=app)
    first = subprocess.Popen([PSQL, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-d', DB, '-c',
        'BEGIN; ' + command.format('A') + '; SELECT pg_sleep(3); COMMIT;'],
        env=env_first, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    # Второй запрос запускается только после INSERT, когда первый уже удерживает блокировку.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if sql(f"SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='{app}' "
               "AND wait_event='PgSleep')").strip() == 't':
            break
        if first.poll() is not None:
            raise AssertionError('Первая сессия завершилась до контрольной точки')
        time.sleep(0.05)
    else:
        raise AssertionError('Не достигнута точка конкурирующей записи')
    second = subprocess.Popen([PSQL, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-v', 'VERBOSITY=verbose',
        '-d', DB, '-c', 'BEGIN; ' + command.format('B') + '; COMMIT;'],
        env=dict(ENV, PGAPPNAME='hotel_race_second'), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out_a, err_a = first.communicate(timeout=20)
    out_b, err_b = second.communicate(timeout=20)
    assert first.returncode == 0, err_a
    assert second.returncode != 0 and '23P01' in err_b, err_b
    assert sql(f"SELECT count(*) FROM bookings WHERE reference LIKE '{prefix}%'").strip() == '1'
    print('ПРОЙДЕНО: две параллельные транзакции; одна бронь, вторая отклонена с SQLSTATE 23P01')
    print(json.dumps({'regression_checks': passed_checks, 'repeat_install': 'passed',
                      'concurrent_booking': 'passed', 'fixture_rows_restored': True}, ensure_ascii=False))
finally:
    for process in (first, second):
        if process is not None and process.poll() is None:
            process.kill()
            process.communicate()
    if created:
        subprocess.run([DROPDB, '--force', DB], env=ENV, check=True, capture_output=True, text=True)
        print('Одноразовая тестовая база удалена; рабочая база не изменялась.')
