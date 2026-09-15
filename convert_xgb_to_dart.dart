import 'dart:io';

void main() async {
  final file = File('triage_rules_export.csv');
  final lines = await file.readAsLines();

  // trees[target][treeId] = [nodes]
  Map<int, Map<int, List<Map<String, dynamic>>>> trees = {};

  // Skip header
  for (int i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    
    final parts = line.split(',');
    final treeId = int.parse(parts[0]);
    final target = int.parse(parts[1]);
    final nodeId = int.parse(parts[2]);
    final feature = parts[4];
    
    double split = 0.0;
    if (parts[5].isNotEmpty) split = double.parse(parts[5]);
    
    int yesNode = -1;
    if (parts[6].isNotEmpty) yesNode = int.parse(parts[6].split('-')[1]);
    
    int noNode = -1;
    if (parts[7].isNotEmpty) noNode = int.parse(parts[7].split('-')[1]);
    
    int missingNode = -1;
    if (parts[8].isNotEmpty) missingNode = int.parse(parts[8].split('-')[1]);
    
    double gain = 0.0;
    if (parts[9].isNotEmpty) gain = double.parse(parts[9]);

    trees.putIfAbsent(target, () => {});
    trees[target]!.putIfAbsent(treeId, () => []);
    
    trees[target]![treeId]!.add({
      'nodeId': nodeId,
      'feature': feature,
      'split': split,
      'yesNode': yesNode,
      'noNode': noNode,
      'missingNode': missingNode,
      'gain': gain
    });
  }

  // Now generate the dart code
  StringBuffer dartCode = StringBuffer();
  dartCode.writeln('// AUTO-GENERATED NATIVE XGBOOST INFERENCE ENGINE');
  dartCode.writeln('// Do not edit manually. Generated from triage_rules_export.csv');
  dartCode.writeln();
  dartCode.writeln('import \'dart:math\' as math;');
  dartCode.writeln();
  dartCode.writeln('class XgbNode {');
  dartCode.writeln('  final int id;');
  dartCode.writeln('  final String feature;');
  dartCode.writeln('  final double split;');
  dartCode.writeln('  final int yesNode;');
  dartCode.writeln('  final int noNode;');
  dartCode.writeln('  final int missingNode;');
  dartCode.writeln('  final double leafValue;');
  dartCode.writeln('  const XgbNode(this.id, this.feature, this.split, this.yesNode, this.noNode, this.missingNode, this.leafValue);');
  dartCode.writeln('}');
  dartCode.writeln();
  dartCode.writeln('class XgbModel {');
  dartCode.writeln('  // Map of ClassID -> List of Trees (each Tree is a List of Nodes)');
  dartCode.writeln('  static const Map<int, List<List<XgbNode>>> trees = {');

  for (int target in trees.keys.toList()..sort()) {
    dartCode.writeln('    $target: [');
    final targetTrees = trees[target]!;
    for (int treeId in targetTrees.keys.toList()..sort()) {
      dartCode.writeln('      // Tree $treeId');
      dartCode.writeln('      [');
      final nodes = targetTrees[treeId]!;
      for (var node in nodes) {
        String featureString = node['feature'] == 'Leaf' ? '""' : '"${node['feature']}"';
        dartCode.writeln('        XgbNode(${node['nodeId']}, $featureString, ${node['split']}, ${node['yesNode']}, ${node['noNode']}, ${node['missingNode']}, ${node['gain']}),');
      }
      dartCode.writeln('      ],');
    }
    dartCode.writeln('    ],');
  }

  dartCode.writeln('  };');
  dartCode.writeln();
  dartCode.writeln('''
  static List<double> predict(Map<String, double> features) {
    List<double> rawScores = List.filled(trees.length, 0.0);
    
    // Evaluate trees for each class
    for (int classIdx in trees.keys) {
      double classScore = 0.5; // Base margin
      for (var tree in trees[classIdx]!) {
        int currentNodeIdx = 0;
        while (true) {
          var node = tree[currentNodeIdx];
          if (node.feature.isEmpty) { // Leaf node
            classScore += node.leafValue;
            break;
          }
          
          double? featureVal = features[node.feature];
          if (featureVal == null) {
            currentNodeIdx = node.missingNode;
          } else if (featureVal < node.split) {
            currentNodeIdx = node.yesNode;
          } else {
            currentNodeIdx = node.noNode;
          }
        }
      }
      rawScores[classIdx] = classScore;
    }

    // Softmax
    double maxScore = rawScores.reduce(math.max);
    double sum = 0.0;
    for (int i = 0; i < rawScores.length; i++) {
      rawScores[i] = math.exp(rawScores[i] - maxScore);
      sum += rawScores[i];
    }
    for (int i = 0; i < rawScores.length; i++) {
      rawScores[i] /= sum;
    }
    
    return rawScores;
  }
}
''');

  await File('lib/services/xgboost_rules.dart').writeAsString(dartCode.toString());
  print('Generated lib/services/xgboost_rules.dart');
}
