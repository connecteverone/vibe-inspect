import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

abstract class StorageRepository {
  Future<List<ConnectionRecord>> fetchConnections();
  Future<List<ToolSession>> fetchToolSessions();
  Future<List<TimelineEvent>> fetchTimelineEvents();
  Future<void> insertConnection(ConnectionRecord connection);
  Future<void> insertToolSession(ToolSession session);
  Future<void> insertTimelineEvent(TimelineEvent event);
  Future<void> deleteConnection(String connectionId);
  Future<void> deleteToolSessionsByAgent(String agentId);
  Future<String?> readKeyValue(String key);
  Future<void> writeKeyValue(String key, String value);
  Future<void> deleteKeyValue(String key);
}

abstract class StorageInitializer {
  const StorageInitializer();

  Future<StorageRepository> initialize();
}

class LocalStorageInitializer extends StorageInitializer {
  const LocalStorageInitializer();

  static const _databaseName = 'vibe_inspect.db';
  static const _schemaVersion = 3;
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
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await _createConnectionsTable(db);
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE tool_sessions ADD COLUMN agent_id TEXT');
          if (oldVersion >= 2) {
            await db.execute(
              'ALTER TABLE connections ADD COLUMN agent_url TEXT',
            );
          }
        }
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
    await _createConnectionsTable(db);
    await db.execute('''
      CREATE TABLE tool_sessions (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        label TEXT NOT NULL,
        status TEXT NOT NULL,
        agent_id TEXT,
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

  static Future<void> _createConnectionsTable(Database db) async {
    await db.execute('''
      CREATE TABLE connections (
        id TEXT PRIMARY KEY,
        token TEXT NOT NULL,
        status TEXT NOT NULL,
        connected_at INTEGER NOT NULL,
        agent_url TEXT,
        tunnel_url TEXT,
        tunnel_error TEXT,
        last_seen_at INTEGER
      )
    ''');
    await db.execute(
      'CREATE INDEX connections_connected_at ON connections(connected_at)',
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
  Future<List<ConnectionRecord>> fetchConnections() async {
    final rows = await _database.query(
      'connections',
      orderBy: 'connected_at DESC',
    );
    return rows.map(ConnectionRecord.fromDatabase).toList();
  }

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
  Future<void> insertConnection(ConnectionRecord connection) async {
    await _database.insert(
      'connections',
      connection.toDatabase(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
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

  @override
  Future<void> deleteConnection(String connectionId) async {
    await _database.delete(
      'connections',
      where: 'id = ?',
      whereArgs: [connectionId],
    );
  }

  @override
  Future<void> deleteToolSessionsByAgent(String agentId) async {
    await _database.transaction((txn) async {
      await txn.delete(
        'tool_sessions',
        where: 'agent_id = ?',
        whereArgs: [agentId],
      );
    });
  }

  @override
  Future<String?> readKeyValue(String key) async {
    return _secureStorage.read(key: key);
  }

  @override
  Future<void> writeKeyValue(String key, String value) async {
    await _secureStorage.write(key: key, value: value);
  }

  @override
  Future<void> deleteKeyValue(String key) async {
    await _secureStorage.delete(key: key);
  }
}

class MemoryStorage implements StorageRepository {
  final List<ConnectionRecord> _connections = [];
  final List<ToolSession> _sessions = [];
  final List<TimelineEvent> _events = [];
  final Map<String, String> _keyValues = {};

  @override
  Future<List<ConnectionRecord>> fetchConnections() async {
    return List<ConnectionRecord>.from(_connections.reversed);
  }

  @override
  Future<List<ToolSession>> fetchToolSessions() async {
    return List<ToolSession>.from(_sessions.reversed);
  }

  @override
  Future<List<TimelineEvent>> fetchTimelineEvents() async {
    return List<TimelineEvent>.from(_events.reversed);
  }

  @override
  Future<void> insertConnection(ConnectionRecord connection) async {
    _connections.add(connection);
  }

  @override
  Future<void> insertToolSession(ToolSession session) async {
    _sessions.add(session);
  }

  @override
  Future<void> insertTimelineEvent(TimelineEvent event) async {
    _events.add(event);
  }

  @override
  Future<void> deleteConnection(String connectionId) async {
    _connections.removeWhere((connection) => connection.id == connectionId);
  }

  @override
  Future<void> deleteToolSessionsByAgent(String agentId) async {
    final removedSessionIds = _sessions
        .where((session) => session.agentId == agentId)
        .map((session) => session.id)
        .toSet();
    _sessions.removeWhere((session) => session.agentId == agentId);
    if (removedSessionIds.isEmpty) {
      return;
    }
    _events.removeWhere(
      (event) => removedSessionIds.contains(event.sessionId),
    );
  }

  @override
  Future<String?> readKeyValue(String key) async {
    return _keyValues[key];
  }

  @override
  Future<void> writeKeyValue(String key, String value) async {
    _keyValues[key] = value;
  }

  @override
  Future<void> deleteKeyValue(String key) async {
    _keyValues.remove(key);
  }
}

class ToolSession {
  const ToolSession({
    required this.id,
    required this.type,
    required this.label,
    required this.status,
    this.agentId,
    required this.createdAt,
  });

  final String id;
  final String type;
  final String label;
  final String status;
  final String? agentId;
  final DateTime createdAt;

  Map<String, dynamic> toDatabase() {
    return {
      'id': id,
      'type': type,
      'label': label,
      'status': status,
      'agent_id': agentId,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  factory ToolSession.fromDatabase(Map<String, Object?> row) {
    return ToolSession(
      id: row['id']?.toString() ?? '',
      type: row['type']?.toString() ?? 'unknown',
      label: row['label']?.toString() ?? 'Untitled session',
      status: row['status']?.toString() ?? 'unknown',
      agentId: row['agent_id']?.toString(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (row['created_at'] as int?) ?? 0,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'label': label,
      'status': status,
      'agentId': agentId,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory ToolSession.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Tool session id is required.');
    }
    final type = json['type'];
    if (type is! String || type.isEmpty) {
      throw const FormatException('Tool session type is required.');
    }
    final label = json['label'];
    if (label is! String || label.isEmpty) {
      throw const FormatException('Tool session label is required.');
    }
    final status = json['status'];
    if (status is! String || status.isEmpty) {
      throw const FormatException('Tool session status is required.');
    }
    final agentId = json['agentId'];
    final createdAtRaw = json['createdAt'];
    if (createdAtRaw is! String) {
      throw const FormatException('Tool session createdAt must be a string.');
    }
    final createdAt = _parseTimestamp(
      createdAtRaw,
      'Tool session createdAt must be an ISO-8601 timestamp.',
    );
    return ToolSession(
      id: id,
      type: type,
      label: label,
      status: status,
      agentId: agentId is String && agentId.isNotEmpty ? agentId : null,
      createdAt: createdAt,
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

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sessionId': sessionId,
      'type': type,
      'title': title,
      'payload': payload,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory TimelineEvent.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Timeline event id is required.');
    }
    final sessionId = json['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const FormatException('Timeline event sessionId is required.');
    }
    final type = json['type'];
    if (type is! String || type.isEmpty) {
      throw const FormatException('Timeline event type is required.');
    }
    final title = json['title'];
    if (title is! String || title.isEmpty) {
      throw const FormatException('Timeline event title is required.');
    }
    final payloadRaw = json['payload'];
    if (payloadRaw is! Map) {
      throw const FormatException('Timeline event payload must be an object.');
    }
    final createdAtRaw = json['createdAt'];
    if (createdAtRaw is! String) {
      throw const FormatException('Timeline event createdAt must be a string.');
    }
    final createdAt = _parseTimestamp(
      createdAtRaw,
      'Timeline event createdAt must be an ISO-8601 timestamp.',
    );
    return TimelineEvent(
      id: id,
      sessionId: sessionId,
      type: type,
      title: title,
      payload: Map<String, dynamic>.from(payloadRaw),
      createdAt: createdAt,
    );
  }
}

class ConnectionRecord {
  const ConnectionRecord({
    required this.id,
    required this.token,
    required this.status,
    required this.connectedAt,
    this.agentUrl,
    this.tunnelUrl,
    this.tunnelError,
    this.lastSeenAt,
  });

  final String id;
  final String token;
  final String status;
  final DateTime connectedAt;
  final String? agentUrl;
  final String? tunnelUrl;
  final String? tunnelError;
  final DateTime? lastSeenAt;

  Map<String, dynamic> toDatabase() {
    return {
      'id': id,
      'token': token,
      'status': status,
      'connected_at': connectedAt.millisecondsSinceEpoch,
      'agent_url': agentUrl,
      'tunnel_url': tunnelUrl,
      'tunnel_error': tunnelError,
      'last_seen_at': lastSeenAt?.millisecondsSinceEpoch,
    };
  }

  factory ConnectionRecord.fromDatabase(Map<String, Object?> row) {
    return ConnectionRecord(
      id: row['id']?.toString() ?? '',
      token: row['token']?.toString() ?? '',
      status: row['status']?.toString() ?? 'unknown',
      connectedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['connected_at'] as int?) ?? 0,
      ),
      agentUrl: row['agent_url']?.toString(),
      tunnelUrl: row['tunnel_url']?.toString(),
      tunnelError: row['tunnel_error']?.toString(),
      lastSeenAt: row['last_seen_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (row['last_seen_at'] as int?) ?? 0,
            )
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'token': token,
      'status': status,
      'connectedAt': connectedAt.toIso8601String(),
      'agentUrl': agentUrl,
      'tunnelUrl': tunnelUrl,
      'tunnelError': tunnelError,
      'lastSeenAt': lastSeenAt?.toIso8601String(),
    };
  }

  factory ConnectionRecord.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('Connection id is required.');
    }
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw const FormatException('Connection token is required.');
    }
    final status = json['status'];
    if (status is! String || status.isEmpty) {
      throw const FormatException('Connection status is required.');
    }
    final agentUrlRaw = json['agentUrl'];
    final connectedAtRaw = json['connectedAt'];
    if (connectedAtRaw is! String) {
      throw const FormatException('Connection connectedAt must be a string.');
    }
    final connectedAt = _parseTimestamp(
      connectedAtRaw,
      'Connection connectedAt must be an ISO-8601 timestamp.',
    );
    final tunnelUrl = json['tunnelUrl'];
    if (tunnelUrl != null && tunnelUrl is! String) {
      throw const FormatException('Connection tunnelUrl must be a string.');
    }
    final tunnelError = json['tunnelError'];
    if (tunnelError != null && tunnelError is! String) {
      throw const FormatException('Connection tunnelError must be a string.');
    }
    final lastSeenRaw = json['lastSeenAt'];
    DateTime? lastSeenAt;
    if (lastSeenRaw != null) {
      if (lastSeenRaw is! String) {
        throw const FormatException('Connection lastSeenAt must be a string.');
      }
      lastSeenAt = _parseTimestamp(
        lastSeenRaw,
        'Connection lastSeenAt must be an ISO-8601 timestamp.',
      );
    }
    return ConnectionRecord(
      id: id,
      token: token,
      status: status,
      connectedAt: connectedAt,
      agentUrl: agentUrlRaw is String && agentUrlRaw.isNotEmpty
          ? agentUrlRaw
          : null,
      tunnelUrl: tunnelUrl as String?,
      tunnelError: tunnelError as String?,
      lastSeenAt: lastSeenAt,
    );
  }
}

class ExportBundle {
  const ExportBundle({
    required this.version,
    required this.deviceName,
    required this.exportedAt,
    required this.connections,
    required this.toolSessions,
    required this.timelineEvents,
  });

  static const int currentVersion = 2;

  final int version;
  final String deviceName;
  final DateTime exportedAt;
  final List<ConnectionRecord> connections;
  final List<ToolSession> toolSessions;
  final List<TimelineEvent> timelineEvents;

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'deviceName': deviceName,
      'exportedAt': exportedAt.toIso8601String(),
      'connections': connections.map((connection) => connection.toJson()).toList(),
      'toolSessions': toolSessions.map((session) => session.toJson()).toList(),
      'timelineEvents': timelineEvents.map((event) => event.toJson()).toList(),
    };
  }

  factory ExportBundle.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! int) {
      throw const FormatException('Bundle version must be an integer.');
    }
    if (version > currentVersion || version < 1) {
      throw FormatException(
        'Unsupported bundle version $version. Expected 1-$currentVersion.',
      );
    }
    final deviceName = json['deviceName'];
    if (deviceName is! String || deviceName.isEmpty) {
      throw const FormatException('Bundle deviceName is required.');
    }
    final exportedAtRaw = json['exportedAt'];
    if (exportedAtRaw is! String) {
      throw const FormatException('Bundle exportedAt must be a string.');
    }
    final exportedAt = _parseTimestamp(
      exportedAtRaw,
      'Bundle exportedAt must be an ISO-8601 timestamp.',
    );
    final connectionsRaw = json['connections'];
    if (connectionsRaw is! List) {
      throw const FormatException('Bundle connections must be a list.');
    }
    final connections = connectionsRaw.map<ConnectionRecord>((item) {
      if (item is! Map) {
        throw const FormatException('Connection entry must be an object.');
      }
      return ConnectionRecord.fromJson(Map<String, dynamic>.from(item));
    }).toList();
    final sessionsRaw = json['toolSessions'];
    final toolSessions = <ToolSession>[];
    if (sessionsRaw != null) {
      if (sessionsRaw is! List) {
        throw const FormatException('Bundle toolSessions must be a list.');
      }
      for (final item in sessionsRaw) {
        if (item is! Map) {
          throw const FormatException('Tool session entry must be an object.');
        }
        toolSessions.add(ToolSession.fromJson(Map<String, dynamic>.from(item)));
      }
    }
    final eventsRaw = json['timelineEvents'];
    if (eventsRaw is! List) {
      throw const FormatException('Bundle timelineEvents must be a list.');
    }
    final timelineEvents = eventsRaw.map<TimelineEvent>((item) {
      if (item is! Map) {
        throw const FormatException('Timeline event entry must be an object.');
      }
      return TimelineEvent.fromJson(Map<String, dynamic>.from(item));
    }).toList();
    return ExportBundle(
      version: version,
      deviceName: deviceName,
      exportedAt: exportedAt,
      connections: connections,
      toolSessions: toolSessions,
      timelineEvents: timelineEvents,
    );
  }
}

DateTime _parseTimestamp(String value, String message) {
  try {
    return DateTime.parse(value);
  } catch (_) {
    throw FormatException(message);
  }
}

String createStorageId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final random = Random();
  return '$timestamp-${random.nextInt(0x7fffffff)}';
}
