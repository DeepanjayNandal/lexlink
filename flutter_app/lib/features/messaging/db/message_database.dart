import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class MessageDatabase {
  static const String OUTBOX_TABLE = 'outbox';
  static const String INBOX_TABLE = 'inbox';

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'messages.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $OUTBOX_TABLE (
            id TEXT PRIMARY KEY,
            sessionId TEXT NOT NULL,
            peerId TEXT,
            blob TEXT NOT NULL,
            status TEXT NOT NULL,
            retryCount INTEGER NOT NULL,
            nextAttemptAt INTEGER NOT NULL,
            lastError TEXT,
            createdAt INTEGER NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE $INBOX_TABLE (
            id TEXT PRIMARY KEY,
            sessionId TEXT NOT NULL,
            peerId TEXT,
            blob TEXT NOT NULL,
            receivedAt INTEGER NOT NULL,
            readAt INTEGER
          )
        ''');

        await db.execute(
            'CREATE INDEX outbox_status_next ON $OUTBOX_TABLE (status, nextAttemptAt)');
        await db.execute(
            'CREATE INDEX outbox_created ON $OUTBOX_TABLE (createdAt)');
        await db.execute(
            'CREATE INDEX inbox_session_received ON $INBOX_TABLE (sessionId, receivedAt)');
      },
    );
  }
}
