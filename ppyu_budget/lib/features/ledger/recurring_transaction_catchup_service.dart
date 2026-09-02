import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:ppyu_budget/core/supabase_client.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_repository.dart';
import 'package:ppyu_budget/features/ledger/recurring_transaction_schedule.dart';
import 'package:ppyu_budget/features/ledger/transaction_form_screen.dart' show transactionRepository;
import 'package:ppyu_budget/features/ledger/transaction_repository.dart';

class RecurringTransactionCatchUpService {
  RecurringTransactionCatchUpService({
    required this.recurringTransactionRepository,
    required this.transactionRepository,
  });

  final RecurringTransactionRepository recurringTransactionRepository;
  final TransactionRepository transactionRepository;

  /// Silently creates every occurrence an `auto_register=true` template is
  /// behind on, for [householdId]. Concurrency is no longer this service's
  /// concern: `transactions_recurring_occurrence_unique` (a DB-level partial
  /// unique index) makes a duplicate insert fail outright, so two
  /// overlapping runs (e.g. both household members opening the app at the
  /// same moment) each simply attempt every missing date, and whichever
  /// insert loses the race is rejected by Postgres and ignored here.
  /// `auto_register=false` templates are skipped entirely — their missing
  /// occurrences surface in the todo screen (Task 6) instead. Returns how
  /// many transactions were actually created.
  ///
  /// [now] defaults to the real current time; tests pass a fixed value so
  /// the "is this due yet" cutoff is deterministic.
  Future<int> run(String householdId, {DateTime? now}) async {
    final cutoff = now ?? DateTime.now();
    final templates = await recurringTransactionRepository.list(householdId);
    var createdCount = 0;

    for (final template in templates.where((t) => t.autoRegister)) {
      final existing = await transactionRepository.occurredAtsForRecurringTransaction(template.id);
      final missing = missingOccurrences(template, now: cutoff, existingOccurredAt: existing);
      for (final occurrenceDate in missing) {
        try {
          await transactionRepository.create(
            householdId: householdId,
            accountId: template.accountId,
            categoryId: template.categoryId,
            memberId: template.ownerMemberId,
            type: template.type,
            amount: template.amount,
            memo: template.memo,
            source: 'recurring_auto',
            occurredAt: occurrenceDate,
            recurringTransactionId: template.id,
          );
          createdCount++;
        } on PostgrestException catch (e) {
          // 23505 = unique_violation — another session created this exact
          // occurrence between our read and our insert. See Global
          // Constraints for why this is the correct check.
          if (e.code != '23505') rethrow;
        }
      }
    }

    return createdCount;
  }
}

final recurringTransactionRepository = RecurringTransactionRepository(client: supabase);
final recurringTransactionCatchUpService = RecurringTransactionCatchUpService(
  recurringTransactionRepository: recurringTransactionRepository,
  transactionRepository: transactionRepository,
);
