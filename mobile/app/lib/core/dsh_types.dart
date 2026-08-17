/// Business types mirrored from the dsh web API surface (see
/// docs/mobile-agent-monitor.md §1) as consumed through the relay tunnel.
library;

/// One `session.list` entry (`SessionSummary` in dsh).
class SessionSummary {
  final String sessionId;
  final int updatedAt;
  final bool running;
  final bool conversationStarted;
  final String? title;

  const SessionSummary({
    required this.sessionId,
    required this.updatedAt,
    required this.running,
    required this.conversationStarted,
    this.title,
  });

  factory SessionSummary.fromJson(Map<String, dynamic> json) => SessionSummary(
        sessionId: json['sessionId'] as String,
        updatedAt: (json['updatedAt'] as num).toInt(),
        running: json['running'] as bool? ?? false,
        conversationStarted: json['conversationStarted'] as bool? ?? true,
        title: json['title'] as String?,
      );
}

/// Background job view (`JobView` in dsh): bash/subagent/… tasks.
class JobView {
  final String id;
  final String kind;
  final String label;
  final String status; // running | stopping | completed | killed | failed
  final String? detail;
  final int startedAt;
  final int? finishedAt;

  const JobView({
    required this.id,
    required this.kind,
    required this.label,
    required this.status,
    this.detail,
    required this.startedAt,
    this.finishedAt,
  });

  factory JobView.fromJson(Map<String, dynamic> json) => JobView(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? '',
        label: json['label'] as String? ?? '',
        status: json['status'] as String? ?? '',
        detail: json['detail'] as String?,
        startedAt: (json['startedAt'] as num?)?.toInt() ?? 0,
        finishedAt: (json['finishedAt'] as num?)?.toInt(),
      );

  bool get isActive => status == 'running' || status == 'stopping';
}

/// A frame pushed on the mux/host SSE stream (narrow `server-request` form
/// translated by the bridge: `{rpcId, method, payload}`).
class SseFrame {
  final String? rpcId;
  final String? method;
  final Map<String, dynamic> payload;

  const SseFrame({this.rpcId, this.method, required this.payload});

  factory SseFrame.fromJson(Map<String, dynamic> json) => SseFrame(
        rpcId: json['rpcId'] as String?,
        method: json['method'] as String?,
        payload: (json['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
      );

  String get type => payload['type'] as String? ?? '';
  String? get sessionId => payload['sessionId'] as String?;

  /// For `session/event` frames: the inner `SessionEvent` map.
  Map<String, dynamic>? get event =>
      payload['event'] as Map<String, dynamic>?;

  /// For `session/jobs` frames.
  List<JobView> get jobs => (payload['jobs'] as List? ?? [])
      .map((j) => JobView.fromJson((j as Map).cast<String, dynamic>()))
      .toList();

  /// For `approval/requested`.
  String? get approvalId => payload['approvalId'] as String?;
  String? get toolName => payload['toolName'] as String?;

  /// For `session/event` inner events.
  String? get eventType => event?['type'] as String?;
  Map<String, dynamic>? get eventData =>
      event?['data'] as Map<String, dynamic>?;

  /// Human-friendly one-line summary for list rendering.
  String get summary {
    switch (type) {
      case 'session/event':
        switch (eventType) {
          case 'step/start':
            return '▶ ${eventData?['label'] ?? '步骤开始'}';
          case 'step/end':
            return '✓ 步骤完成';
          case 'assistant/chunk':
            return (eventData?['text'] as String? ?? '').trim();
          case 'assistant/message':
            return (eventData?['content']?.toString() ?? '').trim();
          case 'tool/call':
            return '🔧 ${eventData?['name'] ?? '工具调用'}';
          case 'tool/result':
            return '✅ 工具结果';
          case 'approval/asked':
            return '🛂 需要审批';
          case 'command/run':
            return '⌘ ${eventData?['command'] ?? ''}';
          default:
            return eventType ?? type;
        }
      case 'approval/requested':
        return '🛂 审批请求: $toolName';
      case 'session/subscribed':
        return '已连接会话';
      case 'session/jobs':
        return '任务 ${jobs.where((j) => j.isActive).length} 运行中';
      default:
        return type;
    }
  }
}
