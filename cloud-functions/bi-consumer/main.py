"""
BI Consumer Cloud Function
Consumes events from Kafka and sends to Google Sheets/BigQuery for Marketing

Security: Uses Google Cloud Secret Manager for sensitive configuration
Error Handling: Comprehensive try/catch with proper logging
Monitoring: Structured logging with correlation IDs
"""

import os
import json
import base64
import traceback
from datetime import datetime
from typing import Dict, Any, Optional, List
from google.cloud import bigquery, secretmanager
from google.oauth2 import service_account
from kafka import KafkaConsumer
from kafka.errors import KafkaError, KafkaTimeoutError
import logging
import uuid
from functools import wraps

# Configure structured logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s - %(correlation_id)s'
)
logger = logging.getLogger(__name__)

# Configuration from environment with secure defaults
KAFKA_BOOTSTRAP_SERVERS = os.environ.get('KAFKA_BOOTSTRAP_SERVERS', 'redpanda.codet-prod.svc.cluster.local:9092')
KAFKA_TOPIC_PATTERN = os.environ.get('KAFKA_TOPIC_PATTERN', 'codet.prod.*')
KAFKA_GROUP_ID = os.environ.get('KAFKA_GROUP_ID', 'marketing-bi-consumer')
BIGQUERY_DATASET = os.environ.get('BIGQUERY_DATASET', 'marketing_events')
BIGQUERY_TABLE = os.environ.get('BIGQUERY_TABLE', 'user_events')
PROJECT_ID = os.environ.get('GCP_PROJECT')
ENVIRONMENT = os.environ.get('ENVIRONMENT', 'production')

# Security: Use Secret Manager for sensitive configuration
SECRET_CLIENT = secretmanager.SecretManagerServiceClient()

# Constants
MAX_BATCH_SIZE = int(os.environ.get('MAX_BATCH_SIZE', '50'))
CONSUMER_TIMEOUT_MS = int(os.environ.get('CONSUMER_TIMEOUT_MS', '10000'))
MAX_POLL_RECORDS = int(os.environ.get('MAX_POLL_RECORDS', '100'))

def correlation_logger(func):
    """Decorator to add correlation ID to logs"""
    @wraps(func)
    def wrapper(*args, **kwargs):
        correlation_id = str(uuid.uuid4())
        # Add correlation ID to all log records
        old_factory = logging.getLogRecordFactory()
        def record_factory(*args, **kwargs):
            record = old_factory(*args, **kwargs)
            record.correlation_id = correlation_id
            return record
        logging.setLogRecordFactory(record_factory)
        
        try:
            logger.info(f"Starting function {func.__name__}")
            result = func(*args, **kwargs)
            logger.info(f"Completed function {func.__name__}")
            return result
        except Exception as e:
            logger.error(f"Error in function {func.__name__}: {str(e)}", exc_info=True)
            raise
        finally:
            logging.setLogRecordFactory(old_factory)
    return wrapper

def get_secret(secret_name: str) -> Optional[str]:
    """Securely retrieve secrets from Google Secret Manager"""
    try:
        name = f"projects/{PROJECT_ID}/secrets/{secret_name}/versions/latest"
        response = SECRET_CLIENT.access_secret_version(request={"name": name})
        return response.payload.data.decode("UTF-8")
    except Exception as e:
        logger.warning(f"Could not retrieve secret {secret_name}: {e}")
        return None

def validate_environment() -> bool:
    """Validate required environment variables and dependencies"""
    required_vars = ['GCP_PROJECT', 'KAFKA_BOOTSTRAP_SERVERS']
    missing_vars = [var for var in required_vars if not os.environ.get(var)]
    
    if missing_vars:
        logger.error(f"Missing required environment variables: {missing_vars}")
        return False
    
    if not PROJECT_ID:
        logger.error("GCP_PROJECT environment variable is required")
        return False
    
    return True

