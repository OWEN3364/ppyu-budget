import 'dart:async';

import 'package:ppyu_budget/features/ledger/account_repository.dart';
import 'package:ppyu_budget/features/ledger/category_repository.dart';
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';
import 'package:ppyu_budget/features/notification_capture/notification_capture_service.dart';
import 'package:ppyu_budget/features/notification_capture/notification_parser.dart';

class NotificationAutoSaveService {
  NotificationAutoSaveService({
    required Stream<RawNotification> notifications,
    required this.householdId,
    required this.memberId,
    required this.accountRepository,
    required this.categoryRepository,
    required this.transactionRepository,
  }) : _notifications = notifications;

  final Stream<RawNotification> _notifications;
  final String householdId;
  final String memberId;
  final AccountRepository accountRepository;
  final CategoryRepository categoryRepository;
  final TransactionRepository transactionRepository;

  StreamSubscription<RawNotification>? _subscription;

  void start() {
    // ponytail: pause/resume serializes handling so two notifications can't
    // interleave and both pass the "account doesn't exist" check before
    // either finishes creating it (no unique constraint on accounts(name)).
    _subscription = _notifications.listen((n) {
      _subscription?.pause();
      _handle(n).whenComplete(() => _subscription?.resume());
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _handle(RawNotification notification) async {
    final parsed = NotificationParser.parse(notification.packageName, notification.text);
    if (parsed == null) return;

    final accounts = await accountRepository.list(householdId);
    final existing = accounts.where((a) => a.name == parsed.issuerName);
    final accountId = existing.isNotEmpty
        ? existing.first.id
        : (await accountRepository.create(householdId, parsed.issuerName, 'card')).id;

    final categories = await categoryRepository.list(householdId, type: 'expense');
    final fallbackCategory = categories.where((c) => c.name == '기타');
    final categoryId = fallbackCategory.isNotEmpty
        ? fallbackCategory.first.id
        : (categories.isNotEmpty ? categories.first.id : null);
    if (categoryId == null) return;

    await transactionRepository.create(
      householdId: householdId,
      accountId: accountId,
      categoryId: categoryId,
      memberId: memberId,
      type: 'expense',
      amount: parsed.amount,
      merchant: parsed.merchant,
      source: 'notification_auto',
    );
  }
}
