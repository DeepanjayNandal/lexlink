import 'dart:math' as math;
import 'dart:async';
import 'package:uuid/uuid.dart';
import 'package:logger/logger.dart';
import '../db/message_database.dart';

class MessageRepository {
  final MessageDatabase _db;
  final Uuid _uuid = Uuid();
  final Logger _logger = Logger();

  MessageRepository(this._db);

  String generateMessageId() => _uuid.v4();

  Future<void> insertOutboxMessage({
    required String id,
    required String sessionId,
    required String blob,
    String? peerId,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final db = await _db.database;
    await db.insert(
      MessageDatabase.OUTBOX_TABLE,
      {
        'id': id,
        'sessionId': sessionId,
        'peerId': peerId,
        'blob': blob,
        'status': 'pending',
        'retryCount': 0,
        'nextAttemptAt': now,
        'createdAt': now,
        'lastError': null,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchDueOutboxMessages(
      {int limit = 50}) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.query(
      MessageDatabase.OUTBOX_TABLE,
      where: 'status = ? AND nextAttemptAt <= ?',
      whereArgs: ['pending', now],
      orderBy: 'createdAt ASC',
      limit: limit, // Process in batches for better performance
    );
  }

  /// Process outbox messages in batches with transaction support
  Future<void> processOutboxQueue(
      Future<bool> Function(Map<String, dynamic>) processMessage) async {
    final db = await _db.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Use a transaction for better performance
    await db.transaction((txn) async {
      final messages = await txn.query(
        MessageDatabase.OUTBOX_TABLE,
        where: 'status = ? AND nextAttemptAt <= ?',
        whereArgs: ['pending', now],
        orderBy: 'createdAt ASC',
        limit: 50, // Process in batches
      );

      for (final message in messages) {
        try {
          final success = await processMessage(message);

          if (success) {
            await txn.update(
              MessageDatabase.OUTBOX_TABLE,
              {'status': 'sent', 'retryCount': 0},
              where: 'id = ?',
              whereArgs: [message['id']],
            );
          } else {
            // Bump retry count and apply backoff
            final retryCount = ((message['retryCount']) as num).toInt() + 1;
            final backoffMs =
                math.min((1000 * math.pow(2, retryCount)).toInt(), 45000);
            final nextAttempt =
                DateTime.now().millisecondsSinceEpoch + backoffMs;

            await txn.update(
              MessageDatabase.OUTBOX_TABLE,
              {
                'retryCount': retryCount,
                'nextAttemptAt': nextAttempt,
                'lastError': 'Send failed',
              },
              where: 'id = ?',
              whereArgs: [message['id']],
            );
          }
        } catch (e) {
          // Handle error for this message but continue processing others
          await bumpRetry(message['id'] as String, e.toString());
        }
      }
    });
  }

  Future<void> markMessageSent(String id) async {
    final db = await _db.database;
    await db.update(
      MessageDatabase.OUTBOX_TABLE,
      {'status': 'sent', 'retryCount': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> bumpRetry(String id, String error) async {
    final db = await _db.database;
    final result = await db.query(
      MessageDatabase.OUTBOX_TABLE,
      columns: ['retryCount'],
      where: 'id = ?',
      whereArgs: [id],
    );
    if (result.isEmpty) return;

    final retryCount = ((result.first['retryCount']) as num).toInt() + 1;
    final backoffMs = math.min((1000 * math.pow(2, retryCount)).toInt(), 45000);
    final nextAttempt = DateTime.now().millisecondsSinceEpoch + backoffMs;

    await db.update(
      MessageDatabase.OUTBOX_TABLE,
      {
        'retryCount': retryCount,
        'nextAttemptAt': nextAttempt,
        'lastError': error,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Check if a message with the given ID exists in the inbox
  Future<bool> messageExists(String id) async {
    final db = await _db.database;
    final result = await db.query(
      MessageDatabase.INBOX_TABLE,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return result.isNotEmpty;
  }

  /// Add a message ID to the processed messages table to prevent duplicates
  /// Returns true if the message was new, false if it was a duplicate
  Future<bool> markMessageProcessed(String id, String sessionId) async {
    final db = await _db.database;

    try {
      // Use a transaction for atomicity
      return await db.transaction((txn) async {
        // Check if message already exists
        final existing = await txn.query(
          'processed_messages',
          columns: ['id'],
          where: 'message_id = ?',
          whereArgs: [id],
          limit: 1,
        );

        if (existing.isNotEmpty) {
          return false; // Already processed
        }

        // Insert into processed messages table
        await txn.insert('processed_messages', {
          'message_id': id,
          'session_id': sessionId,
          'processed_at': DateTime.now().millisecondsSinceEpoch,
        });

        return true; // New message
      });
    } catch (e) {
      // If table doesn't exist yet, create it and try again
      if (e.toString().contains('no such table')) {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS processed_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT NOT NULL,
            session_id TEXT NOT NULL,
            processed_at INTEGER NOT NULL,
            UNIQUE(message_id)
          )
        ''');

        // Create index for faster lookups
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_processed_messages_message_id ON processed_messages(message_id)');

        // Try again with the table created
        return markMessageProcessed(id, sessionId);
      }
      rethrow;
    }
  }

  /// Purge old processed message IDs to prevent memory growth
  Future<void> purgeOldMessages(int olderThanDays) async {
    final db = await _db.database;
    final cutoffTime = DateTime.now()
        .subtract(Duration(days: olderThanDays))
        .millisecondsSinceEpoch;

    try {
      // Use a transaction for consistency
      await db.transaction((txn) async {
        // Delete old inbox messages
        final inboxDeleted = await txn.delete(
          MessageDatabase.INBOX_TABLE,
          where: 'receivedAt < ?',
          whereArgs: [cutoffTime],
        );

        // Delete old outbox messages that have been sent
        final outboxDeleted = await txn.delete(
          MessageDatabase.OUTBOX_TABLE,
          where: 'createdAt < ? AND status = ?',
          whereArgs: [cutoffTime, 'sent'],
        );

        // Delete old processed message records
        int processedDeleted = 0;
        try {
          processedDeleted = await txn.delete(
            'processed_messages',
            where: 'processed_at < ?',
            whereArgs: [cutoffTime],
          );
        } catch (e) {
          // Table might not exist yet, which is fine
          if (!e.toString().contains('no such table')) {
            rethrow;
          }
        }

        return {
          'inbox_deleted': inboxDeleted,
          'outbox_deleted': outboxDeleted,
          'processed_deleted': processedDeleted,
        };
      });
    } catch (e) {
      // Log error but don't crash the app over cleanup
      _logger.e('Error purging old messages: $e');
    }
  }

  /// Schedule periodic message purging
  void schedulePurging({
    Duration interval = const Duration(days: 1),
    int olderThanDays = 30,
  }) {
    // Set up a periodic timer to purge old messages
    Timer.periodic(interval, (_) async {
      await purgeOldMessages(olderThanDays);
    });
  }
}
