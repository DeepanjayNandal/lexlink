import 'package:flutter/material.dart';
import '../../features/p2p/connection_diagnostic_service.dart';
import '../../core/p2p/signaling/signaling_config.dart';

/// Screen for diagnosing connection issues
class ConnectionDiagnosticScreen extends StatefulWidget {
  final String? serverUrl;

  const ConnectionDiagnosticScreen({
    Key? key,
    this.serverUrl,
  }) : super(key: key);

  @override
  _ConnectionDiagnosticScreenState createState() =>
      _ConnectionDiagnosticScreenState();
}

class _ConnectionDiagnosticScreenState
    extends State<ConnectionDiagnosticScreen> {
  final ConnectionDiagnosticService _diagnosticService =
      ConnectionDiagnosticService();

  bool _isRunning = false;
  Map<String, dynamic>? _results;
  String? _error;
  late String _serverUrl;

  @override
  void initState() {
    super.initState();
    // Use provided URL or default from config
    _serverUrl = widget.serverUrl ?? 'ws://192.168.1.6:9090/ws';
    _runDiagnostic();
  }

  Future<void> _runDiagnostic() async {
    if (_isRunning) return;

    setState(() {
      _isRunning = true;
      _error = null;
      _results = null;
    });

    try {
      final results = await _diagnosticService.runDiagnostic(_serverUrl);
      setState(() {
        _results = results;
        _isRunning = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Diagnostics'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildServerInfo(),
            const SizedBox(height: 16),
            _isRunning
                ? _buildLoadingIndicator()
                : _error != null
                    ? _buildErrorDisplay()
                    : _results != null
                        ? _buildResultsDisplay()
                        : const SizedBox(),
            const SizedBox(height: 16),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildServerInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Server Information',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text('URL: $_serverUrl'),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingIndicator() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Running diagnostic tests...'),
        ],
      ),
    );
  }

  Widget _buildErrorDisplay() {
    return Card(
      color: Colors.red.shade100,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Error',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(_error ?? 'Unknown error'),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsDisplay() {
    final status = _results!['status'] as String;
    final isSuccess = status == 'success';

    return Expanded(
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              color: isSuccess ? Colors.green.shade100 : Colors.orange.shade100,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isSuccess ? Icons.check_circle : Icons.warning,
                          color: isSuccess ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Status: ${status.toUpperCase()}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    if (!isSuccess && _results!['primaryIssue'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          'Issue: ${_results!['primaryIssue']}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _buildTestResultCard(
              'Internet Connectivity',
              _results!['internetConnectivity'] == true,
              details:
                  'Internet connection is ${_results!['internetConnectivity'] == true ? 'available' : 'unavailable'}',
            ),
            _buildTestResultCard(
              'Server Reachable',
              _results!['serverReachable'] == true,
              details:
                  'Server is ${_results!['serverReachable'] == true ? 'reachable' : 'unreachable'}',
            ),
            if (_results!['webSocketTest'] != null) ...[
              _buildWebSocketTestResults(_results!['webSocketTest']),
            ],
            const SizedBox(height: 16),
            const Text(
              'Raw Results:',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _results.toString(),
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebSocketTestResults(Map<String, dynamic> wsTest) {
    final success = wsTest['success'] == true;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'WebSocket Connection Test',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _buildTestItem(
                'Connection Established', wsTest['connectSuccess'] == true),
            _buildTestItem(
                'Registration Sent', wsTest['registerSuccess'] == true),
            _buildTestItem(
                'Welcome Message Received', wsTest['welcomeReceived'] == true),
            _buildTestItem(
                'Pong Response Received', wsTest['pongReceived'] == true),
            if (wsTest['error'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  'Error: ${wsTest['error']}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestResultCard(String title, bool success, {String? details}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(
              success ? Icons.check_circle : Icons.error,
              color: success ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (details != null) Text(details),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestItem(String label, bool success) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(
            success ? Icons.check_circle : Icons.cancel,
            color: success ? Colors.green : Colors.red,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ElevatedButton(
          onPressed: _isRunning ? null : _runDiagnostic,
          child: const Text('Run Diagnostics Again'),
        ),
        const SizedBox(width: 16),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
