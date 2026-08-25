class Category {
  const Category({
    required this.id,
    required this.name,
    required this.type,
    this.icon,
    this.isDefault = false,
  });

  final String id;
  final String name;
  final String type;
  final String? icon;
  final bool isDefault;

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        icon: json['icon'] as String?,
        isDefault: json['is_default'] as bool? ?? false,
      );
}
