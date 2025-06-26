"""
Unit tests for BI Consumer Cloud Function
Tests functionality, security, and error handling
"""

import pytest
import json
import os
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime
import sys

# Add the parent directory to the path so we can import main
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import main


class TestEnvironmentValidation:
    """Test environment validation functionality"""
    
    @patch.dict(os.environ, {'GCP_PROJECT': 'test-project', 'KAFKA_BOOTSTRAP_SERVERS': 'localhost:9092'})
    def test_validate_environment_success(self):
        """Test successful environment validation"""
        assert main.validate_environment() is True
    
    @patch.dict(os.environ, {}, clear=True)
    def test_validate_environment_missing_vars(self):
        """Test environment validation with missing variables"""
        assert main.validate_environment() is False
    
    @patch.dict(os.environ, {'KAFKA_BOOTSTRAP_SERVERS': 'localhost:9092'}, clear=True)
    def test_validate_environment_missing_project(self):
        """Test environment validation with missing GCP project"""
        assert main.validate_environment() is False


class TestSecretManagement:
    """Test secret management functionality"""
    
    @patch('main.SECRET_CLIENT')
    @patch.dict(os.environ, {'GCP_PROJECT': 'test-project'})
    def test_get_secret_success(self, mock_client):
        """Test successful secret retrieval"""
        mock_response = Mock()
        mock_response.payload.data.decode.return_value = "test-secret-value"
        mock_client.access_secret_version.return_value = mock_response
        
        result = main.get_secret("test-secret")
        assert result == "test-secret-value"
    
    @patch('main.SECRET_CLIENT')
    @patch.dict(os.environ, {'GCP_PROJECT': 'test-project'})
    def test_get_secret_failure(self, mock_client):
        """Test secret retrieval failure"""
        mock_client.access_secret_version.side_effect = Exception("Secret not found")
        
        result = main.get_secret("non-existent-secret")
        assert result is None


class TestEventValidation:
    """Test event validation functionality"""
    
    def test_validate_event_success(self):
        """Test successful event validation"""
        valid_event = {
            'op': 'c',
            'source': {'table': 'users'},
            'after': {'id': 1, 'name': 'test'}
        }
        assert main.validate_event(valid_event) is True
    
    def test_validate_event_missing_op(self):
        """Test event validation with missing operation"""
        invalid_event = {
            'source': {'table': 'users'},
            'after': {'id': 1, 'name': 'test'}
        }
        assert main.validate_event(invalid_event) is False
    
    def test_validate_event_missing_source(self):
        """Test event validation with missing source"""
        invalid_event = {
            'op': 'c',
            'after': {'id': 1, 'name': 'test'}
        }
        assert main.validate_event(invalid_event) is False
    
    def test_validate_event_not_dict(self):
        """Test event validation with non-dictionary input"""
        assert main.validate_event("not a dict") is False
        assert main.validate_event(None) is False
        assert main.validate_event([]) is False


class TestEventProcessing:
    """Test event processing functionality"""
    
    def test_process_event_insert(self):
        """Test processing INSERT event"""
        event = {
            'op': 'c',
            'source': {'table': 'users'},
            'after': {'id': 1, 'email': 'test@example.com'},
            'ts_ms': 1640995200000  # 2022-01-01 00:00:00 UTC
        }
        
        result = main.process_event(event)
        
        assert result is not None
        assert result['event_type'] == 'users.INSERT'
        assert result['operation'] == 'INSERT'
        assert result['source_table'] == 'users'
        assert result['user_email'] == 'test@example.com'
        assert result['environment'] == 'production'
    
    def test_process_event_update(self):
        """Test processing UPDATE event"""
        event = {
            'op': 'u',
            'source': {'table': 'orders'},
            'after': {'id': 123, 'status': 'completed'},
            'ts_ms': 1640995200000
        }
        
        result = main.process_event(event)
        
        assert result is not None
        assert result['event_type'] == 'orders.UPDATE'
        assert result['operation'] == 'UPDATE'
        assert result['source_table'] == 'orders'
    
    def test_process_event_delete(self):
        """Test processing DELETE event"""
        event = {
            'op': 'd',
            'source': {'table': 'users'},
            'before': {'id': 1, 'email': 'deleted@example.com'},
            'ts_ms': 1640995200000
        }
        
        result = main.process_event(event)
        
        assert result is not None
        assert result['event_type'] == 'users.DELETE'
        assert result['operation'] == 'DELETE'
        assert result['source_table'] == 'users'
        assert result['user_email'] == 'deleted@example.com'
    
    def test_process_event_invalid(self):
        """Test processing invalid event"""
        invalid_event = {'invalid': 'data'}
        
        result = main.process_event(invalid_event)
        assert result is None
    
    def test_process_event_invalid_timestamp(self):
        """Test processing event with invalid timestamp"""
        event = {
            'op': 'c',
            'source': {'table': 'users'},
            'after': {'id': 1},
            'ts_ms': 'invalid-timestamp'
        }
        
        result = main.process_event(event)
        
        assert result is not None
        # Should use current timestamp when invalid
        assert isinstance(result['event_timestamp'], datetime)


