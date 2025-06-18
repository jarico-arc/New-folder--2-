-- YugabyteDB Messaging Patterns Setup
-- Implements all 4 patterns from the field guide

-- ============================================================================
-- PATTERN 1: LISTEN/NOTIFY (PG-style lightweight pub-sub)
-- ============================================================================

-- Enable notifications (already available in YugabyteDB)
-- No setup required - LISTEN/NOTIFY works out of the box

-- Example usage:
-- Publisher:
-- SELECT pg_notify('cache_invalidate', json_build_object('key', 'user:123', 'action', 'update')::text);

-- Subscriber (in application):
-- LISTEN cache_invalidate;
-- SELECT 1 FROM pg_notification_queue() LIMIT 1;

-- ============================================================================
-- PATTERN 2: Queue Table + SKIP LOCKED (Transactional Job/Task Queue)
-- ============================================================================

-- Create job queue table with optimal sharding
CREATE TABLE job_queue (
    job_id      BIGSERIAL PRIMARY KEY,
    job_type    TEXT NOT NULL,
    payload     JSONB NOT NULL,
    priority    INTEGER DEFAULT 0,
    run_after   TIMESTAMPTZ NOT NULL DEFAULT now(),
    locked_by   TEXT,
    locked_at   TIMESTAMPTZ,
    processed   BOOLEAN DEFAULT false,
    failed      BOOLEAN DEFAULT false,
    error_msg   TEXT,
    retry_count INTEGER DEFAULT 0,
    max_retries INTEGER DEFAULT 3,
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
) SPLIT INTO 8 TABLETS;

-- Partial index for faster queue polling
CREATE INDEX CONCURRENTLY idx_job_queue_pending 
ON job_queue (priority DESC, job_id ASC) 
WHERE processed = false AND failed = false AND run_after <= now();

-- Index for cleanup operations
CREATE INDEX CONCURRENTLY idx_job_queue_cleanup 
ON job_queue (created_at) 
WHERE processed = true OR failed = true;

-- Function to enqueue jobs
CREATE OR REPLACE FUNCTION enqueue_job(
    p_job_type TEXT,
    p_payload JSONB,
    p_priority INTEGER DEFAULT 0,
    p_delay_seconds INTEGER DEFAULT 0
) RETURNS BIGINT AS $$
DECLARE
    job_id BIGINT;
BEGIN
    INSERT INTO job_queue (job_type, payload, priority, run_after)
    VALUES (
        p_job_type, 
        p_payload, 
        p_priority, 
        now() + (p_delay_seconds || ' seconds')::INTERVAL
    )
    RETURNING job_queue.job_id INTO job_id;
    
    -- Notify listeners about new job
    PERFORM pg_notify('new_job', json_build_object(
        'job_id', job_id,
        'job_type', p_job_type,
        'priority', p_priority
    )::text);
    
    RETURN job_id;
END;
$$ LANGUAGE plpgsql;

-- Function to dequeue and process jobs
CREATE OR REPLACE FUNCTION dequeue_job(
    p_worker_id TEXT,
    p_job_types TEXT[] DEFAULT NULL
) RETURNS TABLE(
    job_id BIGINT,
    job_type TEXT,
    payload JSONB,
    retry_count INTEGER
) AS $$
BEGIN
    RETURN QUERY
    WITH next_job AS (
        SELECT jq.job_id, jq.job_type, jq.payload, jq.retry_count
        FROM job_queue jq
        WHERE jq.processed = false 
          AND jq.failed = false
          AND jq.run_after <= now()
          AND (p_job_types IS NULL OR jq.job_type = ANY(p_job_types))
        ORDER BY jq.priority DESC, jq.job_id ASC
        FOR UPDATE SKIP LOCKED
        LIMIT 1
    )
    UPDATE job_queue jq
    SET locked_by = p_worker_id,
        locked_at = now(),
        updated_at = now()
    FROM next_job nj
    WHERE jq.job_id = nj.job_id
    RETURNING jq.job_id, jq.job_type, jq.payload, jq.retry_count;
END;
$$ LANGUAGE plpgsql;

-- Function to mark job as completed
CREATE OR REPLACE FUNCTION complete_job(p_job_id BIGINT) RETURNS BOOLEAN AS $$
BEGIN
    UPDATE job_queue 
    SET processed = true, 
        updated_at = now()
    WHERE job_id = p_job_id 
      AND processed = false;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- Function to mark job as failed
