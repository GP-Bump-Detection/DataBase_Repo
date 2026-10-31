-- =====================================================================
--  AI-Based Road Hazard Detection - PostgreSQL 14+ / PostGIS 3+
--  11 tables, no standalone Notifications table
-- =====================================================================
--  hazards         = the hazard itself (one consolidated record)
--  hazard_reports  = manual report / confirmation / "not found" from a user
--  ai_hazards      = one detection event from the on-device model
--  trip_hazards    = a hazard linked to a trip (warning + pass-through state)
--
--  VERIFICATION WORKFLOW (enforced by triggers; thresholds are small fn_* config functions)
--   AI detections - one VOTE per account (a detection below fn_ai_min_confidence() = 0.70 is stored, not counted):
--     1-2 different accounts -> stored as a hidden PENDING hazard until it reaches 3
--     3-4 different accounts -> enters the moderator queue; the moderator approves (active) or rejects
--     5+  different accounts -> becomes ACTIVE automatically, no review (audited)
--     hazards.confidence_score grows with the number of accounts: 1 - exp(-n/4)  (5 -> 0.71, 10 -> 0.92, 30 -> ~1.0)
--   Manual reports (report form with text/voice OR map marker) -> 'pending' until a moderator/administrator approves;
--     approved report -> hazard ACTIVE.  When 5 different accounts report the same hazard their pending reports
--     are approved automatically (audited); every other report waits for review.
--   Approved not_found / fixed reports newer than the last positive evidence turn a hazard RESOLVED.
--   A hazard rejected by a moderator keeps collecting votes but is never re-queued or auto-activated.
-- =====================================================================

BEGIN;

CREATE EXTENSION IF NOT EXISTS postgis;

-- ---------------------------------------------------------------------
-- 1. ENUM types (instead of free-text VARCHAR)
-- ---------------------------------------------------------------------
CREATE TYPE hazard_type_enum      AS ENUM ('speed_bump', 'pothole', 'rough_road', 'other');
CREATE TYPE hazard_status_enum    AS ENUM ('pending', 'active', 'resolved', 'expired', 'rejected');
CREATE TYPE report_type_enum      AS ENUM ('new_hazard', 'confirm', 'not_found', 'fixed');
CREATE TYPE report_status_enum    AS ENUM ('pending', 'approved', 'rejected', 'withdrawn');
CREATE TYPE report_source_enum    AS ENUM ('form', 'map_marker');   -- report box vs. marker button on the map
CREATE TYPE ai_status_enum        AS ENUM ('pending', 'matched', 'rejected');
CREATE TYPE trip_status_enum      AS ENUM ('planned', 'active', 'completed', 'cancelled');
CREATE TYPE complaint_status_enum AS ENUM ('open', 'in_progress', 'resolved', 'rejected');
CREATE TYPE theme_mode_enum       AS ENUM ('light', 'dark', 'system');

-- ---------------------------------------------------------------------
-- 2. Helper: auto-update updated_at
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------
-- 3. ROLES
-- ---------------------------------------------------------------------
CREATE TABLE roles (
    role_id  SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name     VARCHAR(50) NOT NULL UNIQUE
);

-- order matters: role_id 1 (driver) is the default role of every new account
INSERT INTO roles (name) VALUES ('driver'), ('moderator'), ('administrator');

-- ---------------------------------------------------------------------
-- 4. USERS  (soft delete: is_active / deleted_at)
-- ---------------------------------------------------------------------
CREATE TABLE users (
    user_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name      VARCHAR(150) NOT NULL,
    email          VARCHAR(255) NOT NULL,
    password_hash  TEXT         NOT NULL,
    role_id        SMALLINT     NOT NULL DEFAULT 1
                   REFERENCES roles(role_id) ON DELETE RESTRICT,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    deleted_at     TIMESTAMPTZ,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT ck_users_email   CHECK (position('@' in email) > 1),
    CONSTRAINT ck_users_deleted CHECK (deleted_at IS NULL OR is_active = FALSE)
);

