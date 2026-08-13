-- Provision the bundled-Keycloak database and its dedicated login role inside the
-- shared metadatadb Postgres.
--
-- This script is run by the `keycloak-db-init` one-shot service on every `up`
-- (see docker-compose.keycloak.yml), which waits for metadatadb and then executes
-- it via psql AS THE SUPERUSER (so it can create the role and database). It works
-- on ANY pgdata volume state — both a fresh volume and a pre-existing metadatadb
-- volume (created before bundled Keycloak was enabled) get the role and database,
-- so Keycloak (KC_DB_URL_DATABASE=keycloak) never crash-loops on a missing DB.
-- Keycloak creates its own tables but not the role/database itself.
--
-- Least privilege: Keycloak connects as this dedicated `keycloak` role (owner of
-- the `keycloak` database), NOT the metadatadb superuser, so a Keycloak compromise
-- is confined to its own database instead of the whole cluster (which also holds
-- the envector metadata). The role's password comes from the KEYCLOAK_DB_PASSWORD
-- env via the psql `:kc_pw` variable set by keycloak-db-init, so it is never
-- hard-coded in this file; format(%L) safely quotes/escapes it.
--
-- Idempotent: role create-if-absent then ALTER on every run (env is the source of
-- truth, so a rotated password re-syncs); `CREATE DATABASE ... WHERE NOT EXISTS`
-- runs only when absent; `ALTER DATABASE ... OWNER TO` always runs so a database
-- created by an earlier revision (owned by the superuser) is handed to the
-- dedicated role; the metadata-DB `REVOKE` re-applies every run. \gexec is a psql
-- meta-command; the init service invokes psql.
--
-- Confinement: PostgreSQL 14 leaves PUBLIC with CONNECT on every database (and
-- CREATE on each `public` schema), so owning only `keycloak` is NOT enough — the
-- role could still connect to the shared envector metadata DB, the `postgres`
-- maintenance DB, and `template1` (which is even cloned into every future
-- database), and create objects (or consume storage) there. Steps 3-5 revoke
-- PUBLIC CONNECT on all three so the role is confined to its own `keycloak`
-- database. Revoking CONNECT is sufficient: with no connection the role cannot
-- reach the `public` schema to create anything. Only the superuser (which the
-- envector services and this init use, and which bypasses the check) can still
-- reach them; a non-default, non-superuser envector DB user would need its own
-- `GRANT CONNECT` after this.

-- 1) Dedicated least-privilege login role for Keycloak.
SELECT format('CREATE ROLE keycloak LOGIN PASSWORD %L', :'kc_pw')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak')\gexec
SELECT format('ALTER ROLE keycloak WITH LOGIN PASSWORD %L', :'kc_pw')\gexec

-- 2) The `keycloak` database, owned by that role so Keycloak can create its own
--    schema/tables inside it without any cluster-wide privilege.
SELECT 'CREATE DATABASE keycloak OWNER keycloak'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
SELECT 'ALTER DATABASE keycloak OWNER TO keycloak'
WHERE EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec

-- 3) Confine the keycloak role: revoke PUBLIC's default CONNECT on the shared
--    envector metadata DB (:meta_db) so the role cannot reach it. Guarded on
--    existence; the envector services connect as the superuser and are unaffected
--    (superuser bypasses privilege checks).
SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'meta_db')
WHERE EXISTS (SELECT FROM pg_database WHERE datname = :'meta_db')\gexec

-- 4) Same for the `postgres` maintenance DB (PG14 grants PUBLIC CONNECT there too).
--    Idempotent; the superuser still connects (bypass).
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;

-- 5) And `template1` — PG14 leaves it connectable (datallowconn=true) with PUBLIC
--    CONNECT + CREATE on its public schema. Left open, the keycloak role could
--    connect there and create objects that CREATE DATABASE silently clones into
--    every FUTURE database (a cross-DB persistence/taint vector), plus read the
--    cluster catalog. Revoking it confines the role to its own `keycloak` database
--    for real. (template0 is datallowconn=false, so it needs no revoke.) After
--    steps 3-5 the role cannot connect anywhere in the cluster except `keycloak`.
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
