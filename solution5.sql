-- Q5 - Hostel Room Allocation
-- One student = one ACTIVE allocation. ENDED = history, does not occupy a bed.

-- (a) Tables
CREATE TABLE IF NOT EXISTS students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE IF NOT EXISTS allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CHECK ((status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL DEFAULT 0,
    free_beds INT NOT NULL DEFAULT 0,
    PRIMARY KEY (snapshot_date, room_id)
);

-- (b) Function: free beds in a room
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE
    v_capacity INT;
    v_active INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room: %', p_room_id;
    END IF;
    SELECT COUNT(*) INTO v_active FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';
    RETURN v_capacity - v_active;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: allocate room
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student: %', p_student_id;
    END IF;
    IF NOT EXISTS(SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room: %', p_room_id;
    END IF;
    IF EXISTS(SELECT 1 FROM allocations
              WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;
    INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: also enforce for direct SQL INSERT / UPDATE
-- Excludes the row being updated from the counts.
CREATE OR REPLACE FUNCTION trg_allocation_check_fn()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity INT;
    v_occupied INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        IF NEW.released_on IS NOT NULL THEN
            RAISE EXCEPTION 'ACTIVE allocation must have released_on NULL';
        END IF;
        -- One ACTIVE per student, excluding self
        IF EXISTS(SELECT 1 FROM allocations
                  WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                    AND allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
        -- Capacity, excluding self
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id;
        SELECT COUNT(*) INTO v_occupied FROM allocations
        WHERE room_id = NEW.room_id AND status = 'ACTIVE'
          AND allocation_id <> COALESCE(NEW.allocation_id, -1);
        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full', NEW.room_id;
        END IF;
    ELSIF NEW.status = 'ENDED' THEN
        IF NEW.released_on IS NULL THEN
            RAISE EXCEPTION 'ENDED allocation must have a release date';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_allocation_check ON allocations;
CREATE TRIGGER trg_allocation_check
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_check_fn();

-- (a) Seed data: rooms = full, partly occupied, empty
INSERT INTO students(student_number, full_name) VALUES
('STU001', 'Chanda Mwila'),
('STU002', 'Grace Banda'),
('STU003', 'Peter Phiri'),
('STU004', 'Mary Zulu'),
('STU005', 'John Tembo')
ON CONFLICT (student_number) DO NOTHING;

INSERT INTO rooms(room_number, capacity) VALUES
('R101', 2),
('R102', 3),
('R103', 2)
ON CONFLICT (room_number) DO NOTHING;

-- R101 full (2 ACTIVE), R102 partly occupied (1 ACTIVE + 1 ENDED history), R103 empty
CALL pr_allocate_room(1, 1, '2026-01-05');
CALL pr_allocate_room(2, 1, '2026-01-05');
CALL pr_allocate_room(3, 2, '2026-01-06');
-- ENDED history: student 4 was in R102, now released - does NOT occupy a bed
INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, '2026-01-01', '2026-01-10', 'ENDED');

-- (e) View: every room, including rooms with no allocations
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_number, r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
       fn_free_beds(r.room_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index: ACTIVE allocations filtered by room_id
-- Justification: Partial index on room_id WHERE status = 'ACTIVE' matches
-- the query exactly. It is small (only ACTIVE rows) and lets Postgres
-- seek by room instead of scanning all allocations including ENDED history.
CREATE INDEX IF NOT EXISTS idx_allocations_room_active
ON allocations(room_id) WHERE status = 'ACTIVE';

-- Matching query + plan:
-- EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';

-- (g) Scheduled job: refresh occupancy snapshot
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
AS $$
BEGIN
    INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id,
           (r.capacity - fn_free_beds(r.room_id)),
           fn_free_beds(r.room_id)
    FROM rooms r
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$ LANGUAGE plpgsql;

-- Test refresh:
CALL pr_refresh_occupancy();

-- Schedule daily at 23:55 (pg_cron):
-- SELECT cron.schedule('refresh-occupancy-daily', '55 23 * * *',
--   $$CALL pr_refresh_occupancy()$$);

-- Checks:
SELECT * FROM v_room_occupancy;
SELECT fn_free_beds(1);
SELECT fn_free_beds(2);
SELECT fn_free_beds(3);
SELECT * FROM occupancy_snapshot;