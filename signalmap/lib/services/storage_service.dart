import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/floorplan.dart';
import '../models/project.dart';
import '../models/recommendation.dart';
import '../models/sample_point.dart';
import '../models/scan_session.dart';

/// Persists all SignalMap data in a local SQLite database.
class StorageService {
  static const _dbName = 'signalmap.db';
  static const _version = 2;

  late Database _db;

  Future<void> init() async {
    final docDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docDir.path, _dbName);

    _db = await openDatabase(
      dbPath,
      version: _version,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add router anchor columns to persisted sessions.
      await db.execute(
          'ALTER TABLE scan_sessions ADD COLUMN routerX REAL');
      await db.execute(
          'ALTER TABLE scan_sessions ADD COLUMN routerY REAL');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        floorplanId TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE floorplans (
        id TEXT PRIMARY KEY,
        imagePath TEXT NOT NULL,
        scale REAL NOT NULL,
        anchors TEXT NOT NULL,
        createdAt TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE scan_sessions (
        id TEXT PRIMARY KEY,
        projectId TEXT NOT NULL,
        floorplanId TEXT NOT NULL,
        signalType TEXT NOT NULL,
        networkId TEXT NOT NULL,
        startTime TEXT NOT NULL,
        endTime TEXT,
        state TEXT NOT NULL,
        algorithmVersion INTEGER NOT NULL,
        routerX REAL,
        routerY REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE sample_points (
        id TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        x REAL NOT NULL,
        y REAL NOT NULL,
        rssiDbm REAL NOT NULL,
        variance REAL NOT NULL,
        confidence REAL NOT NULL,
        sourceMode TEXT NOT NULL,
        timestamp TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE recommendations (
        id TEXT PRIMARY KEY,
        sessionId TEXT NOT NULL,
        data TEXT NOT NULL
      )
    ''');
  }

  // ── Projects ──────────────────────────────────────────────────────────────

  Future<void> saveProject(Project project) async {
    await _db.insert(
      'projects',
      project.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Project>> loadProjects() async {
    final rows = await _db.query('projects', orderBy: 'updatedAt DESC');
    return rows.map(Project.fromMap).toList();
  }

  Future<void> deleteProject(String id) async {
    await _db.delete('projects', where: 'id = ?', whereArgs: [id]);
  }

  /// Stamp the project's updatedAt to now, so the home screen shows
  /// the project as recently active after a scan completes.
  Future<void> updateProjectTimestamp(String id) async {
    await _db.update(
      'projects',
      {'updatedAt': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── Floorplans ────────────────────────────────────────────────────────────

  Future<void> saveFloorplan(Floorplan floorplan) async {
    await _db.insert(
      'floorplans',
      {
        'id': floorplan.id,
        'imagePath': floorplan.imagePath,
        'scale': floorplan.scalePixelsPerMeter,
        'anchors': jsonEncode(floorplan.anchorPoints.map((a) => a.toMap()).toList()),
        'createdAt': floorplan.createdAt.toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Floorplan?> loadFloorplan(String id) async {
    final rows =
        await _db.query('floorplans', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final anchors = (jsonDecode(row['anchors'] as String) as List<dynamic>)
        .map((a) => AnchorPoint.fromMap(a as Map<String, dynamic>))
        .toList();
    return Floorplan(
      id: row['id'] as String,
      imagePath: row['imagePath'] as String,
      scalePixelsPerMeter: (row['scale'] as num).toDouble(),
      anchorPoints: anchors,
      createdAt: DateTime.parse(row['createdAt'] as String),
    );
  }

  // ── Scan Sessions ─────────────────────────────────────────────────────────

  Future<void> saveSession(ScanSession session) async {
    await _db.insert(
      'scan_sessions',
      session.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ScanSession>> loadSessionsForProject(String projectId) async {
    final rows = await _db.query(
      'scan_sessions',
      where: 'projectId = ?',
      whereArgs: [projectId],
      orderBy: 'startTime DESC',
    );
    return rows.map(ScanSession.fromMap).toList();
  }

  // ── Sample Points ─────────────────────────────────────────────────────────

  Future<void> saveSamplePoints(List<SamplePoint> points) async {
    final batch = _db.batch();
    for (final p in points) {
      batch.insert(
        'sample_points',
        p.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<SamplePoint>> loadSamplePoints(String sessionId) async {
    final rows = await _db.query(
      'sample_points',
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return rows.map(SamplePoint.fromMap).toList();
  }

  // ── Recommendations ───────────────────────────────────────────────────────

  Future<void> saveRecommendations(
      String sessionId, List<Recommendation> recs) async {
    await _db.delete(
        'recommendations', where: 'sessionId = ?', whereArgs: [sessionId]);
    final batch = _db.batch();
    for (int i = 0; i < recs.length; i++) {
      batch.insert('recommendations', {
        'id': '$sessionId-$i',
        'sessionId': sessionId,
        'data': jsonEncode(recs[i].toMap()),
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<Recommendation>> loadRecommendations(String sessionId) async {
    final rows = await _db.query(
      'recommendations',
      where: 'sessionId = ?',
      whereArgs: [sessionId],
    );
    return rows.map((r) {
      final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
      return Recommendation.fromMap(data);
    }).toList();
  }

  Future<void> close() => _db.close();
}