def create_bigquery_table_if_not_exists(bq_client: bigquery.Client) -> bool:
    """Create BigQuery table if it doesn't exist with proper error handling."""
    try:
        dataset_id = f"{PROJECT_ID}.{BIGQUERY_DATASET}"
        table_id = f"{dataset_id}.{BIGQUERY_TABLE}"
        
        # Create dataset if not exists
        dataset = bigquery.Dataset(dataset_id)
        dataset.location = "US"
        dataset.description = f"Marketing events dataset for {ENVIRONMENT}"
        dataset = bq_client.create_dataset(dataset, exists_ok=True)
        logger.info(f"Dataset {dataset_id} ready")
        
        # Define comprehensive table schema
        schema = [
            bigquery.SchemaField("event_id", "STRING", mode="REQUIRED", description="Unique event identifier"),
            bigquery.SchemaField("event_type", "STRING", mode="REQUIRED", description="Type of database operation"),
            bigquery.SchemaField("event_timestamp", "TIMESTAMP", mode="REQUIRED", description="When the event occurred"),
            bigquery.SchemaField("user_id", "STRING", description="User identifier"),
            bigquery.SchemaField("user_email", "STRING", description="User email address"),
            bigquery.SchemaField("event_data", "JSON", description="Full event payload"),
            bigquery.SchemaField("source_table", "STRING", description="Source database table"),
            bigquery.SchemaField("operation", "STRING", description="Database operation type"),
            bigquery.SchemaField("ingested_at", "TIMESTAMP", mode="REQUIRED", description="When data was ingested"),
            bigquery.SchemaField("partition_date", "DATE", mode="REQUIRED", description="Date for partitioning"),
            bigquery.SchemaField("environment", "STRING", mode="REQUIRED", description="Environment (dev/staging/prod)"),
        ]
        
        # Create table with partitioning and clustering
        table = bigquery.Table(table_id, schema=schema)
        table.time_partitioning = bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.DAY,
            field="partition_date",
            expiration_ms=None  # Don't auto-delete partitions
        )
        table.clustering_fields = ["source_table", "operation", "environment"]
        table.description = f"User events from YugabyteDB CDC for {ENVIRONMENT}"
        
        table = bq_client.create_table(table, exists_ok=True)
        logger.info(f"Table {table_id} ready with partitioning")
        return True
        
    except Exception as e:
        logger.error(f"Error creating BigQuery table: {e}", exc_info=True)
        return False

def validate_event(event: Dict[str, Any]) -> bool:
    """Validate event structure before processing"""
    if not isinstance(event, dict):
        logger.warning("Event is not a dictionary")
        return False
    
    required_fields = ['op', 'source']
    for field in required_fields:
        if field not in event:
            logger.warning(f"Event missing required field: {field}")
            return False
    
    return True

