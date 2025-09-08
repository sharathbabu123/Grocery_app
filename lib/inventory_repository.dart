import 'package:cloud_firestore/cloud_firestore.dart';
import 'inventory_item.dart';

class InventoryRepository {
  InventoryRepository(this._firestore);
  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _itemsCol(String uid) =>
      _firestore.collection('users').doc(uid).collection('inventory');

  String _docIdFor(InventoryItem item) {
    // Prefer existing id if provided; else slugify the name
    final id = item.id.trim().isNotEmpty ? item.id : _slug(item.name);
    return id;
  }

  static String _slug(String value) {
    final lower = value.toLowerCase().trim();
    final cleaned = lower.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return cleaned.replaceAll(RegExp(r'_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  }

  Map<String, dynamic> _toMap(InventoryItem item) {
    return {
      'name': item.name,
      'lowerName': item.name.toLowerCase(),
      'quantity': item.quantity,
      'category': item.category.name,
      if (item.expiryDate != null) 'expiryDate': Timestamp.fromDate(item.expiryDate!),
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  InventoryItem _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final categoryName = (data['category'] as String?) ?? 'other';
    ItemCategory category = ItemCategory.other;
    for (final c in ItemCategory.values) {
      if (c.name == categoryName) {
        category = c;
        break;
      }
    }
    return InventoryItem(
      id: doc.id,
      name: (data['name'] as String?) ?? doc.id,
      quantity: (data['quantity'] is int)
          ? (data['quantity'] as int)
          : ((data['quantity'] as num?)?.toInt() ?? 0),
      expiryDate: (data['expiryDate'] is Timestamp)
          ? (data['expiryDate'] as Timestamp).toDate()
          : null,
      category: category,
    );
  }

  Stream<List<InventoryItem>> streamInventory(String uid) {
    return _itemsCol(uid)
        .orderBy('lowerName')
        .snapshots()
        .map((snap) => snap.docs.map(_fromDoc).toList());
  }

  Future<void> upsertDetectedItems(String uid, List<InventoryItem> items) async {
    if (items.isEmpty) return;
    final batch = _firestore.batch();
    for (final item in items) {
      final docRef = _itemsCol(uid).doc(_docIdFor(item));
      batch.set(docRef, {
        'name': item.name,
        'lowerName': item.name.toLowerCase(),
        'category': item.category.name,
        if (item.expiryDate != null) 'expiryDate': Timestamp.fromDate(item.expiryDate!),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batch.update(docRef, {
        'quantity': FieldValue.increment(item.quantity),
      });
    }
    await batch.commit();
  }

  Future<void> addOrUpdateItem(String uid, InventoryItem item) async {
    final docRef = _itemsCol(uid).doc(_docIdFor(item));
    await docRef.set(_toMap(item), SetOptions(merge: true));
  }

  Future<void> setQuantity(String uid, String id, int quantity) async {
    await _itemsCol(uid).doc(id).set({
      'quantity': quantity,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> incrementQuantity(String uid, String id, int delta) async {
    await _itemsCol(uid).doc(id).set({
      'quantity': FieldValue.increment(delta),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> deleteItem(String uid, String id) async {
    await _itemsCol(uid).doc(id).delete();
  }
}

