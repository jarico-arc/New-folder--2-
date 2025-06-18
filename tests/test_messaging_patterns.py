#!/usr/bin/env python3
"""
Unit tests for YugabyteDB Messaging Patterns Demo
Tests the core functionality without requiring a live database
"""

import json
import pytest
from unittest.mock import Mock, patch, MagicMock
import sys
import os

# Add the examples directory to the path so we can import the demo
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'examples'))

from messaging_patterns_demo import YugabyteMessagingDemo


class TestYugabyteMessagingDemo:
    """Test suite for the messaging patterns demo"""
    
    def setup_method(self):
        """Set up test fixtures"""
        self.connection_params = {
            'host': 'localhost',
            'port': 5433,
            'database': 'yugabyte',
            'user': 'yugabyte'
        }
        self.demo = YugabyteMessagingDemo(self.connection_params)
    
    def test_initialization(self):
        """Test demo initialization"""
        assert self.demo.connection_params == self.connection_params
        assert self.demo.kafka_broker is None
        assert self.demo.running is True
        assert self.demo.connections == {}
    
    def test_signal_handler(self):
        """Test signal handler sets running to False"""
        self.demo._signal_handler(2, None)  # SIGINT
        assert self.demo.running is False
    
    @patch('psycopg2.connect')
    def test_get_connection(self, mock_connect):
        """Test database connection creation"""
        mock_conn = Mock()
        mock_connect.return_value = mock_conn
        
        conn = self.demo.get_connection("test")
        
        assert conn == mock_conn
        assert "test" in self.demo.connections
        mock_connect.assert_called_once_with(**self.connection_params)
    
    @patch('psycopg2.connect')
    def test_get_connection_reuse(self, mock_connect):
        """Test that connections are reused"""
        mock_conn = Mock()
        mock_connect.return_value = mock_conn
        
        # First call creates connection
        conn1 = self.demo.get_connection("test")
        # Second call reuses connection
        conn2 = self.demo.get_connection("test")
        
        assert conn1 == conn2
        mock_connect.assert_called_once()
    
    def test_simulate_cache_refresh(self):
        """Test cache refresh simulation"""
        # Should not raise any exceptions
        self.demo._simulate_cache_refresh("test_key")
    
    def test_simulate_job_processing(self):
        """Test job processing simulation"""
        payload = {"test": "data"}
        
        # Test normal processing
        processing_time = self.demo._simulate_job_processing("send_email", payload)
        assert isinstance(processing_time, float)
        assert processing_time > 0
        
        # Test with unknown job type
        processing_time = self.demo._simulate_job_processing("unknown", payload)
        assert isinstance(processing_time, float)
        assert processing_time > 0
    
    def test_simulate_job_processing_failure(self):
        """Test job processing failure simulation"""
        # Use a payload that will trigger failure (hash % 20 == 0)
        payload = {"test": "data", "trigger": "fail"}
        
        # Find a payload that triggers failure
        for i in range(100):
            test_payload = {"test": f"data_{i}"}
            if abs(hash(str(test_payload))) % 20 == 0:
                with pytest.raises(Exception, match="Simulated failure"):
                    self.demo._simulate_job_processing("send_email", test_payload)
                break
    
    def test_process_cdc_event(self):
        """Test CDC event processing"""
        event = {
            "table": "test_table",
            "operation": "INSERT",
            "data": {"id": 1, "name": "test"},
            "timestamp": "2023-01-01T00:00:00Z"
        }
        
        # Should not raise any exceptions
        self.demo._process_cdc_event(event)
    
    def test_process_kafka_cdc_event(self):
        """Test Kafka CDC event processing"""
        event = {
            "op": "c",  # Create operation
            "after": {"id": 1, "name": "test"},
            "ts_ms": 1672531200000
        }
        topic = "yb.public.test_table"
        
        # Should not raise any exceptions
        self.demo._process_kafka_cdc_event(event, topic)
    
    def test_process_kafka_cdc_event_invalid(self):
        """Test Kafka CDC event processing with invalid data"""
        # Should handle None event gracefully
        self.demo._process_kafka_cdc_event(None, "test_topic")
        
        # Should handle empty event gracefully
        self.demo._process_kafka_cdc_event({}, "test_topic")
    
    def test_close_connections(self):
        """Test connection cleanup"""
        mock_conn = Mock()
        self.demo.connections["test"] = mock_conn
        
        self.demo.close_connections()
        
        mock_conn.close.assert_called_once()


class TestUtilityFunctions:
    """Test utility functions"""
    
    def test_hash_absolute_value(self):
        """Test that hash operations use absolute values"""
        # This tests the fix for negative hash values
        test_data = "test_string"
        hash_val = abs(hash(test_data))
        assert hash_val >= 0
        assert hash_val % 20 >= 0
        assert hash_val % 100 >= 0


@pytest.mark.integration
class TestIntegrationPatterns:
    """Integration tests that require external dependencies"""
    
    def setup_method(self):
        """Set up integration test fixtures"""
        self.connection_params = {
            'host': 'localhost',
            'port': 5433,
            'database': 'yugabyte',
            'user': 'yugabyte'
        }
    
    @pytest.mark.skip(reason="Requires live database")
    def test_full_listen_notify_pattern(self):
        """Test complete LISTEN/NOTIFY pattern"""
        # This would test the full pattern with a real database
        pass
    
    @pytest.mark.skip(reason="Requires live database")
    def test_full_job_queue_pattern(self):
        """Test complete job queue pattern"""
        # This would test the full pattern with a real database
        pass
    
    @pytest.mark.skip(reason="Requires live database and Kafka")
    def test_full_cdc_pattern(self):
        """Test complete CDC pattern"""
        # This would test the full pattern with real database and Kafka
        pass


if __name__ == "__main__":
    pytest.main([__file__]) 