CREATE OR REPLACE FUNCTION fail_job(
    p_job_id BIGINT, 
    p_error_msg TEXT,
    p_retry BOOLEAN DEFAULT true
) RETURNS BOOLEAN AS $$
DECLARE
    current_retry_count INTEGER;
    max_retry_count INTEGER;
BEGIN
    SELECT retry_count, max_retries 
    INTO current_retry_count, max_retry_count
    FROM job_queue 
    WHERE job_id = p_job_id;
    
    IF p_retry AND current_retry_count < max_retry_count THEN
        -- Retry with exponential backoff
        UPDATE job_queue 
        SET retry_count = retry_count + 1,
            run_after = now() + (POWER(2, retry_count + 1) || ' seconds')::INTERVAL,
            error_msg = p_error_msg,
            locked_by = NULL,
            locked_at = NULL,
            updated_at = now()
        WHERE job_id = p_job_id;
    ELSE
        -- Mark as permanently failed
        UPDATE job_queue 
        SET failed = true,
            error_msg = p_error_msg,
            updated_at = now()
        WHERE job_id = p_job_id;
    END IF;
    
    RETURN FOUND;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PATTERN 3: CDC Tables (for Kafka/Event Streaming)
-- ============================================================================

-- Events table for CDC streaming
CREATE TABLE events (
    event_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type  TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id   TEXT NOT NULL,
    event_data  JSONB NOT NULL,
    metadata    JSONB DEFAULT '{}',
    occurred_at TIMESTAMPTZ DEFAULT now(),
    version     INTEGER DEFAULT 1
) SPLIT INTO 8 TABLETS;

-- Index for event sourcing queries
CREATE INDEX CONCURRENTLY idx_events_entity 
ON events (entity_type, entity_id, occurred_at DESC);

-- Index for event type filtering
CREATE INDEX CONCURRENTLY idx_events_type_time 
ON events (event_type, occurred_at DESC);

-- Function to emit events
CREATE OR REPLACE FUNCTION emit_event(
    p_event_type TEXT,
    p_entity_type TEXT,
    p_entity_id TEXT,
    p_event_data JSONB,
    p_metadata JSONB DEFAULT '{}'
) RETURNS UUID AS $$
DECLARE
    event_id UUID;
BEGIN
    INSERT INTO events (event_type, entity_type, entity_id, event_data, metadata)
    VALUES (p_event_type, p_entity_type, p_entity_id, p_event_data, p_metadata)
    RETURNING events.event_id INTO event_id;
    
    -- Also send immediate notification for real-time listeners
    PERFORM pg_notify('event_stream', json_build_object(
        'event_id', event_id,
        'event_type', p_event_type,
        'entity_type', p_entity_type,
        'entity_id', p_entity_id
    )::text);
    
    RETURN event_id;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PATTERN 4: Logical Replication Setup (Read-only Event Log)
-- ============================================================================

-- Create a publication for logical replication
-- (Requires ysql_enable_logical_replication flag to be enabled)
CREATE PUBLICATION events_publication FOR TABLE events, job_queue;

-- Create a replication slot
-- SELECT pg_create_logical_replication_slot('events_slot', 'pgoutput');

-- Note: Logical replication setup requires additional configuration
-- and is typically done at the cluster level

-- ============================================================================
-- DEMO DATA AND EXAMPLES
-- ============================================================================

