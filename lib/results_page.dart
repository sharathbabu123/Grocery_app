import 'package:flutter/material.dart';

class ResultsPage extends StatelessWidget {
  final List<String> detectedItems;

  const ResultsPage({Key? key, required this.detectedItems}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Detected Grocery Items'),
      ),
      body: detectedItems.isEmpty
          ? const Center(
              child: Text(
                'No items were detected.',
                style: TextStyle(fontSize: 18),
              ),
            )
          : ListView.builder(
              itemCount: detectedItems.length,
              itemBuilder: (context, index) {
                final item = detectedItems[index];
                return ListTile(
                  title: Text(
                    item,
                    style: const TextStyle(fontSize: 16),
                  ),
                );
              },
            ),
    );
  }
}