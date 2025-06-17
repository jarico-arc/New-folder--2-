-- YugabyteDB RBAC Setup Template
-- This file contains the SQL commands to set up role-based access control
-- Replace {ENVIRONMENT} with your actual environment name (dev, staging, prod)

-- Create admin role for environment management
CREATE ROLE codet_{ENVIRONMENT}_admin WITH LOGIN PASSWORD 'your-secure-admin-password' SUPERUSER;

-- Create application role with restricted access
CREATE ROLE codet_{ENVIRONMENT}_app WITH LOGIN PASSWORD 'your-secure-app-password';

-- Create application database
CREATE DATABASE codet_{ENVIRONMENT} OWNER codet_{ENVIRONMENT}_admin;

-- Connect to the application database
\c codet_{ENVIRONMENT}

-- Create application schema
CREATE SCHEMA IF NOT EXISTS app_schema AUTHORIZATION codet_{ENVIRONMENT}_admin;

-- Grant schema usage to application role
GRANT USAGE ON SCHEMA app_schema TO codet_{ENVIRONMENT}_app;

-- Example table structure
CREATE TABLE IF NOT EXISTS app_schema.users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS app_schema.audit_log (
    id SERIAL PRIMARY KEY,
    user_id INTEGER,
    action VARCHAR(255) NOT NULL,
    details JSONB,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_username ON app_schema.users(username);
CREATE INDEX IF NOT EXISTS idx_users_email ON app_schema.users(email);
CREATE INDEX IF NOT EXISTS idx_audit_log_user_id ON app_schema.audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at ON app_schema.audit_log(created_at);

-- SECURITY CRITICAL: Revoke all default permissions from application role
REVOKE ALL ON TABLE app_schema.users FROM codet_{ENVIRONMENT}_app;
REVOKE ALL ON TABLE app_schema.audit_log FROM codet_{ENVIRONMENT}_app;
REVOKE ALL ON SCHEMA public FROM codet_{ENVIRONMENT}_app;
REVOKE CREATE ON SCHEMA app_schema FROM codet_{ENVIRONMENT}_app;
REVOKE CREATE ON DATABASE codet_{ENVIRONMENT} FROM codet_{ENVIRONMENT}_app;

-- Create a view for safe user data access (optional)
CREATE VIEW app_schema.user_info AS 
SELECT id, username, email, created_at 
FROM app_schema.users;

-- Grant view access to application role
GRANT SELECT ON app_schema.user_info TO codet_{ENVIRONMENT}_app;

-- Display final security configuration
SELECT 
    'RBAC Configuration Complete' as status,
    'Application role has NO direct table access' as security_note,
    'All operations must go through stored procedures' as requirement; 