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

  /// Checks every due recurring-transaction template for [householdId] and
  /// creates the transactions it's behind on, one at a time, using a
  /// compare-and-swap on `next_run_at` after each create so concurrent
  /// catch-up runs (e.g. both household members opening the app the same
  /// day) can duplicate at most the single occurrence each session was
  /// already mid-creating when the race was detected — never the whole
  /// overdue batch. Returns how many transactions were created (0 if
  /// nothing was due).
  ///
  /// [now] defaults to the real current time; tests pass a fixed value so
  /// the "is this due yet" cutoff is deterministic.
  Future<int> run(String householdId, {DateTime? now}) async {
    final cutoff = now ?? DateTime.now();
    final templates = await recurringTransactionRepository.list(householdId);
    var createdCount = 0;

    for (final template in templates) {
      var cursor = template.nextRunAt;
      var countForTemplate = 0;
      while (!cursor.isAfter(cutoff) && countForTemplate < maxCatchUpOccurrences) {
        final occurrenceDate = cursor;
        await transactionRepository.create(
          householdId: householdId,
          accountId: template.accountId,
          categoryId: template.categoryId,
          memberId: template.createdBy,
          type: template.type,
          amount: template.amount,
          memo: template.memo,
          source: 'recurring_auto',
          occurredAt: occurrenceDate,
        );
        final nextCursor = advanceOccurrence(template.intervalRule, occurrenceDate);
        final advanced = await recurringTransactionRepository.advanceNextRunAt(
          template.id,
          nextCursor,
          expectedCurrentNextRunAt: occurrenceDate,
        );
        createdCount++;
        countForTemplate++;
        if (!advanced) break; // another session already advanced past this point — stop here
        cursor = nextCursor;
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