def process_event(event: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Process Kafka event and transform for BigQuery with validation."""
    try:
        if not validate_event(event):
            return None
        
        # Extract event metadata safely
        event_type = event.get('op', 'unknown')
        source_info = event.get('source', {})
        source_table = source_info.get('table', 'unknown')
        
        # Map operation types
        operation_map = {
            'c': 'INSERT',
            'u': 'UPDATE', 
            'd': 'DELETE',
            'r': 'READ'
        }
        operation = operation_map.get(event_type, 'UNKNOWN')
        
        # Extract payload (after transformation)
        payload = event.get('after', event.get('before', {}))
        
        # Generate unique event ID if not present
        event_id = str(event.get('ts_ms', int(datetime.utcnow().timestamp() * 1000)))
        
        # Get timestamp and handle potential conversion errors
        try:
            ts_ms = event.get('ts_ms', int(datetime.utcnow().timestamp() * 1000))
            event_timestamp = datetime.utcfromtimestamp(ts_ms / 1000)
        except (ValueError, TypeError):
            event_timestamp = datetime.utcnow()
            logger.warning(f"Invalid timestamp in event, using current time: {ts_ms}")
        
        # Build BigQuery row with comprehensive data
        row = {
            'event_id': event_id,
            'event_type': f"{source_table}.{operation}",
            'event_timestamp': event_timestamp,
            'user_id': str(payload.get('user_id', payload.get('id', ''))),
            'user_email': payload.get('email', ''),
            'event_data': json.dumps(payload),
            'source_table': source_table,
            'operation': operation,
            'ingested_at': datetime.utcnow(),
            'partition_date': datetime.utcnow().date(),
            'environment': ENVIRONMENT,
        }
        
        return row
        
    except Exception as e:
        logger.error(f"Error processing event: {e}", exc_info=True)
        return None

def get_kafka_config() -> Dict[str, Any]:
    """Get Kafka configuration with secure credential handling"""
    config = {
        'bootstrap_servers': KAFKA_BOOTSTRAP_SERVERS.split(','),
        'group_id': KAFKA_GROUP_ID,
        'value_deserializer': lambda m: json.loads(m.decode('utf-8')),
        'auto_offset_reset': 'latest',
        'enable_auto_commit': True,
        'max_poll_records': MAX_POLL_RECORDS,
        'session_timeout_ms': 30000,
        'consumer_timeout_ms': CONSUMER_TIMEOUT_MS,
        'api_version': (0, 10, 1),  # Explicit API version
    }
    
    # Add authentication if credentials are available
    kafka_username = get_secret('kafka-username') or os.environ.get('KAFKA_USERNAME')
    kafka_password = get_secret('kafka-password') or os.environ.get('KAFKA_PASSWORD')
    
    if kafka_username and kafka_password:
        config.update({
            'security_protocol': 'SASL_SSL',
            'sasl_mechanism': 'SCRAM-SHA-512',
            'sasl_plain_username': kafka_username,
            'sasl_plain_password': kafka_password
        })
        logger.info("Using SASL authentication for Kafka")
    else:
        logger.info("Using plaintext connection to Kafka")
    
    return config

def insert_rows_to_bigquery(bq_client: bigquery.Client, rows: List[Dict[str, Any]]) -> bool:
    """Insert rows to BigQuery with proper error handling."""
    if not rows:
        return True
    
    table_id = f"{PROJECT_ID}.{BIGQUERY_DATASET}.{BIGQUERY_TABLE}"
    
    try:
        # Insert with job configuration for better error handling
        job_config = bigquery.LoadJobConfig()
        job_config.source_format = bigquery.SourceFormat.NEWLINE_DELIMITED_JSON
        job_config.write_disposition = bigquery.WriteDisposition.WRITE_APPEND
        job_config.ignore_unknown_values = True
        
        errors = bq_client.insert_rows_json(table_id, rows, job_config=job_config)
        
        if errors:
            logger.error(f"BigQuery insert errors: {errors}")
            return False
        else:
            logger.info(f"Successfully inserted {len(rows)} rows to BigQuery")
            return True
            
    except Exception as e:
        logger.error(f"Error inserting to BigQuery: {e}", exc_info=True)
        return False

@correlation_logger
def consume_events(request):
    """
    Cloud Function entry point.
    Consumes events from Kafka and writes to BigQuery.
    """
    # Validate environment before starting
    if not validate_environment():
        return {'error': 'Environment validation failed'}, 500
    
    # Initialize BigQuery client with error handling
    try:
        bq_client = bigquery.Client()
    except Exception as e:
        logger.error(f"Failed to initialize BigQuery client: {e}")
        return {'error': 'BigQuery client initialization failed'}, 500
    
    # Initialize table
    if not create_bigquery_table_if_not_exists(bq_client):
        return {'error': 'BigQuery table initialization failed'}, 500
    
    # Configure Kafka consumer
    try:
        consumer_config = get_kafka_config()
    except Exception as e:
        logger.error(f"Failed to get Kafka configuration: {e}")
        return {'error': 'Kafka configuration failed'}, 500
    
    rows_to_insert = []
    processed_count = 0
    error_count = 0
    
    consumer = None
    try:
        # Create consumer with timeout and error handling
        logger.info(f"Creating Kafka consumer with config for topics: {KAFKA_TOPIC_PATTERN}")
        consumer = KafkaConsumer(**consumer_config)
        
        # Subscribe to topics with error handling
        consumer.subscribe(pattern=KAFKA_TOPIC_PATTERN)
        logger.info(f"Subscribed to topics matching: {KAFKA_TOPIC_PATTERN}")
        
        # Consume messages with timeout
        for message in consumer:
            try:
                # Process event with validation
                row = process_event(message.value)
                if row:
                    rows_to_insert.append(row)
                    processed_count += 1
                else:
                    error_count += 1
                
                # Batch insert when we have enough rows or timeout
                if len(rows_to_insert) >= MAX_BATCH_SIZE:
                    if insert_rows_to_bigquery(bq_client, rows_to_insert):
                        rows_to_insert = []
                    else:
                        error_count += len(rows_to_insert)
                        rows_to_insert = []
                    
            except json.JSONDecodeError as e:
                logger.warning(f"Invalid JSON in message: {e}")
                error_count += 1
                continue
            except Exception as e:
                logger.error(f"Error processing message: {e}")
                error_count += 1
                continue
        
        # Insert remaining rows
        if rows_to_insert:
            if insert_rows_to_bigquery(bq_client, rows_to_insert):
                logger.info(f"Inserted final batch of {len(rows_to_insert)} rows")
            else:
                error_count += len(rows_to_insert)
            
    except KafkaTimeoutError:
        logger.info("Kafka consumer timeout reached, finishing processing")
    except KafkaError as e:
        logger.error(f"Kafka error: {e}")
        return {'error': f'Kafka error: {str(e)}'}, 500
    except Exception as e:
        logger.error(f"Unexpected error: {e}", exc_info=True)
        return {'error': f'Unexpected error: {str(e)}'}, 500
    finally:
        if consumer:
            try:
                consumer.close()
                logger.info("Kafka consumer closed successfully")
            except Exception as e:
                logger.warning(f"Error closing consumer: {e}")
    
    # Return comprehensive status
    return {
        'status': 'success',
        'events_processed': processed_count,
        'events_failed': error_count,
        'environment': ENVIRONMENT,
        'timestamp': datetime.utcnow().isoformat()
    }, 200

# Health check endpoint
def health_check(request):
    """Health check endpoint for monitoring"""
    try:
        # Basic validation
        if not validate_environment():
            return {'status': 'unhealthy', 'reason': 'environment'}, 503
        
        # Test BigQuery connectivity
        bq_client = bigquery.Client()
        bq_client.query("SELECT 1").result()
        
        return {
            'status': 'healthy',
            'environment': ENVIRONMENT,
            'timestamp': datetime.utcnow().isoformat()
        }, 200
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return {'status': 'unhealthy', 'error': str(e)}, 503

# For local testing
if __name__ == "__main__":
    # Mock request object for testing
    class MockRequest:
        args = {}
        method = 'POST'
    
    # Validate environment first
    if not validate_environment():
        print("Environment validation failed")
        exit(1)
    
    print("Running consumer locally...")
    result = consume_events(MockRequest())
    print(f"Result: {result}") 