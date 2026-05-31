SELECT 'CREATE DATABASE harmony_test'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'harmony_test')\gexec
