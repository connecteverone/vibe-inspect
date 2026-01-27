import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

abstract class StorageRepository {
  Future<List<ToolSession>> fetchToolSessions();
  Future<List<TimelineEvent>> fetchTimelineEvents();
  Future<void> insertToolSession(ToolSession session);
  Future<void> insertTimelineEvent(TimelineEvent event);
}

abstract class StorageInitializer {
  const StorageInitializer();

  Future<StorageRepository> initialize();
}

class LocalStorageInitializer extends StorageInitializer {
  const LocalStorageInitializer();

  static const _databaseName = 'vibe_inspect.db';
  static const _schemaVersion = 1;
  static const _storageKeyId = 'vibe_storage_key';

  @override
  Future<StorageRepository> initialize() async {
    final secureStorage = const FlutterSecureStorage();
    final databasePath = await getDatabasesPath();
    final path = '$databasePath/$_databaseName';
    final database = await openDatabase(
      path,
      version: _schemaVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );
    await _ensureStorageKey(secureStorage);
    return LocalStorage._(database, secureStorage);
  }

  Future<void> _ensureStorageKey(FlutterSecureStorage secureStorage) async {
    final existing = await secureStorage.read(key: _storageKeyId);
    if (existing != null && existing.isNotEmpty) {
      return;
    }
    final random = Random();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final encoded = base64UrlEncode(bytes);
    await secureStorage.write(key: _storageKeyId, value: encoded);
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE tool_sessions (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        label TEXT NOT NULL,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE timeline_events (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES tool_sessions(id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX timeline_events_created_at ON timeline_events(created_at)',
    );
    await db.execute(
      'CREATE INDEX tool_sessions_created_at ON tool_sessions(created_at)',
    );
  }
}

class MemoryStorageInitializer extends StorageInitializer {
  const MemoryStorageInitializer();

  @override
  Future<StorageRepository> initialize() async {
    return MemoryStorage();
  }
}

class LocalStorage implements StorageRepository {
  LocalStorage._(this._database, this._secureStorage);

  final Database _database;
  final FlutterSecureStorage _secureStorage;

  @override
  Future<List<ToolSession>> fetchToolSessions() async {
    final rows = await _database.query(
      'tool_sessions',
      orderBy: 'created_at DESC',
    );
    return rows.map(ToolSession.fromDatabase).toList();
  }

  @override
  Future<List<TimelineEvent>> fetchTimelineEvents() async {
    final rows = await _database.query(
      'timeline_events',
      orderBy: 'created_at DESC',
    );
    return rows.map(TimelineEvent.fromDatabase).toList();
  }

  @override
  Future<void> insertToolSession(ToolSession session) async {
    await _database.insert(
      'tool_sessions',
      session.toDatabase(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> insertTimelineEvent(TimelineEvent event) async {
    await _database.insert(
      'timeline_events',
      event.toDatabase(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String?> readSecureValue(String key) async {
    return _secureStorage.read(key: key);
  }
}

class MemoryStorage implements StorageRepository {
  final List<ToolSession> _sessions = [];
  final List<TimelineEvent> _events = [];

  @override
  Future<List<ToolSession>> fetchToolSessions() async {
    return List<ToolSession>.from(_sessions.reversed);
  }

  @override
  Future<List<TimelineEvent>> fetchTimelineEvents() async {
    return List<TimelineEvent>.from(_events.reversed);
  }

  @override
  Future<void> insertToolSession(ToolSession session) async {
    _sessions.add(session);
  }

  @override
  Future<void> insertTimelineEvent(TimelineEvent event) async {
    _events.add(event);
  }
}

class ToolSession {
  const ToolSession({
    required this.id,
    required this.type,
    required this.label,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String type;
  final String label;
  final String status;
  final DateTime createdAt;

  Map<String, dynamic> toDatabase() {
    return {
      'id': id,
      'type': type,
      'label': label,
      'status': status,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  factory ToolSession.fromDatabase(Map<String, Object?> row) {
    return ToolSession(
      id: row['id']?.toString() ?? '',
      type: row['type']?.toString() ?? 'unknown',
      label: row['label']?.toString() ?? 'Untitled session',
      status: row['status']?.toString() ?? 'unknown',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as int?) ?? 0,
      ),
    );
  }
}

class TimelineEvent {
  const TimelineEvent({
    required this.id,
    required this.sessionId,
    required this.type,
    required this.title,
    required this.payload,
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final String type;
  final String title;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  Map<String, dynamic> toDatabase() {
    return {
      'id': id,
      'session_id': sessionId,
      'type': type,
      'title': title,
      'payload': jsonEncode(payload),
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  factory TimelineEvent.fromDatabase(Map<String, Object?> row) {
    final rawPayload = row['payload']?.toString() ?? '{}';
    Map<String, dynamic> payload;
    try {
      final decoded = jsonDecode(rawPayload);
      payload = decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      payload = {};
    }
    return TimelineEvent(
      id: row['id']?.toString() ?? '',
      sessionId: row['session_id']?.toString() ?? '',
      type: row['type']?.toString() ?? 'unknown',
      title: row['title']?.toString() ?? 'Untitled',
      payload: payload,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as int?) ?? 0,
      ),
    );
  }
}

String createStorageId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final random = Random();
  return '$timestamp-${random.nextInt(0x7fffffff)}';
}
