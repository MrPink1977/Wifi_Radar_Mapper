/// Top-level container grouping a floor plan with its scan sessions.
class Project {
  final String id;
  String name;
  final String floorplanId;
  final DateTime createdAt;
  DateTime updatedAt;

  Project({
    required this.id,
    required this.name,
    required this.floorplanId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'floorplanId': floorplanId,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Project.fromMap(Map<String, dynamic> m) => Project(
        id: m['id'] as String,
        name: m['name'] as String,
        floorplanId: m['floorplanId'] as String,
        createdAt: DateTime.parse(m['createdAt'] as String),
        updatedAt: DateTime.parse(m['updatedAt'] as String),
      );
}
