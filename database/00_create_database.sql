\set ON_ERROR_STOP on
-- Запуск: psql -X -d postgres -f database/00_create_database.sql
-- Повторное выполнение не удаляет базу и не меняет владельца существующей базы.
SELECT 'CREATE DATABASE hotel_booking_web ENCODING ''UTF8'' TEMPLATE template0'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'hotel_booking_web')
\gexec
\connect hotel_booking_web
\ir 01_schema.sql
\ir 02_demo_data.sql
