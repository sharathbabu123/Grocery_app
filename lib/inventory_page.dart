// lib/InventoryPage.dart

import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // Add this to your pubspec.yaml for date formatting

import 'inventory_item.dart';

class InventoryPage extends StatefulWidget {
  final List<String> detectedItems;

  const InventoryPage({Key? key, required this.detectedItems}) : super(key: key);

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  late List<InventoryItem> _inventoryList;
  final TextEditingController _manualAddController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Convert the initial list of strings into our new InventoryItem objects
    _inventoryList = widget.detectedItems.map((name) {
      return InventoryItem(
        id: DateTime.now().millisecondsSinceEpoch.toString() + name,
        name: name,
      );
    }).toList();
  }

  @override
  void dispose() {
    _manualAddController.dispose();
    super.dispose();
  }

  Future<void> _selectExpiryDate(InventoryItem item) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: item.expiryDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2101),
    );
    if (picked != null && picked != item.expiryDate) {
      setState(() {
        item.expiryDate = picked;
      });
    }
  }

  void _addItem(String name) {
    if (name.trim().isEmpty) return;
    setState(() {
      _inventoryList.add(
        InventoryItem(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          name: name.trim(),
        ),
      );
    });
    Navigator.of(context).pop(); // Close the dialog
    _manualAddController.clear();
  }

  void _showManualAddDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Add Item Manually'),
          content: TextField(
            controller: _manualAddController,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Enter item name"),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop();
                _manualAddController.clear();
              },
            ),
            ElevatedButton(
              child: const Text('Add'),
              onPressed: () => _addItem(_manualAddController.text),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Confirm Inventory'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showManualAddDialog,
            tooltip: 'Add Item Manually',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _inventoryList.length,
              itemBuilder: (context, index) {
                final item = _inventoryList[index];
                final quantityController = TextEditingController(text: item.quantity.toString());

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(item.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () {
                                setState(() {
                                  _inventoryList.removeAt(index);
                                });
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            // Quantity Input
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: quantityController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Quantity',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (value) {
                                  item.quantity = int.tryParse(value) ?? 1;
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            // Category Dropdown
                            Expanded(
                              flex: 3,
                              child: DropdownButtonFormField<ItemCategory>(
                                value: item.category,
                                decoration: const InputDecoration(
                                  labelText: 'Category',
                                  border: OutlineInputBorder(),
                                ),
                                items: ItemCategory.values.map((category) {
                                  return DropdownMenuItem(
                                    value: category,
                                    child: Text(category.displayName),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  setState(() {
                                    item.category = value!;
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Expiry Date Picker
                        ListTile(
                          leading: const Icon(Icons.calendar_today),
                          title: Text(
                            item.expiryDate == null
                                ? 'Select Expiry Date'
                                : 'Expires: ${DateFormat.yMMMd().format(item.expiryDate!)}',
                          ),
                          onTap: () => _selectExpiryDate(item),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                            side: BorderSide(color: Colors.grey.shade400)
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              onPressed: () {
                // Return the confirmed items to the CameraPage.
                Navigator.of(context).pop<List<InventoryItem>>(_inventoryList);
              },
              child: const Text('Save Inventory', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }
}