-- Example: E-commerce order processing workflow
CREATE TABLE orders (
    order_id    BIGSERIAL PRIMARY KEY,
    customer_id BIGINT NOT NULL,
    total       DECIMAL(10,2) NOT NULL,
    status      TEXT DEFAULT 'pending',
    created_at  TIMESTAMPTZ DEFAULT now(),
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Example: Product catalog with cache invalidation
CREATE TABLE products (
    product_id  BIGSERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    price       DECIMAL(10,2) NOT NULL,
    inventory   INTEGER DEFAULT 0,
    updated_at  TIMESTAMPTZ DEFAULT now()
);

-- Trigger to emit events on order changes
CREATE OR REPLACE FUNCTION notify_order_change() RETURNS TRIGGER AS $$
BEGIN
    -- Emit event for CDC/streaming
    PERFORM emit_event(
        'order.' || TG_OP::text,
        'order',
        NEW.order_id::text,
        row_to_json(NEW)::jsonb
    );
    
    -- For urgent processing, also enqueue a job
    IF NEW.status = 'paid' THEN
        PERFORM enqueue_job(
            'process_payment',
            json_build_object(
                'order_id', NEW.order_id,
                'customer_id', NEW.customer_id,
                'total', NEW.total
            )::jsonb,
            1  -- High priority
        );
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER order_change_trigger
    AFTER INSERT OR UPDATE ON orders
    FOR EACH ROW EXECUTE FUNCTION notify_order_change();

-- Trigger for cache invalidation on product changes
CREATE OR REPLACE FUNCTION invalidate_product_cache() RETURNS TRIGGER AS $$
BEGIN
    -- Immediate cache invalidation via LISTEN/NOTIFY
    PERFORM pg_notify('cache_invalidate', json_build_object(
        'type', 'product',
        'id', NEW.product_id,
        'action', TG_OP
    )::text);
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER product_cache_invalidation
    AFTER INSERT OR UPDATE OR DELETE ON products
    FOR EACH ROW EXECUTE FUNCTION invalidate_product_cache();

-- ============================================================================
-- CLEANUP AND MAINTENANCE FUNCTIONS
-- ============================================================================

-- Function to clean up old processed jobs
CREATE OR REPLACE FUNCTION cleanup_old_jobs(p_days_old INTEGER DEFAULT 7) RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM job_queue 
    WHERE (processed = true OR failed = true)
      AND created_at < now() - (p_days_old || ' days')::INTERVAL;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Function to get queue statistics
CREATE OR REPLACE FUNCTION get_queue_stats() RETURNS TABLE(
    job_type TEXT,
    pending INTEGER,
    processing INTEGER,
    failed INTEGER,
    avg_wait_time INTERVAL
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        jq.job_type,
        COUNT(*) FILTER (WHERE jq.processed = false AND jq.failed = false AND jq.locked_by IS NULL)::INTEGER as pending,
        COUNT(*) FILTER (WHERE jq.locked_by IS NOT NULL AND jq.processed = false)::INTEGER as processing,
        COUNT(*) FILTER (WHERE jq.failed = true)::INTEGER as failed,
        AVG(CASE 
            WHEN jq.processed = true THEN jq.updated_at - jq.created_at
            ELSE NULL 
        END) as avg_wait_time
    FROM job_queue jq
    GROUP BY jq.job_type
    ORDER BY pending DESC;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- PERFORMANCE TUNING
-- ============================================================================

-- Enable parallel query execution for analytics
SET max_parallel_workers_per_gather = 4;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;

-- Optimize for queue table performance
ALTER TABLE job_queue SET (fillfactor = 90);
ALTER TABLE events SET (fillfactor = 95);

-- ============================================================================
-- MONITORING VIEWS
-- ============================================================================

-- View for monitoring queue health
CREATE VIEW queue_monitor AS
SELECT 
    job_type,
    COUNT(*) FILTER (WHERE processed = false AND failed = false AND run_after <= now()) as ready,
    COUNT(*) FILTER (WHERE locked_by IS NOT NULL AND processed = false) as processing,
    COUNT(*) FILTER (WHERE failed = true) as failed,
    COUNT(*) FILTER (WHERE run_after > now()) as scheduled,
    MAX(created_at) as last_job_time,
    AVG(EXTRACT(EPOCH FROM (COALESCE(updated_at, now()) - created_at))) as avg_processing_seconds
FROM job_queue
GROUP BY job_type
ORDER BY ready DESC;

-- View for CDC lag monitoring
CREATE VIEW cdc_monitor AS
SELECT 
    schemaname,
    tablename,
    n_tup_ins as inserts,
    n_tup_upd as updates,
    n_tup_del as deletes,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'public'
  AND tablename IN ('events', 'orders', 'products', 'job_queue');

COMMENT ON TABLE job_queue IS 'High-performance job queue using FOR UPDATE SKIP LOCKED pattern';
COMMENT ON TABLE events IS 'Event store for CDC streaming and event sourcing';
COMMENT ON FUNCTION enqueue_job IS 'Safely enqueue jobs with priority and delay support';
COMMENT ON FUNCTION dequeue_job IS 'Atomically dequeue jobs using SKIP LOCKED for concurrency';
COMMENT ON VIEW queue_monitor IS 'Real-time queue health monitoring';

-- Grant permissions for application users
-- GRANT SELECT, INSERT, UPDATE ON job_queue TO app_user;
-- GRANT EXECUTE ON FUNCTION enqueue_job TO app_user;
-- GRANT EXECUTE ON FUNCTION dequeue_job TO app_user;
-- GRANT EXECUTE ON FUNCTION complete_job TO app_user;
-- GRANT EXECUTE ON FUNCTION fail_job TO app_user; 