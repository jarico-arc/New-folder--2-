-- Example Stored Procedures for YugabyteDB RBAC
-- These procedures demonstrate how to implement secure data access
-- All procedures use SECURITY DEFINER to run with elevated privileges

-- =====================================================
-- USER MANAGEMENT PROCEDURES
-- =====================================================

-- Create a new user with validation and audit logging
CREATE OR REPLACE FUNCTION app_schema.create_user(
    p_username VARCHAR,
    p_email VARCHAR
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id INTEGER;
    v_email_regex VARCHAR := '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$';
BEGIN
    -- Input validation
    IF p_username IS NULL OR LENGTH(TRIM(p_username)) = 0 THEN
        RAISE EXCEPTION 'Username cannot be empty';
    END IF;
    
    IF LENGTH(p_username) < 3 THEN
        RAISE EXCEPTION 'Username must be at least 3 characters long';
    END IF;
    
    IF p_email IS NULL OR NOT p_email ~ v_email_regex THEN
        RAISE EXCEPTION 'Invalid email format';
    END IF;
    
    -- Check for duplicates
    IF EXISTS (SELECT 1 FROM app_schema.users WHERE username = p_username) THEN
        RAISE EXCEPTION 'Username already exists';
    END IF;
    
    IF EXISTS (SELECT 1 FROM app_schema.users WHERE email = p_email) THEN
        RAISE EXCEPTION 'Email already exists';
    END IF;
    
    -- Insert user
    INSERT INTO app_schema.users (username, email)
    VALUES (TRIM(p_username), LOWER(TRIM(p_email)))
    RETURNING id INTO v_user_id;
    
    -- Audit log
    INSERT INTO app_schema.audit_log (user_id, action, details)
    VALUES (v_user_id, 'USER_CREATED', 
            json_build_object(
                'username', p_username, 
                'email', p_email,
                'created_by', session_user,
                'timestamp', CURRENT_TIMESTAMP
            ));
    
    RETURN v_user_id;
END;
$$;

-- Get user information by username (read-only)
CREATE OR REPLACE FUNCTION app_schema.get_user_by_username(
    p_username VARCHAR
) RETURNS TABLE(
    id INTEGER, 
    username VARCHAR, 
    email VARCHAR, 
    created_at TIMESTAMP
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF p_username IS NULL OR LENGTH(TRIM(p_username)) = 0 THEN
        RAISE EXCEPTION 'Username cannot be empty';
    END IF;
    
    RETURN QUERY
    SELECT u.id, u.username, u.email, u.created_at
    FROM app_schema.users u
    WHERE u.username = p_username;
    
    -- Log the access (optional - for high-security environments)
    INSERT INTO app_schema.audit_log (user_id, action, details)
    SELECT u.id, 'USER_ACCESSED', 
           json_build_object(
               'username', p_username,
               'accessed_by', session_user,
               'timestamp', CURRENT_TIMESTAMP
           )
    FROM app_schema.users u
    WHERE u.username = p_username;
END;
$$;

-- Update user email with validation and audit
CREATE OR REPLACE FUNCTION app_schema.update_user_email(
    p_user_id INTEGER,
    p_new_email VARCHAR
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_old_email VARCHAR;
    v_updated INTEGER;
    v_email_regex VARCHAR := '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$';
BEGIN
    -- Validate new email
    IF p_new_email IS NULL OR NOT p_new_email ~ v_email_regex THEN
        RAISE EXCEPTION 'Invalid email format';
    END IF;
    
    -- Get current email and check if user exists
    SELECT email INTO v_old_email 
    FROM app_schema.users 
    WHERE id = p_user_id;
    
    IF v_old_email IS NULL THEN
        RAISE EXCEPTION 'User not found';
    END IF;
    
    -- Check if new email is already taken
    IF EXISTS (SELECT 1 FROM app_schema.users WHERE email = p_new_email AND id != p_user_id) THEN
        RAISE EXCEPTION 'Email already exists';
    END IF;
    
    -- Update email
    UPDATE app_schema.users 
    SET email = LOWER(TRIM(p_new_email)), 
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_user_id;
    
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    
    -- Audit log
    INSERT INTO app_schema.audit_log (user_id, action, details)
    VALUES (p_user_id, 'EMAIL_UPDATED', 
            json_build_object(
                'old_email', v_old_email, 
                'new_email', p_new_email,
                'updated_by', session_user,
                'timestamp', CURRENT_TIMESTAMP
            ));
    
    RETURN v_updated > 0;
END;
$$;

-- Soft delete user (sets deleted flag instead of actual deletion)
CREATE OR REPLACE FUNCTION app_schema.deactivate_user(
    p_user_id INTEGER,
    p_reason VARCHAR DEFAULT 'User requested'
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_username VARCHAR;
    v_updated INTEGER;
BEGIN
    -- Add deleted_at column if it doesn't exist
    BEGIN
        ALTER TABLE app_schema.users ADD COLUMN deleted_at TIMESTAMP;
        ALTER TABLE app_schema.users ADD COLUMN deletion_reason VARCHAR(500);
    EXCEPTION 
        WHEN duplicate_column THEN 
            NULL; -- Column already exists
    END;
    
    -- Get username for audit
    SELECT username INTO v_username 
    FROM app_schema.users 
    WHERE id = p_user_id AND deleted_at IS NULL;
    
    IF v_username IS NULL THEN
        RAISE EXCEPTION 'User not found or already deactivated';
    END IF;
    
    -- Soft delete
    UPDATE app_schema.users 
    SET deleted_at = CURRENT_TIMESTAMP,
        deletion_reason = p_reason,
        updated_at = CURRENT_TIMESTAMP
    WHERE id = p_user_id;
    
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    
    -- Audit log
    INSERT INTO app_schema.audit_log (user_id, action, details)
    VALUES (p_user_id, 'USER_DEACTIVATED', 
            json_build_object(
                'username', v_username,
                'reason', p_reason,
                'deactivated_by', session_user,
                'timestamp', CURRENT_TIMESTAMP
            ));
    
    RETURN v_updated > 0;
END;
$$;

-- =====================================================
-- AUDIT AND REPORTING PROCEDURES
-- =====================================================

-- Get audit log for a specific user
CREATE OR REPLACE FUNCTION app_schema.get_user_audit_log(
    p_user_id INTEGER,
    p_limit INTEGER DEFAULT 50
) RETURNS TABLE(
    id INTEGER,
    action VARCHAR,
    details JSONB,
    created_at TIMESTAMP
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF p_limit > 1000 THEN
        RAISE EXCEPTION 'Limit cannot exceed 1000 records';
    END IF;
    
    RETURN QUERY
    SELECT a.id, a.action, a.details, a.created_at
    FROM app_schema.audit_log a
    WHERE a.user_id = p_user_id
    ORDER BY a.created_at DESC
    LIMIT p_limit;
END;
$$;

-- Get recent activity summary
CREATE OR REPLACE FUNCTION app_schema.get_activity_summary(
    p_hours INTEGER DEFAULT 24
) RETURNS TABLE(
    action VARCHAR,
    count BIGINT,
    latest_occurrence TIMESTAMP
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF p_hours > 168 THEN -- Max 1 week
        RAISE EXCEPTION 'Hours cannot exceed 168 (1 week)';
    END IF;
    
    RETURN QUERY
    SELECT a.action, COUNT(*) as count, MAX(a.created_at) as latest_occurrence
    FROM app_schema.audit_log a
    WHERE a.created_at > CURRENT_TIMESTAMP - INTERVAL '1 hour' * p_hours
    GROUP BY a.action
    ORDER BY count DESC;
END;
$$;

-- =====================================================
-- UTILITY PROCEDURES
-- =====================================================

-- Search users with pagination
CREATE OR REPLACE FUNCTION app_schema.search_users(
    p_search_term VARCHAR,
    p_offset INTEGER DEFAULT 0,
    p_limit INTEGER DEFAULT 20
) RETURNS TABLE(
    id INTEGER,
    username VARCHAR,
    email VARCHAR,
    created_at TIMESTAMP
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    IF p_limit > 100 THEN
        RAISE EXCEPTION 'Limit cannot exceed 100 records';
    END IF;
    
    IF p_search_term IS NULL OR LENGTH(TRIM(p_search_term)) < 2 THEN
        RAISE EXCEPTION 'Search term must be at least 2 characters';
    END IF;
    
    RETURN QUERY
    SELECT u.id, u.username, u.email, u.created_at
    FROM app_schema.users u
    WHERE u.deleted_at IS NULL 
      AND (u.username ILIKE '%' || p_search_term || '%' 
           OR u.email ILIKE '%' || p_search_term || '%')
    ORDER BY u.username
    OFFSET p_offset
    LIMIT p_limit;
    
    -- Log the search
    INSERT INTO app_schema.audit_log (user_id, action, details)
    VALUES (NULL, 'USER_SEARCH', 
            json_build_object(
                'search_term', p_search_term,
                'searched_by', session_user,
                'timestamp', CURRENT_TIMESTAMP
            ));
END;
$$;

-- =====================================================
-- GRANT PERMISSIONS TO APPLICATION ROLE
-- =====================================================

-- NOTE: Replace {ENVIRONMENT} with actual environment name (dev, staging, prod) when deploying
-- For automated deployment, use the setup-database-rbac.sh script which handles this replacement

-- Example grants (replace {ENVIRONMENT} with dev, staging, or prod):
-- GRANT EXECUTE ON FUNCTION app_schema.create_user(VARCHAR, VARCHAR) TO codet_dev_app;
-- GRANT EXECUTE ON FUNCTION app_schema.get_user_by_username(VARCHAR) TO codet_dev_app;
-- etc.

-- Template grants for script processing:
GRANT EXECUTE ON FUNCTION app_schema.create_user(VARCHAR, VARCHAR) TO codet_{ENVIRONMENT}_app;
GRANT EXECUTE ON FUNCTION app_schema.get_user_by_username(VARCHAR) TO codet_{ENVIRONMENT}_app;
GRANT EXECUTE ON FUNCTION app_schema.update_user_email(INTEGER, VARCHAR) TO codet_{ENVIRONMENT}_app;
GRANT EXECUTE ON FUNCTION app_schema.deactivate_user(INTEGER, VARCHAR) TO codet_{ENVIRONMENT}_app;
GRANT EXECUTE ON FUNCTION app_schema.get_user_audit_log(INTEGER, INTEGER) TO codet_{ENVIRONMENT}_app;
GRANT EXECUTE ON FUNCTION app_schema.get_activity_summary(INTEGER) TO codet_{ENVIRONMENT}_app;
GRANT EXECUTE ON FUNCTION app_schema.search_users(VARCHAR, INTEGER, INTEGER) TO codet_{ENVIRONMENT}_app;

-- =====================================================
-- SECURITY TEST QUERIES
-- =====================================================

/*
-- Test the security implementation by connecting as the application role and trying:

-- These should WORK (application role has EXECUTE permissions):
SELECT app_schema.create_user('testuser', 'test@example.com');
SELECT * FROM app_schema.get_user_by_username('testuser');
SELECT app_schema.update_user_email(1, 'newemail@example.com');

-- These should FAIL (application role has NO table permissions):
SELECT * FROM app_schema.users;                    -- Permission denied
INSERT INTO app_schema.users VALUES (...);         -- Permission denied
UPDATE app_schema.users SET email = '...';         -- Permission denied
DELETE FROM app_schema.users WHERE id = 1;         -- Permission denied
DROP TABLE app_schema.users;                       -- Permission denied
*/ 