// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';

import 'package:args/args.dart';

import '../base/common.dart';
import '../base/file_system.dart';
import '../base/logger.dart';
import '../base/utils.dart';
import '../cache.dart';
import '../dart/analysis.dart';
import '../dart/sdk.dart' as sdk;
import '../globals.dart';
import 'analyze.dart';
import 'analyze_base.dart';

/// An aspect of the [AnalyzeCommand] to perform once time analysis.
class AnalyzeOnce extends AnalyzeBase {
  AnalyzeOnce(
    ArgResults argResults,
    this.repoRoots,
    this.repoPackages, {
    this.workingDirectory,
    this.previewDart2: false,
  }) : super(argResults);

  final List<String> repoRoots;
  final List<Directory> repoPackages;

  /// The working directory for testing analysis using dartanalyzer.
  final Directory workingDirectory;

  final bool previewDart2;

  @override
  Future<Null> analyze() async {
    final String currentDirectory =
        (workingDirectory ?? fs.currentDirectory).path;

    // find directories from argResults.rest
    final Set<String> directories = new Set<String>.from(argResults.rest
        .map<String>((String path) => fs.path.canonicalize(path)));
    if (directories.isNotEmpty) {
      for (String directory in directories) {
        final FileSystemEntityType type = fs.typeSync(directory);

        if (type == FileSystemEntityType.notFound) {
          throwToolExit("'$directory' does not exist");
        } else if (type != FileSystemEntityType.directory) {
          throwToolExit("'$directory' is not a directory");
        }
      }
    }

    if (argResults['flutter-repo']) {
      // check for conflicting dependencies
      final PackageDependencyTracker dependencies =
          new PackageDependencyTracker();
      dependencies.checkForConflictingDependencies(repoPackages, dependencies);

      directories.addAll(repoRoots);

      if (argResults.wasParsed('current-package') &&
          argResults['current-package']) {
        directories.add(currentDirectory);
      }
    } else {
      if (argResults['current-package']) {
        directories.add(currentDirectory);
      }
    }

    if (argResults['dartdocs'] && !argResults['flutter-repo']) {
      throwToolExit(
          'The --dartdocs option is currently only supported with --flutter-repo.');
    }

    if (directories.isEmpty) {
      throwToolExit('Nothing to analyze.', exitCode: 0);
    }

    // analyze all
    final Completer<Null> analysisCompleter = new Completer<Null>();
    final List<AnalysisError> errors = <AnalysisError>[];

    final String sdkPath = argResults['dart-sdk'] ?? sdk.dartSdkPath;

    final AnalysisServer server = new AnalysisServer(
      sdkPath,
      directories.toList(),
      previewDart2: previewDart2,
    );

    StreamSubscription<bool> subscription;
    subscription = server.onAnalyzing.listen((bool isAnalyzing) {
      if (!isAnalyzing) {
        analysisCompleter.complete();
        subscription?.cancel();
        subscription = null;
      }
    });
    server.onErrors.listen((FileAnalysisErrors fileErrors) {
      fileErrors.errors
          .removeWhere((AnalysisError error) => error.type == 'TODO');
      errors.addAll(fileErrors.errors);
    });

    await server.start();
    server.onExit.then((int exitCode) {
      if (!analysisCompleter.isCompleted) {
        analysisCompleter.completeError('analysis server exited: $exitCode');
      }
    });

    Cache.releaseLockEarly();

    // collect results
    final Stopwatch timer = new Stopwatch()..start();
    final String message = directories.length > 1
        ? '${directories.length} ${directories.length == 1 ? 'directory' : 'directories'}'
        : fs.path.basename(directories.first);
    final Status progress = argResults['preamble']
        ? logger.startProgress('Analyzing $message...')
        : null;

    await analysisCompleter.future;
    progress?.cancel();
    timer.stop();

    // report dartdocs
    int undocumentedMembers = 0;

    if (argResults['flutter-repo']) {
      undocumentedMembers = errors.where((AnalysisError error) {
        return error.code == 'public_member_api_docs';
      }).length;

      if (!argResults['dartdocs']) {
        errors.removeWhere(
            (AnalysisError error) => error.code == 'public_member_api_docs');
      }
    }

    // emit benchmarks
    if (isBenchmarking) {
      writeBenchmark(timer, errors.length, undocumentedMembers);
    }

    // report results
    dumpErrors(
        errors.map<String>((AnalysisError error) => error.toLegacyString()));

    if (errors.isNotEmpty && argResults['preamble']) {
      printStatus('');
    }
    errors.sort();
    for (AnalysisError error in errors) {
      printStatus(error.toString());
    }

    final String seconds =
        (timer.elapsedMilliseconds / 1000.0).toStringAsFixed(1);

    // We consider any level of error to be an error exit (we don't report different levels).
    if (errors.isNotEmpty) {
      printStatus('');

      printStatus(
          '${errors.length} ${pluralize('issue', errors.length)} found. (ran in ${seconds}s)');

      if (undocumentedMembers > 0) {
        throwToolExit('[lint] $undocumentedMembers public '
            '${ undocumentedMembers == 1
            ? "member lacks"
            : "members lack" } documentation');
      } else {
        throwToolExit(null);
      }
    }

    if (argResults['congratulate']) {
      if (undocumentedMembers > 0) {
        printStatus('No issues found! (ran in ${seconds}s; '
            '$undocumentedMembers public ${ undocumentedMembers ==
            1 ? "member lacks" : "members lack" } documentation)');
      } else {
        printStatus('No issues found! (ran in ${seconds}s)');
      }
    }
  }
}
