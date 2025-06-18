#!/usr/bin/env python3
"""
YugabyteDB Messaging Patterns Demo
==================================

Demonstrates all four messaging patterns from the field guide:
1. LISTEN/NOTIFY - Real-time cache invalidation
2. Queue Tables + SKIP LOCKED - Background job processing  
3. CDC Events - Event streaming
4. Logical Replication - Database-as-bus (conceptual)

Usage:
    python messaging-patterns-demo.py --help
    python messaging-patterns-demo.py --pattern listen-notify
    python messaging-patterns-demo.py --pattern job-queue --worker-id worker-1
    python messaging-patterns-demo.py --pattern cdc-events
    python messaging-patterns-demo.py --pattern all
"""

import asyncio
import json
import logging
import os
import time
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any
import argparse
import signal
import sys
import ssl

try:
    import psycopg2
    import psycopg2.extras
    from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
except ImportError:
    print("❌ psycopg2 not installed. Install with: pip install psycopg2-binary")
    sys.exit(1)

try:
    from kafka import KafkaConsumer, KafkaProducer
    from kafka.errors import KafkaError
    KAFKA_AVAILABLE = True
except ImportError:
    print("⚠️ kafka-python not installed. CDC → Kafka demo will be limited.")
    print("Install with: pip install kafka-python")
    KAFKA_AVAILABLE = False

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class YugabyteMessagingDemo:
    def __init__(self, connection_params: Dict[str, Any], kafka_broker: Optional[str] = None):
        self.connection_params = self._prepare_connection_params(connection_params)
        self.kafka_broker = kafka_broker
        self.connections = {}
        self.running = True
        
        # Set up signal handlers for graceful shutdown
        signal.signal(signal.SIGINT, self._signal_handler)
        signal.signal(signal.SIGTERM, self._signal_handler)
    
    def _prepare_connection_params(self, params: Dict[str, Any]) -> Dict[str, Any]:
        """Prepare connection parameters with TLS and authentication support"""
        # Make a copy to avoid modifying the original
        conn_params = params.copy()
        
        # ✅ FIXED: Add TLS support for production clusters
        if params.get('sslmode') or os.getenv('YUGABYTEDB_SSL_MODE'):
            conn_params['sslmode'] = params.get('sslmode', os.getenv('YUGABYTEDB_SSL_MODE', 'require'))
            
            # Handle SSL certificate paths
            if os.getenv('YUGABYTEDB_SSL_CERT'):
                conn_params['sslcert'] = os.getenv('YUGABYTEDB_SSL_CERT')
            if os.getenv('YUGABYTEDB_SSL_KEY'):
                conn_params['sslkey'] = os.getenv('YUGABYTEDB_SSL_KEY')
            if os.getenv('YUGABYTEDB_SSL_ROOT_CERT'):
                conn_params['sslrootcert'] = os.getenv('YUGABYTEDB_SSL_ROOT_CERT')
        
        # ✅ FIXED: Add authentication support
        if not conn_params.get('password') and os.getenv('YUGABYTEDB_PASSWORD'):
            conn_params['password'] = os.getenv('YUGABYTEDB_PASSWORD')
        
        # ✅ FIXED: Add connection timeout and retry logic
        conn_params.setdefault('connect_timeout', 30)
        
        logger.info(f"Connection configured - SSL: {conn_params.get('sslmode', 'disabled')}, "
                   f"Auth: {'enabled' if conn_params.get('password') else 'disabled'}")
        
        return conn_params
    
    def _signal_handler(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down gracefully...")
        self.running = False
    
    def get_connection(self, name: str = "default", autocommit: bool = False):
        """Get or create a database connection with retry logic"""
        if name not in self.connections:
            max_retries = 3
            retry_delay = 2
            
            for attempt in range(max_retries):
                try:
                    conn = psycopg2.connect(**self.connection_params)
                    if autocommit:
                        conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
                    self.connections[name] = conn
                    
                    # ✅ FIXED: Verify connection with a simple query
                    with conn.cursor() as cursor:
                        cursor.execute("SELECT version()")
                        version = cursor.fetchone()[0]
                        logger.info(f"Connected to: {version[:50]}...")
                    
                    break
                    
                except Exception as e:
                    logger.warning(f"Connection attempt {attempt + 1} failed: {e}")
                    if attempt < max_retries - 1:
                        time.sleep(retry_delay)
                        retry_delay *= 2
                    else:
                        raise Exception(f"Failed to connect after {max_retries} attempts: {e}")
        
        return self.connections[name]
    
    def close_connections(self):
        """Close all database connections"""
        for name, conn in self.connections.items():
            try:
                conn.close()
                logger.info(f"Closed connection: {name}")
            except Exception as e:
                logger.error(f"Error closing connection {name}: {e}")
    
    # ========================================================================
    # PATTERN 1: LISTEN/NOTIFY - Real-time cache invalidation
    # ========================================================================
    
    def listen_notify_publisher(self, count: int = 10):
        """Demonstrate LISTEN/NOTIFY publisher (cache invalidation)"""
        logger.info("🔔 Starting LISTEN/NOTIFY publisher demo...")
        
        conn = self.get_connection("publisher", autocommit=True)
        cursor = conn.cursor()
        
        try:
            for i in range(count):
                if not self.running:
                    break
                    
                # Simulate cache invalidation events
                cache_key = f"product:{i % 5}"  # Cycle through 5 products
                notification = {
                    "key": cache_key,
                    "action": "invalidate",
                    "timestamp": datetime.now().isoformat(),
                    "reason": "price_update"
                }
                
                cursor.execute(
                    "SELECT pg_notify(%s, %s)",
                    ("cache_invalidate", json.dumps(notification))
                )
                
                logger.info(f"📤 Published cache invalidation: {cache_key}")
                time.sleep(2)
                
        except Exception as e:
            logger.error(f"Publisher error: {e}")
        finally:
            cursor.close()
    
    def listen_notify_subscriber(self):
        """Demonstrate LISTEN/NOTIFY subscriber (cache invalidation listener)"""
        logger.info("🔔 Starting LISTEN/NOTIFY subscriber demo...")
        
        conn = self.get_connection("subscriber", autocommit=True)
        cursor = conn.cursor()
        
        try:
            # Start listening
            cursor.execute("LISTEN cache_invalidate")
            logger.info("👂 Listening for cache invalidation events...")
            
            while self.running:
                # Wait for notifications
                conn.poll()
                
                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    try:
                        payload = json.loads(notify.payload)
                        logger.info(f"🔄 Cache invalidation received: {payload['key']} - {payload['reason']}")
                        
                        # Simulate cache update
                        self._simulate_cache_refresh(payload['key'])
                        
                    except json.JSONDecodeError:
                        logger.warning(f"Invalid JSON in notification: {notify.payload}")
                
                time.sleep(0.1)
                
        except Exception as e:
            logger.error(f"Subscriber error: {e}")
        finally:
            cursor.execute("UNLISTEN cache_invalidate")
            cursor.close()
    
    def _simulate_cache_refresh(self, cache_key: str):
        """Simulate refreshing a cache entry"""
        logger.info(f"🔄 Refreshing cache for: {cache_key}")
        # In a real application, this would update Redis, Memcached, etc.
        time.sleep(0.1)  # Simulate cache update time
    
    # ========================================================================
    # PATTERN 2: Queue Tables + SKIP LOCKED - Background job processing
    # ========================================================================
    
    def job_queue_producer(self, count: int = 20):
        """Demonstrate job queue producer"""
        logger.info("📝 Starting job queue producer demo...")
        
        conn = self.get_connection("producer")
        cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        job_types = [
            "send_email",
            "process_payment", 
            "generate_report",
            "resize_image",
            "send_sms"
        ]
        
        try:
            for i in range(count):
                if not self.running:
                    break
                
                job_type = job_types[i % len(job_types)]
                payload = {
                    "user_id": 1000 + (i % 100),
                    "data": f"Job data for task {i}",
                    "timestamp": datetime.now().isoformat(),
                    "priority": 1 if job_type == "process_payment" else 0
                }
                
                # Enqueue job with different priorities and delays
                delay = 0 if job_type == "process_payment" else (i % 10)
                
                cursor.execute(
                    "SELECT enqueue_job(%s, %s, %s, %s)",
                    (job_type, json.dumps(payload), payload["priority"], delay)
                )
                job_id = cursor.fetchone()[0]
                
                conn.commit()
                logger.info(f"📤 Enqueued {job_type} job {job_id} (delay: {delay}s)")
                time.sleep(1)
                
        except Exception as e:
            logger.error(f"Producer error: {e}")
            conn.rollback()
        finally:
            cursor.close()
    
    def job_queue_worker(self, worker_id: str, job_types: Optional[List[str]] = None):
        """Demonstrate job queue worker"""
        logger.info(f"📝 Starting job queue worker demo: {worker_id}")
        
        conn = self.get_connection(f"worker_{worker_id}")
        cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        try:
            while self.running:
                # Dequeue next job
                if job_types:
                    cursor.execute(
                        "SELECT * FROM dequeue_job(%s, %s)",
                        (worker_id, job_types)
                    )
                else:
                    cursor.execute(
                        "SELECT * FROM dequeue_job(%s)",
                        (worker_id,)
                    )
                
                job = cursor.fetchone()
                
                if job:
                    logger.info(f"🔨 Worker {worker_id} processing job {job['job_id']}: {job['job_type']}")
                    
                    try:
                        # Simulate job processing
                        processing_time = self._simulate_job_processing(job['job_type'], job['payload'])
                        
                        # Mark job as completed
                        cursor.execute("SELECT complete_job(%s)", (job['job_id'],))
                        conn.commit()
                        
                        logger.info(f"✅ Job {job['job_id']} completed in {processing_time:.2f}s")
                        
                    except Exception as job_error:
                        # Mark job as failed
                        cursor.execute(
                            "SELECT fail_job(%s, %s, %s)",
                            (job['job_id'], str(job_error), True)
                        )
                        conn.commit()
                        logger.error(f"❌ Job {job['job_id']} failed: {job_error}")
                else:
                    # No jobs available, sleep before polling again
                    time.sleep(0.5)
                
        except Exception as e:
            logger.error(f"Worker {worker_id} error: {e}")
        finally:
            cursor.close()
    
    def _simulate_job_processing(self, job_type: str, payload: Dict) -> float:
        """Simulate processing different types of jobs"""
        processing_times = {
            "send_email": (0.5, 2.0),
            "process_payment": (1.0, 3.0),
            "generate_report": (2.0, 5.0),
            "resize_image": (0.8, 2.5),
            "send_sms": (0.3, 1.0)
        }
        
        min_time, max_time = processing_times.get(job_type, (0.5, 2.0))
        processing_time = min_time + (max_time - min_time) * (abs(hash(str(payload))) % 100) / 100
        
        time.sleep(processing_time)
        
        # Simulate occasional failures (5% chance)
        if abs(hash(str(payload))) % 20 == 0:
            raise Exception(f"Simulated failure in {job_type}")
        
        return processing_time
    
    # ========================================================================
    # PATTERN 3: CDC Events - Event streaming
    # ========================================================================
    
    def cdc_event_producer(self, count: int = 15):
        """Demonstrate CDC event production"""
        logger.info("📡 Starting CDC event producer demo...")
        
        conn = self.get_connection("cdc_producer")
        cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        entity_types = ["user", "order", "product", "payment"]
        event_types = ["created", "updated", "deleted", "status_changed"]
        
        try:
            for i in range(count):
                if not self.running:
                    break
                
                entity_type = entity_types[i % len(entity_types)]
                event_type = event_types[i % len(event_types)]
                entity_id = str(1000 + (i % 50))
                
                event_data = {
                    "change_id": i,
                    "previous_value": f"old_value_{i}",
                    "new_value": f"new_value_{i}",
                    "changed_fields": ["status", "updated_at"],
                    "user_id": 100 + (i % 10)
                }
                
                metadata = {
                    "source": "api",
                    "version": "1.0",
                    "correlation_id": f"corr_{i}"
                }
                
                cursor.execute(
                    "SELECT emit_event(%s, %s, %s, %s, %s)",
                    (f"{entity_type}.{event_type}", entity_type, entity_id, 
                     json.dumps(event_data), json.dumps(metadata))
                )
                event_id = cursor.fetchone()[0]
                
                conn.commit()
                logger.info(f"📡 Emitted event {event_id}: {entity_type}.{event_type} for {entity_id}")
                time.sleep(1.5)
                
        except Exception as e:
            logger.error(f"CDC producer error: {e}")
            conn.rollback()
        finally:
            cursor.close()
    
    def cdc_event_consumer(self):
        """Demonstrate CDC event consumption"""
        logger.info("📡 Starting CDC event consumer demo...")
        
        # Try Kafka consumer first if available
        if KAFKA_AVAILABLE and self.kafka_broker:
            return self._cdc_kafka_consumer()
        else:
            return self._cdc_postgres_consumer()
    
    def _cdc_kafka_consumer(self):
        """Real Kafka consumer for CDC events"""
        if not KAFKA_AVAILABLE:
            logger.warning("Kafka not available, simulating CDC events...")
            self._simulate_cdc_events()
            return
            
        logger.info("🔔 Starting real Kafka CDC consumer...")
        
        try:
            # ✅ FIXED: Corrected Kafka consumer configuration for YugabyteDB CDC
            consumer = KafkaConsumer(
                'yb.public.events',
                'yb.public.job_queue', 
                'yb.public.orders',
                'yb.public.products',
                'yb.heartbeat',  # Include heartbeat topic for monitoring
                bootstrap_servers=[f'{self.kafka_broker}'],
                group_id='yugabytedb-cdc-demo-consumer',
                value_deserializer=self._deserialize_cdc_message,
                key_deserializer=lambda m: m.decode('utf-8') if m else None,
                auto_offset_reset='earliest',  # Start from beginning to catch up
                enable_auto_commit=True,
                auto_commit_interval_ms=1000,
                consumer_timeout_ms=10000,  # Increased timeout for CDC messages
                max_poll_records=10,
                fetch_min_bytes=1,
                fetch_max_wait_ms=500
            )
            
            logger.info(f"📡 Connected to Kafka at {self.kafka_broker}")
            logger.info("👂 Listening for CDC events...")
            
            message_count = 0
            timeout_count = 0
            max_timeout = 3  # Stop after 3 timeouts
            
            while self.running and timeout_count < max_timeout:
                try:
                    # Poll for messages
                    message_batch = consumer.poll(timeout_ms=1000)
                    
                    if message_batch:
                        timeout_count = 0  # Reset timeout counter
                        for topic_partition, messages in message_batch.items():
                            for message in messages:
                                try:
                                    self._process_kafka_cdc_event(message.value, message.topic)
                                    message_count += 1
                                    
                                    if message_count >= 20:  # Limit for demo
                                        logger.info(f"📊 Processed {message_count} CDC events, stopping demo")
                                        return
                                        
                                except Exception as e:
                                    logger.error(f"Error processing message: {e}")
                    else:
                        timeout_count += 1
                        logger.info(f"⏳ No messages received (timeout {timeout_count}/{max_timeout})")
                    
                    time.sleep(0.1)
                    
                except Exception as e:
                    logger.error(f"Error polling Kafka: {e}")
                    break
                    
        except Exception as e:
            logger.error(f"Failed to connect to Kafka: {e}")
            logger.info("Falling back to simulated CDC events...")
            self._simulate_cdc_events()
        finally:
            try:
                consumer.close()
                logger.info("🔌 Kafka consumer closed")
            except:
                pass

    def _simulate_cdc_events(self):
        """Simulate CDC events when Kafka is not available"""
        logger.info("🎭 Simulating CDC events...")
        
        sample_events = [
            {"table": "events", "operation": "INSERT", "data": {"event_type": "user_created", "entity_id": "user_123"}},
            {"table": "orders", "operation": "UPDATE", "data": {"order_id": 456, "status": "shipped"}},
            {"table": "products", "operation": "INSERT", "data": {"product_id": 789, "name": "New Product"}},
            {"table": "job_queue", "operation": "INSERT", "data": {"job_type": "send_email", "priority": 1}},
        ]
        
        for i, event in enumerate(sample_events):
            if not self.running:
                break
            logger.info(f"📨 Simulated CDC event {i+1}: {event['table']} - {event['operation']}")
            self._process_cdc_event(event)
            time.sleep(2)

    def _process_kafka_cdc_event(self, event: Dict, topic: str):
        """Process a CDC event received from Kafka"""
        if not event:
            return
            
        try:
            # Extract table name from topic (e.g., 'yb.public.events' -> 'events')
            table_name = topic.split('.')[-1] if '.' in topic else topic
            
            logger.info(f"📨 Kafka CDC event from {table_name}: {event.get('op', 'UNKNOWN')} operation")
            
            # Process based on operation type
            operation = event.get('op', 'UNKNOWN')
            if operation in ['c', 'r']:  # Create/Read
                logger.info(f"  ➕ New {table_name} record created")
            elif operation == 'u':  # Update
                logger.info(f"  ✏️  {table_name} record updated")
            elif operation == 'd':  # Delete
                logger.info(f"  🗑️  {table_name} record deleted")
            
            # Extract payload
            payload = event.get('after') or event.get('before', {})
            if payload:
                logger.info(f"  📄 Payload: {payload}")
                
            # ✅ FIXED: Better event processing
            self._process_cdc_event({
                "table": table_name,
                "operation": operation,
                "data": payload,
                "timestamp": event.get('ts_ms'),
                "source": "kafka"
            })
            
        except Exception as e:
            logger.error(f"Error processing Kafka CDC event: {e}")
            logger.debug(f"Event data: {event}")
    
    def _cdc_postgres_consumer(self):
        """Fallback PostgreSQL event consumer"""
        logger.info("📡 Starting PostgreSQL CDC event consumer...")
        
        conn = self.get_connection("cdc_consumer", autocommit=True)
        cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        try:
            # Listen for real-time event notifications
            cursor.execute("LISTEN event_stream")
            logger.info("👂 Listening for CDC events...")
            
            # Also poll for events from the events table
            last_check = datetime.now() - timedelta(minutes=1)
            
            while self.running:
                # Check for real-time notifications
                conn.poll()
                while conn.notifies:
                    notify = conn.notifies.pop(0)
                    try:
                        event_notification = json.loads(notify.payload)
                        logger.info(f"🔔 Real-time event notification: {event_notification}")
                    except json.JSONDecodeError:
                        logger.warning(f"Invalid JSON in event notification: {notify.payload}")
                
                # Poll for new events
                cursor.execute(
                    """
                    SELECT event_id, event_type, entity_type, entity_id, 
                           event_data, metadata, occurred_at
                    FROM events 
                    WHERE occurred_at > %s 
                    ORDER BY occurred_at ASC 
                    LIMIT 10
                    """,
                    (last_check,)
                )
                
                events = cursor.fetchall()
                if events:
                    for event in events:
                        logger.info(f"📨 Processing CDC event: {event['event_type']} - {event['entity_id']}")
                        self._process_cdc_event(event)
                        last_check = max(last_check, event['occurred_at'])
                
                time.sleep(2)
                
        except Exception as e:
            logger.error(f"CDC consumer error: {e}")
        finally:
            cursor.execute("UNLISTEN event_stream")
            cursor.close()
    
    def _deserialize_cdc_message(self, message):
        """Deserialize CDC message with proper error handling"""
        if not message:
            return None
        try:
            # CDC messages are JSON-encoded
            return json.loads(message.decode('utf-8'))
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            logger.warning(f"Failed to deserialize CDC message: {e}")
            return None

    def _process_cdc_event(self, event: Dict):
        """Process a CDC event (simulate downstream processing)"""
        event_type = event['event_type']
        entity_type = event['entity_type']
        
        # Simulate different processing based on event type
        if event_type.endswith('.created'):
            logger.info(f"🆕 New {entity_type} created: {event['entity_id']}")
        elif event_type.endswith('.updated'):
            logger.info(f"🔄 {entity_type} updated: {event['entity_id']}")
        elif event_type.endswith('.deleted'):
            logger.info(f"🗑️  {entity_type} deleted: {event['entity_id']}")
        
        # Simulate processing time
        time.sleep(0.1)
    
    # ========================================================================
    # PATTERN 4: Monitoring and Stats
    # ========================================================================
    
    def show_queue_stats(self):
        """Show current queue statistics"""
        conn = self.get_connection("stats")
        cursor = conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        
        try:
            cursor.execute("SELECT * FROM queue_monitor")
            stats = cursor.fetchall()
            
            print("\n📊 Queue Statistics:")
            print("=" * 60)
            print(f"{'Job Type':<15} {'Ready':<8} {'Processing':<12} {'Failed':<8} {'Scheduled':<10}")
            print("-" * 60)
            
            for stat in stats:
                print(f"{stat['job_type']:<15} {stat['ready']:<8} {stat['processing']:<12} "
                      f"{stat['failed']:<8} {stat['scheduled']:<10}")
            
            # Event statistics
            cursor.execute("""
                SELECT event_type, COUNT(*) as count 
                FROM events 
                WHERE occurred_at > now() - interval '1 hour'
                GROUP BY event_type 
                ORDER BY count DESC
            """)
            event_stats = cursor.fetchall()
            
            print(f"\n📡 Event Statistics (last hour):")
            print("=" * 40)
            for stat in event_stats:
                print(f"{stat['event_type']:<25} {stat['count']:>8}")
            
        except Exception as e:
            logger.error(f"Stats error: {e}")
        finally:
            cursor.close()
    
    # ========================================================================
    # Demo Orchestration
    # ========================================================================
    
    def run_pattern_demo(self, pattern: str, **kwargs):
        """Run a specific messaging pattern demo"""
        try:
            if pattern == "listen-notify":
                self._run_listen_notify_demo()
            elif pattern == "job-queue":
                self._run_job_queue_demo(kwargs.get('worker_id', 'demo-worker'))
            elif pattern == "cdc-events":
                self._run_cdc_events_demo()
            elif pattern == "stats":
                self.show_queue_stats()
            elif pattern == "all":
                self._run_all_patterns_demo()
            else:
                logger.error(f"Unknown pattern: {pattern}")
                
        except KeyboardInterrupt:
            logger.info("Demo interrupted by user")
        finally:
            self.close_connections()
    
    def _run_listen_notify_demo(self):
        """Run LISTEN/NOTIFY demo with both publisher and subscriber"""
        import threading
        
        # Start subscriber in background thread
        subscriber_thread = threading.Thread(target=self.listen_notify_subscriber)
        subscriber_thread.daemon = True
        subscriber_thread.start()
        
        time.sleep(2)  # Let subscriber start
        
        # Run publisher in main thread
        self.listen_notify_publisher(count=10)
    
    def _run_job_queue_demo(self, worker_id: str):
        """Run job queue demo with producer and worker"""
        import threading
        
        # Start worker in background thread
        worker_thread = threading.Thread(target=self.job_queue_worker, args=(worker_id,))
        worker_thread.daemon = True
        worker_thread.start()
        
        time.sleep(2)  # Let worker start
        
        # Run producer in main thread
        self.job_queue_producer(count=15)
        
        # Show final stats
        time.sleep(5)
        self.show_queue_stats()
    
    def _run_cdc_events_demo(self):
        """Run CDC events demo with producer and consumer"""
        import threading
        
        # Start consumer in background thread
        consumer_thread = threading.Thread(target=self.cdc_event_consumer)
        consumer_thread.daemon = True
        consumer_thread.start()
        
        time.sleep(2)  # Let consumer start
        
        # Run producer in main thread
        self.cdc_event_producer(count=10)
    
    def _run_all_patterns_demo(self):
        """Run a comprehensive demo of all patterns"""
        import threading
        
        logger.info("🚀 Starting comprehensive messaging patterns demo...")
        
        # Start all background services
        threads = []
        
        # LISTEN/NOTIFY subscriber
        t1 = threading.Thread(target=self.listen_notify_subscriber)
        t1.daemon = True
        t1.start()
        threads.append(t1)
        
        # Job queue worker
        t2 = threading.Thread(target=self.job_queue_worker, args=("demo-worker",))
        t2.daemon = True
        t2.start()
        threads.append(t2)
        
        # CDC event consumer
        t3 = threading.Thread(target=self.cdc_event_consumer)
        t3.daemon = True
        t3.start()
        threads.append(t3)
        
        time.sleep(3)  # Let services start
        
        # Run producers in sequence
        logger.info("📡 Running CDC events producer...")
        self.cdc_event_producer(count=5)
        
        logger.info("📝 Running job queue producer...")
        self.job_queue_producer(count=10)
        
        logger.info("🔔 Running LISTEN/NOTIFY publisher...")
        self.listen_notify_publisher(count=8)
        
        # Show final statistics
        time.sleep(5)
        self.show_queue_stats()


def main():
    parser = argparse.ArgumentParser(
        description="YugabyteDB Messaging Patterns Demo - Production Ready",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment Variables (Production Support):
  YUGABYTEDB_HOST          Database host
  YUGABYTEDB_PORT          Database port
  YUGABYTEDB_DATABASE      Database name
  YUGABYTEDB_USER          Database user
  YUGABYTEDB_PASSWORD      Database password (required for production)
  YUGABYTEDB_SSL_MODE      SSL mode (disable, allow, prefer, require, verify-ca, verify-full)
  YUGABYTEDB_SSL_CERT      Client certificate path
  YUGABYTEDB_SSL_KEY       Client private key path
  YUGABYTEDB_SSL_ROOT_CERT Root certificate path
  KAFKA_BROKER             Kafka broker for CDC events (host:port)

Production Example:
  export YUGABYTEDB_HOST=yb-tserver-service.codet-prod-yb.svc.cluster.local
  export YUGABYTEDB_PORT=5433
  export YUGABYTEDB_USER=yugabyte
  export YUGABYTEDB_PASSWORD=your-secure-password
  export YUGABYTEDB_SSL_MODE=require
  export KAFKA_BROKER=kafka-service:9092
  python messaging-patterns-demo.py --pattern all
        """
    )
    parser.add_argument(
        "--pattern",
        choices=["listen-notify", "job-queue", "cdc-events", "stats", "all"],
        default="all",
        help="Messaging pattern to demonstrate"
    )
    parser.add_argument("--worker-id", default="demo-worker", help="Worker ID for job queue demo")
    
    # ✅ FIXED: Enhanced connection options with environment variable support
    parser.add_argument("--host", 
                       default=os.getenv('YUGABYTEDB_HOST', 'localhost'), 
                       help="Database host (env: YUGABYTEDB_HOST)")
    parser.add_argument("--port", type=int, 
                       default=int(os.getenv('YUGABYTEDB_PORT', '5433')), 
                       help="Database port (env: YUGABYTEDB_PORT)")
    parser.add_argument("--database", 
                       default=os.getenv('YUGABYTEDB_DATABASE', 'yugabyte'), 
                       help="Database name (env: YUGABYTEDB_DATABASE)")
    parser.add_argument("--user", 
                       default=os.getenv('YUGABYTEDB_USER', 'yugabyte'), 
                       help="Database user (env: YUGABYTEDB_USER)")
    parser.add_argument("--password", 
                       default=os.getenv('YUGABYTEDB_PASSWORD', ''), 
                       help="Database password (env: YUGABYTEDB_PASSWORD)")
    
    # ✅ FIXED: TLS/SSL options for production clusters
    parser.add_argument("--ssl-mode", 
                       default=os.getenv('YUGABYTEDB_SSL_MODE', 'prefer'),
                       choices=['disable', 'allow', 'prefer', 'require', 'verify-ca', 'verify-full'],
                       help="SSL mode (env: YUGABYTEDB_SSL_MODE)")
    parser.add_argument("--ssl-cert", 
                       default=os.getenv('YUGABYTEDB_SSL_CERT', ''),
                       help="Client certificate path (env: YUGABYTEDB_SSL_CERT)")
    parser.add_argument("--ssl-key", 
                       default=os.getenv('YUGABYTEDB_SSL_KEY', ''),
                       help="Client key path (env: YUGABYTEDB_SSL_KEY)")
    parser.add_argument("--ssl-root-cert", 
                       default=os.getenv('YUGABYTEDB_SSL_ROOT_CERT', ''),
                       help="Root certificate path (env: YUGABYTEDB_SSL_ROOT_CERT)")
    
    # Kafka options
    parser.add_argument("--kafka-broker", 
                       default=os.getenv('KAFKA_BROKER', None),
                       help="Kafka broker for CDC (env: KAFKA_BROKER)")
    
    # Demo options
    parser.add_argument("--verbose", "-v", action="store_true", 
                       help="Enable verbose logging")
    parser.add_argument("--dry-run", action="store_true",
                       help="Test connection only, don't run demo")
    
    args = parser.parse_args()
    
    # ✅ FIXED: Configure logging level
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
        logger.info("Verbose logging enabled")
    
    # ✅ FIXED: Build connection parameters with TLS support
    connection_params = {
        "host": args.host,
        "port": args.port,
        "database": args.database,
        "user": args.user,
        "password": args.password,
        "connect_timeout": 30
    }
    
    # Add SSL parameters if specified
    if args.ssl_mode and args.ssl_mode != 'disable':
        connection_params['sslmode'] = args.ssl_mode
        
        if args.ssl_cert:
            connection_params['sslcert'] = args.ssl_cert
        if args.ssl_key:
            connection_params['sslkey'] = args.ssl_key
        if args.ssl_root_cert:
            connection_params['sslrootcert'] = args.ssl_root_cert
    
    # ✅ FIXED: Display connection info
    logger.info("🔗 Connection Configuration:")
    logger.info(f"  Host: {args.host}:{args.port}")
    logger.info(f"  Database: {args.database}")
    logger.info(f"  User: {args.user}")
    logger.info(f"  SSL Mode: {args.ssl_mode}")
    logger.info(f"  Authentication: {'enabled' if args.password else 'disabled'}")
    
    if args.kafka_broker:
        logger.info(f"  Kafka: {args.kafka_broker}")
    else:
        logger.info("  Kafka: not configured")
    
    # ✅ FIXED: Enhanced connection testing
    logger.info("🔍 Testing database connection...")
    try:
        # Create demo instance for connection testing
        demo = YugabyteMessagingDemo(connection_params, kafka_broker=args.kafka_broker)
        
        # Test connection
        conn = demo.get_connection("test")
        
        # ✅ FIXED: Verify production cluster features
        with conn.cursor() as cursor:
            # Check if we're connected to YugabyteDB
            cursor.execute("SELECT version()")
            version = cursor.fetchone()[0]
            if 'yugabyte' in version.lower():
                logger.info("✅ Connected to YugabyteDB")
            else:
                logger.warning("⚠️ Connected to PostgreSQL (not YugabyteDB)")
            
            # Check for messaging pattern tables
            cursor.execute("""
                SELECT table_name FROM information_schema.tables 
                WHERE table_schema = 'public' 
                AND table_name IN ('job_queue', 'events')
            """)
            tables = [row[0] for row in cursor.fetchall()]
            
            if 'job_queue' in tables:
                logger.info("✅ Job queue tables found")
            else:
                logger.warning("⚠️ Job queue tables not found - run setup SQL first")
                
            if 'events' in tables:
                logger.info("✅ Event tables found")
            else:
                logger.warning("⚠️ Event tables not found - run setup SQL first")
        
        conn.close()
        logger.info("✅ Database connection test successful")
        
        # ✅ FIXED: Test Kafka connection if configured
        if args.kafka_broker:
            logger.info("🔍 Testing Kafka connection...")
            if KAFKA_AVAILABLE:
                try:
                    from kafka.admin import KafkaAdminClient
                    admin = KafkaAdminClient(
                        bootstrap_servers=[args.kafka_broker],
                        request_timeout_ms=5000
                    )
                    # Try to get cluster metadata
                    metadata = admin.describe_cluster()
                    logger.info("✅ Kafka connection test successful")
                except Exception as e:
                    logger.warning(f"⚠️ Kafka connection failed: {e}")
            else:
                logger.warning("⚠️ Kafka not available (install kafka-python)")
        
    except Exception as e:
        logger.error(f"❌ Database connection failed: {e}")
        logger.error("Check your connection parameters and ensure YugabyteDB is running")
        sys.exit(1)
    
    # ✅ FIXED: Dry run mode for testing
    if args.dry_run:
        logger.info("✅ Dry run completed successfully")
        return
    
    # ✅ FIXED: Run the actual demo
    logger.info(f"🚀 Starting {args.pattern} messaging pattern demo...")
    try:
        demo.run_pattern_demo(args.pattern, worker_id=args.worker_id)
    except KeyboardInterrupt:
        logger.info("Demo interrupted by user")
    except Exception as e:
        logger.error(f"Demo failed: {e}")
        sys.exit(1)
    finally:
        demo.close_connections()
        logger.info("🎉 Demo completed")


if __name__ == "__main__":
    main() 