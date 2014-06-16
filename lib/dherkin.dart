library dherkin;

import "dart:io";
import "dart:async";
import "dart:mirrors";

import 'package:args/args.dart';
import "package:log4dart/log4dart.dart";
import "package:worker/worker.dart";

part "src/gherkin_model.dart";
part "src/gherkin_parser.dart";
part "src/outputter.dart";

Logger _log = LoggerFactory.getLogger("dherkin");

var _runTags = [];

final _NOTFOUND = new RegExp("###");

Map _stepRunners = {
    _NOTFOUND : (ctx, params, named) => throw new StepDefUndefined()
};

/**
 * Runs specified gherking files with provided flags
 */

void run(args) {
  LoggerFactory.config[".*"].debugEnabled = false;
  var options = _parseArguments(args);

  if (options["tags"] != null) {
    _runTags = options["tags"].split(",");
  }

  var worker = new Worker(spawnLazily: false, poolSize: Platform.numberOfProcessors);

  var featureFiles = options.rest;

  _scan().whenComplete(() {
    featureFiles.forEach((filePath) {
      worker.handle(new GherkinParserTask(new File(filePath))).then((feature) {
        feature.execute(worker).whenComplete(() => _log.debug("Done processing feature ${feature.name}"));
      });
    });
  });
}

//  Scans the entirety of the vm for step definitions executables
//  TODO Refactor to be less convoluted

Future _scan() {
  Completer comp = new Completer();
  Future.forEach(currentMirrorSystem().libraries.values, (LibraryMirror lib) {
    return new Future.sync(() {
      Future.forEach(lib.declarations.values.where((DeclarationMirror dm) => dm is MethodMirror), (MethodMirror mm) {
        return new Future.sync(() {
          var filteredMetadata = mm.metadata.where((InstanceMirror im) => im.reflectee is StepDef);
          Future.forEach(filteredMetadata, (InstanceMirror im) {
            _log.debug(im.reflectee.verbiage);

            _stepRunners[new RegExp(im.reflectee.verbiage)] = (ctx, params, Map namedParams) {
              _log.debug("Executing ${mm.simpleName} with params: ${[ctx, params]} named: ${namedParams}");
              var converted = namedParams.keys.map((key) => new Symbol(key));
              lib.invoke(mm.simpleName, [ctx, params], new Map.fromIterables(converted, namedParams.values));
            };
          });
        });
      });
    });
  }).whenComplete(() => comp.complete(""));

  return comp.future;
}


/**
 * Parses command line arguments
 */

ArgResults _parseArguments(args) {
  var argParser = new ArgParser();
  argParser.addFlag('junit', defaultsTo: true);
  argParser.addOption("tags");
  return argParser.parse(args);
}

bool _tagsMatch(tags) {
  return _runTags.isEmpty || tags.any((element) => _runTags.contains(element));
}