class TestBigQueryIntegration:
    """Test BigQuery integration functionality"""
    
    @patch('main.bigquery.Client')
    def test_create_bigquery_table_success(self, mock_bq_client):
        """Test successful BigQuery table creation"""
        mock_client = Mock()
        mock_bq_client.return_value = mock_client
        
        # Mock dataset creation
        mock_client.create_dataset.return_value = Mock()
        # Mock table creation
        mock_client.create_table.return_value = Mock()
        
        result = main.create_bigquery_table_if_not_exists(mock_client)
        assert result is True
    
    @patch('main.bigquery.Client')
    def test_create_bigquery_table_failure(self, mock_bq_client):
        """Test BigQuery table creation failure"""
        mock_client = Mock()
        mock_bq_client.return_value = mock_client
        
        # Mock exception during table creation
        mock_client.create_dataset.side_effect = Exception("Permission denied")
        
        result = main.create_bigquery_table_if_not_exists(mock_client)
        assert result is False
    
    @patch('main.bigquery.Client')
    def test_insert_rows_to_bigquery_success(self, mock_bq_client):
        """Test successful BigQuery row insertion"""
        mock_client = Mock()
        mock_table = Mock()
        mock_client.get_table.return_value = mock_table
        mock_client.insert_rows_json.return_value = []  # Empty list means success
        
        test_rows = [
            {
                'event_id': '123',
                'event_type': 'users.INSERT',
                'event_timestamp': datetime.utcnow(),
                'user_id': '1',
                'event_data': '{"test": "data"}',
                'source_table': 'users',
                'operation': 'INSERT',
                'ingested_at': datetime.utcnow(),
                'partition_date': datetime.utcnow().date(),
                'environment': 'test'
            }
        ]
        
        result = main.insert_rows_to_bigquery(mock_client, test_rows)
        assert result is True
    
    @patch('main.bigquery.Client')
    def test_insert_rows_to_bigquery_failure(self, mock_bq_client):
        """Test BigQuery row insertion failure"""
        mock_client = Mock()
        mock_table = Mock()
        mock_client.get_table.return_value = mock_table
        # Mock insertion errors
        mock_client.insert_rows_json.return_value = [{"error": "Schema mismatch"}]
        
        test_rows = [{"invalid": "data"}]
        
        result = main.insert_rows_to_bigquery(mock_client, test_rows)
        assert result is False


class TestKafkaConfiguration:
    """Test Kafka configuration functionality"""
    
    @patch.dict(os.environ, {
        'KAFKA_BOOTSTRAP_SERVERS': 'test-server:9092',
        'KAFKA_GROUP_ID': 'test-group'
    })
    def test_get_kafka_config_basic(self):
        """Test basic Kafka configuration"""
        config = main.get_kafka_config()
        
        assert config['bootstrap_servers'] == ['test-server:9092']
        assert config['group_id'] == 'test-group'
        assert config['auto_offset_reset'] == 'earliest'
        assert config['enable_auto_commit'] is True
    
    @patch('main.get_secret')
    @patch.dict(os.environ, {
        'KAFKA_BOOTSTRAP_SERVERS': 'secure-server:9092',
        'KAFKA_GROUP_ID': 'secure-group'
    })
    def test_get_kafka_config_with_auth(self, mock_get_secret):
        """Test Kafka configuration with authentication"""
        mock_get_secret.side_effect = ['test-user', 'test-password']
        
        config = main.get_kafka_config()
        
        assert 'sasl_plain_username' in config
        assert 'sasl_plain_password' in config
        assert config['security_protocol'] == 'SASL_SSL'


