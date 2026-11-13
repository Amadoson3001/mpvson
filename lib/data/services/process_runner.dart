import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of executing an external process.
class ProcessExecutionResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;

  const ProcessExecutionResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsed,
  });

  bool get isSuccess => exitCode == 0;

  @override
  String toString() =>
      'ProcessExecutionResult(exitCode: $exitCode, elapsed: ${elapsed.inMilliseconds}ms)';
}

/// Abstract contract for executing system processes, enabling easy testing and mocking.
abstract class ProcessRunner {
  const ProcessRunner();

  /// Default production process runner backed by [Process.run] and [Process.start].
  static const ProcessRunner standard = StandardProcessRunner();

  /// Runs an executable to completion and returns the captured output.
  Future<ProcessExecutionResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
    Duration? timeout,
  });

  /// Starts an asynchronous external process.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

/// Standard production implementation of [ProcessRunner].
class StandardProcessRunner extends ProcessRunner {
  const StandardProcessRunner();

  @override
  Future<ProcessExecutionResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();
    var future = Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: stderrEncoding,
    );

    if (timeout != null) {
      future = future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'Process "$executable" timed out after ${timeout.inMilliseconds}ms',
          timeout,
        ),
      );
    }

    final result = await future;
    return ProcessExecutionResult(
      exitCode: result.exitCode,
      stdout: result.stdout?.toString() ?? '',
      stderr: result.stderr?.toString() ?? '',
      elapsed: stopwatch.elapsed,
    );
  }

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
  }
}