-- case-insensitive unique email
-- only live accounts compete for an email; when an account is soft-deleted the backend should
-- anonymize its email (e.g. 'deleted+<uuid>@invalid') so personal data is not kept
CREATE UNIQUE INDEX ux_users_email ON users (lower(email)) WHERE deleted_at IS NULL;
CREATE INDEX ix_users_role_id ON users (role_id);

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ---------------------------------------------------------------------
-- 5. USER_SETTINGS  (1:1 with users)
-- ---------------------------------------------------------------------
CREATE TABLE user_settings (
    user_id                 UUID PRIMARY KEY
                            REFERENCES users(user_id) ON DELETE CASCADE,
    app_language            VARCHAR(10)  NOT NULL DEFAULT 'ar',
    theme_mode              theme_mode_enum NOT NULL DEFAULT 'system',
    audio_warnings_enabled  BOOLEAN      NOT NULL DEFAULT TRUE,
    warning_distance_meters INTEGER      NOT NULL DEFAULT 200
                            CHECK (warning_distance_meters BETWEEN 50 AND 1000),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_settings_updated_at
    BEFORE UPDATE ON user_settings
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ---------------------------------------------------------------------
-- 6. TRIPS  (+ planned_route)
--    The id can be generated on the mobile app (offline-first sync).
-- ---------------------------------------------------------------------
CREATE TABLE trips (
    trip_id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id               UUID NOT NULL
                          REFERENCES users(user_id) ON DELETE CASCADE,
    origin_location       GEOGRAPHY(Point, 4326),
    destination_location  GEOGRAPHY(Point, 4326) NOT NULL,
    origin_name           VARCHAR(255),
    destination_name      VARCHAR(255),
    planned_route         GEOGRAPHY(LineString, 4326),   -- route returned by the navigation provider
    started_at            TIMESTAMPTZ,
    ended_at              TIMESTAMPTZ,
    status                trip_status_enum NOT NULL DEFAULT 'planned',
    distance_meters       NUMERIC(10,2) CHECK (distance_meters >= 0),
    duration_seconds      INTEGER       CHECK (duration_seconds >= 0),
    average_speed_kmh     NUMERIC(6,2)  CHECK (average_speed_kmh >= 0),
    max_speed_kmh         NUMERIC(6,2)  CHECK (max_speed_kmh >= 0),
    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_trips_time_order CHECK (ended_at IS NULL OR started_at IS NULL OR ended_at >= started_at)
);

CREATE INDEX ix_trips_user_started ON trips (user_id, started_at DESC);
CREATE INDEX gix_trips_planned_route ON trips USING GIST (planned_route);

CREATE TRIGGER trg_trips_updated_at
    BEFORE UPDATE ON trips
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ---------------------------------------------------------------------
-- 7. TRIP_LOCATIONS  (large table -> BIGINT identity key)
-- ---------------------------------------------------------------------
CREATE TABLE trip_locations (
    location_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_id          UUID NOT NULL REFERENCES trips(trip_id) ON DELETE CASCADE,
    location         GEOGRAPHY(Point, 4326) NOT NULL,
    recorded_at      TIMESTAMPTZ NOT NULL,
    speed_kmh        NUMERIC(6,2) CHECK (speed_kmh >= 0),
    heading_degrees  NUMERIC(5,2) CHECK (heading_degrees >= 0 AND heading_degrees < 360)
);

CREATE INDEX ix_trip_locations_trip_time ON trip_locations (trip_id, recorded_at);

-- ---------------------------------------------------------------------
-- 8. HAZARDS  (the consolidated hazard record)
-- ---------------------------------------------------------------------
CREATE TABLE hazards (
    hazard_id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    hazard_type                hazard_type_enum   NOT NULL,
    location                   GEOGRAPHY(Point, 4326) NOT NULL,
    heading_degrees            NUMERIC(5,2) NOT NULL
                               CHECK (heading_degrees >= 0 AND heading_degrees < 360),  -- direction of travel it affects
    heading_tolerance_degrees  SMALLINT NOT NULL DEFAULT 45
                               CHECK (heading_tolerance_degrees BETWEEN 5 AND 180),
    severity                   SMALLINT CHECK (severity BETWEEN 1 AND 5),
    confidence_score           NUMERIC(4,3) CHECK (confidence_score BETWEEN 0 AND 1),  -- grows with ai_users_count; NULL when no AI evidence
    status                     hazard_status_enum NOT NULL DEFAULT 'pending',
    distinct_users_count       INTEGER  NOT NULL DEFAULT 0 CHECK (distinct_users_count >= 0),  -- all accounts behind it (reports + AI)
    ai_users_count             INTEGER  NOT NULL DEFAULT 0 CHECK (ai_users_count >= 0),        -- different accounts whose model detected it
    last_confirmed_at          TIMESTAMPTZ,
    review_requested_at        TIMESTAMPTZ,   -- set when 3+ AI accounts reached it: it enters the moderator queue
    reviewed_by_user_id        UUID REFERENCES users(user_id) ON DELETE SET NULL,
    reviewed_at                TIMESTAMPTZ,
    created_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                 TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_hazard_review CHECK (reviewed_by_user_id IS NULL OR reviewed_at IS NOT NULL)
);

CREATE INDEX gix_hazards_location ON hazards USING GIST (location);
CREATE INDEX ix_hazards_status ON hazards (status);
CREATE INDEX ix_hazards_review_queue ON hazards (review_requested_at) WHERE status = 'pending';
CREATE INDEX ix_hazards_last_confirmed ON hazards (last_confirmed_at);

CREATE TRIGGER trg_hazards_updated_at
    BEFORE UPDATE ON hazards
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ---------------------------------------------------------------------
-- 9. AI_HAZARDS  (detection event from the on-device model)
--    user_id = the account whose phone ran the on-device model (used to count distinct users).
--    The id can be generated on the mobile app.
-- ---------------------------------------------------------------------
CREATE TABLE ai_hazards (
    ai_hazard_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id           UUID REFERENCES trips(trip_id)     ON DELETE SET NULL,
    user_id           UUID REFERENCES users(user_id)     ON DELETE SET NULL,
    hazard_id         UUID REFERENCES hazards(hazard_id) ON DELETE SET NULL,   -- filled once matched
    hazard_type       hazard_type_enum NOT NULL,
    location          GEOGRAPHY(Point, 4326) NOT NULL,
    heading_degrees   NUMERIC(5,2) NOT NULL CHECK (heading_degrees >= 0 AND heading_degrees < 360),
    detected_at       TIMESTAMPTZ NOT NULL,
    confidence_score  NUMERIC(4,3) NOT NULL CHECK (confidence_score BETWEEN 0 AND 1),
    speed_kmh         NUMERIC(6,2) CHECK (speed_kmh >= 0),
    peak_acceleration NUMERIC(7,3),                 -- vibration strength (severity is calibrated later from field-test data)
    status            ai_status_enum NOT NULL DEFAULT 'pending',
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX gix_ai_hazards_location ON ai_hazards USING GIST (location);
CREATE INDEX ix_ai_hazards_trip      ON ai_hazards (trip_id);
CREATE INDEX ix_ai_hazards_hazard    ON ai_hazards (hazard_id);
CREATE INDEX ix_ai_hazards_user      ON ai_hazards (user_id);
CREATE INDEX ix_ai_hazards_status    ON ai_hazards (status, created_at);

-- ---------------------------------------------------------------------
-- 10. HAZARD_REPORTS  (manual report / confirmation / "not found")
-- ---------------------------------------------------------------------
CREATE TABLE hazard_reports (
    report_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    trip_id              UUID REFERENCES trips(trip_id)     ON DELETE SET NULL,
    hazard_id            UUID REFERENCES hazards(hazard_id) ON DELETE SET NULL,  -- NULL for a brand-new hazard
    report_type          report_type_enum NOT NULL,
    source               report_source_enum NOT NULL DEFAULT 'form',
    hazard_type          hazard_type_enum NOT NULL,
    location             GEOGRAPHY(Point, 4326) NOT NULL,
    heading_degrees      NUMERIC(5,2) NOT NULL CHECK (heading_degrees >= 0 AND heading_degrees < 360),
    description          TEXT,
    voice_file_url       TEXT,
    status               report_status_enum NOT NULL DEFAULT 'pending',
    reviewed_by_user_id  UUID REFERENCES users(user_id) ON DELETE SET NULL,
    reviewed_at          TIMESTAMPTZ,
    withdrawn_at         TIMESTAMPTZ,      -- the user took back his own report
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_report_review    CHECK (reviewed_by_user_id IS NULL OR reviewed_at IS NOT NULL),
    CONSTRAINT ck_report_withdrawn CHECK ((status = 'withdrawn') = (withdrawn_at IS NOT NULL)),
    -- a report from the form must carry details (text or voice); a map marker may be just a location
    CONSTRAINT ck_report_details   CHECK (source = 'map_marker' OR description IS NOT NULL OR voice_file_url IS NOT NULL)
);

CREATE INDEX gix_hazard_reports_location ON hazard_reports USING GIST (location);
CREATE INDEX ix_hazard_reports_status    ON hazard_reports (status, created_at);
CREATE INDEX ix_hazard_reports_hazard    ON hazard_reports (hazard_id);
CREATE INDEX ix_hazard_reports_user      ON hazard_reports (user_id, created_at DESC);
CREATE INDEX ix_hazard_reports_trip      ON hazard_reports (trip_id);

-- Block the same user from reporting the same hazard repeatedly in a short window
CREATE OR REPLACE FUNCTION fn_prevent_duplicate_report()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM hazard_reports r
        WHERE r.user_id     = NEW.user_id
          AND r.report_type = NEW.report_type
          AND r.status     <> 'withdrawn'
          AND r.created_at  > now() - interval '10 minutes'
          AND (
                (NEW.hazard_id IS NOT NULL AND r.hazard_id = NEW.hazard_id)
                OR (r.hazard_type = NEW.hazard_type AND ST_DWithin(r.location, NEW.location, 30))
              )
    ) THEN
        RAISE EXCEPTION 'Duplicate report from the same user within 10 minutes'
            USING ERRCODE = 'unique_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hazard_reports_no_duplicates
    BEFORE INSERT ON hazard_reports
    FOR EACH ROW EXECUTE FUNCTION fn_prevent_duplicate_report();

-- ---------------------------------------------------------------------
-- 11. TRIP_HAZARDS  (hazard <-> trip: warning state + pass-through)
--     is_notified was removed: use notified_at IS NOT NULL
-- ---------------------------------------------------------------------
CREATE TABLE trip_hazards (
    trip_hazard_id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trip_id                     UUID NOT NULL REFERENCES trips(trip_id)     ON DELETE CASCADE,
    hazard_id                   UUID NOT NULL REFERENCES hazards(hazard_id) ON DELETE RESTRICT,
    distance_from_start_meters  NUMERIC(10,2) CHECK (distance_from_start_meters >= 0),
    notified_at                 TIMESTAMPTZ,      -- NULL = no warning was fired
    passed_at                   TIMESTAMPTZ,      -- NULL = not passed yet
    speed_at_pass_kmh           NUMERIC(6,2) CHECK (speed_at_pass_kmh >= 0),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_trip_hazard UNIQUE (trip_id, hazard_id)
);

CREATE INDEX ix_trip_hazards_trip   ON trip_hazards (trip_id, distance_from_start_meters);
CREATE INDEX ix_trip_hazards_hazard ON trip_hazards (hazard_id);

-- ---------------------------------------------------------------------
-- 12. COMPLAINTS
-- ---------------------------------------------------------------------
CREATE TABLE complaints (
    complaint_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID NOT NULL REFERENCES users(user_id) ON DELETE RESTRICT,
    subject              VARCHAR(200) NOT NULL,
    description          TEXT,             -- written complaint
    voice_file_url       TEXT,             -- or a voice recording (at least one of the two is required)
    status               complaint_status_enum NOT NULL DEFAULT 'open',
    resolved_by_user_id  UUID REFERENCES users(user_id) ON DELETE SET NULL,
    resolved_at          TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_complaint_resolution CHECK (resolved_by_user_id IS NULL OR resolved_at IS NOT NULL),
    CONSTRAINT ck_complaint_content    CHECK (description IS NOT NULL OR voice_file_url IS NOT NULL)
);

CREATE INDEX ix_complaints_user   ON complaints (user_id);
CREATE INDEX ix_complaints_status ON complaints (status, created_at);

CREATE TRIGGER trg_complaints_updated_at
    BEFORE UPDATE ON complaints
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- ---------------------------------------------------------------------
-- 13. AUDIT_LOGS
--     entity_id is TEXT on purpose (polymorphic: it may point to any table's key)
-- ---------------------------------------------------------------------
CREATE TABLE audit_logs (
    audit_log_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_user_id  UUID REFERENCES users(user_id) ON DELETE SET NULL,
    action         VARCHAR(100) NOT NULL,
    entity_type    VARCHAR(100) NOT NULL,
    entity_id      TEXT,
    details        JSONB,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ix_audit_logs_actor  ON audit_logs (actor_user_id, created_at DESC);
CREATE INDEX ix_audit_logs_entity ON audit_logs (entity_type, entity_id);

-- =====================================================================
--  Spatial / business functions
-- =====================================================================

-- 14. Active hazards near a planned route, filtered by travel direction.
--     Returns them ordered along the route with their distance from its start.
CREATE OR REPLACE FUNCTION fn_hazards_near_route(
    p_route     GEOGRAPHY,
    p_buffer_m  NUMERIC DEFAULT 30
)
RETURNS TABLE (
    hazard_id                  UUID,
    hazard_type                hazard_type_enum,
    severity                   SMALLINT,
    location                   GEOGRAPHY,
    distance_from_start_meters NUMERIC,
    distance_to_route_meters   NUMERIC,
    confidence_score           NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH r AS (
        SELECT p_route::geometry AS g, ST_Length(p_route) AS len
    )
    SELECT
        h.hazard_id,
        h.hazard_type,
        h.severity,
        h.location,
        (loc.f * r.len)::numeric,
        ST_Distance(h.location, p_route)::numeric,
        h.confidence_score
    FROM hazards h
    CROSS JOIN r
    CROSS JOIN LATERAL (
        SELECT ST_LineLocatePoint(r.g, h.location::geometry) AS f
    ) loc
    CROSS JOIN LATERAL (
        -- route heading at the hazard's position
        SELECT degrees(ST_Azimuth(
                   ST_LineInterpolatePoint(r.g, GREATEST(loc.f - 0.0005, 0)),
                   ST_LineInterpolatePoint(r.g, LEAST(loc.f + 0.0005, 1))
               ))::numeric AS az
    ) hd
    WHERE h.status = 'active'
      AND ST_DWithin(h.location, p_route, p_buffer_m)
      AND (
            hd.az IS NULL
            OR abs(((hd.az - h.heading_degrees + 540) % 360) - 180) <= h.heading_tolerance_degrees
          )
    ORDER BY 5;
$$;

-- 15. Find an existing hazard that a new detection / report should be attached to.
--     p_include_rejected = TRUE lets AI votes attach to a hazard a moderator already rejected,
--     so the same spot is not queued again.
CREATE OR REPLACE FUNCTION fn_find_matching_hazard(
    p_location          GEOGRAPHY,
    p_hazard_type       hazard_type_enum,
    p_heading           NUMERIC,
    p_radius_m          NUMERIC DEFAULT 25,
    p_include_rejected  BOOLEAN DEFAULT FALSE
)
RETURNS UUID
LANGUAGE sql STABLE AS $$
    SELECT h.hazard_id
    FROM hazards h
    WHERE (h.status IN ('pending', 'active') OR (p_include_rejected AND h.status = 'rejected'))
      AND h.hazard_type = p_hazard_type
      AND ST_DWithin(h.location, p_location, p_radius_m)
      AND abs(((p_heading - h.heading_degrees + 540) % 360) - 180) <= h.heading_tolerance_degrees
    ORDER BY ST_Distance(h.location, p_location)
    LIMIT 1;
$$;

-- 16. Workflow thresholds - change them here only.
CREATE OR REPLACE FUNCTION fn_ai_min_confidence()
RETURNS NUMERIC LANGUAGE sql STABLE AS $$ SELECT 0.70::numeric $$;      -- below this a detection is stored but is not a vote

CREATE OR REPLACE FUNCTION fn_ai_review_users()
RETURNS INTEGER LANGUAGE sql STABLE AS $$ SELECT 3 $$;                  -- AI accounts needed to reach the moderator queue

CREATE OR REPLACE FUNCTION fn_ai_auto_users()
RETURNS INTEGER LANGUAGE sql STABLE AS $$ SELECT 5 $$;                  -- AI accounts needed for automatic activation

CREATE OR REPLACE FUNCTION fn_report_auto_approve_users()
RETURNS INTEGER LANGUAGE sql STABLE AS $$ SELECT 5 $$;                  -- accounts that auto-approve manual reports

-- Confidence of a hazard from the number of different AI accounts that reported it:
-- 1 -> 0.221, 3 -> 0.528, 5 -> 0.713, 10 -> 0.918, 30 -> 0.999
CREATE OR REPLACE FUNCTION fn_users_confidence(p_users INTEGER)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_users IS NULL OR p_users <= 0 THEN NULL
                ELSE round((1 - exp(-p_users / 4.0))::numeric, 3) END
$$;

-- 16b. Recompute a hazard's statistics and apply the verification rules.
--      Called automatically by triggers after every report / AI detection change.
--      AI : by number of different accounts  1-2 stored | 3-4 moderator queue | 5+ active automatically
--      Reports: approved report -> active;  5 different accounts auto-approve their pending reports
--      Negative (not_found / fixed) approved after the last positive evidence -> resolved
--      distinct_users_count = accounts behind the hazard (reports not rejected/withdrawn + matched AI votes);
--      last_confirmed_at / confidence_score are recomputed from scratch, so withdrawn or rejected
--      evidence never leaves a stale value behind.
CREATE OR REPLACE FUNCTION fn_refresh_hazard_stats(p_hazard_id UUID)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_n         INTEGER := fn_report_auto_approve_users();
    v_ai_auto   INTEGER := fn_ai_auto_users();
    v_ai_review INTEGER := fn_ai_review_users();
    v_old       hazard_status_enum;
    v_users     INTEGER;
    v_neg_users INTEGER;
    v_ai_users  INTEGER;
    v_last_pos  TIMESTAMPTZ;
    v_has_pos   BOOLEAN;
    v_has_neg   BOOLEAN;
    v_rows      INTEGER;
BEGIN
    SELECT h.status INTO v_old FROM hazards h WHERE h.hazard_id = p_hazard_id;
    IF v_old IS NULL THEN
        RETURN;
    END IF;

    -- (1) crowd auto-approval of manual positive reports
    SELECT count(DISTINCT r.user_id) INTO v_users
    FROM hazard_reports r
    WHERE r.hazard_id = p_hazard_id
      AND r.report_type IN ('new_hazard', 'confirm')
      AND r.status IN ('pending', 'approved');

    IF v_users >= v_n THEN
        PERFORM set_config('app.auto_approval', 'on', true);
        UPDATE hazard_reports
        SET status = 'approved', reviewed_at = now()
        WHERE hazard_id = p_hazard_id
          AND report_type IN ('new_hazard', 'confirm')
          AND status = 'pending';
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        PERFORM set_config('app.auto_approval', 'off', true);
        IF v_rows > 0 THEN
            INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
            VALUES (NULL, 'hazard.auto_approved', 'hazard', p_hazard_id::text,
                    jsonb_build_object('source', 'reports', 'direction', 'positive', 'threshold', v_n));
        END IF;
    END IF;

    -- positive evidence = approved reports + matched AI detections (timestamps);
    -- activation by reports needs an APPROVED report
    SELECT max(x.ts) INTO v_last_pos
    FROM (
        SELECT r.created_at AS ts
        FROM hazard_reports r
        WHERE r.hazard_id = p_hazard_id AND r.report_type IN ('new_hazard', 'confirm') AND r.status = 'approved'
        UNION ALL
        SELECT a.detected_at
        FROM ai_hazards a
        WHERE a.hazard_id = p_hazard_id AND a.status = 'matched'
    ) x;
    v_has_pos := EXISTS (
        SELECT 1 FROM hazard_reports r
        WHERE r.hazard_id = p_hazard_id AND r.report_type IN ('new_hazard', 'confirm') AND r.status = 'approved'
    );

    -- (3) crowd auto-approval of negative reports (only those newer than the last positive evidence)
    SELECT count(DISTINCT r.user_id) INTO v_neg_users
    FROM hazard_reports r
    WHERE r.hazard_id = p_hazard_id
      AND r.report_type IN ('not_found', 'fixed')
      AND r.status IN ('pending', 'approved')
      AND r.created_at > COALESCE(v_last_pos, '-infinity'::timestamptz);

    IF v_neg_users >= v_n THEN
        PERFORM set_config('app.auto_approval', 'on', true);
        UPDATE hazard_reports
        SET status = 'approved', reviewed_at = now()
        WHERE hazard_id = p_hazard_id
          AND report_type IN ('not_found', 'fixed')
          AND status = 'pending'
          AND created_at > COALESCE(v_last_pos, '-infinity'::timestamptz);
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        PERFORM set_config('app.auto_approval', 'off', true);
        IF v_rows > 0 THEN
            INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
            VALUES (NULL, 'hazard.auto_approved', 'hazard', p_hazard_id::text,
                    jsonb_build_object('source', 'reports', 'direction', 'negative', 'threshold', v_n));
        END IF;
    END IF;

    v_has_neg := EXISTS (
        SELECT 1 FROM hazard_reports r
        WHERE r.hazard_id = p_hazard_id
          AND r.report_type IN ('not_found', 'fixed')
          AND r.status = 'approved'
          AND r.created_at > COALESCE(v_last_pos, '-infinity'::timestamptz)
    );

    -- counters
    SELECT count(DISTINCT e.user_id) INTO v_users
    FROM (
        SELECT r.user_id
        FROM hazard_reports r
        WHERE r.hazard_id = p_hazard_id AND r.report_type IN ('new_hazard', 'confirm') AND r.status IN ('pending', 'approved')
        UNION ALL
        SELECT a.user_id
        FROM ai_hazards a
        WHERE a.hazard_id = p_hazard_id AND a.status = 'matched' AND a.user_id IS NOT NULL
    ) e;

    SELECT count(DISTINCT a.user_id) INTO v_ai_users
    FROM ai_hazards a
    WHERE a.hazard_id = p_hazard_id AND a.status = 'matched' AND a.user_id IS NOT NULL;

    -- (2) status transitions and moderator-queue entry
    PERFORM set_config('app.auto_approval', 'on', true);
    UPDATE hazards h
    SET distinct_users_count = v_users,
        ai_users_count       = v_ai_users,
        last_confirmed_at    = v_last_pos,
        confidence_score     = fn_users_confidence(v_ai_users),
        review_requested_at  = CASE
                                  WHEN h.review_requested_at IS NULL AND h.status = 'pending'
                                       AND v_ai_users >= v_ai_review AND v_ai_users < v_ai_auto
                                  THEN now()
                                  ELSE h.review_requested_at
                               END,
        status = CASE
                    WHEN h.status = 'pending' AND (v_has_pos OR v_ai_users >= v_ai_auto) THEN 'active'::hazard_status_enum
                    WHEN h.status = 'active'  AND v_has_neg THEN 'resolved'::hazard_status_enum
                    ELSE h.status
                 END
    WHERE h.hazard_id = p_hazard_id;
    PERFORM set_config('app.auto_approval', 'off', true);

    IF v_old = 'pending' AND NOT v_has_pos AND v_ai_users >= v_ai_auto THEN
        INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
        VALUES (NULL, 'hazard.auto_approved', 'hazard', p_hazard_id::text,
                jsonb_build_object('source', 'ai_users', 'ai_users', v_ai_users, 'threshold', v_ai_auto));
    END IF;
END;
$$;

-- 17. Expire stale hazards (run from a daily job / pg_cron):
--     active hazards nobody confirmed for p_active_days;
--     pending hazards with no new evidence for p_pending_days (hazards waiting in the moderator queue are kept);
--     stored low-confidence AI detections older than p_ai_days are rejected.
CREATE OR REPLACE FUNCTION fn_expire_stale_hazards(
    p_active_days  INTEGER DEFAULT 180,
    p_pending_days INTEGER DEFAULT 90,
    p_ai_days      INTEGER DEFAULT 30
)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE hazards
    SET status = 'expired'
    WHERE (status = 'active'
           AND COALESCE(last_confirmed_at, created_at) < now() - make_interval(days => p_active_days))
       OR (status = 'pending' AND review_requested_at IS NULL
           AND COALESCE(last_confirmed_at, created_at) < now() - make_interval(days => p_pending_days));
    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE ai_hazards
    SET status = 'rejected'
    WHERE status = 'pending'
      AND created_at < now() - make_interval(days => p_ai_days);

    RETURN v_count;
END;
$$;

-- 18. Collapse a finished trip's GPS points into one LineString (call after the trip ends,
--     then you may delete the raw trip_locations rows or keep them sampled).
CREATE OR REPLACE FUNCTION fn_build_trip_path(p_trip_id UUID)
RETURNS GEOGRAPHY LANGUAGE sql STABLE AS $$
    SELECT ST_MakeLine(location::geometry ORDER BY recorded_at)::geography
    FROM trip_locations
    WHERE trip_id = p_trip_id;
$$;

-- =====================================================================
--  Integrity + audit triggers (server-side RBAC support, SEC-10 / RBAC-04)
-- =====================================================================

-- 19. Only active moderators / administrators may review reports or resolve complaints.
--     (A plain FK cannot check the reviewer's role.)
CREATE OR REPLACE FUNCTION fn_require_staff(p_user UUID)
RETURNS void LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_user IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM users u
        JOIN roles r ON r.role_id = u.role_id
        WHERE u.user_id = p_user
          AND u.is_active
          AND r.name IN ('moderator', 'administrator')
    ) THEN
        RAISE EXCEPTION 'User % is not an active moderator/administrator', p_user
            USING ERRCODE = 'insufficient_privilege';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION fn_report_reviewer_check()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_require_staff(NEW.reviewed_by_user_id);
    IF NEW.reviewed_by_user_id IS NOT NULL AND NEW.reviewed_by_user_id = NEW.user_id THEN
        RAISE EXCEPTION 'A user cannot review his own report'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hazard_reports_reviewer
    BEFORE INSERT OR UPDATE OF reviewed_by_user_id ON hazard_reports
    FOR EACH ROW EXECUTE FUNCTION fn_report_reviewer_check();

CREATE OR REPLACE FUNCTION fn_complaint_resolver_check()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_require_staff(NEW.resolved_by_user_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_complaints_resolver
    BEFORE INSERT OR UPDATE OF resolved_by_user_id ON complaints
    FOR EACH ROW EXECUTE FUNCTION fn_complaint_resolver_check();

-- 20. user_id and trip_id on ai_hazards / hazard_reports must agree:
--     a detection or report attached to a trip belongs to that trip's owner.
CREATE OR REPLACE FUNCTION fn_check_trip_owner()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_owner UUID;
BEGIN
    IF NEW.trip_id IS NOT NULL AND NEW.user_id IS NOT NULL THEN
        SELECT t.user_id INTO v_owner FROM trips t WHERE t.trip_id = NEW.trip_id;
        IF v_owner IS DISTINCT FROM NEW.user_id THEN
            RAISE EXCEPTION 'user_id does not match the owner of trip %', NEW.trip_id
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ai_hazards_trip_owner
    BEFORE INSERT OR UPDATE OF trip_id, user_id ON ai_hazards
    FOR EACH ROW EXECUTE FUNCTION fn_check_trip_owner();

CREATE TRIGGER trg_hazard_reports_trip_owner
    BEFORE INSERT OR UPDATE OF trip_id, user_id ON hazard_reports
    FOR EACH ROW EXECUTE FUNCTION fn_check_trip_owner();

-- 21. Audit: every review decision and every role change is recorded.
--     The backend should run  SET LOCAL app.actor_user_id = '<uuid>'  in the transaction
--     so role changes know who did them.
CREATE OR REPLACE FUNCTION fn_audit_report_review()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
    VALUES (NEW.reviewed_by_user_id, 'report.' || NEW.status::text, 'hazard_report',
            NEW.report_id::text,
            jsonb_build_object('from', OLD.status, 'to', NEW.status, 'hazard_id', NEW.hazard_id));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_report_review
    AFTER UPDATE OF status ON hazard_reports
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
          AND NEW.status IN ('approved', 'rejected')
          AND NEW.reviewed_by_user_id IS NOT NULL)
    EXECUTE FUNCTION fn_audit_report_review();

CREATE OR REPLACE FUNCTION fn_audit_role_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
    VALUES (NULLIF(current_setting('app.actor_user_id', true), '')::uuid,
            'user.role_changed', 'user', NEW.user_id::text,
            jsonb_build_object('from_role_id', OLD.role_id, 'to_role_id', NEW.role_id));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_role_change
    AFTER UPDATE OF role_id ON users
    FOR EACH ROW
    WHEN (OLD.role_id IS DISTINCT FROM NEW.role_id)
    EXECUTE FUNCTION fn_audit_role_change();

-- 21b. Report status guard: a manual approve/reject must carry reviewed_by_user_id (so it is audited);
--      only the system's crowd rule (flag app.auto_approval) may approve without a reviewer;
--      only a pending report can be withdrawn.
CREATE OR REPLACE FUNCTION fn_report_status_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status = 'withdrawn' AND OLD.status <> 'pending' THEN
        RAISE EXCEPTION 'Only a pending report can be withdrawn'
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.status IN ('approved', 'rejected')
       AND NEW.reviewed_by_user_id IS NULL
       AND COALESCE(current_setting('app.auto_approval', true), '') <> 'on' THEN
        RAISE EXCEPTION 'A review decision requires reviewed_by_user_id'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hazard_reports_status_guard
    BEFORE UPDATE OF status ON hazard_reports
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_report_status_guard();

-- 22. Intake of manual reports: attach to a nearby hazard, or open a PENDING one.
--     Applies to both entry points (report form and map marker).
CREATE OR REPLACE FUNCTION fn_report_link_hazard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.hazard_id IS NULL THEN
        NEW.hazard_id := fn_find_matching_hazard(NEW.location, NEW.hazard_type, NEW.heading_degrees);
        IF NEW.hazard_id IS NULL AND NEW.report_type IN ('new_hazard', 'confirm') THEN
            INSERT INTO hazards (hazard_type, location, heading_degrees, status)
            VALUES (NEW.hazard_type, NEW.location, NEW.heading_degrees, 'pending')
            RETURNING hazard_id INTO NEW.hazard_id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hazard_reports_link_hazard
    BEFORE INSERT ON hazard_reports
    FOR EACH ROW EXECUTE FUNCTION fn_report_link_hazard();

-- 23. Intake of AI detections.  A detection at/above the confidence floor is one VOTE of its account:
--     it is attached to the nearby hazard (also a rejected one, so a moderator's "no" is not queued again)
--     or opens a new PENDING hazard.  fn_refresh_hazard_stats then decides by the number of different accounts:
--     1-2 stored | 3-4 moderator queue | 5+ active automatically.
CREATE OR REPLACE FUNCTION fn_ai_intake()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.confidence_score >= fn_ai_min_confidence() THEN
        IF NEW.hazard_id IS NULL THEN
            NEW.hazard_id := fn_find_matching_hazard(NEW.location, NEW.hazard_type, NEW.heading_degrees, 25, TRUE);
            IF NEW.hazard_id IS NULL THEN
                INSERT INTO hazards (hazard_type, location, heading_degrees, status)
                VALUES (NEW.hazard_type, NEW.location, NEW.heading_degrees, 'pending')
                RETURNING hazard_id INTO NEW.hazard_id;
            END IF;
        END IF;
        NEW.status := 'matched';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ai_hazards_intake
    BEFORE INSERT ON ai_hazards
    FOR EACH ROW EXECUTE FUNCTION fn_ai_intake();

-- 24. Keep hazard statistics / status in sync after every change (no backend call needed).
CREATE OR REPLACE FUNCTION fn_trg_refresh_hazard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.hazard_id IS NOT NULL THEN
        PERFORM fn_refresh_hazard_stats(NEW.hazard_id);
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.hazard_id IS NOT NULL AND OLD.hazard_id IS DISTINCT FROM NEW.hazard_id THEN
        PERFORM fn_refresh_hazard_stats(OLD.hazard_id);
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_hazard_reports_refresh
    AFTER INSERT OR UPDATE OF status, hazard_id ON hazard_reports
    FOR EACH ROW EXECUTE FUNCTION fn_trg_refresh_hazard();

CREATE TRIGGER trg_ai_hazards_refresh
    AFTER INSERT OR UPDATE OF status, hazard_id ON ai_hazards
    FOR EACH ROW EXECUTE FUNCTION fn_trg_refresh_hazard();

-- 25. Every new account gets its default settings row.
CREATE OR REPLACE FUNCTION fn_create_default_settings()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO user_settings (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_default_settings
    AFTER INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION fn_create_default_settings();

-- 26. Hazard review (candidates built from AI votes wait in the moderator queue).
--     A moderator/administrator approves (status 'active') or rejects (status 'rejected') the hazard and
--     fills reviewed_by_user_id / reviewed_at.  Only staff may be named as reviewer; every decision is audited;
--     only the system (flag app.auto_approval) may change pending/rejected -> active/rejected without a reviewer.
CREATE OR REPLACE FUNCTION fn_hazard_reviewer_check()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM fn_require_staff(NEW.reviewed_by_user_id);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hazards_reviewer
    BEFORE INSERT OR UPDATE OF reviewed_by_user_id ON hazards
    FOR EACH ROW EXECUTE FUNCTION fn_hazard_reviewer_check();

CREATE OR REPLACE FUNCTION fn_hazard_status_guard()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.status IN ('pending', 'rejected')
       AND NEW.status IN ('active', 'rejected')
       AND NEW.reviewed_by_user_id IS NULL
       AND COALESCE(current_setting('app.auto_approval', true), '') <> 'on' THEN
        RAISE EXCEPTION 'Approving or rejecting a hazard requires reviewed_by_user_id'
            USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_hazards_status_guard
    BEFORE UPDATE OF status ON hazards
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION fn_hazard_status_guard();

CREATE OR REPLACE FUNCTION fn_audit_hazard_review()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO audit_logs (actor_user_id, action, entity_type, entity_id, details)
    VALUES (NEW.reviewed_by_user_id,
            CASE WHEN NEW.status = 'active' THEN 'hazard.approved' ELSE 'hazard.rejected' END,
            'hazard', NEW.hazard_id::text,
            jsonb_build_object('from', OLD.status, 'to', NEW.status, 'ai_users', NEW.ai_users_count));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_hazard_review
    AFTER UPDATE OF status ON hazards
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
          AND NEW.status IN ('active', 'rejected')
          AND NEW.reviewed_by_user_id IS NOT NULL)
    EXECUTE FUNCTION fn_audit_hazard_review();

-- 27. The moderator's work list: pending manual reports + hazards built from 3-4 AI accounts.
CREATE OR REPLACE VIEW v_moderator_queue AS
SELECT 'report'::text        AS item_type,
       r.report_id           AS item_id,
       r.hazard_id           AS hazard_id,
       r.hazard_type         AS hazard_type,
       r.location            AS location,
       r.heading_degrees     AS heading_degrees,
       r.report_type::text   AS detail,
       1                     AS users_count,
       r.created_at          AS queued_at
FROM hazard_reports r
WHERE r.status = 'pending'
UNION ALL
SELECT 'ai_candidate'::text,
       h.hazard_id,
       h.hazard_id,
       h.hazard_type,
       h.location,
       h.heading_degrees,
       'ai_detections'::text,
       h.ai_users_count,
       h.review_requested_at
FROM hazards h
WHERE h.status = 'pending' AND h.review_requested_at IS NOT NULL;

COMMIT;

-- =====================================================================
--  Usage examples
-- =====================================================================
-- Hazards ahead on a trip's planned route:
--   SELECT * FROM fn_hazards_near_route(
--       (SELECT planned_route FROM trips WHERE trip_id = '<trip-uuid>'), 30);
--
-- Link them to the trip once:
--   INSERT INTO trip_hazards (trip_id, hazard_id, distance_from_start_meters)
--   SELECT '<trip-uuid>', f.hazard_id, f.distance_from_start_meters
--   FROM fn_hazards_near_route(
--       (SELECT planned_route FROM trips WHERE trip_id = '<trip-uuid>')) f
--   ON CONFLICT (trip_id, hazard_id) DO NOTHING;
--
-- Mark a warning as fired / hazard as passed:
--   UPDATE trip_hazards SET notified_at = now() WHERE trip_id = '<t>' AND hazard_id = '<h>';
--   UPDATE trip_hazards SET passed_at = now(), speed_at_pass_kmh = 42
--    WHERE trip_id = '<t>' AND hazard_id = '<h>';