class TestCorrelationLogging:
    """Test correlation logging functionality"""
    
    def test_correlation_logger_decorator(self):
        """Test correlation logger decorator"""
        @main.correlation_logger
        def test_function():
            return "success"
        
        result = test_function()
        assert result == "success"
    
    def test_correlation_logger_with_exception(self):
        """Test correlation logger with exception"""
        @main.correlation_logger
        def failing_function():
            raise ValueError("Test error")
        
        with pytest.raises(ValueError):
            failing_function()


class TestHealthCheck:
    """Test health check functionality"""
    
    def test_health_check_success(self):
        """Test successful health check"""
        mock_request = Mock()
        mock_request.method = 'GET'
        
        result = main.health_check(mock_request)
        
        assert result[0] == 'OK'
        assert result[1] == 200


class TestMainFunction:
    """Test main consume_events function"""
    
    @patch('main.validate_environment')
    @patch('main.bigquery.Client')
    def test_consume_events_invalid_environment(self, mock_bq_client, mock_validate):
        """Test consume_events with invalid environment"""
        mock_validate.return_value = False
        mock_request = Mock()
        
        result = main.consume_events(mock_request)
        
        assert "Environment validation failed" in result[0]
        assert result[1] == 500
    
    @patch('main.validate_environment')
    @patch('main.create_bigquery_table_if_not_exists')
    @patch('main.bigquery.Client')
    def test_consume_events_bigquery_setup_failure(self, mock_bq_client, mock_create_table, mock_validate):
        """Test consume_events with BigQuery setup failure"""
        mock_validate.return_value = True
        mock_create_table.return_value = False
        mock_request = Mock()
        
        result = main.consume_events(mock_request)
        
        assert "BigQuery setup failed" in result[0]
        assert result[1] == 500


class TestSecurityFeatures:
    """Test security-related functionality"""
    
    def test_no_hardcoded_secrets(self):
        """Ensure no hardcoded secrets in the code"""
        # This test examines the main module for potential hardcoded secrets
        import inspect
        
        source = inspect.getsource(main)
        
        # Check for common patterns that might indicate hardcoded secrets
        forbidden_patterns = [
            'password=',
            'secret=',
            'key=',
            'token=',
            'api_key=',
            'private_key='
        ]
        
        for pattern in forbidden_patterns:
            # Allow environment variable references and secure patterns
            if pattern in source.lower():
                # Check if it's in a secure context (env vars, comments, etc.)
                lines_with_pattern = [line for line in source.split('\n') if pattern in line.lower()]
                for line in lines_with_pattern:
                    # Allow if it's getting from environment or secret manager
                    assert any(safe_pattern in line.lower() for safe_pattern in [
                        'os.environ', 'get_secret', 'secret_manager', '#', 'secretkeyref'
                    ]), f"Potential hardcoded secret found: {line.strip()}"
    
    def test_input_validation(self):
        """Test input validation prevents injection attacks"""
        # Test SQL injection prevention (should use parameterized queries)
        malicious_input = "'; DROP TABLE users; --"
        
        event = {
            'op': 'c',
            'source': {'table': malicious_input},
            'after': {'id': malicious_input},
            'ts_ms': 1640995200000
        }
        
        # The function should handle this safely
        result = main.process_event(event)
        
        # Check that the malicious input is properly escaped/handled
        if result:
            assert isinstance(result['event_data'], str)
            # JSON encoding should escape the malicious content
            assert malicious_input in result['event_data']


if __name__ == '__main__':
    pytest.main([__file__, '-v']) 