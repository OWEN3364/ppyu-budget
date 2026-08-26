class Tag {
  const Tag({required this.id, required this.name});

  final String id;
  final String name;

  factory Tag.fromJson(Map<String, dynamic> json) => Tag(
        id: json['id'] as String,
        name: json['name'] as String,
      );
}
