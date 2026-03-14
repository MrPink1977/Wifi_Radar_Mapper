import 'dart:ui';

enum RecommendationType {
  bestGateway,
  bestMeshExtender,
  deadZone,
  comparisonTrust,
}

class Recommendation {
  final RecommendationType type;
  final Offset position; // real-world meters
  final double score; // 0.0–1.0
  final String title;
  final String description;

  const Recommendation({
    required this.type,
    required this.position,
    required this.score,
    required this.title,
    required this.description,
  });

  /// Icon label shown on the heatmap overlay.
  String get markerLabel {
    switch (type) {
      case RecommendationType.bestGateway:
        return '📡';
      case RecommendationType.bestMeshExtender:
        return '🔁';
      case RecommendationType.deadZone:
        return '⚠️';
      case RecommendationType.comparisonTrust:
        return '✅';
    }
  }

  Map<String, dynamic> toMap() => {
        'type': type.name,
        'x': position.dx,
        'y': position.dy,
        'score': score,
        'title': title,
        'description': description,
      };

  factory Recommendation.fromMap(Map<String, dynamic> m) => Recommendation(
        type: RecommendationType.values.firstWhere(
          (e) => e.name == m['type'],
          orElse: () => RecommendationType.bestGateway,
        ),
        position: Offset((m['x'] as num).toDouble(), (m['y'] as num).toDouble()),
        score: (m['score'] as num).toDouble(),
        title: m['title'] as String,
        description: m['description'] as String,
      );
}
