import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/floorplan.dart';
import '../models/project.dart';
import '../services/storage_service.dart';

const _uuid = Uuid();

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Project> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    final storage = context.read<StorageService>();
    final projects = await storage.loadProjects();
    if (mounted) {
      setState(() {
        _projects = projects;
        _loading = false;
      });
    }
  }

  Future<void> _createProject(BuildContext context) async {
    final name = await _showNameDialog(context);
    if (name == null || name.isEmpty) return;

    final storage = context.read<StorageService>();
    final floorplanId = _uuid.v4();
    final projectId = _uuid.v4();

    // Create a placeholder floorplan — user will configure it on the next screen.
    final floorplan = Floorplan(
      id: floorplanId,
      imagePath: '',
    );
    await storage.saveFloorplan(floorplan);

    final project = Project(
      id: projectId,
      name: name,
      floorplanId: floorplanId,
    );
    await storage.saveProject(project);

    if (mounted) {
      context.push('/setup?projectId=$projectId');
    }
  }

  Future<String?> _showNameDialog(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Project'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Home – Ground Floor',
            border: OutlineInputBorder(),
          ),
          textCapitalization: TextCapitalization.words,
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SIGNALMAP'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showAbout(context),
            tooltip: 'About',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? _buildEmptyState(context, theme)
              : _buildProjectList(context, theme),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createProject(context),
        icon: const Icon(Icons.add),
        label: const Text('New Project'),
        backgroundColor: theme.colorScheme.primary,
        foregroundColor: Colors.black,
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_find,
                size: 80, color: theme.colorScheme.primary.withOpacity(0.5)),
            const SizedBox(height: 24),
            Text('No projects yet',
                style: theme.textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(
              'Create a project to start mapping\nWi-Fi signal strength in your space.',
              style: theme.textTheme.bodyLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () => _createProject(context),
              icon: const Icon(Icons.add),
              label: const Text('Create First Project'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectList(BuildContext context, ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _loadProjects,
      child: ListView.builder(
        itemCount: _projects.length,
        itemBuilder: (_, i) => _ProjectCard(
          project: _projects[i],
          onTap: () => context.push('/setup?projectId=${_projects[i].id}'),
          onDelete: () async {
            final confirmed = await _confirmDelete(context, _projects[i].name);
            if (confirmed == true) {
              await context.read<StorageService>().deleteProject(_projects[i].id);
              await _loadProjects();
            }
          },
        ),
      ),
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String name) =>
      showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Delete Project?'),
          content: Text('Delete "$name"? This cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );

  void _showAbout(BuildContext context) => showAboutDialog(
        context: context,
        applicationName: 'SignalMap',
        applicationVersion: '0.1.0',
        applicationLegalese: '© 2026',
        children: [
          const SizedBox(height: 12),
          const Text(
            'Turn Wi-Fi signal strength into a floor-plan heatmap '
            'and device placement recommender.',
          ),
        ],
      );
}

class _ProjectCard extends StatelessWidget {
  final Project project;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ProjectCard({
    required this.project,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: theme.colorScheme.primary.withOpacity(0.3)),
          ),
          child: Icon(Icons.wifi_find, color: theme.colorScheme.primary),
        ),
        title: Text(project.name, style: theme.textTheme.titleLarge),
        subtitle: Text(
          'Updated ${_formatDate(project.updatedAt)}',
          style: theme.textTheme.bodyMedium,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chevron_right,
                color: theme.colorScheme.primary.withOpacity(0.5)),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: onDelete,
              tooltip: 'Delete',
            ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    return '${diff.inDays}d ago';
  }
}
