"""
BI Consumer Cloud Function
Consumes events from Kafka and sends to Google Sheets/BigQuery for Marketing
"""

import os
import json
import base64
from datetime import datetime
from typing import Dict, Any
from google.cloud import bigquery
from google.oauth2 import service_account
from kafka import KafkaConsumer
from kafka.errors import KafkaError
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration from environment
KAFKA_BOOTSTRAP_SERVERS = os.environ.get('KAFKA_BOOTSTRAP_SERVERS', 'redpanda.codet-prod.svc.cluster.local:9092')
KAFKA_TOPIC_PATTERN = os.environ.get('KAFKA_TOPIC_PATTERN', 'codet.prod.*')
KAFKA_GROUP_ID = os.environ.get('KAFKA_GROUP_ID', 'marketing-bi-consumer')
KAFKA_USERNAME = os.environ.get('KAFKA_USERNAME')
KAFKA_PASSWORD = os.environ.get('KAFKA_PASSWORD')
BIGQUERY_DATASET = os.environ.get('BIGQUERY_DATASET', 'marketing_events')
BIGQUERY_TABLE = os.environ.get('BIGQUERY_TABLE', 'user_events')
PROJECT_ID = os.environ.get('GCP_PROJECT')

# Initialize BigQuery client
bq_client = bigquery.Client()

def create_bigquery_table_if_not_exists():
    """Create BigQuery table if it doesn't exist."""
    dataset_id = f"{PROJECT_ID}.{BIGQUERY_DATASET}"
    table_id = f"{dataset_id}.{BIGQUERY_TABLE}"
    
    # Create dataset if not exists
    try:
        dataset = bigquery.Dataset(dataset_id)
        dataset.location = "US"
        dataset = bq_client.create_dataset(dataset, exists_ok=True)
        logger.info(f"Dataset {dataset_id} created or already exists")
    except Exception as e:
        logger.error(f"Error creating dataset: {e}")
        raise
    
    # Define table schema
    schema = [
        bigquery.SchemaField("event_id", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("event_type", "STRING", mode="REQUIRED"),
        bigquery.SchemaField("event_timestamp", "TIMESTAMP", mode="REQUIRED"),
        bigquery.SchemaField("user_id", "STRING"),
        bigquery.SchemaField("user_email", "STRING"),
        bigquery.SchemaField("event_data", "JSON"),
        bigquery.SchemaField("source_table", "STRING"),
        bigquery.SchemaField("operation", "STRING"),
        bigquery.SchemaField("ingested_at", "TIMESTAMP", mode="REQUIRED"),
    ]
    
    # Create table if not exists
    try:
        table = bigquery.Table(table_id, schema=schema)
        table = bq_client.create_table(table, exists_ok=True)
        logger.info(f"Table {table_id} created or already exists")
    except Exception as e:
        logger.error(f"Error creating table: {e}")
        raise

def process_event(event: Dict[str, Any]) -> Dict[str, Any]:
    """Process Kafka event and transform for BigQuery."""
    # Extract event metadata
    event_type = event.get('op', 'unknown')  # c=create, u=update, d=delete
    source_table = event.get('source', {}).get('table', 'unknown')
    
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
    
    # Build BigQuery row
    row = {
        'event_id': event.get('ts_ms', str(datetime.utcnow().timestamp())),
        'event_type': f"{source_table}.{operation}",
        'event_timestamp': datetime.utcfromtimestamp(event.get('ts_ms', 0) / 1000),
        'user_id': payload.get('user_id', payload.get('id')),
        'user_email': payload.get('email'),
        'event_data': json.dumps(payload),
        'source_table': source_table,
        'operation': operation,
        'ingested_at': datetime.utcnow()
    }
    
    return row

def consume_events(request):
    """
    Cloud Function entry point.
    Consumes events from Kafka and writes to BigQuery.
    """
    # Initialize table
    create_bigquery_table_if_not_exists()
    
    # Configure Kafka consumer
    consumer_config = {
        'bootstrap_servers': KAFKA_BOOTSTRAP_SERVERS.split(','),
        'group_id': KAFKA_GROUP_ID,
        'value_deserializer': lambda m: json.loads(m.decode('utf-8')),
        'auto_offset_reset': 'latest',
        'enable_auto_commit': True,
        'max_poll_records': 100,
        'session_timeout_ms': 30000,
        'consumer_timeout_ms': 10000  # Return after 10 seconds
    }
    
    # Add authentication if provided
    if KAFKA_USERNAME and KAFKA_PASSWORD:
        consumer_config.update({
            'security_protocol': 'SASL_SSL',
            'sasl_mechanism': 'SCRAM-SHA-512',
            'sasl_plain_username': KAFKA_USERNAME,
            'sasl_plain_password': KAFKA_PASSWORD
        })
    
    rows_to_insert = []
    
    try:
        # Create consumer
        consumer = KafkaConsumer(**consumer_config)
        
        # Subscribe to topics
        consumer.subscribe(pattern=KAFKA_TOPIC_PATTERN)
        logger.info(f"Subscribed to topics matching: {KAFKA_TOPIC_PATTERN}")
        
        # Consume messages
        for message in consumer:
            try:
                # Process event
                row = process_event(message.value)
                rows_to_insert.append(row)
                
                # Batch insert when we have enough rows
                if len(rows_to_insert) >= 50:
                    insert_rows_to_bigquery(rows_to_insert)
                    rows_to_insert = []
                    
            except Exception as e:
                logger.error(f"Error processing message: {e}")
                continue
        
        # Insert remaining rows
        if rows_to_insert:
            insert_rows_to_bigquery(rows_to_insert)
            
    except KafkaError as e:
        logger.error(f"Kafka error: {e}")
        return {'error': str(e)}, 500
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return {'error': str(e)}, 500
    finally:
        if 'consumer' in locals():
            consumer.close()
    
    return {
        'status': 'success',
        'events_processed': len(rows_to_insert)
    }, 200

def insert_rows_to_bigquery(rows):
    """Insert rows to BigQuery."""
    table_id = f"{PROJECT_ID}.{BIGQUERY_DATASET}.{BIGQUERY_TABLE}"
    
    try:
        errors = bq_client.insert_rows_json(table_id, rows)
        if errors:
            logger.error(f"BigQuery insert errors: {errors}")
        else:
            logger.info(f"Inserted {len(rows)} rows to BigQuery")
    except Exception as e:
        logger.error(f"Error inserting to BigQuery: {e}")
        raise

# For local testing
if __name__ == "__main__":
    # Mock request object
    class MockRequest:
        args = {}
    
    result = consume_events(MockRequest())
    print(result) 