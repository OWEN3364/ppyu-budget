class Account {
  const Account({required this.id, required this.name, required this.type});

  final String id;
  final String name;
  final String type;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
      );
}
