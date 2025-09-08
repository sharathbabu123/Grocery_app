// lib/inventory_item.dart



// An enum to represent different categories for better organization.
enum ItemCategory {
  produce,
  dairy,
  pantry,
  spices,
  frozen,
  beverages,
  other,
}

// Helper to get a display name for the enum
extension CategoryExtension on ItemCategory {
  String get displayName {
    // A simple way to capitalize the first letter
    return this.name[0].toUpperCase() + this.name.substring(1);
  }
}

// The main data class for an inventory item.
class InventoryItem {
  String id;
  String name;
  int quantity;
  DateTime? expiryDate;
  ItemCategory category;

  InventoryItem({
    required this.id,
    required this.name,
    this.quantity = 1,
    this.expiryDate,
    this.category = ItemCategory.other,
  });
}